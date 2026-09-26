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
                importDocument(from: url)
            case .failure(let error):
                status = "\(L.t("Import failed")): \(error.localizedDescription)"
            }
        }
        .sheet(item: $editingSource) { entry in
            sourceEditor(entry)
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
        let fileCount = visibleEntries(for: kb).count
        return VStack(alignment: .leading, spacing: 6) {
            Text(kb.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appText)
                .lineLimit(1)
            Text(fileCountText(fileCount))
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
                    Label(L.t("New Asset"), systemImage: "plus")
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
            Text(L.t("Manage reusable context as enabled assets for interview sessions."))
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
                    .help(activeIDs.contains(kb.id) ? "关闭该知识库" : "开启该知识库")
                    if !isSelectingBases {
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
                metadataPill(fileCountText(visibleEntries(for: kb).count), icon: "doc.fill")
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

    private var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selected?.name ?? L.t("Asset Details"))
                            .font(.appSection)
                        Text(L.t("Edit metadata, import sources, and decide whether this asset is available to interviews."))
                            .font(.appCaption)
                            .foregroundStyle(Color.appMuted)
                    }
                }

                if let selected {
                    Toggle(isOn: Binding(
                        get: { activeIDs.contains(selected.id) },
                        set: { isOn in
                            if isOn {
                                activeIDs.insert(selected.id)
                            } else {
                                activeIDs.remove(selected.id)
                            }
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
                    .premiumCard(padding: 16)
                }

                VStack(alignment: .leading, spacing: 14) {
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
                    labeledField(L.t("Import source")) {
                        HStack(spacing: 10) {
                            TextField("Google Drive / GitHub / PDF URL", text: $url)
                                .textFieldStyle(.plain)
                                .darkField()
                            if !isCompact {
                                Button(L.t("Import")) { importURL() }
                                    .buttonStyle(AppButtonStyle())
                                Button("上传文件") { importingDocument = true }
                                    .buttonStyle(AppButtonStyle())
                            }
                        }
                    }
                    if isCompact {
                        HStack {
                            Button(L.t("Import Link")) { importURL() }
                                .buttonStyle(AppButtonStyle())
                            Button("上传文件") { importingDocument = true }
                                .buttonStyle(AppButtonStyle())
                        }
                    }
                }
                .premiumCard()

                sourceList

                HStack {
                    Text(status)
                        .foregroundStyle(Color.appMuted)
                        .font(.appCaption)
                    Spacer()
                    Button(L.t("Save Asset")) { save() }
                        .buttonStyle(AppButtonStyle(prominent: true))
                        .disabled(selected == nil)
                }
            }
            .padding(isCompact ? 0 : 32)
            .padding(.bottom, isCompact ? 140 : 32)
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("Sources"))
                        .font(.appBodyMedium)
                    Text(L.t("Choose which materials AI can use during interviews."))
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
                if let selected {
                    let entries = visibleEntries(for: selected)
                    let enabledCount = entries.filter(\.isEnabled).count
                    StatusPill(text: enabledSourceCountText(enabledCount, total: entries.count), tint: .appPrimary)
                }
            }

            if let selected, !visibleEntries(for: selected).isEmpty, !hasManualSource(selected) {
                Button {
                    addManualSource(to: selected)
                } label: {
                    Label(L.t("Add Main Content"), systemImage: "plus")
                        .frame(maxWidth: isCompact ? .infinity : nil)
                }
                .buttonStyle(AppButtonStyle())
            }

            if let selected, !visibleEntries(for: selected).isEmpty {
                LazyVStack(spacing: 10) {
                    ForEach(sourceEntries(for: selected)) { entry in
                        sourceRow(entry)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.appMuted)
                    Text(L.t("No sources yet"))
                        .font(.appBodyMedium)
                    Text(L.t("Import a PDF or public GitHub link to turn it into interview-ready context."))
                        .font(.appCaption)
                        .foregroundStyle(Color.appMuted)
                        .multilineTextAlignment(.center)
                    if let selected {
                        Button {
                            addManualSource(to: selected)
                        } label: {
                            Label(L.t("Add Main Content"), systemImage: "plus")
                        }
                        .buttonStyle(AppButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .padding(18)
                .background(Color.appField)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .premiumCard()
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

                Button {
                    confirmDeleteSource(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appDanger)
                        .frame(width: 34, height: 34)
                        .background(Color.appDanger.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
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
                        Text(L.t("Content"))
                            .font(.appCaptionMedium)
                            .foregroundStyle(Color.appMuted)
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
        status = L.t("Importing...")
        Task {
            do {
                let text = try await URLFetcher.fetchText(from: input)
                await MainActor.run {
                    let title = sourceTitle(from: input)
                    selected.entries.append(KnowledgeEntry(title: title, content: text, source: input, isEnabled: true, knowledgeBase: selected))
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
                            status = "文件已导入，但没有找到可读取的文本"
                            return
                        }
                        let entryID = UUID()
                        let storedURL = try? storeImportedPDF(from: tempURL, id: entryID, originalName: safeName)
                        let source = storedURL.map { "file:\($0.path)" } ?? "file:\(safeName)"
                        selected.entries.append(KnowledgeEntry(id: entryID, title: safeName, content: trimmed, source: source, isEnabled: true, knowledgeBase: selected))
                        selected.updatedAt = .now
                        try? modelContext.save()
                        status = "文件已导入"
                        try? FileManager.default.removeItem(at: tempURL)
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
        let entry = KnowledgeEntry(title: L.t("Main Content"), content: "", source: "manual", isEnabled: true, knowledgeBase: kb)
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
