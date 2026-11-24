import XCTest
@testable import InterviewAssistant

final class SpeechProtectionTests: XCTestCase {
    func testStrongQuestionRequiresWordingAndPause() {
        XCTAssertTrue(SpeechProtectionPolicy.isStrongQuestionSignal("可以介绍一下这个项目吗？", gapSincePreviousUtterance: 5.1))
        XCTAssertFalse(SpeechProtectionPolicy.isStrongQuestionSignal("可以介绍一下这个项目吗？", gapSincePreviousUtterance: 3.0))
        XCTAssertFalse(SpeechProtectionPolicy.isStrongQuestionSignal("然后我负责完成了交付", gapSincePreviousUtterance: 6.0))
        XCTAssertTrue(SpeechProtectionPolicy.isStrongQuestionSignal("Could you walk me through the design", gapSincePreviousUtterance: 5.5))
    }

    func testChineseBigramAndEnglishWordOverlap() {
        let chinese = SpeechProtectionPolicy.answerOverlap("我负责用户研究和设计系统", "建议强调你负责用户研究和设计系统的经历")
        XCTAssertGreaterThan(chinese, 0.7)
        let english = SpeechProtectionPolicy.answerOverlap("I led the user research", "Emphasize that you led user research and synthesis")
        XCTAssertGreaterThanOrEqual(english, 0.60)
        XCTAssertLessThan(SpeechProtectionPolicy.answerOverlap("数据库扩容", "I led user research"), 0.1)
    }

    func testContentFilterKeepsInterviewerQuestions() {
        let questions = [
            "可以介绍一下这个项目吗？",
            "你上一个项目",
            "我想问一下你对加班怎么看",
            "我们这边主要是做电商的，你有相关经验吗",
            "你为什么离开上一家公司",
            "讲讲你对微服务的理解",
            "Tell me about yourself",
            "What was the biggest challenge in that project"
        ]
        for question in questions {
            XCTAssertFalse(
                UtteranceIntentClassifier.shouldDrop(question, currentAnswer: "", speaker: .unknown, level: .strict),
                question
            )
        }
    }

    func testContentFilterDropsCandidateAnswers() {
        let answers = [
            "我负责用户研究和设计系统",
            "然后我们用了Redis做缓存",
            "嗯我当时主要负责后端的架构设计然后带领团队完成了迁移",
            "这个问题我觉得可以从两方面说",
            "好的，我先简单介绍一下我自己",
            "I led the migration to Kubernetes and we reduced costs",
            "So basically we built a caching layer"
        ]
        for answer in answers {
            XCTAssertTrue(
                UtteranceIntentClassifier.shouldDrop(answer, currentAnswer: "", speaker: .unknown, level: .standard),
                answer
            )
        }
    }

    func testContentFilterRespectsLevelAndVoiceprint() {
        let text = "我负责用户研究和设计系统"
        XCTAssertFalse(UtteranceIntentClassifier.shouldDrop(text, currentAnswer: "", speaker: .unknown, level: .off))
        XCTAssertFalse(UtteranceIntentClassifier.shouldDrop(text, currentAnswer: "", speaker: .unknown, level: .relaxed))
        // A confident interviewer voiceprint needs stronger content evidence.
        XCTAssertFalse(UtteranceIntentClassifier.shouldDrop(text, currentAnswer: "", speaker: .interviewer, level: .standard))
        // Repeating the on-screen suggestion is strong evidence.
        XCTAssertTrue(UtteranceIntentClassifier.shouldDrop(
            "我负责用户研究和设计系统",
            currentAnswer: "建议强调你负责用户研究和设计系统的经历",
            speaker: .interviewer,
            level: .standard
        ))
    }

    func testPreparedAnswerSimilarityIgnoresPoliteFillers() {
        XCTAssertGreaterThan(PreparedAnswerLibrary.similarity("请做一下自我介绍", "自我介绍一下"), 0.8)
        XCTAssertEqual(PreparedAnswerLibrary.similarity("Tell me about yourself", "Tell me about yourself."), 1, accuracy: 0.0001)
        XCTAssertLessThan(PreparedAnswerLibrary.similarity("Redis 和 MySQL 的区别", "你的期望薪资是多少"), 0.1)
    }

    func testPreparedAnswersParsedFromMaterial() {
        let material = """
        # 常见问题
        Q: 为什么从上家公司离职？
        A: 我希望做更贴近用户的产品。
        补充一句。
        问：你的缺点是什么？
        答：我有时过于追求细节。
        """
        let items = PreparedAnswerLibrary.parseMaterial(material, title: "Notes")
        XCTAssertEqual(items.map(\.question), ["为什么从上家公司离职？", "你的缺点是什么？"])
        XCTAssertEqual(items.first?.answer, "我希望做更贴近用户的产品。\n补充一句。")
        XCTAssertEqual(items.last?.answer, "我有时过于追求细节。")
    }

    func testPreparedAnswerCandidatesGateFollowUps() {
        let items = [
            PreparedQA(question: "请做一下自我介绍", answer: "我是……", sourceTitle: "Bank"),
            PreparedQA(question: "具体说说难点", answer: "难点是……", sourceTitle: "Bank", parentQuestion: "介绍一下你最有挑战的项目")
        ]
        let selfIntro = PreparedAnswerLibrary.candidates(for: "自我介绍一下", previousQuestion: nil, items: items, retrievedChunks: [])
        XCTAssertEqual(selfIntro.map(\.question), ["请做一下自我介绍"])
        // A generic follow-up only applies right after its primary question.
        XCTAssertFalse(PreparedAnswerLibrary.candidates(for: "具体说说难点", previousQuestion: "你的期望薪资是多少", items: items, retrievedChunks: []).isEmpty)
        XCTAssertTrue(PreparedAnswerLibrary.candidates(for: "能展开讲讲吗", previousQuestion: "你的期望薪资是多少", items: items, retrievedChunks: []).isEmpty)
        XCTAssertEqual(
            PreparedAnswerLibrary.candidates(for: "能展开讲讲吗", previousQuestion: "介绍一下你最有挑战的项目", items: items, retrievedChunks: []).first?.question,
            "具体说说难点"
        )
    }

    func testQuestionBankIsChunkedAsQuestionAnswerPairs() {
        var document = QuestionBankDocument()
        document.questions = [
            .init(question: "请做一下自我介绍", answer: "我是一名后端工程师。"),
            .init(question: "为什么从上家公司离职？", answer: "希望有更大的成长空间。")
        ]
        let parts = KnowledgeChunker.splitContent(document.searchableText, options: .default)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.isQA })
        XCTAssertTrue(parts[0].text.contains("自我介绍") && !parts[0].text.contains("离职"))
    }

    func testFusionWeights() {
        let value = SpeakerVerifier.fusedScore(similarity: 0.8, rmsCloseness: 0.6, answerOverlap: 0.4)
        XCTAssertEqual(value, 0.69, accuracy: 0.0001)
    }

    func testDoubleThresholdClassification() {
        XCTAssertEqual(SpeakerVerifier.classify(score: 0.72, high: 0.72, low: 0.48), .candidate)
        XCTAssertEqual(SpeakerVerifier.classify(score: 0.48, high: 0.72, low: 0.48), .interviewer)
        XCTAssertEqual(SpeakerVerifier.classify(score: 0.60, high: 0.72, low: 0.48), .unknown)
    }

    func testSyntheticEmbeddingChangePoint() {
        let embeddings: [[Float]] = [[1, 0], [0.98, 0.02], [0, 1], [0.02, 0.98]]
        let ranges = SpeakerVerifier.changePointRanges(
            embeddings: embeddings,
            windowStarts: [0, 0.75, 1.5, 2.25]
        )
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].lowerBound, 1.875, accuracy: 0.001)
        XCTAssertEqual(ranges[0].upperBound, 2.625, accuracy: 0.001)
    }

    @MainActor
    func testDirectorConnectionReportsProgressAndConnects() async {
        let port: UInt16 = 19991
        let server = TCPLineServer(port: port, advertisesBonjour: false)
        server.start()
        defer { server.stop() }

        for _ in 0..<50 where !server.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(server.isRunning)

        let client = TCPLineConnection(port: port)
        client.connect(host: "127.0.0.1", mode: .sender)
        XCTAssertTrue(client.isConnecting || client.isConnected)

        for _ in 0..<50 where !client.isConnected {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(client.isConnected, client.lastErrorText)
        XCTAssertEqual(client.state, .connected)
        client.disconnect()
    }

    @MainActor
    func testDirectorWebControllerServesPage() async throws {
        let port: UInt16 = 19992
        let server = TCPLineServer(port: port, advertisesBonjour: false)
        server.start()
        defer { server.stop() }

        for _ in 0..<50 where !server.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(server.isRunning, server.statusText)

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let page = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(page.contains("Director Mode") || page.contains("导演模式"))
    }

    @MainActor
    func testDirectorWebControllerServesPageOnLANAddress() async throws {
        let port: UInt16 = 19993
        let server = TCPLineServer(port: port, advertisesBonjour: false)
        server.start()
        defer { server.stop() }

        for _ in 0..<50 where !server.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(server.isRunning, server.statusText)

        let ip = try XCTUnwrap(LocalNetworkInfo.wifiIPAddress())
        let url = try XCTUnwrap(URL(string: "http://\(ip):\(port)/"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let page = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(page.contains("Director Mode") || page.contains("导演模式"))
    }

    @MainActor
    func testDirectorConnectionRejectsEmptyHostWithFeedback() {
        let client = TCPLineConnection()
        client.connect(host: "  ", mode: .sender)
        XCTAssertEqual(client.state, .failed)
        XCTAssertFalse(client.lastErrorText.isEmpty)
    }
}
