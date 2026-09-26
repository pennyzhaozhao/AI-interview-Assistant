import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
import CoreText
import UniformTypeIdentifiers
#else
import UIKit
#endif

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    @Query(sort: \InterviewSession.startedAt,
           order: .reverse)
    private var sessions: [InterviewSession]
    /// When false, skips the internal NavigationStack so it can be pushed
    /// onto a parent NavigationStack (e.g. from SettingsView).
    var wrapInNavigation: Bool = true
    @State private var selected: InterviewSession?
    @State private var searchText = ""
    @State private var selectedKind: InterviewSessionKind = .formal
    @State private var pendingDeleteSession: InterviewSession?
    @State private var showDeleteConfirm = false
    @State private var isSelecting = false
    @State private var selectedSessionIDs = Set<UUID>()
    @State private var showBulkDeleteConfirm = false
    @State private var previewImageData: Data?

    var body: some View {
        Group {
            if isCompact {
                mobileBody
            } else {
                desktopBody
            }
        }
        .background(Color.clear)
        .foregroundStyle(Color.appText)
        .onAppear { selected = selected ?? visibleSessions.first }
        .onChange(of: selectedKind) { _, _ in
            selected = visibleSessions.first
            exitSelectionMode()
        }
        .confirmationDialog(L.t("Confirm Delete"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L.t("Delete"), role: .destructive) {
                if let pendingDeleteSession {
                    deleteSession(pendingDeleteSession)
                }
                pendingDeleteSession = nil
            }
            Button(L.t("Cancel"), role: .cancel) {
                pendingDeleteSession = nil
            }
        } message: {
            Text(L.t("This cannot be undone."))
        }
        .confirmationDialog(L.t("Confirm Delete"), isPresented: $showBulkDeleteConfirm, titleVisibility: .visible) {
            Button(bulkDeleteTitle, role: .destructive) {
                deleteSelectedSessions()
            }
            Button(L.t("Cancel"), role: .cancel) {}
        } message: {
            Text(L.t("This cannot be undone."))
        }
        .sheet(item: imagePreviewBinding) { item in
            imagePreview(item.data)
        }
    }

    private var desktopBody: some View {
        HStack(spacing: 0) {
            sessionLibrary
                .frame(width: 430)
            conversationDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private var mobileBody: some View {
        let listContent = mobileListContent
        if wrapInNavigation {
            return AnyView(NavigationStack { listContent })
        } else {
            return AnyView(listContent)
        }
    }

    private var mobileListContent: some View {
        List {
            Section {
                searchField(L.t("Search history"), text: $searchText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            Section {
                Picker(L.t("History Type"), selection: $selectedKind) {
                    ForEach(InterviewSessionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(filteredSessions) { session in
                    Group {
                        if isSelecting {
                            Button {
                                toggleSessionSelection(session)
                            } label: {
                                HStack(spacing: 12) {
                                    selectionIndicator(selectedSessionIDs.contains(session.id))
                                    mobileSessionRow(session)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                mobileSessionDetail(session)
                            } label: {
                                mobileSessionRow(session)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    confirmDelete(session)
                                } label: {
                                    Label(L.t("Delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.bottom, 120, for: .scrollContent)
        .background(Color.appBG)
        .navigationTitle(L.t("Interview History"))
        .iosNavigationBarTitleDisplayMode(wrapInNavigation ? .large : .inline)
        .searchable(text: $searchText, prompt: L.t("Search"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isSelecting {
                    Button(L.t("Cancel")) {
                        exitSelectionMode()
                    }
                }
            }
            ToolbarItem(placement: mobileToolbarTrailingPlacement) {
                if isSelecting {
                    Button(L.t("Delete Selected")) {
                        showBulkDeleteConfirm = !selectedSessionIDs.isEmpty
                    }
                    .disabled(selectedSessionIDs.isEmpty)
                } else {
                    Button(L.t("Select")) {
                        isSelecting = true
                    }
                    .disabled(filteredSessions.isEmpty)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if isSelecting {
                    Button(allVisibleSessionsSelected ? L.t("Deselect All") : L.t("Select All")) {
                        toggleAllVisibleSessions()
                    }
                    .disabled(filteredSessions.isEmpty)
                }
            }
        }
    }

    private func mobileSessionRow(_ session: InterviewSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sessionDisplayTitle(session))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appText)
                .lineLimit(1)
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 13))
                .foregroundStyle(Color.appMuted)
            HStack(spacing: 5) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.appPrimary.opacity(0.8))
                Text(questionCountText(session.turns.count))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appMuted)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.06), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.appBorder, lineWidth: 1)
                )
        )
    }

    private func mobileSessionDetail(_ session: InterviewSession) -> some View {
        conversationDetail
            .padding(.horizontal, 16)
            .background(Color.appBG)
            .navigationTitle(sessionDisplayTitle(session))
            .iosNavigationBarTitleDisplayMode(.inline)
            .onAppear { selected = session }
    }

    private var sessionLibrary: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader
            kindPicker
            searchField(L.t("Search history"), text: $searchText)
            selectionToolbar
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredSessions) { session in
                        sessionCard(session)
                    }
                }
            }
        }
        .padding(24)
        .background(Color.appSurface.opacity(0.45))
    }

    private var selectionToolbar: some View {
        HStack(spacing: 10) {
            Button {
                isSelecting.toggle()
                if !isSelecting { selectedSessionIDs.removeAll() }
            } label: {
                Label(isSelecting ? L.t("Cancel") : L.t("Select"), systemImage: isSelecting ? "xmark" : "checkmark.circle")
            }
            .buttonStyle(AppButtonStyle())
            .disabled(filteredSessions.isEmpty && !isSelecting)

            if isSelecting {
                Button {
                    toggleAllVisibleSessions()
                } label: {
                    Label(allVisibleSessionsSelected ? L.t("Deselect All") : L.t("Select All"), systemImage: "checklist")
                }
                .buttonStyle(AppButtonStyle())
                .disabled(filteredSessions.isEmpty)

                Button {
                    showBulkDeleteConfirm = !selectedSessionIDs.isEmpty
                } label: {
                    Label(bulkDeleteTitle, systemImage: "trash")
                }
                .buttonStyle(AppButtonStyle(kind: .secondary))
                .disabled(selectedSessionIDs.isEmpty)
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("History"))
                .font(isCompact ? .appTitleCompact : .appTitle)
            Text(L.t("Review past interview conversations and outcomes."))
                .font(.appBody)
                .foregroundStyle(Color.appMuted)
        }
    }

    private var kindPicker: some View {
        Picker(L.t("History Type"), selection: $selectedKind) {
            ForEach(InterviewSessionKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
    }

    private func sessionCard(_ session: InterviewSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                if isSelecting {
                    selectionIndicator(selectedSessionIDs.contains(session.id))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(sessionDisplayTitle(session))
                        .font(.appBodyMedium)
                        .foregroundStyle(Color.appText)
                        .lineLimit(1)
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
                HStack(spacing: 8) {
                    StatusPill(text: shortQuestionCountText(session.turns.count), tint: .appPrimary)
                    if !isSelecting {
                        Button {
                            confirmDelete(session)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appDanger)
                                .frame(width: 32, height: 32)
                                .background(Color.appDanger.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 10) {
                metadataPill(questionCountText(session.turns.count), icon: "questionmark.bubble.fill")
                metadataPill(knowledgeCountText(session.activeKBIds.count), icon: "folder.fill")
                if session.kind == .mock, session.overallScore > 0 {
                    metadataPill("\(session.overallScore) \(L.t("Score"))", icon: "chart.bar.fill")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(padding: 16, hover: selected?.id == session.id)
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .onTapGesture {
            if isSelecting {
                toggleSessionSelection(session)
            } else {
                selected = session
            }
        }
    }

    private func selectionIndicator(_ isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isSelected ? Color.appPrimary : Color.appMuted)
            .frame(width: 28, height: 28)
    }

    private func metadataPill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.appSmall.weight(.semibold))
            .foregroundStyle(Color.appMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.appField)
            .clipShape(Capsule())
    }

    private var conversationDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selected.map(sessionDisplayTitle) ?? L.t("Conversation"))
                            .font(.appSection)
                        if let selected {
                            Text("\(selected.startedAt.formatted(date: .numeric, time: .standard)) · \(knowledgeBasesUsedText(selected.activeKBIds.count))")
                                .font(.appCaption)
                                .foregroundStyle(Color.appMuted)
                        } else {
                            Text(L.t("Select a session to inspect the interview flow."))
                                .font(.appCaption)
                                .foregroundStyle(Color.appMuted)
                        }
                    }
                    Spacer()
                    if let selected, selected.kind == .mock {
                        Button {
                            exportMockEvaluationPDF(selected)
                        } label: {
                            Label(L.t("Export Evaluation PDF"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(AppButtonStyle())
                    }
                }

                if let selected {
                    titleEditor(selected)
                    if selected.kind == .mock {
                        mockDetail(selected)
                    } else {
                        let turns = selected.turns.sorted { $0.createdAt < $1.createdAt }
                        if turns.isEmpty {
                            emptyDetail(L.t("This interview does not have AI question records yet."))
                        } else {
                            LazyVStack(spacing: 14) {
                                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                    conversationCard(label: "\(L.t("Question")) \(index + 1)", text: turn.question, tint: .appYellow)
                                    conversationCard(label: L.t("AI Answer"), text: turn.answer, tint: .appGreen, footer: turn.createdAt.formatted(date: .omitted, time: .standard), imageData: turn.screenshotData)
                                }
                            }
                        }
                    }
                } else {
                    emptyDetail(L.t("No interview history yet."))
                }
            }
            .padding(isCompact ? 0 : 32)
            .padding(.bottom, isCompact ? 140 : 32)
        }
    }

    private func conversationCard(label: String, text: String, tint: Color, footer: String? = nil, imageData: Data? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusPill(text: label, tint: tint)
                Spacer()
                if let footer {
                    Text(footer)
                        .font(.appSmall)
                        .foregroundStyle(Color.appMuted)
                }
            }
            Text(text)
                .font(.appBody)
                .foregroundStyle(Color.appText)
                .textSelection(.enabled)
            if let imageData {
                previewImage(imageData)
                    .frame(maxWidth: 360, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.appBorder))
                    .onTapGesture(count: 2) {
                        previewImageData = imageData
                    }
                    .help(L.t("Double-click to view image"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(padding: 18)
    }

    private func mockDetail(_ session: InterviewSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.overallScore > 0 || !session.summaryFeedback.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L.t("Interview Evaluation"))
                                .font(.appSection)
                            Text(session.summaryFeedback)
                                .font(.appBody)
                                .foregroundStyle(Color.appMuted)
                        }
                        Spacer()
                        Text("\(session.overallScore)")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 86, height: 86)
                            .background(Color.appPrimary)
                            .clipShape(Circle())
                    }
                    feedbackCard(L.t("Strengths"), text: session.strengthsText, tint: .appGreen)
                    feedbackCard(L.t("Improvement Suggestions"), text: session.improvementsText, tint: .appYellow)
                }
                .premiumCard()
            }

            let turns = session.turns.sorted { $0.createdAt < $1.createdAt }
            if turns.isEmpty {
                emptyDetail(L.t("This interview does not have AI question records yet."))
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        mockQuestionCard(index: index, turn: turn)
                    }
                }
            }
        }
    }

    private func mockQuestionCard(index: Int, turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusPill(text: "\(index + 1)", tint: .appPrimary)
                if !turn.category.isEmpty {
                    StatusPill(text: turn.category, tint: .appPrimary)
                }
                if turn.score > 0 {
                    StatusPill(text: "\(turn.score) \(L.t("Score"))", tint: .appGreen)
                }
                Spacer()
            }
            Text(turn.question)
                .font(.appBodyMedium)
                .foregroundStyle(Color.appText)
                .textSelection(.enabled)
            conversationSubBlock(L.t("Your Answer"), text: turn.answer)
            if !turn.feedback.isEmpty {
                conversationSubBlock(L.t("AI Deep Feedback"), text: turn.feedback)
            }
            if !turn.suggestedAnswer.isEmpty {
                conversationSubBlock(L.t("Suggested Answer"), text: turn.suggestedAnswer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(padding: 18)
    }

    private func feedbackCard(_ title: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusPill(text: title, tint: tint)
            Text(text.isEmpty ? L.t("No feedback yet.") : text)
                .font(.appBody)
                .foregroundStyle(Color.appText)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.appField)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func conversationSubBlock(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.appCaptionMedium)
                .foregroundStyle(Color.appMuted)
            Text(text)
                .font(.appBody)
                .foregroundStyle(Color.appText)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appField)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func titleEditor(_ session: InterviewSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("Conversation title"))
                .font(.appCaptionMedium)
                .foregroundStyle(Color.appMuted)
            TextField(L.t("Add a clear review title"), text: Binding(
                get: { session.title },
                set: { newValue in
                    session.title = newValue
                    session.updatedAt = .now
                    try? modelContext.save()
                }
            ))
            .textFieldStyle(.plain)
            .darkField()
        }
        .premiumCard(padding: 16)
    }

    private func emptyDetail(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.appMuted)
            Text(text)
                .font(.appBodyMedium)
                .foregroundStyle(Color.appMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .premiumCard()
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var currentLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .english
    }

    private func questionCountText(_ count: Int) -> String {
        currentLanguage == .chinese ? "\(count) 个问题" : "\(count) \(count == 1 ? "question" : "questions")"
    }

    private func shortQuestionCountText(_ count: Int) -> String {
        currentLanguage == .chinese ? "\(count) 问" : "\(count) Qs"
    }

    private func knowledgeCountText(_ count: Int) -> String {
        currentLanguage == .chinese ? "\(count) 个知识库" : "\(count) knowledge"
    }

    private func knowledgeBasesUsedText(_ count: Int) -> String {
        currentLanguage == .chinese ? "使用了 \(count) 个知识库" : "\(count) knowledge bases used"
    }

    private var filteredSessions: [InterviewSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleSessions }
        return visibleSessions.filter {
            $0.role.localizedCaseInsensitiveContains(query) ||
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.turns.contains { turn in
                turn.question.localizedCaseInsensitiveContains(query) ||
                turn.answer.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private func sessionDisplayTitle(_ session: InterviewSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if !session.role.isEmpty { return session.role }
        return "Local Interview"
    }

    private func searchField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appMuted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.appBody)
                .foregroundStyle(Color.appText)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color.appField)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous))
    }

    private var visibleSessions: [InterviewSession] {
        sessions.filter { $0.kind == selectedKind }
    }

    private var allVisibleSessionsSelected: Bool {
        !filteredSessions.isEmpty && filteredSessions.allSatisfy { selectedSessionIDs.contains($0.id) }
    }

    private var bulkDeleteTitle: String {
        "\(L.t("Delete Selected")) (\(selectedSessionIDs.count))"
    }

    private func toggleSessionSelection(_ session: InterviewSession) {
        if selectedSessionIDs.contains(session.id) {
            selectedSessionIDs.remove(session.id)
        } else {
            selectedSessionIDs.insert(session.id)
        }
    }

    private func toggleAllVisibleSessions() {
        if allVisibleSessionsSelected {
            filteredSessions.forEach { selectedSessionIDs.remove($0.id) }
        } else {
            filteredSessions.forEach { selectedSessionIDs.insert($0.id) }
        }
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedSessionIDs.removeAll()
    }

    private func confirmDeleteSelected() {
        guard let selected else { return }
        confirmDelete(selected)
    }

    private func confirmDelete(_ session: InterviewSession) {
        pendingDeleteSession = session
        showDeleteConfirm = true
    }

    private func deleteSession(_ session: InterviewSession) {
        let sessionID = session.id
        let next = visibleSessions.first(where: { $0.id != sessionID })
        if selected?.id == sessionID {
            selected = next
        }
        do {
            let descriptor = FetchDescriptor<InterviewSession>(predicate: #Predicate { $0.id == sessionID })
            guard let existing = try modelContext.fetch(descriptor).first else {
                try modelContext.save()
                return
            }
            let turns = existing.turns
            existing.turns.removeAll()
            for turn in turns {
                modelContext.delete(turn)
            }
            modelContext.delete(existing)
            try modelContext.save()
        } catch {
            print("Delete session failed: \(error.localizedDescription)")
        }
    }

    private func deleteSelectedSessions() {
        let ids = selectedSessionIDs
        guard !ids.isEmpty else { return }
        if let selected, ids.contains(selected.id) {
            self.selected = visibleSessions.first { !ids.contains($0.id) }
        }
        do {
            for session in sessions where ids.contains(session.id) {
                let turns = session.turns
                session.turns.removeAll()
                for turn in turns {
                    modelContext.delete(turn)
                }
                modelContext.delete(session)
            }
            try modelContext.save()
            exitSelectionMode()
        } catch {
            print("Delete selected sessions failed: \(error.localizedDescription)")
        }
    }

    private func exportMockEvaluationPDF(_ session: InterviewSession) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(safeFileName(sessionDisplayTitle(session)))-evaluation.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeMockEvaluationPDF(session, to: url)
        } catch {
            print("\(L.t("PDF export failed.")) \(error.localizedDescription)")
        }
        #endif
    }

    #if os(macOS)
    private func writeMockEvaluationPDF(_ session: InterviewSession, to url: URL) throws {
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 48
        let contentWidth = pageWidth - margin * 2
        let contentHeight = pageHeight - margin * 2

        let report = attributedMockEvaluationReport(session)

        // Use CGContext directly to avoid NSPrintOperation coordinate-flip bug
        // with detached (off-screen) NSTextView that causes mirrored text output.
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let pdfContext = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "InterviewAssistant", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L.t("PDF export failed.")])
        }

        let framesetter = CTFramesetterCreateWithAttributedString(report as CFAttributedString)
        var charIndex = 0
        let totalLength = report.length

        repeat {
            pdfContext.beginPDFPage(nil)

            // White background
            pdfContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            pdfContext.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

            // PDF context uses natural (Y-up) coordinates; CTFrameDraw matches this
            // natively, so no flip transform is needed — text renders right-side up.
            let contentRect = CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight)
            let path = CGMutablePath()
            path.addRect(contentRect)

            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(charIndex, 0), path, nil)
            CTFrameDraw(frame, pdfContext)

            pdfContext.endPDFPage()

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            if visibleRange.length == 0 { break }
            charIndex += visibleRange.length
        } while charIndex < totalLength

        pdfContext.closePDF()
    }

    private func attributedMockEvaluationReport(_ session: InterviewSession) -> NSAttributedString {
        let report = NSMutableAttributedString()
        let titleFont = NSFont.systemFont(ofSize: 24, weight: .bold)
        let headingFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let mutedFont = NSFont.systemFont(ofSize: 10)
        let titleColor = NSColor.labelColor
        let bodyColor = NSColor.labelColor
        let mutedColor = NSColor.secondaryLabelColor

        func append(_ text: String, font: NSFont, color: NSColor = .labelColor, spacing: CGFloat = 5) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            paragraph.paragraphSpacing = 7
            report.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]))
        }

        append("\(L.t("Mock Interview Evaluation"))\n", font: titleFont, color: titleColor)
        append("\(L.t("Created At")): \(session.startedAt.formatted(date: .numeric, time: .standard))\n\(L.t("Job Role")): \(session.role.isEmpty ? sessionDisplayTitle(session) : session.role)\n\(L.t("Overall Score")): \(session.overallScore)\n\n", font: mutedFont, color: mutedColor)
        append("\(L.t("Interview Evaluation"))\n", font: headingFont, color: titleColor)
        append("\(session.summaryFeedback)\n\n", font: bodyFont, color: bodyColor)
        append("\(L.t("Strengths"))\n", font: headingFont, color: titleColor)
        append("\(emptyFallback(session.strengthsText))\n\n", font: bodyFont, color: bodyColor)
        append("\(L.t("Improvement Suggestions"))\n", font: headingFont, color: titleColor)
        append("\(emptyFallback(session.improvementsText))\n\n", font: bodyFont, color: bodyColor)
        append("\(L.t("Question Review"))\n", font: headingFont, color: titleColor)

        for (index, turn) in session.turns.sorted(by: { $0.createdAt < $1.createdAt }).enumerated() {
            append("\n\(index + 1). \(turn.category.isEmpty ? L.t("Question") : turn.category)  \(turn.score > 0 ? "\(turn.score) \(L.t("Score"))" : "")\n", font: headingFont, color: titleColor)
            append("\(turn.question)\n\n", font: bodyFont, color: bodyColor)
            append("\(L.t("Your Answer"))\n", font: mutedFont, color: mutedColor)
            append("\(emptyFallback(turn.answer))\n\n", font: bodyFont, color: bodyColor)
            append("\(L.t("AI Improvement Suggestion"))\n", font: mutedFont, color: mutedColor)
            append("\(emptyFallback(turn.feedback))\n\n", font: bodyFont, color: bodyColor)
            if !turn.suggestedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append("\(L.t("Suggested Answer"))\n", font: mutedFont, color: mutedColor)
                append("\(turn.suggestedAnswer)\n", font: bodyFont, color: bodyColor)
            }
        }
        return report
    }
    #endif

    private func emptyFallback(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? L.t("No feedback yet.") : clean
    }

    private func safeFileName(_ text: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let parts = text.components(separatedBy: invalid).filter { !$0.isEmpty }
        let value = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "mock-interview" : value
    }

    private var imagePreviewBinding: Binding<ImagePreviewItem?> {
        Binding(
            get: {
                guard let previewImageData else { return nil }
                return ImagePreviewItem(data: previewImageData)
            },
            set: { item in
                previewImageData = item?.data
            }
        )
    }

    @ViewBuilder
    private func previewImage(_ data: Data) -> some View {
        #if os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        }
        #else
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        }
        #endif
    }

    private func imagePreview(_ data: Data) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            previewImage(data)
                .padding(24)
            Button {
                previewImageData = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

private struct ImagePreviewItem: Identifiable {
    let id = UUID()
    let data: Data
}

private var mobileToolbarTrailingPlacement: ToolbarItemPlacement {
    #if os(iOS)
    return .topBarTrailing
    #else
    return .automatic
    #endif
}

private enum MobileNavigationTitleMode {
    case large
    case inline
}

private extension View {
    @ViewBuilder
    func iosNavigationBarTitleDisplayMode(_ mode: MobileNavigationTitleMode) -> some View {
        #if os(iOS)
        switch mode {
        case .large:
            self.navigationBarTitleDisplayMode(.large)
        case .inline:
            self.navigationBarTitleDisplayMode(.inline)
        }
        #else
        self
        #endif
    }
}
