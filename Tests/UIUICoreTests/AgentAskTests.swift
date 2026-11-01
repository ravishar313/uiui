import XCTest
@testable import UIUICore

final class AgentAskTests: XCTestCase {
    func testLineShowsOldestFirstAndBindsOnlyAfterItWasVisible() {
        var line = AskLine()
        let first = AskQuestion(agent: "zelta", text: "staging or prod?")
        let second = AskQuestion(agent: "naksha", text: "which table?")
        line.add(first); line.add(second)
        XCTAssertTrue(line.showNext(at: 10))
        XCTAssertEqual(line.shown, first)
        XCTAssertEqual(line.othersWaiting, 1)
        XCTAssertNil(line.bindableQuestion(at: 10.2), "A press this soon could not have read it")
        XCTAssertEqual(line.bindableQuestion(at: 10.5), first)

        line.remove(first.id)
        XCTAssertNil(line.shown)
        XCTAssertTrue(line.showNext(at: 11))
        XCTAssertNil(line.bindableQuestion(at: 11.1), "The next question starts its own clock")
    }

    func testHidingForDictationRestartsTheVisibleClock() {
        var line = AskLine()
        line.add(AskQuestion(agent: "a", text: "q"))
        line.showNext(at: 1)
        line.hide()
        line.showNext(at: 50)
        XCTAssertNil(line.bindableQuestion(at: 50.1))
    }

    func testRemovingAWaitingQuestionLeavesTheShownOne() {
        var line = AskLine()
        let first = AskQuestion(agent: "a", text: "one")
        let second = AskQuestion(agent: "b", text: "two")
        line.add(first); line.add(second)
        line.showNext(at: 1)
        line.remove(second.id)
        XCTAssertEqual(line.shown, first)
        XCTAssertEqual(line.othersWaiting, 0)
        XCTAssertEqual(line.removeAll(), [first])
        XCTAssertNil(line.shown)
    }

    func testQuestionTextAndNameAreBounded() {
        let question = AskQuestion(agent: "   ", text: String(repeating: "x", count: 900))
        XCTAssertEqual(question.agent, "agent")
        XCTAssertEqual(question.text.count, AskRequest.maximumQuestionLength)
    }

    func testHoldSendsOnRelease() {
        var gesture = AskKeyGesture()
        XCTAssertEqual(gesture.pressed(at: 1), .start)
        XCTAssertEqual(gesture.released(at: 2), .finish)
        XCTAssertFalse(gesture.isLatched)
    }

    func testTapLatchesAndTheNextTapSends() {
        var gesture = AskKeyGesture()
        XCTAssertEqual(gesture.pressed(at: 1), .start)
        XCTAssertNil(gesture.released(at: 1.1))
        XCTAssertTrue(gesture.isLatched)
        XCTAssertNil(gesture.pressed(at: 60))
        XCTAssertEqual(gesture.released(at: 60.1), .finish)
        XCTAssertFalse(gesture.isLatched)
    }

    func testChordCancelsAHoldButNeverEndsALatchedAnswer() {
        var gesture = AskKeyGesture()
        _ = gesture.pressed(at: 1)
        XCTAssertEqual(gesture.chord(), .cancel)
        XCTAssertNil(gesture.released(at: 1.1), "The release of a chord does nothing")

        _ = gesture.pressed(at: 2); _ = gesture.released(at: 2.1)
        _ = gesture.pressed(at: 3)
        XCTAssertNil(gesture.chord())
        XCTAssertTrue(gesture.isLatched)
    }

    func testOutcomesHaveDistinctExitCodes() {
        let codes: [AskOutcome] = [.answered, .unavailable, .away, .timeout]
        XCTAssertEqual(Set(codes.map(\.exitCode)).count, codes.count)
        XCTAssertEqual(AskOutcome.answered.exitCode, 0)
    }

    func testSummaryCountsWithoutAnyWords() {
        let now = Date()
        let events = [
            UsageEvent(date: now, action: AskUsage.received),
            UsageEvent(date: now, action: AskUsage.received),
            UsageEvent(date: now, action: AskUsage.answeredHold, durationMS: 2_000),
            UsageEvent(date: now, action: AskUsage.answeredTap, durationMS: 4_000),
            UsageEvent(date: now, action: AskUsage.withdrawn),
            UsageEvent(date: now, action: "paste_dispatched", wordCount: 12),
            UsageEvent(date: now.addingTimeInterval(-30 * 86_400), action: AskUsage.received),
        ]
        let summary = AskUsage.summary(of: events, since: now.addingTimeInterval(-86_400), days: 7)
        XCTAssertEqual(summary.questions, 2)
        XCTAssertEqual(summary.answeredByVoice, 2)
        XCTAssertEqual(summary.withdrawn, 1)
        XCTAssertEqual(summary.dictatedWords, 12)
        XCTAssertEqual(summary.medianAnswerSeconds, 4)
    }
}
