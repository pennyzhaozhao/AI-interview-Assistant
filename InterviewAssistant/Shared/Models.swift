import Foundation
import SwiftData

enum InterviewSessionKind: String, CaseIterable, Identifiable {
    case formal
    case mock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .formal: return L.t("Formal Interview")
        case .mock: return L.t("Mock Interview")
        }
    }
}

enum MockInterviewLanguage: String, CaseIterable, Identifiable {
    case followApp
    case chinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followApp: return L.t("Follow App Language")
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    func resolved(appLanguage: AppLanguage) -> AppLanguage {
        switch self {
        case .followApp: return appLanguage
        case .chinese: return .chinese
        case .english: return .english
        }
    }

    func instruction(appLanguage: AppLanguage) -> String {
        resolved(appLanguage: appLanguage) == .chinese ? "Chinese (Simplified Chinese)" : "English"
    }

    func speechCode(appLanguage: AppLanguage) -> String {
        resolved(appLanguage: appLanguage) == .chinese ? "zh-CN" : "en-US"
    }
}

@Model
final class KnowledgeBase {
    @Attribute(.unique) var id: UUID
    var name: String
    var desc: String
    var createdAt: Date
    var updatedAt: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \KnowledgeEntry.knowledgeBase)
    var entries: [KnowledgeEntry]

    init(id: UUID = UUID(), name: String, desc: String = "", createdAt: Date = .now, updatedAt: Date = .now, entries: [KnowledgeEntry] = []) {
        self.id = id
        self.name = name
        self.desc = desc
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

@Model
final class KnowledgeEntry {
    @Attribute(.unique) var id: UUID
    var title: String
    var content: String
    var source: String
    var createdAt: Date
    var updatedAt: Date = Date.now
    var isEnabled: Bool = true
    var knowledgeBase: KnowledgeBase?

    init(id: UUID = UUID(), title: String, content: String, source: String = "manual", createdAt: Date = .now, updatedAt: Date = .now, isEnabled: Bool = true, knowledgeBase: KnowledgeBase? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isEnabled = isEnabled
        self.knowledgeBase = knowledgeBase
    }
}

@Model
final class InterviewSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var role: String
    var context: String
    var activeKBIdsData: Data
    var kindRaw: String = InterviewSessionKind.formal.rawValue
    var overallScore: Int = 0
    var summaryFeedback: String = ""
    var strengthsText: String = ""
    var improvementsText: String = ""
    var startedAt: Date
    var endedAt: Date?
    var updatedAt: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \ConversationTurn.session)
    var turns: [ConversationTurn]

    var activeKBIds: [UUID] {
        get { (try? JSONDecoder().decode([UUID].self, from: activeKBIdsData)) ?? [] }
        set { activeKBIdsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var kind: InterviewSessionKind {
        get { InterviewSessionKind(rawValue: kindRaw) ?? .formal }
        set { kindRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), title: String, role: String = "", context: String = "", activeKBIds: [UUID] = [], kind: InterviewSessionKind = .formal, overallScore: Int = 0, summaryFeedback: String = "", strengthsText: String = "", improvementsText: String = "", startedAt: Date = .now, endedAt: Date? = nil, updatedAt: Date = .now, turns: [ConversationTurn] = []) {
        self.id = id
        self.title = title
        self.role = role
        self.context = context
        self.activeKBIdsData = (try? JSONEncoder().encode(activeKBIds)) ?? Data()
        self.kindRaw = kind.rawValue
        self.overallScore = overallScore
        self.summaryFeedback = summaryFeedback
        self.strengthsText = strengthsText
        self.improvementsText = improvementsText
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.updatedAt = updatedAt
        self.turns = turns
    }
}

@Model
final class ConversationTurn {
    @Attribute(.unique) var id: UUID
    var question: String
    var answer: String
    var category: String = ""
    var feedback: String = ""
    var suggestedAnswer: String = ""
    var score: Int = 0
    @Attribute(.externalStorage) var screenshotData: Data?
    var createdAt: Date
    var session: InterviewSession?

    init(id: UUID = UUID(), question: String, answer: String, category: String = "", feedback: String = "", suggestedAnswer: String = "", score: Int = 0, screenshotData: Data? = nil, createdAt: Date = .now, session: InterviewSession? = nil) {
        self.id = id
        self.question = question
        self.answer = answer
        self.category = category
        self.feedback = feedback
        self.suggestedAnswer = suggestedAnswer
        self.score = score
        self.screenshotData = screenshotData
        self.createdAt = createdAt
        self.session = session
    }
}

@Model
final class AppSetting {
    @Attribute(.unique) var key: String
    var value: String

    init(key: String, value: String = "") {
        self.key = key
        self.value = value
    }
}

extension ModelContext {
    func seedDefaultsIfNeeded() {
        let descriptor = FetchDescriptor<KnowledgeBase>()
        let count = (try? fetchCount(descriptor)) ?? 0
        guard count == 0 else { return }
        insert(KnowledgeBase(name: "UI/UX 经历", desc: "你的 UI/UX 项目、方法论、作品集故事"))
        insert(KnowledgeBase(name: "其他经历", desc: "其他岗位、项目或通用面试素材"))
        try? save()
    }

    func setting(_ key: String, default defaultValue: String = "") -> String {
        let descriptor = FetchDescriptor<AppSetting>(predicate: #Predicate { $0.key == key })
        return ((try? fetch(descriptor))?.first?.value) ?? defaultValue
    }

    func setSetting(_ key: String, value: String) {
        let descriptor = FetchDescriptor<AppSetting>(predicate: #Predicate { $0.key == key })
        if let existing = (try? fetch(descriptor))?.first {
            existing.value = value
        } else {
            insert(AppSetting(key: key, value: value))
        }
        try? save()
    }

}
