import SwiftUI
import SwiftData

struct ReceiverContainerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var knowledgeBases: [KnowledgeBase]
    @State private var coordinator: ReceiverCoordinator
    @State private var showKB = false
    @State private var showHistory = false
    let session: InterviewSession
    let host: String
    var initialMode: DirectorMode = .ai
    var closeWindow: (() -> Void)?

    init(
        session: InterviewSession,
        host: String,
        initialMode: DirectorMode = .ai,
        directorServer: TCPLineServer? = nil,
        closeWindow: (() -> Void)? = nil
    ) {
        self.session = session
        self.host = host
        self.initialMode = initialMode
        self.closeWindow = closeWindow
        _coordinator = State(initialValue: ReceiverCoordinator(directorServer: directorServer))
    }

    var body: some View {
        PrompterOverlayView(coordinator: coordinator, onClose: close, onKB: { showKB = true }, onHistory: { showHistory = true })
            .onAppear { coordinator.start(session: session, knowledgeBases: knowledgeBases, modelContext: modelContext, host: host, initialMode: initialMode) }
            .onDisappear { coordinator.stop() }
            .sheet(isPresented: $showKB) {
                KnowledgeBaseManagerView(
                    activeIDs: Binding(get: { Set(session.activeKBIds) }, set: { session.activeKBIds = Array($0) }),
                    showsDismissButton: true
                )
            }
            .sheet(isPresented: $showHistory) {
                ZStack(alignment: .topTrailing) {
                    HistoryView()
                    Button(L.t("Done")) {
                        showHistory = false
                    }
                    .font(.appCaptionMedium)
                    .buttonStyle(AppButtonStyle())
                    .padding(20)
                }
            }
    }

    private func close() {
        coordinator.stop()
        closeWindow?()
        dismiss()
    }
}
