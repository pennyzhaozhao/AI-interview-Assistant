import XCTest
@testable import InterviewAssistant

final class SpeechProtectionTests: XCTestCase {
    func testStrongQuestionRequiresWordingAndPause() {
        XCTAssertTrue(SpeechProtectionPolicy.isStrongQuestionSignal("可以介绍一下这个项目吗？", gapSincePreviousUtterance: 1.6))
        XCTAssertFalse(SpeechProtectionPolicy.isStrongQuestionSignal("可以介绍一下这个项目吗？", gapSincePreviousUtterance: 0.8))
        XCTAssertFalse(SpeechProtectionPolicy.isStrongQuestionSignal("然后我负责完成了交付", gapSincePreviousUtterance: 3.0))
        XCTAssertTrue(SpeechProtectionPolicy.isStrongQuestionSignal("Could you walk me through the design", gapSincePreviousUtterance: 2.0))
    }

    func testChineseBigramAndEnglishWordOverlap() {
        let chinese = SpeechProtectionPolicy.answerOverlap("我负责用户研究和设计系统", "建议强调你负责用户研究和设计系统的经历")
        XCTAssertGreaterThan(chinese, 0.7)
        let english = SpeechProtectionPolicy.answerOverlap("I led the user research", "Emphasize that you led user research and synthesis")
        XCTAssertGreaterThanOrEqual(english, 0.60)
        XCTAssertLessThan(SpeechProtectionPolicy.answerOverlap("数据库扩容", "I led user research"), 0.1)
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
}
