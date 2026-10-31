import XCTest
@testable import UIUICore

final class VoiceGestureTests: XCTestCase {
    func testToggleStartsImmediatelyOnFirstCleanReleaseAndDeduplicatesEdges() {
        var state = VoiceGestureState()
        XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: nil, now: 0), [])
        XCTAssertEqual(state.handle(.pressed, mode: .toggle, activeCapture: nil, now: 0), [])
        XCTAssertEqual(state.handle(.pressed, mode: .toggle, activeCapture: nil, now: 0.01), [])
        XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: nil, now: 0.05), [.startDictation])
        XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: .dictation, now: 0.06), [])
    }

    func testSecondTapFinishesDictationAtEveryTapSpeedWithoutPromotion() {
        for secondPress in [0.051, 0.1, 0.3, 0.5, 1.0] {
            var state = VoiceGestureState()
            _ = state.handle(.pressed, mode: .toggle, activeCapture: nil, now: 0)
            XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: nil, now: 0.05), [.startDictation])
            XCTAssertEqual(state.handle(.pressed, mode: .toggle, activeCapture: .dictation, now: secondPress), [])
            XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: .dictation, now: secondPress + 0.1), [.finish])
        }
    }

    func testFreshTapAfterPreviousCaptureEndedStartsOnlyDictation() {
        var state = VoiceGestureState()
        _ = state.handle(.pressed, mode: .toggle, activeCapture: nil, now: 0)
        _ = state.handle(.released, mode: .toggle, activeCapture: nil, now: 0.05)
        // Capture can end independently while the shortcut is up.
        _ = state.handle(.pressed, mode: .toggle, activeCapture: nil, now: 0.1)
        XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: nil, now: 0.15), [.startDictation])
    }

    func testResetBetweenEdgesRequiresAFreshPress() {
        var state = VoiceGestureState()
        _ = state.handle(.pressed, mode: .toggle, activeCapture: nil, now: 0)
        XCTAssertEqual(state.handle(.reset, mode: .toggle, activeCapture: nil, now: 0.01), [.cancelHold])
        XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: nil, now: 0.02), [])
        _ = state.handle(.pressed, mode: .toggle, activeCapture: nil, now: 0.03)
        XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: nil, now: 0.04), [.startDictation])
    }

    func testHoldThresholdStartsOnceAndReleaseFinishesOwnedDictation() {
        var state = VoiceGestureState()
        XCTAssertEqual(state.handle(.pressed, mode: .hold, activeCapture: nil, now: 0), [.scheduleHold])
        XCTAssertEqual(state.handle(.holdThreshold, mode: .hold, activeCapture: nil, now: 0.159), [])
        XCTAssertEqual(state.handle(.holdThreshold, mode: .hold, activeCapture: nil, now: 0.160), [.startDictation])
        XCTAssertEqual(state.handle(.holdThreshold, mode: .hold, activeCapture: .dictation, now: 0.3), [])
        XCTAssertEqual(state.handle(.released, mode: .hold, activeCapture: .dictation, now: 0.4), [.finish])
    }

    func testRepeatedQuickHoldTapsNeverStartCapture() {
        var state = VoiceGestureState()
        for press in [0.0, 0.1, 0.2, 0.6] {
            XCTAssertEqual(state.handle(.pressed, mode: .hold, activeCapture: nil, now: press), [.scheduleHold])
            XCTAssertEqual(state.handle(.released, mode: .hold, activeCapture: nil, now: press + 0.05), [.cancelHold])
            XCTAssertEqual(state.handle(.holdThreshold, mode: .hold, activeCapture: nil, now: press + 0.16), [])
        }
        XCTAssertEqual(state.handle(.pressed, mode: .hold, activeCapture: nil, now: 1), [.scheduleHold])
        XCTAssertEqual(state.handle(.holdThreshold, mode: .hold, activeCapture: nil, now: 1.16), [.startDictation])
    }

    func testHoldingAfterAQuickTapStartsDictationAtThreshold() {
        var state = VoiceGestureState()
        _ = state.handle(.pressed, mode: .hold, activeCapture: nil, now: 0)
        _ = state.handle(.released, mode: .hold, activeCapture: nil, now: 0.05)
        XCTAssertEqual(state.handle(.pressed, mode: .hold, activeCapture: nil, now: 0.10), [.scheduleHold])
        XCTAssertEqual(state.handle(.holdThreshold, mode: .hold, activeCapture: nil, now: 0.26), [.startDictation])
        XCTAssertEqual(state.handle(.released, mode: .hold, activeCapture: .dictation, now: 1.0), [.finish])
    }

    func testChordCancelsOnlyGestureOwnedHoldCapture() {
        var hold = VoiceGestureState()
        _ = hold.handle(.pressed, mode: .hold, activeCapture: nil, now: 0)
        _ = hold.handle(.holdThreshold, mode: .hold, activeCapture: nil, now: 0.16)
        XCTAssertEqual(hold.handle(.cancelled, mode: .hold, activeCapture: .dictation, now: 0.2), [.cancelHold, .cancelCapture])
        XCTAssertEqual(hold.handle(.released, mode: .hold, activeCapture: nil, now: 0.3), [])

        var toggle = VoiceGestureState()
        _ = toggle.handle(.pressed, mode: .toggle, activeCapture: .dictation, now: 0)
        XCTAssertEqual(toggle.handle(.cancelled, mode: .toggle, activeCapture: .dictation, now: 0.1), [.cancelHold])
        XCTAssertEqual(toggle.handle(.released, mode: .toggle, activeCapture: .dictation, now: 0.2), [])
        _ = toggle.handle(.pressed, mode: .toggle, activeCapture: .dictation, now: 0.3)
        XCTAssertEqual(toggle.handle(.released, mode: .toggle, activeCapture: .dictation, now: 0.4), [.finish])
    }

    func testResetReconfigurationAndStaleTimersCannotStartCapture() {
        var state = VoiceGestureState()
        _ = state.handle(.pressed, mode: .hold, activeCapture: nil, now: 0)
        XCTAssertEqual(state.handle(.reset, mode: .toggle, activeCapture: nil, now: 0.1), [.cancelHold])
        XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: nil, now: 0.11), [])
        XCTAssertEqual(state.handle(.holdThreshold, mode: .hold, activeCapture: nil, now: 0.16), [])
        _ = state.handle(.pressed, mode: .hold, activeCapture: nil, now: 1)
        XCTAssertEqual(state.handle(.holdThreshold, mode: .hold, activeCapture: nil, now: 1.05), [])
        XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: nil, now: 1.1), [.cancelHold])
        XCTAssertEqual(state.handle(.released, mode: .toggle, activeCapture: nil, now: 1.2), [])
    }

    func testHoldTimerCannotStartOverAnExistingCapture() {
        var state = VoiceGestureState()
        _ = state.handle(.pressed, mode: .hold, activeCapture: nil, now: 0)
        XCTAssertEqual(state.handle(.holdThreshold, mode: .hold, activeCapture: .dictation, now: 0.16), [.cancelHold])
        XCTAssertEqual(state.handle(.released, mode: .hold, activeCapture: .dictation, now: 0.2), [.finish])
    }

    func testInvalidClockCancelsOwnedHoldWithoutCompletingAStaleRelease() {
        for invalid in [TimeInterval.nan, .infinity, -.infinity] {
            var state = VoiceGestureState()
            _ = state.handle(.pressed, mode: .hold, activeCapture: nil, now: 0)
            _ = state.handle(.holdThreshold, mode: .hold, activeCapture: nil, now: 0.16)
            XCTAssertEqual(state.handle(.released, mode: .hold, activeCapture: .dictation, now: invalid), [.cancelHold, .cancelCapture])
            XCTAssertEqual(state.handle(.released, mode: .hold, activeCapture: nil, now: 1), [])
        }
    }
}
