import Foundation
import SwiftData

enum DataStorageManager {
    private static let selectedFolderBookmarkKey = "data_storage_folder_bookmark_v1"
    private static let cleanupStorePathKey = "data_storage_cleanup_store_path_v1"
    private static let cleanupFolderBookmarkKey = "data_storage_cleanup_folder_bookmark_v1"
    private static let selectedFolderLayoutVersionKey = "data_storage_folder_layout_version"
    private static let directFolderLayoutVersion = 2
    private static let customDataFolderName = "InterviewAssistantData"
    private static let customStoreName = "InterviewAssistant.store"

    nonisolated(unsafe) private static var activeSecurityScopedURL: URL?

    static var schema: Schema {
        Schema([
            KnowledgeBase.self,
            KnowledgeEntry.self,
            InterviewSession.self,
            ConversationTurn.self,
            AppSetting.self
        ])
    }

    static func makeModelContainer() throws -> ModelContainer {
        let schema = schema
        let storeURL = try preparedStoreURL()
        let configuration = ModelConfiguration(
            "InterviewAssistant",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static var currentStoreURL: URL {
        if let folder = selectedFolderURL() {
            return selectedStoreURL(in: folder)
        }
        return defaultStoreURL
    }

    static var currentLocationDescription: String {
        currentStoreURL.deletingLastPathComponent().path(percentEncoded: false)
    }

    static var usesCustomLocation: Bool {
        UserDefaults.standard.data(forKey: selectedFolderBookmarkKey) != nil
    }

    @MainActor
    static func migrateData(from sourceContext: ModelContext, to selectedFolder: URL) throws -> StorageSelectionResult {
        let grantedAccess = selectedFolder.startAccessingSecurityScopedResource()
        defer {
            if grantedAccess {
                selectedFolder.stopAccessingSecurityScopedResource()
            }
        }

        let targetStoreURL = directStoreURL(in: selectedFolder)

        if targetStoreURL.standardizedFileURL == currentStoreURL.standardizedFileURL {
            try selectDirectStorageFolder(selectedFolder)
            clearPendingStoreCleanup()
            return .usingExistingData
        }

        if FileManager.default.fileExists(atPath: targetStoreURL.path) {
            let targetSchema = schema
            let targetConfiguration = ModelConfiguration(
                "InterviewAssistant",
                schema: targetSchema,
                url: targetStoreURL,
                cloudKitDatabase: .none
            )
            _ = try ModelContainer(for: targetSchema, configurations: [targetConfiguration])
            try selectDirectStorageFolder(selectedFolder)
            clearPendingStoreCleanup()
            return .usingExistingData
        }

        try sourceContext.save()
        let targetSchema = schema
        let targetConfiguration = ModelConfiguration(
            "InterviewAssistant",
            schema: targetSchema,
            url: targetStoreURL,
            cloudKitDatabase: .none
        )
        let targetContainer: ModelContainer
        do {
            targetContainer = try ModelContainer(for: targetSchema, configurations: [targetConfiguration])
        } catch {
            removeStoreFiles(at: targetStoreURL)
            throw error
        }
        let targetContext = ModelContext(targetContainer)

        for sourceBase in try sourceContext.fetch(FetchDescriptor<KnowledgeBase>()) {
            let targetBase = KnowledgeBase(
                id: sourceBase.id,
                name: sourceBase.name,
                desc: sourceBase.desc,
                createdAt: sourceBase.createdAt,
                updatedAt: sourceBase.updatedAt
            )
            targetBase.skillsData = sourceBase.skillsData
            targetBase.customInstructions = sourceBase.customInstructions
            targetContext.insert(targetBase)
            for sourceEntry in sourceBase.entries {
                let targetEntry = KnowledgeEntry(
                    id: sourceEntry.id,
                    title: sourceEntry.title,
                    content: sourceEntry.content,
                    source: sourceEntry.source,
                    createdAt: sourceEntry.createdAt,
                    updatedAt: sourceEntry.updatedAt,
                    isEnabled: sourceEntry.isEnabled,
                    knowledgeBase: targetBase
                )
                targetEntry.kindRaw = sourceEntry.kindRaw
                targetEntry.summary = sourceEntry.summary
                targetEntry.meta = sourceEntry.meta
                targetContext.insert(targetEntry)
            }
        }

        for sourceSession in try sourceContext.fetch(FetchDescriptor<InterviewSession>()) {
            let targetSession = InterviewSession(
                id: sourceSession.id,
                title: sourceSession.title,
                role: sourceSession.role,
                context: sourceSession.context,
                activeKBIds: sourceSession.activeKBIds,
                kind: sourceSession.kind,
                overallScore: sourceSession.overallScore,
                summaryFeedback: sourceSession.summaryFeedback,
                strengthsText: sourceSession.strengthsText,
                improvementsText: sourceSession.improvementsText,
                startedAt: sourceSession.startedAt,
                endedAt: sourceSession.endedAt,
                updatedAt: sourceSession.updatedAt
            )
            targetContext.insert(targetSession)
            for sourceTurn in sourceSession.turns {
                let targetTurn = ConversationTurn(
                    id: sourceTurn.id,
                    question: sourceTurn.question,
                    answer: sourceTurn.answer,
                    category: sourceTurn.category,
                    feedback: sourceTurn.feedback,
                    suggestedAnswer: sourceTurn.suggestedAnswer,
                    score: sourceTurn.score,
                    screenshotData: sourceTurn.screenshotData,
                    createdAt: sourceTurn.createdAt,
                    session: targetSession
                )
                targetContext.insert(targetTurn)
            }
        }

        for sourceSetting in try sourceContext.fetch(FetchDescriptor<AppSetting>()) {
            targetContext.insert(AppSetting(key: sourceSetting.key, value: sourceSetting.value))
        }
        do {
            try targetContext.save()
        } catch {
            removeStoreFiles(at: targetStoreURL)
            throw error
        }

        let defaults = UserDefaults.standard
        defaults.set(currentStoreURL.path(percentEncoded: false), forKey: cleanupStorePathKey)
        defaults.set(defaults.data(forKey: selectedFolderBookmarkKey), forKey: cleanupFolderBookmarkKey)
        try selectDirectStorageFolder(selectedFolder)
        return .copiedCurrentData
    }

    @MainActor
    static func deleteUserContent(in context: ModelContext) throws {
        for session in try context.fetch(FetchDescriptor<InterviewSession>()) {
            context.delete(session)
        }
        for knowledgeBase in try context.fetch(FetchDescriptor<KnowledgeBase>()) {
            context.delete(knowledgeBase)
        }
        try context.save()
    }

    private static func preparedStoreURL() throws -> URL {
        guard let selectedFolder = selectedFolderURL() else {
            return defaultStoreURL
        }
        let storeURL = selectedStoreURL(in: selectedFolder)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        cleanupPreviousStoreIfNeeded(replacementStoreURL: storeURL)
        return storeURL
    }

    private static func selectedFolderURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: selectedFolderBookmarkKey) else {
            return nil
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if url.startAccessingSecurityScopedResource() {
                activeSecurityScopedURL = url
            }
            if isStale, let refreshed = try? bookmarkData(for: url) {
                UserDefaults.standard.set(refreshed, forKey: selectedFolderBookmarkKey)
            }
            return url
        } catch {
            return nil
        }
    }

    private static func selectedStoreURL(in selectedFolder: URL) -> URL {
        if UserDefaults.standard.integer(forKey: selectedFolderLayoutVersionKey) >= directFolderLayoutVersion {
            return directStoreURL(in: selectedFolder)
        }
        return selectedFolder
            .appendingPathComponent(customDataFolderName, isDirectory: true)
            .appendingPathComponent(customStoreName, isDirectory: false)
    }

    private static func directStoreURL(in selectedFolder: URL) -> URL {
        selectedFolder.appendingPathComponent(customStoreName, isDirectory: false)
    }

    private static func selectDirectStorageFolder(_ selectedFolder: URL) throws {
        let defaults = UserDefaults.standard
        defaults.set(try bookmarkData(for: selectedFolder), forKey: selectedFolderBookmarkKey)
        defaults.set(directFolderLayoutVersion, forKey: selectedFolderLayoutVersionKey)
    }

    private static func clearPendingStoreCleanup() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: cleanupStorePathKey)
        defaults.removeObject(forKey: cleanupFolderBookmarkKey)
    }

    private static var defaultStoreURL: URL {
        ModelConfiguration(schema: schema, isStoredInMemoryOnly: false).url
    }

    private static func cleanupPreviousStoreIfNeeded(replacementStoreURL: URL) {
        let defaults = UserDefaults.standard
        guard
            FileManager.default.fileExists(atPath: replacementStoreURL.path),
            let oldPath = defaults.string(forKey: cleanupStorePathKey)
        else { return }

        var cleanupScopedURL: URL?
        if let bookmark = defaults.data(forKey: cleanupFolderBookmarkKey) {
            var stale = false
            cleanupScopedURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            _ = cleanupScopedURL?.startAccessingSecurityScopedResource()
        }
        defer { cleanupScopedURL?.stopAccessingSecurityScopedResource() }

        let oldStoreURL = URL(fileURLWithPath: oldPath)
        guard oldStoreURL.standardizedFileURL != replacementStoreURL.standardizedFileURL else { return }
        removeStoreFiles(at: oldStoreURL)
        defaults.removeObject(forKey: cleanupStorePathKey)
        defaults.removeObject(forKey: cleanupFolderBookmarkKey)
    }

    private static func removeStoreFiles(at storeURL: URL) {
        let manager = FileManager.default
        let parent = storeURL.deletingLastPathComponent()
        let stem = storeURL.deletingPathExtension().lastPathComponent
        let candidates = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal"),
            parent.appendingPathComponent(".\(stem)_SUPPORT", isDirectory: true),
            parent.appendingPathComponent("\(stem)_SUPPORT", isDirectory: true),
            parent.appendingPathComponent("\(storeURL.lastPathComponent)_SUPPORT", isDirectory: true)
        ]
        for url in candidates where manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: url)
        }
    }

    private static func bookmarkData(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return .withSecurityScope
        #else
        return []
        #endif
    }
}

enum StorageSelectionResult {
    case copiedCurrentData
    case usingExistingData
}
