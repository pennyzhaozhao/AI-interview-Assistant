import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit

struct KnowledgeBaseManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    @Query(sort: \KnowledgeBase.updatedAt,
           order: .reverse)
    private var bases: [KnowledgeBase]
    @Binding var activeIDs: Set<UUID>
    var showsDismissButton: Bool = false
    /// When false, the mobile body omits its own NavigationStack so it can be
    /// pushed onto a parent NavigationStack (e.g. from SettingsView).
    var wrapInNavigation: Bool = true
    @State private var selected: KnowledgeBase?
    @State private var name = ""
    @State private var desc = ""
    @State private var url = ""
    @State private var importingDocument = false
    @State private var status = ""
    @State private var searchText = ""
    @State private var editingSource: KnowledgeEntry?
    @State private var sourceTitleDraft = ""
    @State private var sourceContentDraft = ""
    @State private var pendingDeleteBase: KnowledgeBase?
    @State private var showBaseDeleteConfirm = false
    @State private var isSelectingBases = false
    @State private var selectedBaseIDs = Set<UUID>()
    @State private var showBulkBaseDeleteConfirm = false
    @State private var pendingDeleteSource: KnowledgeEntry?
    @State private var showSourceDeleteConfirm = false
    // Structured sections (resume / skills / projects / materials / instructions).
    @State private var importTarget: ImportTarget = .material
    @State private var resumeStatus = ""
    @State private var isResumeBusy = false
    @State private var isSkillsBusy = false
    @State private var skillDraft = ""
    @State private var projectURL = ""
    @State private var projectStatus = ""
    @State private var isProjectBusy = false
    @State private var resumeExpanded = true
    @State private var skillsExpanded = true
    @State private var projectsExpanded = true
    @State private var materialsExpanded = true
    @State private var instructionsExpanded = false
    @State private var pendingResumeCandidate: ResumeCandidate?
    @State private var pendingResumeReplaceURL: URL?
    @State private var pendingCopy: PendingCopy?
    @State private var pendingResumeDelete = false

    private enum ImportTarget { case material, resume }

    private struct ResumeCandidate: Identifiable {
        let id = UUID()
        let tempURL: URL
        let fileName: String
        let text: String
    }

    private struct PendingCopy: Identifiable {
        let id = UUID()
        let entry: KnowledgeEntry
        let target: KnowledgeBase
    }

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
        .onAppear { selected = selected ?? visibleBases.first; loadSelected() }
        .onChange(of: selected) { _, _ in loadSelected() }
        .onChange(of: searchText) { _, _ in
            selectedBaseIDs = selectedBaseIDs.filter { id in
                filteredBases.contains { $0.id == id }
            }
        }
        .fileImporter(isPresented: $importingDocument, allowedContentTypes: importableDocumentTypes) { result in
            switch result {
            case .success(let url):
                if importTarget == .resume {
                    beginResumeImport(from: url)
                } else {
                    importDocument(from: url)
                }
            case .failure(let error):
                status = "\(L.t("Import failed")): \(error.localizedDescription)"
            }
        }
        .sheet(item: $editingSource) { entry in
            sourceEditor(entry)
        }
        .onChange(of: name) { _, _ in autosaveMetadata() }
        .onChange(of: desc) { _, _ in autosaveMetadata() }
        .confirmationDialog(L.t("Use as resume?"), isPresented: Binding(
            get: { pendingResumeCandidate != nil },
            set: { if !$0 { pendingResumeCandidate = nil } }
        ), titleVisibility: .visible, presenting: pendingResumeCandidate) { candidate in
            Button(L.t("Set as resume")) {
                pendingResumeCandidate = nil
                processResume(text: candidate.text, fileName: candidate.fileName)
                try? FileManager.default.removeItem(at: candidate.tempURL)
            }
            Button(L.t("Keep as material")) {
                pendingResumeCandidate = nil
                addMaterial(tempURL: candidate.tempURL, fileName: candidate.fileName, text: candidate.text)
            }
        } message: { candidate in
            Text(String(format: L.t("“%@” looks like a resume. Set it as this knowledge base's resume? AI will clean up the original and extract skills."), candidate.fileName))
        }
        .confirmationDialog(L.t("Replace resume?"), isPresented: Binding(
            get: { pendingResumeReplaceURL != nil },
            set: { if !$0 { pendingResumeReplaceURL = nil } }
        ), titleVisibility: .visible) {
            Button(L.t("Replace"), role: .destructive) {
                if let url = pendingResumeReplaceURL { importResume(from: url) }
                pendingResumeReplaceURL = nil
            }
            Button(L.t("Cancel"), role: .cancel) { pendingResumeReplaceURL = nil }
        } message: {
            Text(L.t("This knowledge base already has a resume. Uploading replaces its original and AI summary."))
        }
        .confirmationDialog(L.t("Replace resume?"), isPresented: Binding(
            get: { pendingCopy != nil },
            set: { if !$0 { pendingCopy = nil } }
        ), titleVisibility: .visible, presenting: pendingCopy) { copy in
            Button(L.t("Replace"), role: .destructive) {
                performCopy(copy.entry, to: copy.target)
                pendingCopy = nil
            }
            Button(L.t("Cancel"), role: .cancel) { pendingCopy = nil }
        } message: { copy in
            Text(String(format: L.t("“%@” already has a resume. Copying will replace it."), copy.target.name))
        }
        .confirmationDialog(L.t("Delete resume?"), isPresented: $pendingResumeDelete, titleVisibility: .visible) {
            Button(L.t("Delete"), role: .destructive) { deleteResume() }
            Button(L.t("Cancel"), role: .cancel) {}
        } message: {
            Text(L.t("The resume original and AI summary will be removed from this knowledge base. Skills are kept."))
        }
        .confirmationDialog(L.t("Confirm Delete"), isPresented: $showBaseDeleteConfirm, titleVisibility: .visible) {
            Button(L.t("Delete"), role: .destructive) {
                if let pendingDeleteBase {
                    deleteKnowledge(pendingDeleteBase)
                }
                pendingDeleteBase = nil
            }
            Button(L.t("Cancel"), role: .cancel) {
                pendingDeleteBase = nil
            }
        } message: {
            Text(L.t("This cannot be undone."))
        }
        .confirmationDialog(L.t("Confirm Delete"), isPresented: $showBulkBaseDeleteConfirm, titleVisibility: .visible) {
            Button(bulkDeleteTitle, role: .destructive) {
                deleteSelectedKnowledge()
            }
            Button(L.t("Cancel"), role: .cancel) {}
        } message: {
            Text(L.t("This cannot be undone."))
        }
        .confirmationDialog(L.t("Confirm Delete"), isPresented: $showSourceDeleteConfirm, titleVisibility: .visible) {
            Button(L.t("Delete"), role: .destructive) {
                if let pendingDeleteSource {
                    deleteSource(pendingDeleteSource)
                }
                pendingDeleteSource = nil
            }
            Button(L.t("Cancel"), role: .cancel) {
                pendingDeleteSource = nil
            }
        } message: {
            Text(L.t("This cannot be undone."))
        }
        .overlay(alignment: .topTrailing) {
            if showsDismissButton && !isCompact {
                Button(L.t("Done")) {
                    dismiss()
                }
                .font(.appCaptionMedium)
                .buttonStyle(AppButtonStyle())
                .padding(20)
            }
        }
    }

    private var desktopBody: some View {
        HStack(spacing: 0) {
            assetLibrary
                .frame(width: 430)
            detailView
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
                searchField(L.t("Search knowledge"), text: $searchText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            Section {
                ForEach(filteredBases) { kb in
                    Group {
                        if isSelectingBases {
                            Button {
                                toggleBaseSelection(kb)
                            } label: {
                                HStack(spacing: 12) {
                                    selectionIndicator(selectedBaseIDs.contains(kb.id))
                                    mobileAssetRow(kb)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                mobileDetailView(for: kb)
                            } label: {
                                mobileAssetRow(kb)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    confirmDelete(kb)
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
        .navigationTitle(L.t("Knowledge Base"))
        .iosNavigationBarTitleDisplayMode(wrapInNavigation ? .large : .inline)
        .searchable(text: $searchText, prompt: L.t("Search"))
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("Done")) {
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: mobileToolbarTrailingPlacement) {
                if isSelectingBases {
                    Button(L.t("Delete Selected")) {
                        showBulkBaseDeleteConfirm = !selectedBaseIDs.isEmpty
                    }
                    .disabled(selectedBaseIDs.isEmpty)
                } else {
                    Button {
                        addKB()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if isSelectingBases {
                    Button(allVisibleBasesSelected ? L.t("Deselect All") : L.t("Select All")) {
                        toggleAllVisibleBases()
                    }
                    .disabled(filteredBases.isEmpty)
                } else {
                    Button(L.t("Select")) {
                        isSelectingBases = true
                    }
                    .disabled(filteredBases.isEmpty)
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                if isSelectingBases {
                    Button(L.t("Cancel")) {
                        exitBaseSelectionMode()
                    }
                }
            }
        }
    }

    private func mobileAssetRow(_ kb: KnowledgeBase) -> some View {
        let isEnabled = activeIDs.contains(kb.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text(kb.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appText)
                .lineLimit(1)
            Text(cardSummary(kb))
                .font(.system(size: 13))
                .foregroundStyle(Color.appMuted)
            HStack(spacing: 5) {
                Circle()
                    .fill(isEnabled ? Color.appGreen : Color.appMuted.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(isEnabled ? L.t("Enabled") : L.t("Disabled"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isEnabled ? Color.appGreen : Color.appMuted)
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

    private func mobileDetailView(for kb: KnowledgeBase) -> some View {
        detailView
            .padding(.horizontal, 16)
            .background(Color.appBG)
            .navigationTitle(kb.name)
            .iosNavigationBarTitleDisplayMode(.inline)
            .onAppear {
                selected = kb
                loadSelected()
            }
    }

    private var assetLibrary: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader
            searchField(L.t("Search knowledge"), text: $searchText)
            selectionToolbar
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredBases) { kb in
                        assetCard(kb)
                    }
                }
            }
            HStack {
                Button {
                    addKB()
                } label: {
                    Label(L.t("New Knowledge Base"), systemImage: "plus")
                }
                .buttonStyle(AppButtonStyle(prominent: true))
            }
        }
        .padding(24)
        .background(Color.appSurface.opacity(0.45))
    }

    private var selectionToolbar: some View {
        HStack(spacing: 10) {
            Button {
                isSelectingBases.toggle()
                if !isSelectingBases { selectedBaseIDs.removeAll() }
            } label: {
                Label(isSelectingBases ? L.t("Cancel") : L.t("Select"), systemImage: isSelectingBases ? "xmark" : "checkmark.circle")
            }
            .buttonStyle(AppButtonStyle())
            .disabled(filteredBases.isEmpty && !isSelectingBases)

            if isSelectingBases {
                Button {
                    toggleAllVisibleBases()
                } label: {
                    Label(allVisibleBasesSelected ? L.t("Deselect All") : L.t("Select All"), systemImage: "checklist")
                }
                .buttonStyle(AppButtonStyle())
                .disabled(filteredBases.isEmpty)

                Button {
                    showBulkBaseDeleteConfirm = !selectedBaseIDs.isEmpty
                } label: {
                    Label(bulkDeleteTitle, systemImage: "trash")
                }
                .buttonStyle(AppButtonStyle(kind: .secondary))
                .disabled(selectedBaseIDs.isEmpty)
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("Knowledge Base"))
                .font(isCompact ? .appTitleCompact : .appTitle)
            Text(L.t("One knowledge base per target role: resume, skills, projects and materials live here."))
                .font(.appBody)
                .foregroundStyle(Color.appMuted)
        }
    }

    private func assetCard(_ kb: KnowledgeBase) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                if isSelectingBases {
                    selectionIndicator(selectedBaseIDs.contains(kb.id))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(kb.name)
                        .font(.appBodyMedium)
                        .foregroundStyle(Color.appText)
                        .lineLimit(1)
                    Text(kb.desc.isEmpty ? L.t("Reusable interview context and source material.") : kb.desc)
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(2)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        toggleKnowledgeEnabled(kb)
                    } label: {
                        StatusPill(
                            text: activeIDs.contains(kb.id) ? L.t("Enabled") : L.t("Off"),
                            tint: activeIDs.contains(kb.id) ? .appGreen : .appMuted
                        )
                    }
                    .buttonStyle(.plain)
                    .help(activeIDs.contains(kb.id) ? L.t("Disable this knowledge base") : L.t("Enable this knowledge base"))
                    if !isSelectingBases {
                        Button {
                            duplicateKnowledgeBase(kb)
                        } label: {
                            Image(systemName: "plus.square.on.square")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appText)
                                .frame(width: 32, height: 32)
                                .background(Color.appField)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(L.t("Duplicate"))
                        Button {
                            confirmDelete(kb)
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
                metadataPill(cardSummary(kb), icon: "square.stack.3d.up.fill")
                metadataPill(kb.updatedAt.formatted(date: .abbreviated, time: .omitted), icon: "calendar")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(padding: 16, hover: selected?.id == kb.id)
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .onTapGesture {
            if isSelectingBases {
                toggleBaseSelection(kb)
            } else {
                selected = kb
            }
        }
    }

    private func toggleKnowledgeEnabled(_ kb: KnowledgeBase) {
        if activeIDs.contains(kb.id) {
            activeIDs.remove(kb.id)
        } else {
            activeIDs.insert(kb.id)
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

    @ViewBuilder
    private var detailView: some View {
        if selected != nil {
            detailContent
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selected?.name ?? L.t("Asset Details"))
                            .font(.appSection)
                            .lineLimit(1)
                        Text(L.t("Edit metadata, import sources, and decide whether this asset is available to interviews."))
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }
                    Spacer()
                    Label(L.t("Saved automatically"), systemImage: "checkmark")
                        .font(.appSmall.weight(.semibold))
                        .foregroundStyle(Color.appMuted)
                        .padding(.top, 6)
                }

                if let selected {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: Binding(
                            get: { activeIDs.contains(selected.id) },
                            set: { isOn in
                                if isOn { activeIDs.insert(selected.id) } else { activeIDs.remove(selected.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L.t("Enabled for interviews"))
                                    .font(.appBodyMedium)
                                Text(L.t("AI will prioritize this asset when answering."))
                                    .font(.appCaption)
                                    .foregroundStyle(Color.appMuted)
                            }
                        }
                        .toggleStyle(.switch)

                        let fields = Group {
                            labeledField(L.t("Title")) {
                                TextField(L.t("Knowledge base title"), text: $name)
                                    .textFieldStyle(.plain)
                                    .darkField()
                            }
                            labeledField(L.t("Description")) {
                                TextField(L.t("Short description"), text: $desc)
                                    .textFieldStyle(.plain)
                                    .darkField()
                            }
                        }
                        if isCompact {
                            VStack(alignment: .leading, spacing: 14) { fields }
                        } else {
                            HStack(alignment: .top, spacing: 14) { fields }
                        }
                    }
                    .premiumCard()

                    resumeSection(selected)
                    skillsSection(selected)
                    projectsSection(selected)
                    materialsSection(selected)
                    instructionsSection(selected)
                }
            }
            .padding(isCompact ? 0 : 32)
            .padding(.bottom, isCompact ? 140 : 32)
        }
    }

    // MARK: - Sections

    private func sectionCard<Content: View>(
        _ title: String,
        badge: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.appBodyMedium)
                        .foregroundStyle(Color.appText)
                    if let badge {
                        Text(badge)
                            .font(.appSmall.weight(.semibold))
                            .foregroundStyle(Color.appMuted)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.appField)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.appMuted)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private func statusLine(_ text: String, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func smallButton(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(AppButtonStyle())
    }

    // 1. Resume
    private func resumeSection(_ kb: KnowledgeBase) -> some View {
        sectionCard(L.t("Resume"), badge: kb.resumeEntry == nil ? L.t("Not uploaded") : L.t("Uploaded"), isExpanded: $resumeExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let resume = kb.resumeEntry {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(resume.title, systemImage: "person.text.rectangle")
                                .font(.appBodyMedium)
                                .foregroundStyle(Color.appText)
                                .lineLimit(1)
                            Spacer()
                            if !resume.summary.isEmpty {
                                StatusPill(text: L.t("AI summary"), tint: .appPrimary)
                            }
                        }
                        Text(resume.summary.isEmpty ? String(resume.content.prefix(420)) : resume.summary)
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appField)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    FlowLayout(spacing: 8) {
                        smallButton(L.t("Edit original"), systemImage: "pencil") { beginEditingSource(resume) }
                        smallButton(L.t("Regenerate summary"), systemImage: "arrow.clockwise") { regenerateResumeSummary(kb) }
                            .disabled(isResumeBusy)
                        smallButton(L.t("Replace"), systemImage: "arrow.up.doc") { chooseResumeFile() }
                            .disabled(isResumeBusy)
                        copyToMenu(resume)
                        smallButton(L.t("Delete"), systemImage: "trash", role: .destructive) { pendingResumeDelete = true }
                    }
                } else {
                    Button { chooseResumeFile() } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.doc")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color.appPrimary)
                            Text(L.t("Upload resume (PDF / Word)"))
                                .font(.appBodyMedium)
                                .foregroundStyle(Color.appText)
                            Text(L.t("Click to choose a file. AI turns it into an editable Markdown original plus a summary and skill tags."))
                                .font(.appCaption)
                                .foregroundStyle(Color.appMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 130)
                        .padding(16)
                        .background(Color.appField)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.appBorder, style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isResumeBusy)
                }
                if !resumeStatus.isEmpty {
                    statusLine(resumeStatus, busy: isResumeBusy)
                }
            }
        }
    }

    // 2. Skills
    private func skillsSection(_ kb: KnowledgeBase) -> some View {
        sectionCard(L.t("Skills"), badge: "\(kb.skills.count)", isExpanded: $skillsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if kb.skills.isEmpty {
                    Text(L.t("No skills yet. They are extracted when you upload a resume, or add them yourself (comma-separated)."))
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(kb.skills, id: \.self) { skill in
                            HStack(spacing: 6) {
                                Text(skill)
                                    .font(.appSmall.weight(.semibold))
                                    .foregroundStyle(Color.appPrimary)
                                Button {
                                    removeSkill(skill, from: kb)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Color.appPrimary.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .help(L.t("Remove"))
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 9)
                            .padding(.vertical, 6)
                            .background(Color.appPrimary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }
                HStack(spacing: 10) {
                    TextField(L.t("Add a skill"), text: $skillDraft)
                        .textFieldStyle(.plain)
                        .darkField()
                        .onSubmit { addSkillsFromDraft(to: kb) }
                    smallButton(L.t("Add"), systemImage: "plus") { addSkillsFromDraft(to: kb) }
                    Button {
                        extractSkills(kb)
                    } label: {
                        HStack(spacing: 6) {
                            if isSkillsBusy { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                            Text(L.t("From resume"))
                        }
                    }
                    .buttonStyle(AppButtonStyle())
                    .disabled(kb.resumeEntry == nil || isSkillsBusy)
                    .help(L.t("Extract skills from the resume"))
                }
            }
        }
    }

    // 3. Projects (GitHub)
    private func projectsSection(_ kb: KnowledgeBase) -> some View {
        sectionCard(L.t("Projects"), badge: "\(kb.projectEntries.count)", isExpanded: $projectsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("https://github.com/…", text: $projectURL)
                        .textFieldStyle(.plain)
                        .darkField()
                        .onSubmit { importProjects(projectURL, into: kb) }
                    Button {
                        importProjects(projectURL, into: kb)
                    } label: {
                        HStack(spacing: 6) {
                            if isProjectBusy { ProgressView().controlSize(.small) }
                            Text(L.t("Add project"))
                        }
                    }
                    .buttonStyle(AppButtonStyle())
                    .disabled(isProjectBusy)
                }
                Text(L.t("Paste a GitHub repository link, or a profile link to import the 6 most recently updated repositories."))
                    .font(.appSmall)
                    .foregroundStyle(Color.appMuted)
                if !projectStatus.isEmpty {
                    statusLine(projectStatus, busy: isProjectBusy)
                }
                ForEach(kb.projectEntries) { project in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appPrimary)
                            .frame(width: 34, height: 34)
                            .background(Color.appPrimary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(project.title)
                                    .font(.appCaptionMedium)
                                    .foregroundStyle(Color.appText)
                                    .lineLimit(1)
                                if !project.meta.isEmpty {
                                    Text(project.meta)
                                        .font(.appSmall)
                                        .foregroundStyle(Color.appMuted)
                                }
                            }
                            Text(project.summary.isEmpty ? String(project.content.prefix(240)) : project.summary)
                                .font(.appSmall)
                                .foregroundStyle(Color.appMuted)
                                .lineLimit(3)
                        }
                        Spacer()
                        Toggle("", isOn: sourceEnabledBinding(for: project))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        entryMenu(project)
                    }
                    .padding(14)
                    .background(Color.appField)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    // 4. Materials
    private func materialsSection(_ kb: KnowledgeBase) -> some View {
        sectionCard(L.t("Materials"), badge: "\(kb.materialEntries.count)", isExpanded: $materialsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L.t("Notes, study documents, web pages and more. Pasting a GitHub link adds it to Projects automatically."))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                HStack(spacing: 10) {
                    smallButton(L.t("Upload File"), systemImage: "arrow.up.doc") {
                        importTarget = .material
                        importingDocument = true
                    }
                    smallButton(L.t("New note"), systemImage: "square.and.pencil") { addManualSource(to: kb) }
                }
                HStack(spacing: 10) {
                    TextField(L.t("Paste a web page, PDF or Google Drive link"), text: $url)
                        .textFieldStyle(.plain)
                        .darkField()
                        .onSubmit { importURL() }
                    smallButton(L.t("Import link"), systemImage: "link") { importURL() }
                }
                if !status.isEmpty {
                    statusLine(status, busy: false)
                }
                LazyVStack(spacing: 10) {
                    ForEach(kb.materialEntries) { entry in
                        sourceRow(entry)
                    }
                }
            }
        }
    }

    // 5. Custom instructions
    private func instructionsSection(_ kb: KnowledgeBase) -> some View {
        sectionCard(L.t("Custom instructions"), isExpanded: $instructionsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("Answer preferences for the AI, for this knowledge base only. For example: keep answers under 3 sentences; use the STAR structure; use simple English."))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                TextEditor(text: Binding(
                    get: { kb.customInstructions },
                    set: { value in
                        let limited = String(value.prefix(Self.instructionsLimit))
                        guard limited != kb.customInstructions else { return }
                        kb.customInstructions = limited
                        kb.updatedAt = .now
                        try? modelContext.save()
                    }
                ))
                .scrollContentBackground(.hidden)
                .font(.appBody)
                .frame(minHeight: 120, maxHeight: 240)
                .darkField()
                HStack {
                    Spacer()
                    Text("\(kb.customInstructions.count) / \(Self.instructionsLimit)")
                        .font(.appSmall)
                        .foregroundStyle(Color.appMuted)
                }
            }
        }
    }

    private static let instructionsLimit = 2000

    // MARK: - "⋯" menu: copy to another knowledge base, open, delete

    private func copyToMenu(_ entry: KnowledgeEntry) -> some View {
        Menu {
            let targets = bases.filter { $0.id != entry.knowledgeBase?.id }
            if targets.isEmpty {
                Text(L.t("No other knowledge bases"))
            }
            ForEach(targets) { target in
                Button(target.name) { requestCopy(entry, to: target) }
            }
        } label: {
            Label(L.t("Copy to…"), systemImage: "plus.square.on.square")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(AppButtonStyle())
        .fixedSize()
    }

    private func entryMenu(_ entry: KnowledgeEntry) -> some View {
        Menu {
            Menu(L.t("Copy to…")) {
                let targets = bases.filter { $0.id != entry.knowledgeBase?.id }
                if targets.isEmpty {
                    Text(L.t("No other knowledge bases"))
                }
                ForEach(targets) { target in
                    Button(target.name) { requestCopy(entry, to: target) }
                }
            }
            if let link = URL(string: entry.source), link.scheme?.hasPrefix("http") == true {
                Link(entry.kind == KnowledgeEntryKind.project ? L.t("Open on GitHub") : L.t("Open link"), destination: link)
            }
            Divider()
            Button(L.t("Delete"), role: .destructive) { confirmDeleteSource(entry) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appMuted)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func sourceRow(_ entry: KnowledgeEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sourceIcon(for: entry))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(sourceTint(for: entry))
                    .frame(width: 34, height: 34)
                    .background(sourceTint(for: entry).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(displayTitle(for: entry))
                        .font(.appCaptionMedium)
                        .foregroundStyle(Color.appText)
                        .lineLimit(2)
                    Text(sourceLabel(for: entry))
                        .font(.appSmall)
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("", isOn: sourceEnabledBinding(for: entry))
                    .labelsHidden()
                    .toggleStyle(.switch)

                Button {
                    beginEditingSource(entry)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                        .frame(width: 34, height: 34)
                        .background(Color.appPrimary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)

                entryMenu(entry)
            }

            if !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(entry.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.appSmall)
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.appBG.opacity(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(14)
        .background(Color.appField)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sourceEditor(_ entry: KnowledgeEntry) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                labeledField(L.t("Source title")) {
                    TextField(L.t("Source title"), text: $sourceTitleDraft)
                        .textFieldStyle(.plain)
                        .darkField()
                }

                if isPDFSource(entry) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.t("PDF Preview"))
                            .font(.appCaptionMedium)
                            .foregroundStyle(Color.appMuted)
                        if let url = pdfURL(for: entry), FileManager.default.fileExists(atPath: url.path) {
                            PDFPagesPreview(url: url)
                                .frame(height: isCompact ? 420 : 520)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous)
                                        .stroke(Color.appBorder, lineWidth: 1)
                                )
                        } else {
                            Text(entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L.t("The original PDF file is not available. Re-import this PDF to enable preview.") : entry.content)
                                .font(.appBody)
                                .foregroundStyle(Color.appText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, minHeight: isCompact ? 360 : 500, alignment: .topLeading)
                                .padding(16)
                                .background(Color.appField)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous))
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.kind == KnowledgeEntryKind.resume ? L.t("Resume original (Markdown)") : L.t("Content"))
                            .font(.appCaptionMedium)
                            .foregroundStyle(Color.appMuted)
                        if entry.kind == KnowledgeEntryKind.resume {
                            Text(L.t("The AI summary is regenerated after you save the original."))
                                .font(.appSmall)
                                .foregroundStyle(Color.appMuted)
                        }
                        TextEditor(text: $sourceContentDraft)
                            .scrollContentBackground(.hidden)
                            .font(.appBody)
                            .frame(height: isCompact ? 360 : 500)
                            .darkField()
                    }
                }
            }
            .padding(24)
            .frame(minWidth: isCompact ? 0 : 680, minHeight: isCompact ? 0 : 650)
            .background(Color.appBG)
            .foregroundStyle(Color.appText)
            .navigationTitle(L.t("Edit Source"))
            .iosNavigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("Cancel")) {
                        editingSource = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("Save")) {
                        saveSourceEdit(entry)
                    }
                }
            }
        }
        .onAppear {
            sourceTitleDraft = displayTitle(for: entry)
            sourceContentDraft = entry.content
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.appCaptionMedium)
                .foregroundStyle(Color.appMuted)
            content()
        }
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

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var currentLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .english
    }

    private func fileCountText(_ count: Int) -> String {
        currentLanguage == .chinese ? "\(count) 个文件" : "\(count) \(count == 1 ? "file" : "files")"
    }

    private func enabledSourceCountText(_ enabled: Int, total: Int) -> String {
        currentLanguage == .chinese ? "\(enabled)/\(total) 已启用" : "\(enabled)/\(total) enabled"
    }

    private var filteredBases: [KnowledgeBase] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleBases }
        return visibleBases.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.desc.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleBases: [KnowledgeBase] {
        bases
    }

    private var allVisibleBasesSelected: Bool {
        !filteredBases.isEmpty && filteredBases.allSatisfy { selectedBaseIDs.contains($0.id) }
    }

    private var bulkDeleteTitle: String {
        "\(L.t("Delete Selected")) (\(selectedBaseIDs.count))"
    }

    private func toggleBaseSelection(_ kb: KnowledgeBase) {
        if selectedBaseIDs.contains(kb.id) {
            selectedBaseIDs.remove(kb.id)
        } else {
            selectedBaseIDs.insert(kb.id)
        }
    }

    private func toggleAllVisibleBases() {
        if allVisibleBasesSelected {
            filteredBases.forEach { selectedBaseIDs.remove($0.id) }
        } else {
            filteredBases.forEach { selectedBaseIDs.insert($0.id) }
        }
    }

    private func exitBaseSelectionMode() {
        isSelectingBases = false
        selectedBaseIDs.removeAll()
    }

    private func loadSelected() {
        guard let selected else { return }
        name = selected.name
        desc = selected.desc
    }

    private func addKB() {
        let kb = KnowledgeBase(name: L.t("New Knowledge Asset"), desc: L.t("Interview context, notes, or portfolio material"))
        modelContext.insert(kb)
        activeIDs.insert(kb.id)
        try? modelContext.save()
        selected = kb
    }

    private func confirmDeleteSelected() {
        guard let selected else { return }
        confirmDelete(selected)
    }

    private func confirmDelete(_ kb: KnowledgeBase) {
        pendingDeleteBase = kb
        showBaseDeleteConfirm = true
    }

    private func deleteKnowledge(_ kb: KnowledgeBase) {
        let next = visibleBases.first(where: { $0.id != kb.id })
        activeIDs.remove(kb.id)
        if selected?.id == kb.id {
            selected = next
        }
        do {
            modelContext.delete(kb)
            try modelContext.save()
        } catch {
            print("Delete knowledge failed: \(error.localizedDescription)")
        }
    }

    private func deleteSelectedKnowledge() {
        let ids = selectedBaseIDs
        guard !ids.isEmpty else { return }
        activeIDs.subtract(ids)
        if let selected, ids.contains(selected.id) {
            self.selected = visibleBases.first { !ids.contains($0.id) }
        }
        do {
            for kb in bases where ids.contains(kb.id) {
                modelContext.delete(kb)
            }
            try modelContext.save()
            exitBaseSelectionMode()
        } catch {
            print("Delete selected knowledge failed: \(error.localizedDescription)")
        }
    }

    private func save() {
        guard let selected else { return }
        selected.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L.t("Untitled Knowledge Asset") : name
        selected.desc = desc
        selected.updatedAt = .now
        try? modelContext.save()
        status = L.t("Saved")
    }

    private func importURL() {
        guard let selected else { return }
        let input = url
        if GitHubProjectImporter.isGitHubURL(input) {
            // GitHub links belong in the Projects section.
            url = ""
            status = L.t("GitHub link detected — added to Projects.")
            importProjects(input, into: selected)
            return
        }
        status = L.t("Importing...")
        Task {
            do {
                let text = try await URLFetcher.fetchText(from: input)
                await MainActor.run {
                    let title = sourceTitle(from: input)
                    let entry = KnowledgeEntry(title: title, content: text, source: input, isEnabled: true, knowledgeBase: selected)
                    entry.kindRaw = KnowledgeEntryKind.material
                    selected.entries.append(entry)
                    selected.updatedAt = .now
                    try? modelContext.save()
                    url = ""
                    status = L.t("Link imported")
                }
            } catch {
                await MainActor.run {
                    status = "\(L.t("Import failed")): \(error.localizedDescription)"
                }
            }
        }
    }

    private var importableDocumentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text, .rtf, .html, .json]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        #if os(macOS)
        if let doc = UTType(filenameExtension: "doc") { types.append(doc) }
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        #endif
        return types
    }

    private func importDocument(from sourceURL: URL) {
        guard let selected else { return }
        status = L.t("Importing...")

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let safeName = sourceURL.lastPathComponent.isEmpty ? "Imported Document" : sourceURL.lastPathComponent
            let tempURL = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString)-\(safeName)")
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)

            Task {
                do {
                    let text = try DocumentTextImporter.extractText(from: tempURL, maxCharacters: 20_000)
                    await MainActor.run {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            try? FileManager.default.removeItem(at: tempURL)
                            status = L.t("File imported, but no readable text was found")
                            return
                        }
                        if selected.resumeEntry == nil, KnowledgeAssistant.looksLikeResume(fileName: safeName, text: trimmed) {
                            pendingResumeCandidate = ResumeCandidate(tempURL: tempURL, fileName: safeName, text: trimmed)
                            return
                        }
                        addMaterial(tempURL: tempURL, fileName: safeName, text: trimmed)
                    }
                } catch {
                    await MainActor.run {
                        try? FileManager.default.removeItem(at: tempURL)
                        status = "\(L.t("Import failed")): \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            status = "\(L.t("Import failed")): \(error.localizedDescription)"
        }
    }

    private func sourceEntries(for kb: KnowledgeBase) -> [KnowledgeEntry] {
        visibleEntries(for: kb).sorted {
            if $0.isEnabled != $1.isEnabled { return $0.isEnabled && !$1.isEnabled }
            return $0.createdAt > $1.createdAt
        }
    }

    private func hasManualSource(_ kb: KnowledgeBase) -> Bool {
        visibleEntries(for: kb).contains { $0.source == "manual" || $0.title == "主要内容" || $0.title == "Main Content" }
    }

    private func visibleEntries(for kb: KnowledgeBase) -> [KnowledgeEntry] {
        kb.entries
    }

    private func addManualSource(to kb: KnowledgeBase) {
        let entry = KnowledgeEntry(title: L.t("Note"), content: "", source: "manual", isEnabled: true, knowledgeBase: kb)
        entry.kindRaw = KnowledgeEntryKind.material
        kb.entries.append(entry)
        kb.updatedAt = .now
        do {
            try modelContext.save()
            beginEditingSource(entry)
            status = L.t("Main Content added")
        } catch {
            status = "\(L.t("Add source failed")): \(error.localizedDescription)"
        }
    }

    private func displayTitle(for entry: KnowledgeEntry) -> String {
        (entry.title == "主要内容" || entry.title == "Main Content") ? L.t("Main Content") : entry.title
    }

    private func beginEditingSource(_ entry: KnowledgeEntry) {
        sourceTitleDraft = displayTitle(for: entry)
        sourceContentDraft = entry.content
        editingSource = entry
    }

    private func saveSourceEdit(_ entry: KnowledgeEntry) {
        let trimmedTitle = sourceTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.title = trimmedTitle.isEmpty ? L.t("Main Content") : trimmedTitle
        if !isPDFSource(entry) {
            entry.content = sourceContentDraft
        }
        entry.updatedAt = .now
        entry.knowledgeBase?.updatedAt = .now
        do {
            try modelContext.save()
            status = L.t("Source saved")
            editingSource = nil
            if entry.kind == KnowledgeEntryKind.resume, let kb = entry.knowledgeBase, !isResumeBusy {
                isResumeBusy = true
                let config = AIService.config(from: modelContext)
                Task { @MainActor in
                    await digestResume(entry, in: kb, mergeSkills: false, config: config)
                    isResumeBusy = false
                }
            }
        } catch {
            status = "\(L.t("Save source failed")): \(error.localizedDescription)"
        }
    }

    private func sourceEnabledBinding(for entry: KnowledgeEntry) -> Binding<Bool> {
        Binding(
            get: { entry.isEnabled },
            set: { isEnabled in
                entry.isEnabled = isEnabled
                entry.updatedAt = .now
                entry.knowledgeBase?.updatedAt = .now
                try? modelContext.save()
            }
        )
    }

    private func confirmDeleteSource(_ entry: KnowledgeEntry) {
        pendingDeleteSource = entry
        showSourceDeleteConfirm = true
    }

    private func deleteSource(_ entry: KnowledgeEntry) {
        let base = entry.knowledgeBase
        base?.updatedAt = .now
        do {
            modelContext.delete(entry)
            try modelContext.save()
            status = L.t("Source deleted")
        } catch {
            status = "\(L.t("Delete source failed")): \(error.localizedDescription)"
        }
    }

    // MARK: - Structured knowledge base actions

    private func cardSummary(_ kb: KnowledgeBase) -> String {
        let chinese = currentLanguage == .chinese
        var parts: [String] = []
        if kb.resumeEntry != nil { parts.append(chinese ? "简历 ✓" : "Resume ✓") }
        let projects = kb.projectEntries.count
        let materials = kb.materialEntries.count
        let skills = kb.skills.count
        if projects > 0 { parts.append(chinese ? "\(projects) 个项目" : "\(projects) project\(projects == 1 ? "" : "s")") }
        if materials > 0 { parts.append(chinese ? "\(materials) 份资料" : "\(materials) material\(materials == 1 ? "" : "s")") }
        if skills > 0 { parts.append(chinese ? "\(skills) 项技能" : "\(skills) skill\(skills == 1 ? "" : "s")") }
        return parts.isEmpty ? (chinese ? "空知识库" : "Empty") : parts.joined(separator: " · ")
    }

    /// Title / description save as you type (no Save button).
    private func autosaveMetadata() {
        guard let selected else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmedName.isEmpty ? selected.name : name
        guard newName != selected.name || desc != selected.desc else { return }
        selected.name = newName
        selected.desc = desc
        selected.updatedAt = .now
        try? modelContext.save()
    }

    private func duplicateKnowledgeBase(_ source: KnowledgeBase) {
        let suffix = currentLanguage == .chinese ? " 副本" : " copy"
        let copy = KnowledgeBase(name: source.name + suffix, desc: source.desc)
        copy.skillsData = source.skillsData
        copy.customInstructions = source.customInstructions
        modelContext.insert(copy)
        for entry in source.entries {
            let duplicate = entry.duplicate(into: copy)
            copy.entries.append(duplicate)
        }
        try? modelContext.save()
        selected = copy
        status = String(format: L.t("Duplicated as “%@”"), copy.name)
    }

    private func requestCopy(_ entry: KnowledgeEntry, to target: KnowledgeBase) {
        if entry.kind == KnowledgeEntryKind.resume, target.resumeEntry != nil {
            pendingCopy = PendingCopy(entry: entry, target: target)
        } else {
            performCopy(entry, to: target)
        }
    }

    /// Independent copy of one resume / project / material into another knowledge base.
    private func performCopy(_ entry: KnowledgeEntry, to target: KnowledgeBase) {
        if entry.kind == KnowledgeEntryKind.resume {
            for old in target.entries where old.kind == KnowledgeEntryKind.resume { modelContext.delete(old) }
            target.entries.removeAll { $0.kind == KnowledgeEntryKind.resume }
            if let source = entry.knowledgeBase { target.skills = mergedSkills(target.skills, source.skills) }
        }
        let copy = entry.duplicate(into: target)
        target.entries.append(copy)
        target.updatedAt = .now
        try? modelContext.save()
        status = String(format: L.t("Copied to “%@”"), target.name)
    }

    // Resume

    private func chooseResumeFile() {
        importTarget = .resume
        importingDocument = true
    }

    private func beginResumeImport(from url: URL) {
        if selected?.resumeEntry != nil {
            pendingResumeReplaceURL = url
        } else {
            importResume(from: url)
        }
    }

    /// Upload flow: extract text → AI Markdown (original) → AI summary + skills.
    private func importResume(from sourceURL: URL) {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let fileName = sourceURL.lastPathComponent
            let tempURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(fileName)")
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let text = try DocumentTextImporter.extractText(from: tempURL, maxCharacters: 40_000)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                resumeStatus = L.t("No readable text was found in this file.")
                return
            }
            processResume(text: text, fileName: fileName)
        } catch {
            resumeStatus = "\(L.t("Import failed")): \(error.localizedDescription)"
        }
    }

    private func processResume(text: String, fileName: String) {
        guard let kb = selected, !isResumeBusy else { return }
        isResumeBusy = true
        resumeStatus = L.t("Converting resume to Markdown…")
        let config = AIService.config(from: modelContext)
        Task { @MainActor in
            var markdown = text
            if let converted = try? await KnowledgeAssistant.resumeToMarkdown(text, config: config),
               converted.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                markdown = converted
            }
            for old in kb.entries where old.kind == KnowledgeEntryKind.resume { modelContext.delete(old) }
            kb.entries.removeAll { $0.kind == KnowledgeEntryKind.resume }
            let entry = KnowledgeEntry(
                title: (fileName as NSString).deletingPathExtension,
                content: markdown,
                source: "resume:\(fileName)",
                isEnabled: true,
                knowledgeBase: kb
            )
            entry.kindRaw = KnowledgeEntryKind.resume
            kb.entries.append(entry)
            kb.updatedAt = .now
            try? modelContext.save()
            await digestResume(entry, in: kb, mergeSkills: true, config: config)
            isResumeBusy = false
        }
    }

    @MainActor
    private func digestResume(_ entry: KnowledgeEntry, in kb: KnowledgeBase, mergeSkills: Bool, config: APIConfig) async {
        resumeStatus = L.t("Generating AI summary…")
        do {
            let digest = try await KnowledgeAssistant.digestResume(entry.content, config: config)
            entry.summary = digest.summary
            entry.updatedAt = .now
            var added = 0
            if mergeSkills {
                let before = kb.skills.count
                kb.skills = mergedSkills(kb.skills, digest.skills)
                added = kb.skills.count - before
            }
            kb.updatedAt = .now
            try? modelContext.save()
            resumeStatus = mergeSkills && added > 0
                ? String(format: L.t("Resume processed. %d skills extracted."), added)
                : L.t("AI summary updated.")
        } catch {
            resumeStatus = "\(L.t("AI summary failed (the original is saved; regenerate later):")) \(error.localizedDescription)"
        }
    }

    private func regenerateResumeSummary(_ kb: KnowledgeBase) {
        guard let resume = kb.resumeEntry, !isResumeBusy else { return }
        isResumeBusy = true
        let config = AIService.config(from: modelContext)
        Task { @MainActor in
            await digestResume(resume, in: kb, mergeSkills: false, config: config)
            isResumeBusy = false
        }
    }

    private func deleteResume() {
        guard let kb = selected else { return }
        for entry in kb.entries where entry.kind == KnowledgeEntryKind.resume { modelContext.delete(entry) }
        kb.entries.removeAll { $0.kind == KnowledgeEntryKind.resume }
        kb.updatedAt = .now
        try? modelContext.save()
        resumeStatus = ""
    }

    // Skills

    private func mergedSkills(_ existing: [String], _ incoming: [String]) -> [String] {
        var result = existing
        for skill in KnowledgeAssistant.normalizeSkills(incoming)
        where !result.contains(where: { $0.caseInsensitiveCompare(skill) == .orderedSame }) {
            result.append(skill)
        }
        return result
    }

    private func addSkillsFromDraft(to kb: KnowledgeBase) {
        let parts = skillDraft.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
        let merged = mergedSkills(kb.skills, parts)
        skillDraft = ""
        guard merged != kb.skills else { return }
        kb.skills = merged
        kb.updatedAt = .now
        try? modelContext.save()
    }

    private func removeSkill(_ skill: String, from kb: KnowledgeBase) {
        kb.skills = kb.skills.filter { $0 != skill }
        kb.updatedAt = .now
        try? modelContext.save()
    }

    /// "From resume": adds skills that are not already listed.
    private func extractSkills(_ kb: KnowledgeBase) {
        guard let resume = kb.resumeEntry, !isSkillsBusy else { return }
        isSkillsBusy = true
        resumeStatus = L.t("Extracting skills from the resume…")
        let config = AIService.config(from: modelContext)
        Task { @MainActor in
            do {
                let digest = try await KnowledgeAssistant.digestResume(resume.content, config: config)
                let before = kb.skills.count
                kb.skills = mergedSkills(kb.skills, digest.skills)
                kb.updatedAt = .now
                try? modelContext.save()
                resumeStatus = String(format: L.t("%d new skills added."), kb.skills.count - before)
            } catch {
                resumeStatus = "\(L.t("Skill extraction failed:")) \(error.localizedDescription)"
            }
            isSkillsBusy = false
        }
    }

    // Projects

    /// Adds a repository (or a profile's recent repositories) with an AI one-line summary each.
    private func importProjects(_ input: String, into kb: KnowledgeBase) {
        let link = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !isProjectBusy else { return }
        guard GitHubProjectImporter.isGitHubURL(link) else {
            projectStatus = L.t("Enter a valid GitHub link.")
            return
        }
        isProjectBusy = true
        projectsExpanded = true
        projectStatus = L.t("Reading the repository from GitHub…")
        let config = AIService.config(from: modelContext)
        Task { @MainActor in
            defer { isProjectBusy = false }
            do {
                let projects = try await GitHubProjectImporter.fetch(link)
                var added: [KnowledgeEntry] = []
                for project in projects {
                    let normalized = project.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                    if kb.entries.contains(where: { $0.source.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == normalized }) { continue }
                    let entry = KnowledgeEntry(title: project.name, content: GitHubProjectImporter.buildContent(project), source: project.url, isEnabled: true, knowledgeBase: kb)
                    entry.kindRaw = KnowledgeEntryKind.project
                    entry.meta = GitHubProjectImporter.buildMeta(project)
                    entry.summary = project.description
                            kb.entries.append(entry)
                    added.append(entry)
                }
                projectURL = ""
                kb.updatedAt = .now
                try? modelContext.save()
                guard !added.isEmpty else {
                    projectStatus = L.t("These projects are already in this knowledge base.")
                    return
                }
                projectStatus = L.t("Generating project summaries…")
                for entry in added {
                    if let summary = try? await KnowledgeAssistant.summarizeProject(name: entry.title, readme: entry.content, description: entry.summary, config: config),
                       !summary.isEmpty {
                        entry.summary = summary
                    }
                }
                try? modelContext.save()
                projectStatus = String(format: L.t("%d projects added."), added.count)
            } catch {
                projectStatus = "\(L.t("Project import failed:")) \(error.localizedDescription)"
            }
        }
    }

    // Materials

    private func addMaterial(tempURL: URL, fileName: String, text: String) {
        guard let kb = selected else { return }
        let entryID = UUID()
        let storedURL = try? storeImportedPDF(from: tempURL, id: entryID, originalName: fileName)
        let source = storedURL.map { "file:\($0.path)" } ?? "file:\(fileName)"
        let entry = KnowledgeEntry(id: entryID, title: fileName, content: text, source: source, isEnabled: true, knowledgeBase: kb)
        entry.kindRaw = KnowledgeEntryKind.material
        kb.entries.append(entry)
        kb.updatedAt = .now
        try? modelContext.save()
        status = L.t("File imported")
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func sourceTitle(from input: String) -> String {
        let plainInput = plainURLString(from: input)
        guard let url = URL(string: plainInput) else { return L.t("Imported link") }
        if url.host == "github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                return "\(parts[0])/\(cleanGitHubRepoName(parts[1]))"
            }
        }
        return url.lastPathComponent.isEmpty ? (url.host ?? L.t("Imported link")) : url.lastPathComponent
    }

    private func plainURLString(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "("),
           let close = trimmed.lastIndex(of: ")"),
           open < close {
            return String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func cleanGitHubRepoName(_ repo: String) -> String {
        repo.hasSuffix(".git") ? String(repo.dropLast(4)) : repo
    }

    private func isPDFSource(_ entry: KnowledgeEntry) -> Bool {
        entry.source == "pdf" || entry.source.hasPrefix("pdf:")
    }

    private func pdfURL(for entry: KnowledgeEntry) -> URL? {
        guard entry.source.hasPrefix("pdf:") else { return nil }
        let path = String(entry.source.dropFirst(4))
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func storeImportedPDF(from sourceURL: URL, id: UUID, originalName: String) throws -> URL {
        let directory = try importedPDFDirectory()
        let safeExtension = (originalName as NSString).pathExtension.isEmpty ? "pdf" : (originalName as NSString).pathExtension
        let destination = directory.appending(path: "\(id.uuidString).\(safeExtension)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func importedPDFDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "ImportedPDFs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sourceLabel(for entry: KnowledgeEntry) -> String {
        if entry.source == "manual" { return L.t("Manual source") }
        if isPDFSource(entry) { return L.t("PDF source") }
        if let host = URL(string: entry.source)?.host {
            return host == "github.com" ? L.t("GitHub source") : host
        }
        return entry.source
    }

    private func sourceIcon(for entry: KnowledgeEntry) -> String {
        if isPDFSource(entry) { return "doc.richtext.fill" }
        if URL(string: entry.source)?.host == "github.com" { return "chevron.left.forwardslash.chevron.right" }
        if entry.source == "manual" { return "text.alignleft" }
        return "link"
    }

    private func sourceTint(for entry: KnowledgeEntry) -> Color {
        if isPDFSource(entry) { return .appDanger }
        if URL(string: entry.source)?.host == "github.com" { return .appGreen }
        return .appPrimary
    }
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

private struct PDFPagesPreview: View {
    let url: URL

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(renderedPages.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(L.t("Page")) \(index + 1)")
                            .font(.appSmall.weight(.semibold))
                            .foregroundStyle(Color.appMuted)
                        renderedPages[index]
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .padding(16)
        }
        .background(Color.appField)
    }

    private var renderedPages: [Image] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return [] }
        return (0..<min(document.pageCount, 20)).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let thumbnail = page.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox)
            #if os(macOS)
            return Image(nsImage: thumbnail)
            #else
            return Image(uiImage: thumbnail)
            #endif
        }
    }
}

/// Wrapping row layout for skill chips and action buttons.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        let width = proposal.width.map { $0.isFinite ? $0 : widest } ?? widest
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
