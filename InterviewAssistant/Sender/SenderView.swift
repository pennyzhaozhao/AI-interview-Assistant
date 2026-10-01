import SwiftUI
import SwiftData
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(macOS)
import AppKit
#endif

struct SenderView: View {
    private struct RemoteQuestion: Identifiable, Equatable {
        let id: String
        let text: String
        var answers: [String] = []
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppPreferenceKey.themeMode) private var themeMode = AppThemeMode.dark.rawValue
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    @State private var connection = TCPLineConnection()
    @State private var landingServer = TCPLineServer()
    @State private var localIP = "Detecting…"
    @State private var hostIP = ""
    @State private var draft = ""
    @State private var questions: [RemoteQuestion] = []
    @State private var selectedQuestion = 0
    @State private var remoteMode: DirectorMode = .director
    @State private var hostBoardOpen = false
    @State private var modeToast: String?
    @State private var showReceiver = false
    @State private var hostSession: InterviewSession?
    @State private var hostBoardActive = false
    #if os(macOS)
    @State private var floatingReceiver: NSWindowController?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) { ipCard; qrCard }
                    VStack(alignment: .leading, spacing: 18) { ipCard; qrCard }
                }
                questionPanel
                answerPanel
            }
            .padding(isCompact ? 16 : 32)
            .frame(maxWidth: 1120)
        }
        .background(directorBackground.ignoresSafeArea())
        .foregroundStyle(directorText)
        .environment(\.locale, currentLanguage.locale)
        .overlay(alignment: .top) {
            if let modeToast {
                Text(modeToast).font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(.ultraThinMaterial).clipShape(Capsule()).padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            localIP = LocalNetworkInfo.preferredIPAddress()
            connection.onPacket = receive
            configureLandingServer()
            if !hostBoardActive { landingServer.start() }
        }
        .onDisappear {
            connection.disconnect()
            if !hostBoardActive { landingServer.stop() }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showReceiver) {
            if let hostSession { ReceiverContainerView(session: hostSession, host: "", initialMode: .director) }
        }
        #endif
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("Director Mode")).font(.system(size: isCompact ? 34 : 52, weight: .bold, design: .rounded))
                Text(L.t("Host a prompt board or connect as a controller")).foregroundStyle(directorMuted)
            }
            Spacer()
            Button(L.t("Start")) { startHostBoard() }.buttonStyle(primaryButtonStyle)
        }
    }

    private var ipCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("YOUR IP ADDRESS")).directorLabel(color: directorMuted)
            Text(localIP).font(.system(size: 22, weight: .semibold, design: .monospaced))
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(directorField).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(L.t("ENTER HOST IP ADDRESS")).directorLabel(color: directorMuted)
            HStack(spacing: 10) {
                TextField("192.168.1.23", text: $hostIP).textFieldStyle(.plain)
                    .font(.system(size: 18, design: .monospaced)).padding(15)
                    .background(directorField).clipShape(RoundedRectangle(cornerRadius: 10)).onSubmit { connect() }
                Button(connection.isConnected ? L.t("Connected") : L.t("Connect")) { connect() }
                    .buttonStyle(primaryButtonStyle)
            }
            HStack(spacing: 7) {
                Circle().fill(connection.isConnected ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(connection.isConnected ? L.t("Connected to host") : L.t("Waiting for host connection"))
                    .font(.system(size: 13, weight: .medium))
            }
        }.directorCard(background: directorPanel).frame(maxWidth: .infinity)
    }

    private var qrCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("WEB CONTROLLER")).directorLabel(color: directorMuted)
            HStack(spacing: 18) {
                QRCodeView(text: controllerURL).padding(7).background(Color.white).frame(width: 136, height: 136)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("Scan to send without the app")).font(.system(size: 19, weight: .semibold))
                    Text(controllerURL).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(directorMuted).textSelection(.enabled)
                    Text(L.t("The Host prompt board must be running on the same Wi-Fi."))
                        .font(.system(size: 12)).foregroundStyle(directorMuted)
                }
            }
        }.directorCard(background: directorPanel).frame(maxWidth: .infinity)
    }

    private var questionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L.t("QUESTION")).directorLabel(color: directorMuted); Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label(
                        hostBoardOpen ? L.t("Host opened the prompt board") : L.t("Host closed the prompt board"),
                        systemImage: hostBoardOpen ? "rectangle.on.rectangle" : "rectangle.slash"
                    )
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hostBoardOpen ? Color.green : Color.red)
                    Text(remoteMode == .ai ? L.t("USER in AI mode") : L.t("USER in Director mode"))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.red)
                }
            }
            HStack(spacing: 16) {
                navButton("chevron.left", enabled: selectedQuestion > 0) { selectedQuestion -= 1 }
                Text(currentQuestion?.text ?? "").font(.system(size: isCompact ? 20 : 27, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading).textSelection(.enabled)
                navButton("chevron.right", enabled: selectedQuestion + 1 < questions.count) { selectedQuestion += 1 }
            }
            Text(questions.isEmpty ? L.t("Waiting for the Host to hear or capture a question") : "\(selectedQuestion + 1) / \(questions.count)")
                .font(.system(size: 12)).foregroundStyle(directorMuted)
        }.directorCard(background: directorPanel)
    }

    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("SEND MARKDOWN CONTENT")).directorLabel(color: directorMuted)
            if let answers = currentQuestion?.answers, !answers.isEmpty {
                Text(answers.joined(separator: "\n\n---\n\n")).font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(directorField).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            TextEditor(text: $draft).scrollContentBackground(.hidden).font(.system(size: 16, design: .monospaced))
                .padding(10).frame(minHeight: 150).background(directorField).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(directorBorder))
            HStack {
                Text(L.t("Supports headings, lists, code blocks and links")).font(.system(size: 12)).foregroundStyle(directorMuted)
                Spacer()
                Button(L.t("Clear")) { draft = "" }.buttonStyle(secondaryButtonStyle)
                Button(L.t("Send")) { send() }.buttonStyle(primaryButtonStyle)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connection.isConnected || !hostBoardOpen || remoteMode == .ai)
            }
        }.directorCard(background: directorPanel)
    }

    private var currentQuestion: RemoteQuestion? { questions.indices.contains(selectedQuestion) ? questions[selectedQuestion] : nil }
    private var controllerURL: String { "http://\(localIP):9999" }
    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var currentTheme: AppThemeMode { AppThemeMode(rawValue: themeMode) ?? .dark }
    private var currentLanguage: AppLanguage { AppLanguage(rawValue: language) ?? .english }
    private var isDark: Bool { currentTheme == .dark }
    private var directorBackground: Color { isDark ? Color(hex: "#101116") : Color(hex: "#F9FAFC") }
    private var directorPanel: Color { isDark ? Color(hex: "#1B1D24") : Color(hex: "#F0F1F4") }
    private var directorField: Color { isDark ? Color(hex: "#282B34") : .white }
    private var directorText: Color { isDark ? .white : .black }
    private var directorMuted: Color { directorText.opacity(0.5) }
    private var directorBorder: Color { directorText.opacity(0.12) }
    private var primaryButtonStyle: DirectorPrimaryButton { DirectorPrimaryButton(background: directorText, foreground: directorBackground) }
    private var secondaryButtonStyle: DirectorSecondaryButton { DirectorSecondaryButton(foreground: directorText, background: directorText.opacity(0.08)) }

    private func navButton(_ image: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(directorText.opacity(0.001)))
                .overlay(Circle().stroke(directorText, lineWidth: 1.5))
                .contentShape(Circle())
        }
            .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.22)
    }

    private func connect() {
        connection.connect(host: hostIP, mode: .sender)
    }

    private func receive(_ packet: DirectorPacket) {
        if let isOpen = packet.hostBoardOpen, isOpen != hostBoardOpen {
            hostBoardOpen = isOpen
            showToast(isOpen ? L.t("Host opened the prompt board") : L.t("Host closed the prompt board"))
        }
        if let mode = packet.mode, mode != remoteMode {
            remoteMode = mode
            showToast(mode == .ai ? L.t("User switched to AI mode") : L.t("User switched to Director mode"))
        }
        guard packet.kind == .question || packet.kind == .snapshot,
              let id = packet.questionID, let text = packet.text else { return }
        if let index = questions.firstIndex(where: { $0.id == id }) {
            questions[index] = RemoteQuestion(id: id, text: text, answers: questions[index].answers)
        } else {
            questions.append(RemoteQuestion(id: id, text: text)); selectedQuestion = questions.count - 1
        }
    }

    private func send() {
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        connection.send(.answer(clean, questionID: currentQuestion?.id))
        if questions.indices.contains(selectedQuestion) { questions[selectedQuestion].answers.append(clean) }
        draft = ""
    }

    private func showToast(_ text: String) {
        withAnimation { modeToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { modeToast = nil } }
    }

    @MainActor private func startHostBoard() {
        hostBoardActive = true
        landingServer.stop()
        let session = InterviewSession(title: "Director Mode", role: "Director Mode")
        modelContext.insert(session); try? modelContext.save(); hostSession = session
        #if os(macOS)
        NSApp.windows.compactMap { $0 as? PrompterPanel }.forEach { $0.close() }
        var controller: NSWindowController!
        let root = ReceiverContainerView(session: session, host: "", initialMode: .director, closeWindow: {
            controller?.close(); if floatingReceiver === controller { floatingReceiver = nil }
            hostBoardActive = false
            configureLandingServer()
            landingServer.start()
        }).modelContext(modelContext)
        controller = FloatingWindowController(rootView: root); floatingReceiver = controller; controller.window?.orderFrontRegardless()
        #else
        showReceiver = true
        #endif
    }

    private func configureLandingServer() {
        landingServer.stateProvider = {
            DirectorPacket(kind: .snapshot, mode: .director, hostBoardOpen: false)
        }
        landingServer.onPacket = { packet in
            if packet.kind == .hello {
                landingServer.send(DirectorPacket(kind: .snapshot, mode: .director, hostBoardOpen: false))
            }
        }
    }
}

private struct QRCodeView: View {
    let text: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()
    var body: some View {
        if let image = makeImage() { Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit() }
        else { Image(systemName: "qrcode").resizable().scaledToFit() }
    }
    private func makeImage() -> CGImage? {
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}

private struct DirectorPrimaryButton: ButtonStyle {
    let background: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold)).foregroundStyle(foreground).padding(.horizontal, 22)
            .frame(height: 48).background(background.opacity(configuration.isPressed ? 0.72 : 1)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
private struct DirectorSecondaryButton: ButtonStyle {
    let foreground: Color
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold)).foregroundStyle(foreground).padding(.horizontal, 18)
            .frame(height: 48).background(background.opacity(configuration.isPressed ? 0.7 : 1)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
private extension View {
    func directorCard(background: Color) -> some View { padding(20).background(background).clipShape(RoundedRectangle(cornerRadius: 14)) }
    func directorLabel(color: Color) -> some View { font(.system(size: 12, weight: .bold)).tracking(0.8).foregroundStyle(color) }
}
