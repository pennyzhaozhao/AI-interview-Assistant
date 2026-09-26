import Foundation
import SwiftData

enum DataStorageManager {
    private static let selectedFolderBookmarkKey = "data_storage_folder_bookmark_v1"
    private static let cleanupStorePathKey = "data_storage_cleanup_store_path_v1"
    private static let cleanupFolderBookmarkKey = "data_storage_cleanup_folder_bookmark_v1"
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
            return customStoreURL(in: folder)
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
    static func migrateData(from sourceContext: ModelContext, to selectedFolder: URL) throws {
        let grantedAccess = selectedFolder.startAccessingSecurityScopedResource()
        defer {
            if grantedAccess {
                selectedFolder.stopAccessingSecurityScopedResource()
            }
        }

        let targetDirectory = selectedFolder.appendingPathComponent(customDataFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let targetStoreURL = targetDirectory.appendingPathComponent(customStoreName, isDirectory: false)

        guard targetStoreURL.standardizedFileURL != currentStoreURL.standardizedFileURL else {
            throw StorageError.sameLocation
        }
        guard !FileManager.default.fileExists(atPath: targetStoreURL.path) else {
            throw StorageError.locationAlreadyContainsData
        }

        try sourceContext.save()
        let targetSchema = schema
        let targetConfiguration = ModelConfiguration(
            "InterviewAssistant",
            schema: targetSchema,
            url: targetStoreURL,
            cloudKitDatabase: .none
        )
        let targetContainer = try ModelContainer(for: targetSchema, configurations: [targetConfiguration])
        let targetContext = ModelContext(targetContainer)

        for sourceBase in try sourceContext.fetch(FetchDescriptor<KnowledgeBase>()) {
            let targetBase = KnowledgeBase(
                id: sourceBase.id,
                name: sourceBase.name,
                desc: sourceBase.desc,
                createdAt: sourceBase.createdAt,
                updatedAt: sourceBase.updatedAt
            )
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
        try targetContext.save()

        let defaults = UserDefaults.standard
        defaults.set(currentStoreURL.path(percentEncoded: false), forKey: cleanupStorePathKey)
        defaults.set(defaults.data(forKey: selectedFolderBookmarkKey), forKey: cleanupFolderBookmarkKey)
        defaults.set(try bookmarkData(for: selectedFolder), forKey: selectedFolderBookmarkKey)
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
        let directory = selectedFolder.appendingPathComponent(customDataFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent(customStoreName, isDirectory: false)
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

    private static func customStoreURL(in selectedFolder: URL) -> URL {
        selectedFolder
            .appendingPathComponent(customDataFolderName, isDirectory: true)
            .appendingPathComponent(customStoreName, isDirectory: false)
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

enum StorageError: LocalizedError {
    case sameLocation
    case locationAlreadyContainsData

    var errorDescription: String? {
        switch self {
        case .sameLocation:
            return L.t("This is already the current storage location.")
        case .locationAlreadyContainsData:
            return L.t("This folder already contains InterviewAssistant data. Choose another folder to avoid overwriting it.")
        }
    }
}
