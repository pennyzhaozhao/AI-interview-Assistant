import SwiftUI
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private enum DensityMode: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case balanced = "Balanced"
    case large = "Large"

    var id: String { rawValue }
    var questionSize: CGFloat {
        switch self {
        case .compact: return 18
        case .balanced: return 20
        case .large: return 24
        }
    }
    var answerSize: CGFloat {
        switch self {
        case .compact: return 22
        case .balanced: return 26
        case .large: return 36
        }
    }
}

private enum OverlayAudioMode: CaseIterable {
    case microphone, system, muted
}

private enum ScreenshotSubmissionState: Equatable {
    case idle, loading, success
}

struct PrompterOverlayView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    @Bindable var coordinator: ReceiverCoordinator
    var onClose: () -> Void
    var onKB: () -> Void
    var onHistory: () -> Void

    @State private var pulse = false
    @State private var now = Date()
    @State private var density: DensityMode = .balanced
    @State private var showCodeLanguageEditor = false
    @State private var showJumpToLatest = false
    @State private var audioMode: OverlayAudioMode = .microphone
    @State private var screenshotSubmissionState: ScreenshotSubmissionState = .idle
    @State private var islandExpansion: CGFloat = 0
    @State private var islandContentVisible = false
    @State private var isIslandMinimized = false
    @State private var expandedIslandHeight: CGFloat = 240
    @State private var resizeStartHeight: CGFloat?
    @State private var resizeStartMouseY: CGFloat?
    @State private var browsedTurnIndex: Int?
    @State private var modeToast: String?
    #if os(macOS)
    @AppStorage(AppPreferenceKey.hiddenFromScreenCapture) private var isHiddenFromCapture = true
    @AppStorage(AppPreferenceKey.screenshotHotkey) private var screenshotHotkey = HotkeyManager.screenshotDefaultHotkey
    @AppStorage(AppPreferenceKey.screenshotMode) private var screenshotModeRaw = ScreenshotMode.presetRegion.rawValue
    @StateObject private var screenshotCapture = ScreenshotCapture()
    @State private var showSetupRegionAlert = false
    #endif
    private let updateTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if isCompact {
            mobileBody
        } else {
            desktopBody
        }
    }

    private var desktopBody: some View {
        GeometryReader { geometry in
            if isIslandMinimized {
                minimizedIsland
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            } else {
                let collapsedWidth: CGFloat = 200
                let collapsedHeight: CGFloat = 37
                let currentWidth = collapsedWidth + (geometry.size.width - collapsedWidth) * islandExpansion
                let currentHeight = collapsedHeight + (geometry.size.height - collapsedHeight) * islandExpansion
                let currentTopInset = 8 + (16 - 8) * islandExpansion
                let currentBottomRadius = 8 + (18 - 8) * islandExpansion

                ZStack(alignment: .top) {
                    TextreamDynamicIslandShape(
                        topInset: currentTopInset,
                        bottomRadius: currentBottomRadius
                    )
                    .fill(Color.black.opacity(0.78))

                    VStack(spacing: 0) {
                        Color.clear.frame(height: notchMenuBarHeight)
                        notchHeader
                        compactAnswerArea
                        islandToolbar
                    }
                    .padding(.horizontal, 16)
                    .frame(width: currentWidth, height: geometry.size.height, alignment: .top)
                    .clipped()
                    .opacity(islandContentVisible ? 1 : 0)
                    .allowsHitTesting(islandContentVisible)
                    .accessibilityHidden(!islandContentVisible)
                }
                .overlay(alignment: .bottom) {
                    islandResizeHandle
                        .opacity(islandContentVisible ? 1 : 0)
                }
                .frame(width: currentWidth, height: currentHeight, alignment: .top)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .foregroundStyle(overlayTextPrimary)
        .onReceive(updateTimer) { now = $0 }
        .hotkeyReceivers(coordinator, screenshotHandler: handleScreenshot)
        .onAppear {
            applyDensity(.balanced)
            syncPinnedState()
            audioMode = coordinator.audioSource == .system ? .system : .microphone
            #if os(macOS)
            updateScreenShareVisibility()
            registerScreenshotHotkey()
            if !coordinator.aiEnabled {
                Task { @MainActor in await coordinator.toggleAI() }
            }
            #endif
            logPrompterGeometry("onAppear before expansion")
            withAnimation(.easeOut(duration: 0.4)) {
                islandExpansion = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeOut(duration: 0.25)) {
                    islandContentVisible = true
                }
            }
        }
        .onChange(of: islandContentVisible) { _, visible in
            logPrompterGeometry("islandContentVisible=\(visible)")
            DispatchQueue.main.async {
                logPrompterGeometry("islandContentVisible=\(visible) next run loop")
            }
        }
        #if os(macOS)
        .onChange(of: screenshotCapture.captureMode) { _, mode in
            handleCaptureModeChange(mode)
        }
        .onChange(of: screenshotHotkey) { _, _ in
            registerScreenshotHotkey()
        }
        .onChange(of: isHiddenFromCapture) { _, _ in
            updateScreenShareVisibility()
        }
        .onChange(of: coordinator.mode) { _, newMode in
            showModeToast(newMode)
        }
        .alert(L.t("Set screenshot region first"), isPresented: $showSetupRegionAlert) {
            Button(L.t("OK"), role: .cancel) {}
        } message: {
            Text(L.t("Please set a screenshot region in Settings before using preset region capture."))
        }
        .alert(L.t("Screenshot Incomplete"), isPresented: captureErrorAlertBinding) {
            if screenshotCapture.captureError?.contains("权限") == true {
                Button(L.t("Open System Settings")) {
                    screenshotCapture.openScreenRecordingSettings()
                    screenshotCapture.captureError = nil
                }
            }
            Button(L.t("Cancel"), role: .cancel) {
                screenshotCapture.captureError = nil
            }
        } message: {
            Text(screenshotCapture.captureError ?? "")
        }
        #endif
    }

    #if os(macOS)
    private var notchMenuBarHeight: CGFloat {
        guard let screen = currentPrompterWindow()?.screen ?? NSScreen.main else { return 37 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private func logPrompterGeometry(_ event: String) {
        #if DEBUG
        PrompterPanel.latestPanel?.logNotchGeometry(event)
        #endif
    }

    private var captureErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { screenshotCapture.captureError != nil },
            set: { if !$0 { screenshotCapture.captureError = nil } }
        )
    }
    #else
    private var notchMenuBarHeight: CGFloat { 37 }
    private func logPrompterGeometry(_ event: String) {}
    #endif

    private var notchHeader: some View {
        HStack(spacing: 10) {
            historyArrow(direction: -1)
            Text(currentQuestion.isEmpty ? L.t("Waiting for interview question...") : currentQuestion)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: "#AAAAAA"))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            WaveformView(level: coordinator.audioLevel, active: coordinator.isVoiceDetected, tint: islandYellow)
                .frame(width: 120, height: 20)
            historyArrow(direction: 1)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var compactAnswerArea: some View {
        ZStack {
        ScrollView(.vertical, showsIndicators: true) {
            Group {
                if isPreparingAnswer || coordinator.isCodeGenerationRunning {
                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(islandYellow)
                            .controlSize(.small)
                        Text(L.t("Preparing answer suggestion..."))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: "#AAAAAA"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if hasVisibleAnswer {
                    AnswerRenderer(
                        text: cleanAnswer,
                        fontSize: 17,
                        primary: .white,
                        secondary: Color(hex: "#AAAAAA"),
                        isPreparing: false
                    )
                } else {
                    Text(coordinator.mode == .director ? L.t("Waiting for answer") : L.t("Waiting for AI answer..."))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(hex: "#777777"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        if let modeToast {
            Text(modeToast)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.ultraThinMaterial).clipShape(Capsule())
                .transition(.opacity.combined(with: .scale))
        }
        VStack {
            Spacer()
            pendingInterruptBanner
                .padding(.bottom, 8)
        }
        }
    }

    private var islandToolbar: some View {
        HStack(spacing: 6) {
            islandButton(systemImage: "camera.viewfinder", tint: islandYellow) {
                screenshotSubmissionState = .idle
                Task { await handleScreenshot() }
            }
            if coordinator.mode == .ai { codeLanguageMenu }
            audioControl
            if coordinator.mode == .ai { islandButton(
                systemImage: "folder.fill",
                tint: islandYellow,
                badge: "\(coordinator.session?.activeKBIds.count ?? 0)"
            ) { onKB() } }
            modeSwitchButton
            captureStatusControls
            Spacer(minLength: 6)
            islandAssetButton(imageName: "OverlayMinimize", accessibilityLabel: L.t("Minimize")) {
                minimizeIsland()
            }
            islandButton(systemImage: "xmark", tint: .white.opacity(0.76)) { onClose() }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
    }

    private var minimizedIsland: some View {
        Button {
            restoreIsland()
        } label: {
            Image("OverlayRestore")
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .frame(width: 42, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.t("Restore"))
        .padding(.top, notchMenuBarHeight + 2)
        .frame(width: 80)
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
    }

    private var islandResizeHandle: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.72))
                .frame(width: 56, height: 5)
            #if os(macOS)
            ResizeCursorTrackingView()
            #endif
        }
        .frame(width: 64, height: 16)
        .contentShape(Rectangle())
        .gesture(islandHeightDragGesture)
        .accessibilityLabel(L.t("Resize prompt height"))
    }

    private var islandHeightDragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                #if os(macOS)
                let startHeight: CGFloat
                if let resizeStartHeight {
                    startHeight = resizeStartHeight
                } else {
                    startHeight = currentPrompterWindow()?.frame.height ?? expandedIslandHeight
                    resizeStartHeight = startHeight
                    resizeStartMouseY = NSEvent.mouseLocation.y
                }
                let startMouseY = resizeStartMouseY ?? NSEvent.mouseLocation.y
                let screenHeight = currentPrompterWindow()?.screen?.frame.height ?? 900
                let newHeight = min(max(startHeight + startMouseY - NSEvent.mouseLocation.y, 180), screenHeight)
                (currentPrompterWindow() as? PrompterPanel)?.resizeIsland(
                    to: NSSize(width: 600, height: newHeight)
                )
                #endif
            }
            .onEnded { _ in
                #if os(macOS)
                if let height = currentPrompterWindow()?.frame.height {
                    expandedIslandHeight = height
                }
                #endif
                resizeStartHeight = nil
                resizeStartMouseY = nil
            }
    }

    private func minimizeIsland() {
        #if os(macOS)
        if let height = currentPrompterWindow()?.frame.height {
            expandedIslandHeight = max(180, height)
        }
        #endif
        withAnimation(.easeInOut(duration: 0.22)) {
            isIslandMinimized = true
        }
        #if os(macOS)
        let menuBarHeight: CGFloat
        if let screen = currentPrompterWindow()?.screen {
            menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        } else {
            menuBarHeight = 37
        }
        (currentPrompterWindow() as? PrompterPanel)?.resizeIsland(
            to: NSSize(width: 80, height: max(54, menuBarHeight + 26)),
            animated: true
        )
        #endif
    }

    private func restoreIsland() {
        withAnimation(.easeInOut(duration: 0.22)) {
            isIslandMinimized = false
        }
        #if os(macOS)
        (currentPrompterWindow() as? PrompterPanel)?.resizeIsland(
            to: NSSize(width: 600, height: max(180, expandedIslandHeight)),
            animated: true
        )
        #endif
    }

    private var islandYellow: Color { Color(hex: "#F4EA2A") }

    @ViewBuilder
    private var pendingInterruptBanner: some View {
        if let question = coordinator.pendingInterruptQuestion {
            Button {
                coordinator.answerPendingInterrupt()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble.fill")
                    Text(L.t("New question detected · Tap to answer"))
                    Text(question)
                        .lineLimit(1)
                        .foregroundStyle(Color.appMuted)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.appSurface.opacity(0.96))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.appYellow.opacity(0.65), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityHint(question)
        }
    }

    private var modeSwitchButton: some View {
        Button {
            Task { await coordinator.switchMode() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(islandYellow)
                .frame(width: 34, height: 28)
                .background(Color.white.opacity(0.14))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(coordinator.mode == .ai ? "Switch to Director mode" : "Switch to AI mode")
    }

    private func historyArrow(direction: Int) -> some View {
        Button {
            moveHistory(direction)
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(islandYellow)
                .frame(width: 26, height: 26)
                .background(Circle().fill(islandYellow.opacity(0.001)))
                .overlay(Circle().stroke(islandYellow, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canMoveHistory(direction))
        .opacity(canMoveHistory(direction) ? 1 : 0.28)
    }

    private func moveHistory(_ direction: Int) {
        let count = navigationItems.count
        guard count > 0 else { return }
        if direction < 0 {
            if let index = browsedTurnIndex {
                browsedTurnIndex = max(0, index - 1)
            } else {
                browsedTurnIndex = max(0, count - 2)
            }
        } else if let index = browsedTurnIndex {
            browsedTurnIndex = index >= count - 2 ? nil : index + 1
        }
        coordinator.autoScrollEnabled = browsedTurnIndex == nil
    }

    private func canMoveHistory(_ direction: Int) -> Bool {
        let count = navigationItems.count
        if direction < 0 {
            return count > 1 && (browsedTurnIndex ?? count - 1) > 0
        }
        return browsedTurnIndex != nil
    }

    private func showModeToast(_ mode: DirectorMode) {
        let message = mode == .ai ? L.t("User switched to AI mode") : L.t("User switched to Director mode")
        withAnimation { modeToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { modeToast = nil }
        }
        browsedTurnIndex = nil
    }

    private var codeLanguageMenu: some View {
        Button {
            showCodeLanguageEditor.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .bold))
                Text(coordinator.codeLanguageDraft.isEmpty ? "python" : coordinator.codeLanguageDraft)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(islandYellow)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color(hex: "#292A31"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .layoutPriority(2)
        .popover(isPresented: $showCodeLanguageEditor, arrowEdge: .bottom) {
            codeLanguageEditor
        }
    }

    @ViewBuilder
    private var captureStatusControls: some View {
        #if os(macOS)
        switch screenshotSubmissionState {
        case .loading:
            ScreenshotLoadingIndicator()
                .frame(width: 34, height: 28)
        case .success:
            Image("ScreenshotSuccess")
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 19)
                .frame(width: 34, height: 28)
        case .idle:
            if screenshotCapture.captureMode == .segmentDone, captureCount > 0 {
                Text(String(format: L.t("%d screenshots captured"), captureCount))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                islandIconButton(accessibilityLabel: L.t("Continue Shot")) {
                    ContinueCapturePlusIcon()
                        .frame(width: 10, height: 10)
                } action: {
                    beginScreenshotCapture(reset: false)
                }
                islandButton(systemImage: "checkmark", tint: Color(hex: "#65C889")) {
                    Task { await finishScreenshotAnalysis() }
                }
                islandIconButton(accessibilityLabel: L.t("Delete Previous Screenshot")) {
                    DeleteCaptureIcon()
                        .frame(width: 8, height: 10)
                } action: {
                    removeLastScreenshot()
                }
            } else if screenshotCapture.captureMode == .capturing {
                HStack(spacing: 5) {
                    ScreenshotLoadingIndicator()
                        .scaleEffect(0.82)
                        .frame(width: 18, height: 18)
                    Text(L.t("Getting screenshot..."))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "#AAAAAA"))
                        .lineLimit(1)
                }
                .fixedSize()
            }
        }
        #endif
    }

    private var captureCount: Int {
        #if os(macOS)
        return screenshotCapture.capturedSegments.count
        #else
        return 0
        #endif
    }

    private var audioControl: some View {
        Button {
            Task { await cycleAudioMode() }
        } label: {
            Image(systemName: audioMode == .microphone ? "mic.fill" : audioMode == .system ? "speaker.wave.2.fill" : "mic.slash.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(islandYellow)
                .frame(width: 34, height: 28)
                .background(Color.white.opacity(0.14))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func cycleAudioMode() async {
        switch audioMode {
        case .microphone:
            if coordinator.aiEnabled { await coordinator.toggleAI() }
            audioMode = .system
            coordinator.setAudioSource(.system)
            await coordinator.toggleAI()
        case .system:
            if coordinator.aiEnabled { await coordinator.toggleAI() }
            audioMode = .muted
        case .muted:
            audioMode = .microphone
            coordinator.setAudioSource(.microphone)
            if !coordinator.aiEnabled { await coordinator.toggleAI() }
        }
    }

    private func islandButton(systemImage: String, tint: Color, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .bold))
                if let badge { Text(badge).font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(tint)
            .frame(width: 34, height: 28)
            .background(Color.white.opacity(0.14))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func islandAssetButton(imageName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(imageName)
                .resizable()
                .interpolation(.high)
                .frame(width: 12, height: 12)
                .frame(width: 34, height: 28)
                .background(Color.white.opacity(0.14))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func islandIconButton<Icon: View>(
        accessibilityLabel: String,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 34, height: 28)
                .background(Color.white.opacity(0.14))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var mobileBody: some View {
        VStack(spacing: 0) {
            mobileTopBar
            mobileStatusStrip
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("Question"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appMuted)
                HStack(spacing: 12) {
                    historyArrow(direction: -1)
                    Text(hasQuestion ? currentQuestion : L.t("Waiting for interview question..."))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(hasQuestion ? overlayTextPrimary : overlayTextSecondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    historyArrow(direction: 1)
                }
            }
            .padding(16)
            .frame(minHeight: 112, alignment: .topLeading)
            .background(questionBackground)

            VStack(alignment: .leading, spacing: 10) {
                Text(L.t("AI Suggested Answer"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appMuted)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                mobileAnswerArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appSurface.opacity(0.9))

            keywordsBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBG.ignoresSafeArea())
        .foregroundStyle(overlayTextPrimary)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                pendingInterruptBanner
                if let modeToast {
                    Text(modeToast)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.ultraThinMaterial).clipShape(Capsule())
                }
            }
            .padding(.top, 12)
        }
        .onReceive(updateTimer) { now = $0 }
        .hotkeyReceivers(coordinator, screenshotHandler: handleScreenshot)
        .onAppear {
            applyDensity(.compact)
            #if os(macOS)
            updateScreenShareVisibility()
            registerScreenshotHotkey()
            #endif
        }
        .onChange(of: coordinator.mode) { _, newMode in
            showModeToast(newMode)
        }
        #if os(macOS)
        .onChange(of: screenshotCapture.captureMode) { _, mode in
            handleCaptureModeChange(mode)
        }
        .onChange(of: screenshotHotkey) { _, _ in
            registerScreenshotHotkey()
        }
        .alert(L.t("Set screenshot region first"), isPresented: $showSetupRegionAlert) {
            Button(L.t("OK"), role: .cancel) {}
        } message: {
            Text(L.t("Please set a screenshot region in Settings before using preset region capture."))
        }
        #endif
    }

    private var mobileTopBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                aiButton(showText: true)
                #if os(macOS)
                screenshotButton(showText: true)
                #endif
                if coordinator.mode == .ai { codeLanguageControl(showText: true) }
                sendNowButton(showText: true)
                inputSourceMenu(showText: false)
                languageButton(showText: true)
                if coordinator.mode == .ai { knowledgeButton(showText: false) }
                modeSwitchButton
                pinButton
                closeButton
            }
        .padding(.horizontal, 10)
        }
        .frame(height: 58)
        .background(toolbarGlassBackground)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.12)), alignment: .bottom)
    }

    private var mobileStatusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                mobileStatusPill(listeningLabel, systemImage: "waveform", tint: coordinator.isSpeechListening ? .appGreen : .appMuted)
                mobileStatusPill(recordingLabel, systemImage: "record.circle", tint: isRecording ? .appDanger : .appMuted)
                mobileStatusPill(thinkingLabel, systemImage: "brain.head.profile", tint: isPreparingAnswer ? .appYellow : .appMuted)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
        .background(Color.black.opacity(0.18))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.10)), alignment: .bottom)
    }

    private var mobileAnswerArea: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView(showsIndicators: true) {
                    timelineContent(isMobile: true)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in markUserBrowsingHistory() })
                jumpToLatestButton(proxy: proxy, bottomID: "mobile-answer-bottom")
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
            }
            .onChange(of: coordinator.aiText) { _, _ in
                guard coordinator.autoScrollEnabled else { return }
                showJumpToLatest = false
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo("mobile-answer-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var topStatusBar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarLarge
            toolbarMedium
            toolbarSmall
        }
        .padding(.horizontal, 9)
        .frame(height: 48)
        .background(toolbarGlassBackground)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.12)), alignment: .bottom)
    }

    private var toolbarLarge: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                aiButton(showText: true)
                #if os(macOS)
                screenshotButton(showText: true)
                #endif
                if coordinator.mode == .ai { codeLanguageControl(showText: true) }
                sendNowButton(showText: true)
                inputSourceMenu(showText: true)
                languageButton(showText: true)
                if coordinator.mode == .ai { knowledgeButton(showText: true) }
                modeSwitchButton
            }
            Spacer(minLength: 10)
            HStack(spacing: 5) {
                statusChip(listeningLabel, systemImage: "waveform", tint: coordinator.isSpeechListening ? .appGreen : .appMuted, showText: true)
                statusChip(recordingLabel, systemImage: "record.circle", tint: isRecording ? .appDanger : .appMuted, showText: true)
                fontControls
                moreMenu
                pinButton
                closeButton
            }
        }
    }

    private var toolbarMedium: some View {
        HStack(spacing: 6) {
            aiButton(showText: true)
            #if os(macOS)
            screenshotButton(showText: false)
            #endif
            if coordinator.mode == .ai { codeLanguageControl(showText: false) }
            sendNowButton(showText: false)
            inputSourceMenu(showText: false)
            languageButton(showText: true)
            if coordinator.mode == .ai { knowledgeButton(showText: false) }
            modeSwitchButton
            Spacer(minLength: 8)
            statusChip(listeningLabel, systemImage: "waveform", tint: coordinator.isSpeechListening ? .appGreen : .appMuted, showText: false)
            fontControls
            moreMenu
            pinButton
            closeButton
        }
    }

    private var toolbarSmall: some View {
        HStack(spacing: 5) {
            aiButton(showText: false)
            #if os(macOS)
            screenshotButton(showText: false)
            #endif
            if coordinator.mode == .ai { codeLanguageControl(showText: false) }
            sendNowButton(showText: false)
            inputSourceMenu(showText: false)
            languageButton(showText: false)
            if coordinator.mode == .ai { knowledgeButton(showText: false) }
            modeSwitchButton
            Spacer(minLength: 5)
            fontControls
            pinButton
            closeButton
        }
    }

    private var questionArea: some View {
        HStack(spacing: 10) {
            #if os(macOS)
            if let image = coordinator.screenshotImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.appBorder))
            }
            #endif

            VStack(alignment: .leading, spacing: 4) {
                ScrollView(showsIndicators: true) {
                    Text(currentQuestion)
                        .font(.system(size: density.questionSize, weight: .semibold))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .foregroundStyle(hasQuestion ? overlayTextPrimary : overlayTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                #if os(macOS)
                if coordinator.screenshotImage != nil {
                    Text(screenshotCapture.recognizedText.isEmpty ? L.t("OCR running") : L.t("OCR complete"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appMuted)
                }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(lastUpdatedText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appMuted)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: coordinatorHasScreenshot ? 150 : 96)
        .background(questionBackground)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.12)), alignment: .bottom)
    }

    private var answerArea: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView(showsIndicators: false) {
                    timelineContent(isMobile: false)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in markUserBrowsingHistory() })
                jumpToLatestButton(proxy: proxy, bottomID: "bottom")
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
            }
            .onChange(of: coordinator.aiText) { _, _ in
                guard coordinator.autoScrollEnabled else { return }
                showJumpToLatest = false
                withAnimation(.easeInOut(duration: 0.22)) {
                    if isSenderPrompt {
                        proxy.scrollTo("top", anchor: .top)
                    } else {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: coordinator.isAwaitingCodeLanguage) { _, _ in
                guard coordinator.autoScrollEnabled else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
    }

    private func timelineContent(isMobile: Bool) -> some View {
        VStack(alignment: .leading, spacing: isMobile ? 14 : 16) {
            Color.clear.frame(height: 1).id(isMobile ? "mobile-answer-top" : "top")
            ForEach(Array(overlayHistoryTurns.enumerated()), id: \.element.id) { index, turn in
                timelineTurnCard(index: index, turn: turn, isMobile: isMobile)
                    .padding(.horizontal, isMobile ? 16 : 22)
            }
            currentAnswerBlock(isMobile: isMobile)
                .padding(.horizontal, isMobile ? 16 : 22)
                .padding(.bottom, isMobile ? 20 : 14)
            Color.clear.frame(height: 1).id(isMobile ? "mobile-answer-bottom" : "bottom")
        }
        .padding(.top, overlayHistoryTurns.isEmpty ? 0 : 14)
        .frame(maxWidth: .infinity, minHeight: isMobile ? 180 : 224, alignment: isSenderPrompt ? .topLeading : .bottom)
    }

    @ViewBuilder
    private func currentAnswerBlock(isMobile: Bool) -> some View {
        #if os(macOS)
        if screenshotCapture.captureMode == .segmentDone && !screenshotCapture.capturedSegments.isEmpty {
            capturedSegmentsPreview
                .padding(.vertical, 14)
        } else if isSenderPrompt && hasVisibleAnswer {
            senderPromptBlock(isMobile: isMobile)
        } else if hasVisibleAnswer {
            currentAnswerRenderer(isMobile: isMobile)
        } else {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        }
        #else
        if hasVisibleAnswer {
            if isSenderPrompt {
                senderPromptBlock(isMobile: isMobile)
            } else {
                currentAnswerRenderer(isMobile: isMobile)
            }
        } else {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        }
        #endif
    }

    private func currentAnswerRenderer(isMobile: Bool) -> some View {
        Group {
            if isMobile {
                AnswerRenderer(
                    text: cleanAnswer,
                    fontSize: coordinator.fontSize,
                    primary: overlayTextPrimary,
                    secondary: overlayTextSecondary,
                    isPreparing: isPreparingAnswer
                )
            } else {
                AnswerRenderer(text: cleanAnswer, fontSize: answerDisplayFontSize, primary: overlayTextPrimary, secondary: overlayTextSecondary, isPreparing: isPreparingAnswer)
            }
        }
        .padding(.vertical, isMobile ? 0 : 14)
    }

    private func senderPromptBlock(isMobile: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L.t("Prompt Sender"), systemImage: "paperplane.fill")
                .font(.system(size: isMobile ? 13 : 12, weight: .semibold))
                .foregroundStyle(Color.appMuted)
            AnswerRenderer(
                text: cleanAnswer,
                fontSize: isMobile ? 20 : max(20, answerDisplayFontSize - 4),
                primary: overlayTextPrimary,
                secondary: overlayTextSecondary,
                isPreparing: false
            )
        }
        .padding(.vertical, isMobile ? 0 : 14)
    }

    private func timelineTurnCard(index: Int, turn: ConversationTurn, isMobile: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusPill(text: "\(L.t("Question")) \(index + 1)", tint: .appYellow)
                Spacer()
                Text(turn.createdAt.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(overlayTextSecondary)
            }
            Text(turn.question)
                .font(.system(size: isMobile ? 15 : 14, weight: .semibold))
                .foregroundStyle(overlayTextPrimary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Divider().overlay(Color.white.opacity(0.12))
            AnswerRenderer(
                text: turn.answer,
                fontSize: isMobile ? min(20, coordinator.fontSize - 4) : min(20, answerDisplayFontSize - 4),
                primary: overlayTextPrimary,
                secondary: overlayTextSecondary,
                isPreparing: false
            )
        }
        .padding(14)
        .background(Color.white.opacity(isLightTheme ? 0.32 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12)))
    }

    @ViewBuilder
    private func jumpToLatestButton(proxy: ScrollViewProxy, bottomID: String) -> some View {
        if showJumpToLatest || !overlayHistoryTurns.isEmpty {
            Button {
                coordinator.autoScrollEnabled = true
                showJumpToLatest = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func markUserBrowsingHistory() {
        guard !overlayHistoryTurns.isEmpty else { return }
        coordinator.autoScrollEnabled = false
        showJumpToLatest = true
    }

    private var keywordsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("Must Mention"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appMuted)
                Spacer()
                confidencePill
            }
            if extractedKeywords.isEmpty {
                Text(L.t("Waiting for answer keywords"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(overlayTextSecondary)
            } else {
                FlexibleTagLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(extractedKeywords.prefix(4), id: \.self) { keyword in
                        keywordTag(keyword)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: isCompact ? 106 : 72, alignment: .topLeading)
        .background(Color.black.opacity(0.22))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.12)), alignment: .top)
    }

    private func keywordTag(_ keyword: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.appGreen)
            Text(keyword)
                .lineLimit(1)
        }
        .font(.system(size: density == .large ? 13 : 12, weight: .semibold))
        .foregroundStyle(overlayTextPrimary)
        .padding(.horizontal, density == .compact ? 7 : 9)
        .frame(height: density == .compact ? 24 : 28)
        .background(keywordBackground)
        .clipShape(Capsule())
    }

    private var fontControls: some View {
        HStack(spacing: 2) {
            Button("A-") { setFontSize(22) }
            Button("A") { setFontSize(26) }
            Button("A+") { setFontSize(30) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.black)
        .tint(Color.black)
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(height: 26)
        .background(Color.white.opacity(0.76))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.36)))
    }

    private var moreMenu: some View {
        Menu {
            Section(L.t("Density")) {
                ForEach(DensityMode.allCases) { mode in
                    Button(densityTitle(mode)) { applyDensity(mode) }
                }
            }
            Section(L.t("Controls")) {
                Button(coordinator.autoScrollEnabled ? L.t("Auto Scroll On") : L.t("Auto Scroll Off")) {
                    coordinator.autoScrollEnabled.toggle()
                }
                Button(L.t("Copy Answer")) { copyAnswer() }
                Button(L.t("History")) { onHistory() }
            }
        } label: {
            toolbarCapsule(L.t("More"), systemImage: "slider.horizontal.3", tint: .appMuted, showText: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appText)
        .tint(Color.appText)
    }

    private var pinButton: some View {
        toolbarButton("", systemImage: "pin", tint: coordinator.pinned ? .appPrimary : .appMuted) {
            coordinator.pinned.toggle()
            syncPinnedState()
        }
    }

    private var closeButton: some View {
        toolbarButton("", systemImage: "xmark", tint: .appMuted) {
            onClose()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            waveform
            Text(L.t("Listening"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(overlayTextPrimary)
            Text(L.t("Waiting for interview question"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(overlayTextSecondary)
        }
        .onAppear { pulse = true }
    }

    #if os(macOS)
    private var capturedSegmentsPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L.t("Recognized preview"), systemImage: "doc.text.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appMuted)
                Spacer()
                Text("\(screenshotCapture.segmentCount)\(L.t("shots suffix"))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Color.appYellow)
                    .clipShape(Capsule())
            }

            ForEach(Array(screenshotCapture.capturedSegments.enumerated()), id: \.offset) { index, segment in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(L.t("Shot")) \(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appYellow)
                        .frame(width: 58, alignment: .leading)

                    Text(segmentPreviewText(segment))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(overlayTextSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color.black.opacity(isLightTheme ? 0.04 : 0.24))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.appBorder))
            }
        }
        .padding(12)
        .background(Color.appBG.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.appBorder))
    }
    #endif

    private var waveform: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.appPrimary.opacity(0.85))
                    .frame(width: 4, height: pulse ? CGFloat([14, 24, 18, 28, 16][index]) : 10)
                    .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(Double(index) * 0.08), value: pulse)
            }
        }
        .frame(height: 30)
    }

    private func aiButton(showText: Bool) -> some View {
        toolbarButton(showText ? "AI" : "", systemImage: "sparkles", tint: coordinator.aiEnabled ? .appGreen : .appMuted) {
            Task { @MainActor in await coordinator.toggleAI() }
        }
        .disabled(coordinator.isStartingAI)
    }

    private func sendNowButton(showText: Bool) -> some View {
        toolbarButton(showText ? L.t("Send") : "", systemImage: "arrow.up.circle.fill", tint: .appYellow) {
            coordinator.forceTriggerSpeech()
        }
        .disabled(!coordinator.canForceTriggerSpeech)
        .opacity(coordinator.canForceTriggerSpeech ? 1 : 0.55)
    }

    private func codeLanguageControl(showText: Bool) -> some View {
        HStack(spacing: 3) {
            Menu {
                ForEach(["python", "cpp", "java", "swift", "javascript", "typescript", "go", "rust"], id: \.self) { language in
                    Button(language) {
                        coordinator.codeLanguageDraft = language
                        if coordinator.canGeneratePendingCode {
                            Task { await coordinator.generatePendingCode(language: language) }
                        }
                    }
                }
                Divider()
                Button(L.t("Other language...")) {
                    showCodeLanguageEditor = true
                }
            } label: {
                toolbarCapsule(codeLanguageLabel(showText: showText), systemImage: "chevron.left.forwardslash.chevron.right", tint: coordinator.canGeneratePendingCode ? .appPrimary : .appMuted, showText: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appText)
            .tint(Color.appText)

            Button {
                Task { await coordinator.generatePendingCode(language: coordinator.codeLanguageDraft) }
            } label: {
                toolbarCapsule("", systemImage: coordinator.isCodeGenerationRunning ? "circle.dotted" : "play.fill", tint: coordinator.canGeneratePendingCode ? .appGreen : .appMuted, showText: false)
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.canGeneratePendingCode)
            .opacity(coordinator.canGeneratePendingCode ? 1 : 0.55)
        }
        .popover(isPresented: $showCodeLanguageEditor, arrowEdge: .bottom) {
            codeLanguageEditor
        }
    }

    #if os(macOS)
    private func screenshotButton(showText: Bool) -> some View {
        Group {
            switch screenshotCapture.captureMode {
            case .idle:
                toolbarButton(showText ? L.t("Screenshot") : "", systemImage: "camera.viewfinder", tint: .appMuted) {
                    beginScreenshotCapture(reset: true)
                }

            case .capturing:
                toolbarCapsule(showText ? L.t("Selecting region...") : "", systemImage: "circle.dotted", tint: .appYellow, showText: showText)
                    .opacity(0.85)

            case .segmentDone:
                HStack(spacing: 4) {
                    Text("\(screenshotCapture.segmentCount)\(L.t("shots suffix"))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .background(Color.appYellow)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Button {
                        beginScreenshotCapture(reset: false)
                    } label: {
                        toolbarIconLabel(showText ? L.t("Continue Shot") : "") {
                            ContinueCapturePlusIcon()
                                .frame(width: 10, height: 10)
                        }
                    }
                    .buttonStyle(.plain)

                    toolbarButton(showText ? L.t("Finish Analysis") : "", systemImage: "checkmark.circle.fill", tint: .appYellow) {
                        Task { await finishScreenshotAnalysis() }
                    }

                    Button {
                        removeLastScreenshot()
                    } label: {
                        toolbarIconLabel("") {
                            DeleteCaptureIcon()
                                .frame(width: 8, height: 10)
                        }
                    }
                    .buttonStyle(.plain)
                }

            case .analyzing:
                toolbarCapsule(showText ? L.t("Analyzing") : "", systemImage: "brain", tint: .appGreen, showText: showText)
                    .opacity(0.85)
            }
        }
    }

    #endif

    private func inputSourceMenu(showText: Bool) -> some View {
        Menu {
            Button(L.t("Microphone")) { setAudio(.microphone) }
            Button(L.t("System Audio")) { setAudio(.system) }
        } label: {
            toolbarCapsule(inputSourceLabel(showText: showText), systemImage: inputSourceIcon, tint: coordinator.isSpeechListening ? .appGreen : .appMuted, showText: showText)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appText)
        .tint(Color.appText)
    }

    private func languageButton(showText: Bool) -> some View {
        toolbarButton(languageLabel(showText: showText), systemImage: "globe", tint: .appPrimary) {
            coordinator.toggleLanguage()
        }
    }

    private func knowledgeButton(showText: Bool) -> some View {
        toolbarButton(showText ? "\(coordinator.session?.activeKBIds.count ?? 0)" : "", systemImage: "folder", tint: .appPrimary) {
            onKB()
        }
    }

    private var codeLanguageEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("Choose code language"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appMuted)
            HStack(spacing: 8) {
                TextField("python", text: $coordinator.codeLanguageDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit { showCodeLanguageEditor = false }
                Button(L.t("Save")) {
                    showCodeLanguageEditor = false
                    if coordinator.canGeneratePendingCode {
                        Task { await coordinator.generatePendingCode(language: coordinator.codeLanguageDraft) }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            FlexibleTagLayout(spacing: 6, rowSpacing: 6) {
                ForEach(["python", "cpp", "java", "swift", "javascript", "go"], id: \.self) { language in
                    Button(language) {
                        coordinator.codeLanguageDraft = language
                        showCodeLanguageEditor = false
                        if coordinator.canGeneratePendingCode {
                            Task { await coordinator.generatePendingCode(language: language) }
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.bordered)
                }
            }
            if coordinator.canGeneratePendingCode {
                Button {
                    showCodeLanguageEditor = false
                    Task { await coordinator.generatePendingCode(language: coordinator.codeLanguageDraft) }
                } label: {
                    Label(L.t("Generate Code"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Color.appSurface)
    }

    private func toolbarButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolbarCapsule(title, systemImage: systemImage, tint: tint, showText: !title.isEmpty)
        }
        .buttonStyle(.plain)
    }

    private func toolbarIconLabel<Icon: View>(
        _ title: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 4) {
            icon()
            if !title.isEmpty {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(Color.appText)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, title.isEmpty ? 8 : 7)
        .frame(height: isCompact ? 38 : 26)
        .frame(minWidth: isCompact ? (title.isEmpty ? 44 : 58) : nil)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.appButton)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.36)))
    }

    private func codeLanguageLabel(showText: Bool) -> String {
        let language = coordinator.codeLanguageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if showText { return language.isEmpty ? "code" : language }
        return language.isEmpty ? "py" : String(language.prefix(4))
    }

    private func statusChip(_ title: String, systemImage: String, tint: Color, showText: Bool) -> some View {
        toolbarCapsule(title, systemImage: systemImage, tint: tint, showText: showText)
    }

    private func mobileStatusPill(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconColor(for: tint))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(textColor(for: tint))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(backgroundColor(for: tint))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.36)))
    }

    private func toolbarCapsule(_ title: String, systemImage: String, tint: Color, showText: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconColor(for: tint))
            if showText {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(textColor(for: tint))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .tint(Color.black)
        .padding(.horizontal, showText ? 7 : 8)
        .frame(height: isCompact ? 38 : 26)
        .frame(minWidth: isCompact ? (showText ? 58 : 44) : nil)
        .fixedSize(horizontal: true, vertical: false)
        .background(backgroundColor(for: tint))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.36)))
        .animation(.easeInOut(duration: 0.16), value: showText)
    }

    private var confidencePill: some View {
        Text("\(Int(coordinator.confidence * 100))%")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(confidenceColor)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.appSurface.opacity(0.9))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.appBorder))
    }

    private func inputSourceLabel(showText: Bool) -> String {
        guard showText else { return "" }
        return coordinator.audioSource == .microphone ? L.t("Mic") : L.t("System")
    }

    private var inputSourceIcon: String {
        coordinator.audioSource == .microphone ? "mic" : "speaker.wave.2"
    }

    private func languageLabel(showText: Bool) -> String {
        guard showText else { return "" }
        switch coordinator.languageCode {
        case "zh-CN": return "中文"
        case "auto": return "Auto"
        default: return "EN"
        }
    }

    private var listeningLabel: String {
        if coordinator.isStartingAI { return L.t("Starting") }
        if coordinator.isSpeechListening { return L.t("Listening") }
        return L.t("Standby")
    }

    private var recordingLabel: String {
        isRecording ? L.t("Recording") : L.t("Idle")
    }

    private var thinkingLabel: String {
        isPreparingAnswer ? L.t("Thinking") : L.t("Ready")
    }

    private var currentQuestion: String {
        if let browsedTurn { return browsedTurn.question }
        return baseCurrentQuestion
    }

    private var baseCurrentQuestion: String {
        guard hasQuestion else { return L.t("Question") }
        return (coordinator.lastQuestion.isEmpty ? coordinator.prompterText : coordinator.lastQuestion)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasQuestion: Bool {
        let text = (coordinator.lastQuestion.isEmpty ? coordinator.prompterText : coordinator.lastQuestion)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text != "Waiting for interview question..." && text != L.t("Waiting for interview question...")
    }

    private var cleanAnswer: String {
        if let browsedTurn { return browsedTurn.answer }
        return baseCleanAnswer
    }

    private var baseCleanAnswer: String {
        coordinator.aiText
            .replacingOccurrences(of: "💡", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var overlayHistoryTurns: [ConversationTurn] {
        guard let session = coordinator.session else { return [] }
        var turns = session.turns.sorted { $0.createdAt < $1.createdAt }
        if let last = turns.last {
            let sameQuestion = last.question.trimmingCharacters(in: .whitespacesAndNewlines) == baseCurrentQuestion
            let sameAnswer = last.answer.trimmingCharacters(in: .whitespacesAndNewlines) == baseCleanAnswer
            if sameQuestion && sameAnswer {
                turns.removeLast()
            }
        }
        return turns
    }

    private struct NavigationItem {
        let question: String
        let answer: String
    }

    private var navigationItems: [NavigationItem] {
        if coordinator.mode == .director {
            return coordinator.directorQuestions.map { NavigationItem(question: $0.text, answer: $0.renderedAnswer) }
        }
        var items = (coordinator.session?.turns ?? [])
            .sorted { $0.createdAt < $1.createdAt }
            .map { NavigationItem(question: $0.question, answer: $0.answer) }
        if !baseCurrentQuestion.isEmpty {
            let isDuplicate = items.last.map {
                $0.question.trimmingCharacters(in: .whitespacesAndNewlines) == baseCurrentQuestion &&
                $0.answer.trimmingCharacters(in: .whitespacesAndNewlines) == baseCleanAnswer
            } ?? false
            if !isDuplicate {
                items.append(NavigationItem(question: baseCurrentQuestion, answer: baseCleanAnswer))
            }
        }
        return items
    }

    private var browsedTurn: NavigationItem? {
        guard let index = browsedTurnIndex, navigationItems.indices.contains(index) else { return nil }
        return navigationItems[index]
    }

    private var hasAnswer: Bool {
        let answer = cleanAnswer
        return !answer.isEmpty && answer != "Preparing answer suggestion..." && answer != L.t("Preparing answer suggestion...")
    }

    private var isSenderPrompt: Bool {
        coordinator.lastQuestion == "Prompt Sender" || coordinator.mode == .director
    }

    private var hasVisibleAnswer: Bool {
        !cleanAnswer.isEmpty
    }

    private var isPreparingAnswer: Bool {
        cleanAnswer == "Preparing answer suggestion..." || cleanAnswer == L.t("Preparing answer suggestion...")
    }

    private var extractedKeywords: [String] {
        guard hasAnswer else { return [] }
        let fallback = AppLanguage(rawValue: language) == .chinese
            ? ["用户研究", "利益相关者", "设计系统", "影响"]
            : ["User Research", "Stakeholder", "Design System", "Impact"]
        let stopWords: Set<String> = ["that", "with", "from", "this", "then", "they", "were", "have", "about", "would", "could", "first", "when", "into", "also", "helped", "through", "because", "there", "their", "successfully"]
        let words = cleanAnswer
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 5 && !stopWords.contains($0.lowercased()) }
        var seen = Set<String>()
        let keywords = words.compactMap { word -> String? in
            let normalized = word.lowercased()
            guard !seen.contains(normalized) else { return nil }
            seen.insert(normalized)
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return Array((keywords + fallback).prefix(4))
    }

    private var lastUpdatedText: String {
        guard let updated = coordinator.lastUpdatedAt else { return L.t("Waiting") }
        let seconds = max(0, Int(now.timeIntervalSince(updated)))
        if seconds < 1 { return L.t("Now") }
        return AppLanguage(rawValue: language) == .chinese ? "\(seconds) 秒前" : "\(seconds)s ago"
    }

    private var confidenceColor: Color {
        if coordinator.confidence >= 0.72 { return .appGreen }
        if coordinator.confidence >= 0.45 { return .appYellow }
        return .appDanger
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var coordinatorHasScreenshot: Bool {
        #if os(macOS)
        return coordinator.screenshotImage != nil
        #else
        return false
        #endif
    }

    private var answerDisplayFontSize: CGFloat {
        coordinatorHasScreenshot ? min(18, coordinator.fontSize) : coordinator.fontSize
    }

    private var isLightTheme: Bool {
        AppThemeMode.current == .light
    }

    private var prompterGlassBackground: Color {
        isLightTheme ? Color.white.opacity(0.42) : Color(hex: "#061326").opacity(0.58)
    }

    private var toolbarGlassBackground: Color {
        isLightTheme ? Color.white.opacity(0.34) : Color(hex: "#07172B").opacity(0.34)
    }

    private var overlayTextPrimary: Color {
        isLightTheme ? Color(hex: "#111827") : Color.white
    }

    private var overlayTextSecondary: Color {
        isLightTheme ? Color(hex: "#4B5563") : Color.white.opacity(0.72)
    }

    private var questionBackground: Color {
        isLightTheme ? Color.white.opacity(0.24) : Color.black.opacity(0.24)
    }

    private var keywordBackground: Color {
        isLightTheme ? Color.white.opacity(0.28) : Color.white.opacity(0.10)
    }

    private var isRecording: Bool {
        coordinator.speechStatusText.contains("录音") || coordinator.speechStatusText.contains("Recording")
    }

    private func textColor(for tint: Color) -> Color {
        Color.black
    }

    private func iconColor(for tint: Color) -> Color {
        Color.black
    }

    private func backgroundColor(for tint: Color) -> Color {
        if tint == .appMuted {
            return Color.white.opacity(0.76)
        }
        if tint == .appYellow {
            return Color.appYellow.opacity(0.86)
        }
        if tint == .appGreen {
            return Color.appGreen.opacity(0.82)
        }
        if tint == .appDanger {
            return Color.appDanger.opacity(0.74)
        }
        return Color(hex: "#C8D6FF").opacity(0.86)
    }

    private func densityTitle(_ mode: DensityMode) -> String {
        switch mode {
        case .compact: return L.t("Compact")
        case .balanced: return L.t("Balanced")
        case .large: return L.t("Large")
        }
    }

    private func applyDensity(_ mode: DensityMode) {
        density = mode
        setFontSize(mode.answerSize)
    }

    private func syncPinnedState() {
        #if os(macOS)
        PrompterPanel.latestPanel?.setPinned(coordinator.pinned)
        #endif
    }

    private func setFontSize(_ size: CGFloat) {
        coordinator.fontSize = min(36, max(22, size))
    }

    private func setAudio(_ source: AudioSource) {
        coordinator.setAudioSource(source)
    }

    private func copyAnswer() {
        guard hasAnswer else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleanAnswer, forType: .string)
        #else
        UIPasteboard.general.string = cleanAnswer
        #endif
    }

    #if os(macOS)
    private var screenshotMode: ScreenshotMode {
        ScreenshotMode(rawValue: screenshotModeRaw) ?? .presetRegion
    }

    private func registerScreenshotHotkey() {
        HotkeyManager.shared.register(key: screenshotHotkey, id: HotkeyManager.screenshotID) {
            NotificationCenter.default.post(name: .screenshotHotkey, object: nil)
        }
    }

    private func updateScreenShareVisibility() {
        let panels = NSApp.windows.compactMap { $0 as? PrompterPanel }
        if !panels.isEmpty {
            panels.forEach { $0.setHiddenFromScreenCapture(isHiddenFromCapture) }
        } else if let panel = currentPrompterWindow() as? PrompterPanel {
            panel.setHiddenFromScreenCapture(isHiddenFromCapture)
        } else {
            currentPrompterWindow()?.sharingType = isHiddenFromCapture ? .none : .readOnly
        }
    }

    private func currentPrompterWindow() -> NSWindow? {
        PrompterPanel.latestPanel
            ?? NSApp.windows.compactMap { $0 as? PrompterPanel }.last
            ?? NSApp.keyWindow
    }

    @MainActor
    private func handleScreenshot() async {
        switch screenshotCapture.captureMode {
        case .idle:
            screenshotSubmissionState = .idle
            beginScreenshotCapture(reset: true)
        case .segmentDone:
            screenshotSubmissionState = .idle
            beginScreenshotCapture(reset: false)
        case .capturing, .analyzing:
            return
        }
    }

    @MainActor
    private func beginScreenshotCapture(reset: Bool) {
        switch screenshotMode {
        case .presetRegion:
            screenshotCapture.refreshPresetRegion()
            guard screenshotCapture.hasPresetRegion else {
                showSetupRegionAlert = true
                return
            }
            Task { @MainActor in
                await screenshotCapture.silentCaptureSegment(reset: reset)
            }
        case .manualSelect:
            beginManualScreenshotCapture(reset: reset)
        }
    }

    @MainActor
    private func beginManualScreenshotCapture(reset: Bool) {
        Task { @MainActor in
            if reset {
                screenshotCapture.startMultiCapture()
            } else {
                screenshotCapture.continueCapture()
            }
        }
    }

    @MainActor
    private func removeLastScreenshot() {
        _ = screenshotCapture.removeLastCapture()
        coordinator.screenshotImage = screenshotCapture.capturedImages.last
        screenshotSubmissionState = .idle
    }

    @MainActor
    private func finishScreenshotAnalysis() async {
        screenshotSubmissionState = .loading
        let previewImage = screenshotCapture.capturedImages.last
        let recognizedText = screenshotCapture.finishAndMerge().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognizedText.isEmpty else {
            coordinator.aiText = L.t("No clear question was recognized. Try capturing a larger region.")
            coordinator.confidence = 0.18
            screenshotCapture.resetMultiCapture()
            screenshotSubmissionState = .idle
            return
        }

        if let previewImage { coordinator.screenshotImage = previewImage }
        await coordinator.askScreenshotQuestion(rawText: recognizedText)
        screenshotCapture.resetMultiCapture()
        screenshotSubmissionState = .success
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard screenshotSubmissionState == .success else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                screenshotSubmissionState = .idle
            }
        }
    }

    @MainActor
    private func handleCaptureModeChange(_ mode: ScreenshotCapture.CaptureMode) {
        switch mode {
        case .segmentDone:
            currentPrompterWindow()?.orderFrontRegardless()
            updateScreenShareVisibility()
        case .idle, .analyzing:
            currentPrompterWindow()?.orderFrontRegardless()
            updateScreenShareVisibility()
        case .capturing:
            break
        }
    }

    private func segmentPreviewText(_ segment: String) -> String {
        let prefix = String(segment.prefix(120))
        return segment.count > 120 ? "\(prefix)..." : prefix
    }
    #else
    @MainActor
    private func handleScreenshot() async {}
    #endif
}

private extension View {
    @ViewBuilder
    func hotkeyReceivers(_ coordinator: ReceiverCoordinator, screenshotHandler: @escaping @MainActor () async -> Void) -> some View {
        #if os(macOS)
        self.onReceive(NotificationCenter.default.publisher(for: .screenshotHotkey)) { _ in
            Task { await screenshotHandler() }
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct ResizeCursorTrackingView: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeCursorNSView {
        ResizeCursorNSView()
    }

    func updateNSView(_ nsView: ResizeCursorNSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class ResizeCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
#endif

private struct AnswerRenderer: View {
    let text: String
    let fontSize: CGFloat
    let primary: Color
    let secondary: Color
    let isPreparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    MarkdownTextView(
                        markdown: value,
                        fontSize: fontSize,
                        color: isPreparing ? secondary : primary
                    )
                case .code(let value, let language):
                    CodeBlockView(code: value.trimmingCharacters(in: .whitespacesAndNewlines), language: language)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [AnswerBlock] {
        AnswerBlock.parse(text)
    }
}

private struct MarkdownTextView: View {
    let markdown: String
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.52) {
            ForEach(Array(MarkdownDisplayBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let value):
                    markdownText(value)
                        .font(.system(size: headingSize(level), weight: .bold))
                        .lineSpacing(fontSize * 0.2)
                case .paragraph(let value):
                    markdownText(value)
                        .font(.system(size: fontSize, weight: .semibold))
                        .lineSpacing(fontSize * 0.38)
                case .listItem(let marker, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(.system(size: fontSize, weight: .bold))
                            .foregroundStyle(color.opacity(0.82))
                            .frame(minWidth: fontSize, alignment: .trailing)
                        markdownText(value)
                            .font(.system(size: fontSize, weight: .semibold))
                            .lineSpacing(fontSize * 0.32)
                    }
                case .quote(let value):
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color.opacity(0.45))
                            .frame(width: 3)
                        markdownText(value)
                            .font(.system(size: fontSize, weight: .medium))
                            .italic()
                            .foregroundStyle(color.opacity(0.82))
                    }
                case .divider:
                    Divider()
                        .overlay(color.opacity(0.22))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func markdownText(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        return Text(attributed)
            .foregroundColor(color)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize * 1.42
        case 2: return fontSize * 1.28
        case 3: return fontSize * 1.16
        default: return fontSize * 1.06
        }
    }
}

private enum MarkdownDisplayBlock {
    case heading(Int, String)
    case paragraph(String)
    case listItem(String, String)
    case quote(String)
    case divider

    static func parse(_ markdown: String) -> [MarkdownDisplayBlock] {
        var result: [MarkdownDisplayBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            result.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                flushParagraph()
                continue
            }

            let headingMarks = trimmed.prefix { $0 == "#" }
            if (1...6).contains(headingMarks.count),
               trimmed.dropFirst(headingMarks.count).first == " " {
                flushParagraph()
                let value = trimmed.dropFirst(headingMarks.count + 1).trimmingCharacters(in: .whitespaces)
                result.append(.heading(headingMarks.count, value))
                continue
            }

            if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                result.append(.divider)
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                result.append(.listItem("•", String(trimmed.dropFirst(2))))
                continue
            }

            let pieces = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if pieces.count == 2,
               pieces[0].hasSuffix("."),
               pieces[0].dropLast().allSatisfy(\.isNumber) {
                flushParagraph()
                result.append(.listItem(String(pieces[0]), String(pieces[1])))
                continue
            }

            paragraphLines.append(trimmed)
        }

        flushParagraph()
        return result.isEmpty ? [.paragraph(markdown)] : result
    }
}

private struct ScreenshotLoadingIndicator: View {
    @State private var rotation = 0.0

    var body: some View {
        Image("ScreenshotLoading")
            .resizable()
            .interpolation(.high)
            .frame(width: 22, height: 19)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct WaveformView: View {
    let level: Double
    let active: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<28, id: \.self) { index in
                let profile = 0.35 + abs(sin(Double(index) * 0.78)) * 0.65
                let height: CGFloat = active ? CGFloat(5 + (level * 21 * profile)) : 7
                Capsule()
                    .fill(active ? tint : Color(hex: "#777777"))
                    .frame(width: 2, height: height)
                    .animation(.easeOut(duration: 0.10), value: level)
            }
        }
    }
}

private struct ContinueCapturePlusIcon: View {
    var body: some View {
        ContinueCapturePlusShape()
            .fill(Color(hex: "#F4EA2A"))
    }
}

private struct ContinueCapturePlusShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 10
        let sy = rect.height / 10
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        path.move(to: point(9.4711, 4.47222))
        path.addLine(to: point(5.52444, 4.47222))
        path.addLine(to: point(5.52444, 0.526668))
        path.addCurve(to: point(4.4711, 0.526668), control1: point(5.52444, 0.236554), control2: point(5.289, 0))
        path.addLine(to: point(4.4711, 4.47333))
        path.addLine(to: point(0.526668, 4.47333))
        path.addCurve(to: point(0.526668, 5.52667), control1: point(0.235438, 4.47333), control2: point(0, 4.70877))
        path.addLine(to: point(4.47333, 5.52667))
        path.addLine(to: point(4.47333, 9.47333))
        path.addCurve(to: point(5.52667, 9.47333), control1: point(4.47333, 9.76345), control2: point(4.70877, 10))
        path.addLine(to: point(5.52667, 5.52667))
        path.addLine(to: point(9.47333, 5.52667))
        path.addCurve(to: point(9.4711, 4.47222), control1: point(9.76456, 5.52667), control2: point(10, 5.29123))
        path.closeSubpath()
        return path
    }
}

private struct DeleteCaptureIcon: View {
    var body: some View {
        ZStack {
            DeleteCaptureBodyShape()
                .fill(.white, style: FillStyle(eoFill: true))
            DeleteCaptureDetailShape()
                .fill(.white, style: FillStyle(eoFill: true))
        }
    }
}

private struct DeleteCaptureBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 7.5
        let sy = rect.height / 10
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        path.move(to: point(6.875, 10))
        path.addLine(to: point(0.625, 10))
        path.addLine(to: point(0.625, 2.8125))
        path.addLine(to: point(1.25, 2.8125))
        path.addLine(to: point(1.25, 9.375))
        path.addLine(to: point(6.25, 9.375))
        path.addLine(to: point(6.25, 2.8125))
        path.addLine(to: point(6.875, 2.8125))
        path.closeSubpath()
        path.addRect(CGRect(x: rect.minX, y: rect.minY + 1.5625 * sy, width: rect.width, height: 0.625 * sy))
        return path
    }
}

private struct DeleteCaptureDetailShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 7.5
        let sy = rect.height / 10
        var path = Path()
        path.addRect(CGRect(x: rect.minX + 2.1875 * sx, y: rect.minY, width: 3.125 * sx, height: 2.1875 * sy))
        path.addRect(CGRect(x: rect.minX + 2.8125 * sx, y: rect.minY + 0.625 * sy, width: 1.875 * sx, height: 0.9375 * sy))
        path.addRect(CGRect(x: rect.minX + 2.5 * sx, y: rect.minY + 3.75 * sy, width: 0.625 * sx, height: 4.375 * sy))
        path.addRect(CGRect(x: rect.minX + 4.375 * sx, y: rect.minY + 3.75 * sy, width: 0.625 * sx, height: 4.375 * sy))
        return path
    }
}

private struct TextreamDynamicIslandShape: Shape {
    var topInset: CGFloat = 16
    var bottomRadius: CGFloat = 18

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topInset, bottomRadius) }
        set {
            topInset = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let inset = min(topInset, width / 2)
        let radius = max(0, min(bottomRadius, min(width / 2 - inset, height - inset)))
        var path = Path()

        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: inset, y: inset),
            control: CGPoint(x: inset, y: 0)
        )
        path.addLine(to: CGPoint(x: inset, y: height - radius))
        path.addQuadCurve(
            to: CGPoint(x: inset + radius, y: height),
            control: CGPoint(x: inset, y: height)
        )
        path.addLine(to: CGPoint(x: width - inset - radius, y: height))
        path.addQuadCurve(
            to: CGPoint(x: width - inset, y: height - radius),
            control: CGPoint(x: width - inset, y: height)
        )
        path.addLine(to: CGPoint(x: width - inset, y: inset))
        path.addQuadCurve(
            to: CGPoint(x: width, y: 0),
            control: CGPoint(x: width - inset, y: 0)
        )
        path.closeSubpath()
        return path
    }
}

private enum AnswerBlock {
    case text(String)
    case code(String, String)

    static func parse(_ text: String) -> [AnswerBlock] {
        let parts = text.components(separatedBy: "```")
        guard parts.count > 1 else { return [.text(text)] }

        return parts.enumerated().compactMap { index, part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if index.isMultiple(of: 2) {
                return .text(trimmed)
            }
            let lines = trimmed.components(separatedBy: .newlines)
            let hasLanguage = lines.first?.range(of: #"^[A-Za-z0-9_+#.-]+$"#, options: .regularExpression) != nil
            let language = hasLanguage ? (lines.first ?? "code") : "code"
            let code = hasLanguage
                ? lines.dropFirst().joined(separator: "\n")
                : trimmed
            return .code(code, language)
        }
    }
}

private struct FlexibleTagLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestLine: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0 && lineWidth + spacing + size.width > maxWidth {
                widestLine = max(widestLine, lineWidth)
                totalHeight += lineHeight + rowSpacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += lineWidth == 0 ? size.width : spacing + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }

        widestLine = max(widestLine, lineWidth)
        totalHeight += lineHeight
        return CGSize(width: maxWidth == 0 ? widestLine : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + rowSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
