import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// MARK: - Settings Hub

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppPreferenceKey.themeMode) private var themeMode = AppThemeMode.dark.rawValue
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    @AppStorage(AppPreferenceKey.mockInterviewLanguage) private var mockInterviewLanguageRaw = MockInterviewLanguage.followApp.rawValue
    @AppStorage(AppPreferenceKey.interviewerLanguage) private var interviewerLanguageRaw = MockInterviewLanguage.followApp.rawValue
    @AppStorage(AppPreferenceKey.resumeAIProcessing) private var resumeAIProcessingRaw = ResumeAIMode.ask.rawValue
    @State private var showingStoragePicker = false
    @State private var showingClearDataConfirmation = false
    @State private var showingStorageMessage = false
    @State private var storageMessage = ""
    @State private var storageRefreshID = UUID()
    @State private var showingVoiceSettings = false
    #if os(macOS)
    @State private var showingFeedbackComposer = false
    @State private var showingLogUploadResult = false
    @State private var logUploadResult = ""
    @State private var feedbackRecords: [SupportFeedbackRecord] = []
    @State private var isRefreshingFeedback = false
    @AppStorage(AppPreferenceKey.screenshotHotkey) private var screenshotHotkey = HotkeyManager.screenshotDefaultHotkey
    @AppStorage(AppPreferenceKey.screenshotMode) private var screenshotModeRaw = ScreenshotMode.presetRegion.rawValue
    @AppStorage(AppPreferenceKey.hiddenFromScreenCapture) private var hiddenFromScreenCapture = true
    @AppStorage(AppPreferenceKey.hideDockIcon) private var hideDockIcon = false
    @AppStorage(AppPreferenceKey.speechContentFilterLevel) private var speechContentFilterLevelRaw = SpeechContentFilterLevel.standard.rawValue
    @StateObject private var screenshotCapture = ScreenshotCapture()
    @State private var regionSetConfirmed = false
    #endif

    var body: some View {
        NavigationStack {
            if showingVoiceSettings {
                SpeakerEnrollmentView {
                    showingVoiceSettings = false
                }
            } else {
                settingsRoot
            }
        }
    }

    private var settingsRoot: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsGroups
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 140)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBG.ignoresSafeArea())
        .navigationTitle(L.t("Settings"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .animation(.easeInOut(duration: 0.48), value: themeMode)
        .id(language)
        .fileImporter(
            isPresented: $showingStoragePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleStorageFolderSelection
        )
        .alert(L.t("Clear Local Data"), isPresented: $showingClearDataConfirmation) {
            Button(L.t("Cancel"), role: .cancel) {}
            Button(L.t("Clear All Data"), role: .destructive) {
                clearAllUserData()
            }
        } message: {
            Text(L.t("This permanently deletes all interview history, knowledge bases, and saved screenshots. API keys and app preferences are not affected."))
        }
        .alert(L.t("Data Storage"), isPresented: $showingStorageMessage) {
            Button(L.t("OK"), role: .cancel) {}
        } message: {
            Text(storageMessage)
        }
        #if os(macOS)
        .sheet(isPresented: $showingFeedbackComposer) {
            FeedbackComposerView { record in
                feedbackRecords = SupportLogUploader.history()
                logUploadResult = String(format: L.t("Feedback submitted. Your tracking code is %@."), record.code)
                showingLogUploadResult = true
            }
        }
        .alert(L.t("Feedback"), isPresented: $showingLogUploadResult) {
            Button(L.t("OK"), role: .cancel) {}
        } message: {
            Text(logUploadResult)
        }
        .task {
            feedbackRecords = SupportLogUploader.history()
            await refreshFeedbackHistory()
        }
        #endif
    }

    private var settingsGroups: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection(L.t("Appearance")) {
                preferenceCard
            }

            settingsSection(L.t("Data Storage")) {
                dataStorageCard
            }

            settingsSection(L.t("AI")) {
                VStack(alignment: .leading, spacing: 12) {
                    preferenceCardRow(title: L.t("Mock Interviewer Language"), icon: "person.wave.2", tint: Color.appPrimary) {
                        PremiumMenuPicker(
                            selection: $mockInterviewLanguageRaw,
                            options: MockInterviewLanguage.allCases.map { ($0.rawValue, $0.title) },
                            minWidth: preferencePickerWidth
                        )
                    }

                    preferenceCardRow(title: L.t("Interviewer Speech Language"), icon: "waveform.and.mic", tint: Color.appPrimary) {
                        PremiumMenuPicker(
                            selection: $interviewerLanguageRaw,
                            options: MockInterviewLanguage.allCases.map { ($0.rawValue, $0.title) },
                            minWidth: preferencePickerWidth
                        )
                    }

                    preferenceCardRow(title: L.t("Organize uploaded resumes with AI"), icon: "person.text.rectangle", tint: Color.appPrimary) {
                        PremiumMenuPicker(
                            selection: $resumeAIProcessingRaw,
                            options: ResumeAIMode.allCases.map { ($0.rawValue, $0.title) },
                            minWidth: preferencePickerWidth
                        )
                    }

                    NavigationLink {
                        APIConfigView()
                    } label: {
                        Label(L.t("API Configure"), systemImage: "key.horizontal")
                    }
                    .buttonStyle(AppButtonStyle())

                    #if os(macOS)
                    preferenceCardRow(title: L.t("Screenshot OCR"), icon: "camera.viewfinder", tint: Color.appPrimary) {
                        HotkeyRecorderView(
                            hotkey: $screenshotHotkey,
                            preferenceKey: AppPreferenceKey.screenshotHotkey,
                            notificationName: .screenshotHotkey,
                            hotkeyID: HotkeyManager.screenshotID,
                            defaultHotkey: HotkeyManager.screenshotDefaultHotkey
                        )
                    }
                    screenshotModeCard
                    preferenceCardRow(title: L.t("Hide Prompter During Screen Sharing"), icon: "eye.slash.fill", tint: Color.appYellow) {
                        Toggle("", isOn: $hiddenFromScreenCapture)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .help(L.t("When enabled, the prompter is hidden from screenshots and screen sharing."))
                    }
                    preferenceCardRow(title: L.t("Hide Dock During Interview"), icon: "dock.rectangle", tint: Color.appMuted) {
                        Toggle("", isOn: $hideDockIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    #endif
                }
            }

            settingsSection(L.t("Speaker Recognition")) {
                VStack(alignment: .leading, spacing: 12) {
                speechContentFilterCard
                Button {
                    showingVoiceSettings = true
                } label: {
                    HStack(spacing: 14) {
                        iconTile("waveform.badge.mic", tint: Color.appPrimary)
                        Text(L.t("Set Up Voices"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.appText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.appMuted.opacity(0.8))
                    }
                    .frame(minHeight: 72)
                    .padding(.horizontal, 16)
                    .background(cardBackground(radius: 20))
                }
                .buttonStyle(.plain)
                }
            }

            #if os(macOS)
            settingsSection(L.t("Support")) {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        showingFeedbackComposer = true
                    } label: {
                        HStack(spacing: 14) {
                            iconTile("exclamationmark.bubble.fill", tint: Color.appPrimary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L.t("Report a Problem"))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.appText)
                                Text(L.t("Describe the issue, optionally attach diagnostic logs, and track its progress."))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.appMuted)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.appMuted)
                        }
                        .frame(minHeight: 72)
                        .padding(.horizontal, 16)
                        .background(cardBackground(radius: 20))
                    }
                    .buttonStyle(.plain)

                    if !feedbackRecords.isEmpty {
                        feedbackHistoryCard
                    }
                }
            }
            #endif

            settingsSection(L.t("About")) {
                SettingsCardLink(
                    title: L.t("About"),
                    subtitle: L.t("Version, support, and app information"),
                    icon: "info.circle.fill",
                    tint: Color(hex: "#64748B")
                ) {
                    AboutView()
                }
            }
        }
    }

    private var dataStorageCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                iconTile("externaldrive.fill", tint: Color.appPrimary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("Storage Location"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appText)
                    Text(L.t("Interview history, knowledge bases, and screenshots are stored together in this folder."))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(DataStorageManager.currentLocationDescription)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.appText)
                        .textSelection(.enabled)
                        .padding(.top, 3)
                        .id(storageRefreshID)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                Button(L.t("Choose Folder")) {
                    showingStoragePicker = true
                }
                .buttonStyle(AppButtonStyle(prominent: true))

                #if os(macOS)
                Button(L.t("Open Folder")) {
                    NSWorkspace.shared.open(DataStorageManager.currentStoreURL.deletingLastPathComponent())
                }
                .buttonStyle(AppButtonStyle())
                #endif

                Spacer()

                Button(L.t("Clear All Data"), role: .destructive) {
                    showingClearDataConfirmation = true
                }
                .buttonStyle(AppButtonStyle())
            }

            Text(L.t("The selected folder is used directly. Existing InterviewAssistant data is loaded; otherwise, your current data is copied there. Restart the app after changing folders."))
                .font(.system(size: 11))
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(cardBackground(radius: 20))
    }

    private func handleStorageFolderSelection(_ result: Result<[URL], Error>) {
        do {
            guard let folder = try result.get().first else { return }
            let selectionResult = try DataStorageManager.migrateData(from: modelContext, to: folder)
            storageRefreshID = UUID()
            switch selectionResult {
            case .copiedCurrentData:
                storageMessage = L.t("Your data was copied successfully. Quit and reopen InterviewAssistant to use the new storage location.")
            case .usingExistingData:
                storageMessage = L.t("Existing InterviewAssistant data was found. Quit and reopen InterviewAssistant to load it.")
            }
        } catch {
            storageMessage = String(format: L.t("Could not change the storage location: %@"), error.localizedDescription)
        }
        showingStorageMessage = true
    }

    private func clearAllUserData() {
        do {
            try DataStorageManager.deleteUserContent(in: modelContext)
            storageMessage = L.t("Interview history, knowledge bases, and screenshots were deleted.")
        } catch {
            storageMessage = String(format: L.t("Could not clear local data: %@"), error.localizedDescription)
        }
        showingStorageMessage = true
    }

    #if os(macOS)
    private var feedbackHistoryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L.t("Feedback History"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appText)
                Spacer()
                Button {
                    Task { await refreshFeedbackHistory() }
                } label: {
                    if isRefreshingFeedback { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshingFeedback)
                .help(L.t("Refresh Status"))
            }
            .padding(16)

            ForEach(Array(feedbackRecords.enumerated()), id: \.element.id) { index, record in
                if index > 0 { Divider().overlay(Color.appBorder) }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.issue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.appText)
                            .lineLimit(2)
                        Text("\(record.code) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.appMuted)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 10)
                    Text(record.status.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(feedbackStatusColor(record.status))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(feedbackStatusColor(record.status).opacity(0.13), in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(cardBackground(radius: 20))
    }

    private func refreshFeedbackHistory() async {
        guard !isRefreshingFeedback else { return }
        isRefreshingFeedback = true
        feedbackRecords = await SupportLogUploader.refreshHistory()
        isRefreshingFeedback = false
    }

    private func feedbackStatusColor(_ status: SupportFeedbackStatus) -> Color {
        switch status {
        case .new: return Color.appPrimary
        case .review: return Color.appYellow
        case .resolved: return Color.appGreen
        }
    }
    #endif

    private var preferenceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            preferenceRow(title: L.t("Language"), icon: "globe", tint: Color.appPrimary) {
                PremiumMenuPicker(
                    selection: $language,
                    options: AppLanguage.allCases.map { ($0.rawValue, $0.title) },
                    minWidth: preferencePickerWidth
                )
            }

            Divider().overlay(Color.appBorder)

            preferenceRow(title: L.t("Mode"), icon: "circle.lefthalf.filled", tint: Color.appYellow) {
                Button {
                    withAnimation(.easeInOut(duration: 0.48)) {
                        themeMode = themeMode == AppThemeMode.dark.rawValue
                            ? AppThemeMode.light.rawValue
                            : AppThemeMode.dark.rawValue
                    }
                } label: {
                    ZStack {
                        Image("NightModeToggle")
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .opacity(themeMode == AppThemeMode.dark.rawValue ? 1 : 0)
                        Image("LightModeToggle")
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .opacity(themeMode == AppThemeMode.light.rawValue ? 1 : 0)
                    }
                    .frame(width: 94, height: 39)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.t("Mode"))
                .accessibilityValue(themeMode == AppThemeMode.dark.rawValue ? L.t("Dark") : L.t("Light"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(cardBackground(radius: 20))
    }

    private var speechContentFilterCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            preferenceRow(title: L.t("Filter My Own Speech by Content"), icon: "text.badge.xmark", tint: Color.appPrimary) {
                PremiumMenuPicker(
                    selection: $speechContentFilterLevelRaw,
                    options: SpeechContentFilterLevel.allCases.map { ($0.rawValue, $0.title) },
                    minWidth: preferencePickerWidth
                )
            }
            Text(L.t("In microphone mode, transcripts that read like your own answer instead of an interviewer question are ignored. Works alongside voiceprints."))
                .font(.system(size: 12))
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(cardBackground(radius: 20))
    }

    private func preferenceCardRow<Control: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder control: () -> Control
    ) -> some View {
        preferenceRow(title: title, icon: icon, tint: tint, control: control)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(cardBackground(radius: 20))
    }

    #if os(macOS)
    private var screenshotMode: ScreenshotMode {
        get { ScreenshotMode(rawValue: screenshotModeRaw) ?? .presetRegion }
        nonmutating set { screenshotModeRaw = newValue.rawValue }
    }

    private var screenshotModeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                iconTile("viewfinder", tint: Color.appYellow)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("Screenshot Mode"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appText)
                    Text(L.t("Choose whether screenshots use a preset region for silent capture during interviews."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Label(
                    screenshotCapture.hasScreenCapturePermission ? L.t("Screen Recording Permission Granted") : L.t("Screen Recording Permission Not Granted"),
                    systemImage: screenshotCapture.hasScreenCapturePermission ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(screenshotCapture.hasScreenCapturePermission ? Color.appGreen : Color.appYellow)
                Spacer()
                if !screenshotCapture.hasScreenCapturePermission {
                    Button(L.t("Request Permission")) {
                        Task {
                            if !(await screenshotCapture.requestScreenCapturePermissionIfNeeded()) {
                                screenshotCapture.openScreenRecordingSettings()
                            }
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(ScreenshotMode.allCases) { mode in
                    Button {
                        screenshotMode = mode
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: screenshotMode == mode ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(screenshotMode == mode ? Color.appYellow : Color.appMuted)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.appText)
                                Text(mode.description)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.appMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if screenshotMode == .presetRegion {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Label(
                            screenshotCapture.hasPresetRegion ? L.t("Screenshot region set") : L.t("Screenshot region not set"),
                            systemImage: screenshotCapture.hasPresetRegion ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(screenshotCapture.hasPresetRegion ? Color.appGreen : Color.appYellow)
                        Spacer()
                        Button(screenshotCapture.hasPresetRegion ? L.t("Reset") : L.t("Set Region")) {
                            screenshotCapture.setupPresetRegion { _ in
                                regionSetConfirmed = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    regionSetConfirmed = false
                                }
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.bordered)
                        if screenshotCapture.hasPresetRegion {
                            Button(L.t("Clear")) {
                                screenshotCapture.clearPresetRegion()
                                regionSetConfirmed = false
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .buttonStyle(.bordered)
                        }
                    }
                    if regionSetConfirmed {
                        Label(L.t("Screenshot region saved. Use the hotkey or screenshot button during the interview to capture silently."), systemImage: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.appGreen)
                    }
                    Text(L.t("Set the region before the interview starts. During the interview, capture directly without affecting the interview window focus."))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.appBG.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.appBorder))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(cardBackground(radius: 20))
        .onAppear {
            screenshotCapture.refreshPresetRegion()
            screenshotCapture.refreshScreenCapturePermission()
        }
    }
    #endif

    private func preferenceRow<Control: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(icon, tint: tint)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            control()
        }
        .frame(maxWidth: .infinity, minHeight: 54)
    }

    private var preferencePickerWidth: CGFloat {
        horizontalSizeClass == .compact ? 160 : 180
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appMuted)
                .textCase(.uppercase)
                .padding(.horizontal, 4)
            content()
        }
    }
}

#if os(macOS)
private struct FeedbackComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var issue = ""
    @State private var includeLogs = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    let onSubmitted: (SupportFeedbackRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("Report a Problem"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.appText)
                    Text(L.t("Tell us what happened. You can follow the review status from Settings."))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("What went wrong?"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appText)
                TextEditor(text: $issue)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 150)
                    .background(Color.appBG.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder))
                Text("\(issue.count)/2000")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Toggle(isOn: $includeLogs) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("Attach Diagnostic Logs"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L.t("Logs are redacted before upload. API keys, voiceprints, resumes, screenshots, and interview history are not included."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted)
                }
            }
            .toggleStyle(.switch)

            HStack {
                Button(L.t("Cancel")) { dismiss() }
                    .buttonStyle(AppButtonStyle())
                    .disabled(isSubmitting)
                Spacer()
                Button {
                    submit()
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting { ProgressView().controlSize(.small) }
                        Text(isSubmitting ? L.t("Submitting...") : L.t("Submit Feedback"))
                    }
                }
                .buttonStyle(AppButtonStyle(prominent: true))
                .disabled(isSubmitting || issue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || issue.count > 2_000)
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(Color.appSurface)
        .alert(L.t("Feedback Could Not Be Sent"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L.t("OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            do {
                let record = try await SupportLogUploader.submitFeedback(issue: issue, includeLogs: includeLogs)
                onSubmitted(record)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
#endif

private struct SettingsCardLink<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 14) {
                iconTile(icon, tint: tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appText)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appMuted.opacity(0.8))
            }
            .frame(minHeight: 72)
            .padding(.horizontal, 16)
            .background(cardBackground(radius: 20))
        }
        .buttonStyle(.plain)
    }
}

struct SettingsBackButton: View {
    @Environment(\.dismiss) private var dismiss
    var title = "Settings"
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            if let action {
                action()
            } else {
                dismiss()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                Text(L.t(title))
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Color.appText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func iconTile(_ icon: String, tint: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: 42, height: 42)
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
    }
}

func cardBackground(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Color.appSurface.opacity(0.86))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.appBorder, lineWidth: 1)
        }
}

// MARK: - About View

struct AboutView: View {
    #if os(macOS)
    @ObservedObject private var updateChecker = UpdateChecker.shared
    #else
    @State private var updateChecker = UpdateChecker.shared
    #endif
    @State private var selectedPolicy: AboutPolicy?

    @ViewBuilder
    var body: some View {
        if let selectedPolicy {
            SimplePolicyView(title: selectedPolicy.rawValue) {
                self.selectedPolicy = nil
            }
        } else {
            aboutContent
        }
    }

    private var aboutContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsBackButton()
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Color.appPrimary)
                    VStack(spacing: 5) {
                        Text("Interview AI")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Color.appText)
                        Text(L.t("Your calm interview copilot."))
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appMuted)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(cardBackground(radius: 24))

                VStack(spacing: 12) {
                    infoRow(L.t("Version"), value: appVersion)
                    infoRow(L.t("Build"), value: buildNumber)
                    infoRow(L.t("Platform"), value: platformName)
                    infoRow(L.t("Storage"), value: L.t("Local only"))
                }
                .padding(18)
                .background(cardBackground(radius: 20))

                Button {
                    #if os(macOS)
                    updateChecker.checkForUpdates()
                    #else
                    Task { await updateChecker.check(manual: true) }
                    #endif
                } label: {
                    HStack(spacing: 12) {
                        iconTile("arrow.triangle.2.circlepath", tint: Color.appPrimary)
                        VStack(alignment: .leading, spacing: 3) {
                            #if os(macOS)
                            Text(L.t("Check for Updates..."))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.appText)
                            #else
                            Text(updateChecker.isChecking ? L.t("Checking for Updates...") : L.t("Check for Updates..."))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.appText)
                            #endif
                            #if !os(macOS)
                            if !updateChecker.statusText.isEmpty {
                                Text(updateChecker.statusText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.appMuted)
                                    .lineLimit(2)
                            }
                            #endif
                        }
                        Spacer()
                        #if os(macOS)
                        if !updateChecker.canCheckForUpdates {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appMuted)
                        }
                        #else
                        if updateChecker.isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appMuted)
                        }
                        #endif
                    }
                    .frame(minHeight: 52)
                    .padding(18)
                    .background(cardBackground(radius: 20))
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .disabled(!updateChecker.canCheckForUpdates)
                #else
                .disabled(updateChecker.isChecking)
                #endif

                VStack(spacing: 12) {
                    Button {
                        selectedPolicy = .privacy
                    } label: {
                        supportRow(L.t("Privacy Policy"), icon: "lock.shield.fill")
                    }
                    .buttonStyle(.plain)
                    Button {
                        selectedPolicy = .terms
                    } label: {
                        supportRow(L.t("Terms of Service"), icon: "doc.text.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
                .background(cardBackground(radius: 20))
            }
            .padding(20)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBG.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.appMuted)
            Spacer()
            Text(value).foregroundStyle(Color.appText)
        }
        .font(.system(size: 15, weight: .medium))
    }

    private func supportRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            iconTile(icon, tint: Color.appPrimary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appText)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appMuted)
        }
        .frame(minHeight: 52)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var platformName: String {
        #if os(macOS)
        return "macOS"
        #else
        return "iOS"
        #endif
    }
}

struct SimplePolicyView: View {
    let title: String
    var onBack: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsBackButton(title: "About", action: onBack)
                Text(L.t(title))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.appText)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections, id: \.heading) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.heading)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.appText)
                            Text(section.body)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.appMuted)
                                .lineSpacing(3)
                        }
                    }
                }
                .padding(20)
                .background(cardBackground(radius: 22))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBG.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
    }

    private var sections: [(heading: String, body: String)] {
        if title == "Privacy Policy" {
            return [
                (L.t("Local storage"), L.t("Interview AI stores interview history, knowledge bases, API configuration, and preferences locally on your device.")),
                (L.t("Credentials"), L.t("API keys and speech-service credentials are stored in Apple Keychain. They are used only to connect directly to the provider you configure. Voiceprints are encrypted in Keychain and never uploaded.")),
                (L.t("Third-party services"), L.t("When you use an external AI or speech provider, the question, relevant context, screenshot, or audio required for that request may be sent directly to that provider under its own privacy terms.")),
                (L.t("Your choices"), L.t("You can use Ollama and Apple on-device speech recognition for a more local workflow. You can delete locally stored interview and knowledge content from the app."))
            ]
        }
        return [
            (L.t("Using the app"), L.t("Interview AI is a preparation and assistance tool. You are responsible for complying with interview rules, workplace or school policies, and local laws.")),
            (L.t("AI output"), L.t("Generated responses can be incomplete or inaccurate. Review suggestions before relying on them.")),
            (L.t("Your content"), L.t("Do not send confidential or restricted content to an external model or speech provider unless you have permission.")),
            (L.t("Availability"), L.t("External model and speech features depend on the providers you configure. Fully local availability depends on your installed local models and Apple speech resources."))
        ]
    }
}

private enum AboutPolicy: String {
    case privacy = "Privacy Policy"
    case terms = "Terms of Service"
}
