import Foundation
import XCTest
@testable import UIUI

@MainActor
final class NotchFeedbackLifetimeTests: XCTestCase {
    private func paste() -> VoiceActionFeedback {
        VoiceActionFeedback(state: .information, title: "Paste sent · copied", detail: "", presentation: .pasteDispatch)
    }

    private func waitFor(_ description: String, until condition: () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(description, file: file, line: line)
        throw ReceiptTestError.conditionNotReached
    }

    func testRepeatedUpdatesDoNotExtendPasteDeadlineAndExpiryDoesNotRequireExpandedNotch() async throws {
        let clock = ReceiptClock()
        var expired: [(UUID, Bool)] = []
        let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { expired.append(($0, $1)); return true }
        defer { lifetime.cancel(); clock.releaseAll() }
        let feedback = paste()
        lifetime.update(feedback: feedback, busy: false)
        try await waitFor("Receipt sleep not scheduled") { clock.requests.count == 1 }
        XCTAssertEqual(clock.requests[0], 0.65, accuracy: 0.000_001)
        clock.now = 0.60
        for _ in 0..<20 { lifetime.update(feedback: feedback, busy: false) }
        XCTAssertEqual(clock.requests.count, 1)
        clock.now = 0.65
        // No expanded/collapsed input exists: the receipt expires in either state.
        lifetime.update(feedback: feedback, busy: false)
        XCTAssertEqual(expired.map(\.0), [feedback.id])
        XCTAssertEqual(expired.map(\.1), [true])
        clock.now = 100
        lifetime.update(feedback: feedback, busy: false)
        XCTAssertEqual(expired.count, 1, "Collapse or another activity update cannot restart an expired receipt")
    }

    func testBusyPauseResumesOnlyRemainingTimeAndSleepActuallyExpiresReceipt() async throws {
        let clock = ReceiptClock()
        var expired: [UUID] = []
        let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { id, _ in expired.append(id); return true }
        defer { lifetime.cancel(); clock.releaseAll() }
        let feedback = paste()
        lifetime.update(feedback: feedback, busy: false)
        try await waitFor("Initial sleep not scheduled") { clock.requests.count == 1 }
        clock.now = 0.20
        lifetime.update(feedback: feedback, busy: true)
        clock.now = 0.40
        lifetime.update(feedback: feedback, busy: false)
        try await waitFor("Remaining sleep not scheduled") { clock.requests.count == 2 }
        XCTAssertEqual(clock.requests[1], 0.25, accuracy: 0.000_001)
        clock.now = 0.65
        clock.release(0) // Simulate a cancelled sleep finishing late.
        clock.release(1)
        try await waitFor("Remaining sleep did not expire receipt") { expired.count == 1 }
        XCTAssertEqual(expired, [feedback.id])
    }

    func testBusyReceiptWhoseDeadlinePassedExpiresImmediatelyWhenWorkEnds() {
        let clock = ReceiptClock()
        var expired: [UUID] = []
        let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { id, _ in expired.append(id); return true }
        defer { lifetime.cancel(); clock.releaseAll() }
        let feedback = paste()
        lifetime.update(feedback: feedback, busy: true)
        clock.now = 3
        lifetime.update(feedback: feedback, busy: true)
        XCTAssertTrue(expired.isEmpty)
        lifetime.update(feedback: feedback, busy: false)
        XCTAssertEqual(expired, [feedback.id])
        XCTAssertTrue(clock.requests.isEmpty, "An overdue receipt needs no extra timer")
    }

    func testStaleSleepCannotExpireNewerReceipt() async throws {
        let clock = ReceiptClock()
        var expired: [UUID] = []
        let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { id, _ in expired.append(id); return true }
        defer { lifetime.cancel(); clock.releaseAll() }
        let first = paste()
        let second = paste()
        lifetime.update(feedback: first, busy: false)
        try await waitFor("First sleep not scheduled") { clock.requests.count == 1 }
        clock.now = 0.30
        lifetime.update(feedback: second, busy: false)
        try await waitFor("Second sleep not scheduled") { clock.requests.count == 2 }
        clock.now = 0.65
        clock.release(0)
        try await waitFor("Old sleep did not return") { clock.returned.contains(0) }
        XCTAssertTrue(expired.isEmpty)
        clock.now = 0.95
        clock.release(1)
        try await waitFor("Current receipt did not expire") { !expired.isEmpty }
        XCTAssertEqual(expired, [second.id])
    }

    func testCancelAndNilResetDeadlineWithoutDeliveringCancelledExpiry() async throws {
        let clock = ReceiptClock()
        var expired: [UUID] = []
        let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { id, _ in expired.append(id); return true }
        defer { lifetime.cancel(); clock.releaseAll() }
        let feedback = paste()
        lifetime.update(feedback: feedback, busy: false)
        try await waitFor("Initial sleep not scheduled") { clock.requests.count == 1 }
        lifetime.cancel()
        clock.now = 10
        clock.release(0)
        try await waitFor("Cancelled sleep did not return") { clock.returned.contains(0) }
        XCTAssertTrue(expired.isEmpty)
        lifetime.update(feedback: feedback, busy: true)
        clock.now = 10.50
        lifetime.update(feedback: nil, busy: false)
        clock.now = 20
        lifetime.update(feedback: feedback, busy: true)
        clock.now = 20.64
        lifetime.update(feedback: feedback, busy: false)
        XCTAssertTrue(expired.isEmpty, "Reset creates a new deadline even for the same receipt identity")
        clock.now = 20.65
        lifetime.update(feedback: feedback, busy: false)
        XCTAssertEqual(expired, [feedback.id])
    }

    func testWorkingFailureAndNeedsInputRemainVisibleWithoutExpiry() {
        for state in [VoiceActionFeedback.State.working, .failure, .needsInput] {
            let clock = ReceiptClock()
            var calls = 0
            let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { _, _ in calls += 1; return true }
            let feedback = VoiceActionFeedback(state: state, title: "Action", detail: "")
            lifetime.update(feedback: feedback, busy: false)
            clock.now = 600
            lifetime.update(feedback: feedback, busy: false)
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(clock.requests.isEmpty)
            lifetime.cancel()
        }
    }

    func testTypedCancellationUsesShortFixedDeadlineAndCannotReplay() async throws {
        let clock = ReceiptClock()
        var expired: [UUID] = []
        let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { id, hide in
            XCTAssertTrue(hide)
            expired.append(id)
            return true
        }
        defer { lifetime.cancel(); clock.releaseAll() }
        let receipt = VoiceActionFeedback(state: .information, title: "Localized cancellation", detail: "", presentation: .cancellation)
        lifetime.update(feedback: receipt, busy: false)
        try await waitFor("Cancellation sleep not scheduled") { clock.requests.count == 1 }
        XCTAssertEqual(clock.requests[0], 0.28, accuracy: 0.000_001)
        clock.now = 0.27
        for _ in 0..<20 { lifetime.update(feedback: receipt, busy: false) }
        XCTAssertTrue(expired.isEmpty)
        XCTAssertEqual(clock.requests.count, 1)
        clock.now = 0.28
        lifetime.update(feedback: receipt, busy: false)
        XCTAssertEqual(expired, [receipt.id])
        clock.now = 5
        lifetime.update(feedback: receipt, busy: true)
        lifetime.update(feedback: receipt, busy: false)
        XCTAssertEqual(expired, [receipt.id], "An expired cancellation cannot return after another activity update")
    }

    func testCopiedReceiptClearsAfterAShortNoticeAndHidesTheNotch() {
        for state in [VoiceActionFeedback.State.needsInput, .information] {
            let clock = ReceiptClock()
            var expired: [(UUID, Bool)] = []
            let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { id, hide in expired.append((id, hide)); return true }
            defer { lifetime.cancel(); clock.releaseAll() }
            let receipt = VoiceActionFeedback(state: state, title: "Copied", detail: "", presentation: .copiedOnly)
            lifetime.update(feedback: receipt, busy: false)
            clock.now = 3.9
            lifetime.update(feedback: receipt, busy: false)
            XCTAssertTrue(expired.isEmpty, "The notice stays long enough to read")
            clock.now = 4
            lifetime.update(feedback: receipt, busy: false)
            XCTAssertEqual(expired.map(\.0), [receipt.id])
            XCTAssertEqual(expired.map(\.1), [true])
        }
    }

    func testCancellationCopyInAnOrdinaryMessageKeepsInformationDeadline() {
        let clock = ReceiptClock()
        var expired: [UUID] = []
        let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { id, _ in expired.append(id); return true }
        defer { lifetime.cancel(); clock.releaseAll() }
        let receipt = VoiceActionFeedback(state: .information, title: "Cancelled", detail: "")
        lifetime.update(feedback: receipt, busy: true)
        clock.now = 0.28
        lifetime.update(feedback: receipt, busy: true)
        XCTAssertTrue(expired.isEmpty)
        clock.now = 1.4
        lifetime.update(feedback: receipt, busy: false)
        XCTAssertEqual(expired, [receipt.id])
    }

    func testRejectedExpiryRemainsDueForNextIdleUpdateWithoutAnotherSleep() {
        let clock = ReceiptClock()
        var accepted = false
        var attempts = 0
        var hidden: [UUID] = []
        let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { id, _ in
            attempts += 1
            if accepted { hidden.append(id) }
            return accepted
        }
        defer { lifetime.cancel(); clock.releaseAll() }
        let feedback = paste()
        lifetime.update(feedback: feedback, busy: true)
        clock.now = 1
        lifetime.update(feedback: feedback, busy: false)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(hidden.isEmpty)
        lifetime.update(feedback: feedback, busy: true)
        XCTAssertEqual(attempts, 1, "Rejected expiry must not poll or retry while busy")
        accepted = true
        lifetime.update(feedback: feedback, busy: false)
        XCTAssertEqual(hidden, [feedback.id])
        XCTAssertTrue(clock.requests.isEmpty, "The original deadline remains overdue")
    }

    func testRejectedCallbackCannotRestoreReceiptReplacedDuringCallback() {
        let clock = ReceiptClock()
        let first = paste()
        let second = paste()
        var attempted: [UUID] = []
        var lifetime: NotchFeedbackLifetime!
        lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { id, _ in
            attempted.append(id)
            if id == first.id {
                lifetime.update(feedback: second, busy: true)
                return false
            }
            return true
        }
        defer { lifetime.cancel(); lifetime = nil; clock.releaseAll() }
        lifetime.update(feedback: first, busy: true)
        clock.now = 1
        lifetime.update(feedback: first, busy: false)
        clock.now = 1.65
        lifetime.update(feedback: second, busy: false)
        XCTAssertEqual(attempted, [first.id, second.id])
    }

    func testInformationAndSuccessExpireAtTheirOwnFixedDeadlines() {
        for (state, seconds) in [(VoiceActionFeedback.State.information, 1.4), (.success, 2.0)] {
            let clock = ReceiptClock()
            var hiding: [Bool] = []
            let lifetime = NotchFeedbackLifetime(now: { clock.now }, sleep: clock.sleep) { _, hide in hiding.append(hide); return true }
            let feedback = VoiceActionFeedback(state: state, title: "Receipt", detail: "")
            lifetime.update(feedback: feedback, busy: true)
            clock.now = seconds
            lifetime.update(feedback: feedback, busy: false)
            XCTAssertEqual(hiding, [true])
            lifetime.cancel()
        }
    }
}

private enum ReceiptTestError: Error { case conditionNotReached }

/// Test-controlled suspensions deliberately ignore cancellation until released,
/// exercising the lifetime's stale-task guard without wall-clock waits or OS work.
@MainActor
private final class ReceiptClock {
    var now: TimeInterval = 0
    private(set) var requests: [Double] = []
    private(set) var returned: Set<Int> = []
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]

    func sleep(_ duration: Duration) async throws {
        let index = requests.count
        let parts = duration.components
        requests.append(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        try await withCheckedThrowingContinuation { pending[index] = $0 }
        returned.insert(index)
    }

    func release(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
    func releaseAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume() }
    }
}
