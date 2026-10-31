import Foundation
import XCTest
@testable import UIUI

final class NotchReceiptTests: XCTestCase {
    @MainActor
    func testExpiredCancellationCannotBeRelitByRetainedHistoryStatus() throws {
        let model = try makeModel()
        model.cancelVoiceInputFromEscape()
        let receipt = try XCTUnwrap(model.notchVoiceFeedback)
        XCTAssertTrue(model.notchCancellationVisible)
        XCTAssertEqual(receipt.title, "Cancelled")
        XCTAssertEqual(receipt.presentation, .cancellation)
        model.dismissNotchFeedback(receipt.id)
        XCTAssertFalse(model.notchCancellationVisible, "Retained History status cannot leave cancelled eyes lit indefinitely")
        XCTAssertEqual(model.statusMessage, "Cancelled · microphone off")
        XCTAssertEqual(model.activeVoiceFeedback, receipt)
    }

    @MainActor
    func testPanelOwnerClearsCancellationAfterItsDeadline() async throws {
        let model = try makeModel()
        model.settings.notchEnabled = false
        let panels = PanelCoordinator(model: model, installSystemObservers: false)
        defer { panels.shutdown() }
        model.cancelVoiceInputFromEscape()
        let receipt = try XCTUnwrap(model.notchVoiceFeedback)
        panels.activityChanged()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.notchCancellationVisible {
            guard .now < deadline else {
                XCTFail("The panel owner left cancellation visible past its receipt deadline")
                return
            }
            await Task.yield()
        }
        XCTAssertNil(model.notchVoiceFeedback)
        XCTAssertEqual(model.activeVoiceFeedback, receipt)
        XCTAssertEqual(model.statusMessage, "Cancelled · microphone off")
        XCTAssertFalse(model.notchExpanded)
    }

    @MainActor
    private func makeModel() throws -> AppModel {
        let suite = "uiui-notch-receipt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, persistSettings: false, cleanup: NotchReceiptCleanup(),
                             voice: TriggeredVoice(capture: SpeechCapture()))
        // No start(): no database, system services, recognizer, synthesis,
        // model preparation, clipboard, or provider boundary is exercised.
        addTeardownBlock {
            await MainActor.run { model.shutdown() }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return model
    }

    @MainActor
    func testExpiredPasteDisappearsFromNotchWhileHistoryKeepsCompleteReceipt() throws {
        let model = try makeModel()
        let receipt = VoiceActionFeedback(state: .information, title: "Paste sent · copied",
                                           detail: "Synthetic destination. Complete words remain available.",
                                           presentation: .pasteDispatch)
        model.dictationFeedback = receipt
        XCTAssertEqual(model.notchVoiceFeedback, receipt)
        model.dismissNotchFeedback(receipt.id)
        XCTAssertNil(model.notchVoiceFeedback)
        XCTAssertEqual(model.activeVoiceFeedback, receipt)
        XCTAssertEqual(model.dictationFeedback, receipt)
    }

    @MainActor
    func testNewReceiptRemainsVisibleAndStaleExpiryCannotHideIt() throws {
        let model = try makeModel()
        let previous = VoiceActionFeedback(state: .information, title: "Previous paste", detail: "Synthetic old receipt",
                                          presentation: .pasteDispatch)
        model.dictationFeedback = previous
        model.dismissNotchFeedback(previous.id)
        let latest = VoiceActionFeedback(state: .information, title: "Latest paste", detail: "Synthetic current receipt",
                                        presentation: .pasteDispatch)
        model.dictationFeedback = latest
        XCTAssertEqual(model.notchVoiceFeedback, latest)
        model.dismissNotchFeedback(previous.id)
        model.dismissNotchFeedback(UUID())
        XCTAssertEqual(model.notchVoiceFeedback, latest)
        XCTAssertEqual(model.activeVoiceFeedback, latest)
        model.dismissNotchFeedback(latest.id)
        XCTAssertNil(model.notchVoiceFeedback)
        XCTAssertEqual(model.activeVoiceFeedback, latest)
    }

    @MainActor
    func testFailureWorkingAndNeedsInputCannotBeDismissedButCopiedNoticeCan() throws {
        let model = try makeModel()
        for state in [VoiceActionFeedback.State.failure, .working, .needsInput] {
            let receipt = VoiceActionFeedback(state: state, title: "Result requiring attention", detail: "Synthetic status")
            model.dictationFeedback = receipt
            model.dismissNotchFeedback(receipt.id)
            XCTAssertEqual(model.notchVoiceFeedback, receipt)
            XCTAssertEqual(model.activeVoiceFeedback, receipt)
        }
        let copied = VoiceActionFeedback(state: .needsInput, title: "Copied · paste manually", detail: "Synthetic status", presentation: .copiedOnly)
        model.dictationFeedback = copied
        model.dismissNotchFeedback(copied.id)
        // The words are safe on the clipboard and in Home; the notch clears.
        XCTAssertNil(model.notchVoiceFeedback)
        XCTAssertEqual(model.activeVoiceFeedback, copied)
    }

    @MainActor
    func testExpiredReceiptsStayHiddenUntilReplacementAndHistoricalIDsArePruned() throws {
        let model = try makeModel()
        let first = VoiceActionFeedback(state: .information, title: "First paste", detail: "Synthetic receipt")
        model.dictationFeedback = first
        model.dismissNotchFeedback(first.id)
        for _ in 0..<20 {
            let current = VoiceActionFeedback(state: .information, title: "New paste", detail: "Synthetic receipt",
                                             presentation: .pasteDispatch)
            model.dictationFeedback = current
            XCTAssertEqual(model.notchVoiceFeedback, current)
            model.dismissNotchFeedback(current.id)
            XCTAssertNil(model.notchVoiceFeedback)
            XCTAssertEqual(model.activeVoiceFeedback, current)
            model.dismissNotchFeedback(first.id)
            XCTAssertNil(model.notchVoiceFeedback, "A stale expiry cannot relight the current expired receipt")
        }
        // Replacement prunes historical expiry identities. Reusing a synthetic
        // old value observes bounded retention without reading private storage.
        model.dictationFeedback = first
        XCTAssertEqual(model.notchVoiceFeedback, first)
    }

    @MainActor
    func testPanelOwnerExpiresPasteEvenWhenNotchIsAlreadyCollapsed() async throws {
        let model = try makeModel()
        model.settings.notchEnabled = false
        model.notchExpanded = false
        let panels = PanelCoordinator(model: model, installSystemObservers: false)
        defer { panels.shutdown() }
        let receipt = VoiceActionFeedback(state: .information, title: "Paste sent · copied",
                                           detail: "Synthetic completed paste", presentation: .pasteDispatch)
        model.dictationFeedback = receipt
        panels.activityChanged()
        XCTAssertFalse(model.notchExpanded)
        XCTAssertEqual(model.notchVoiceFeedback, receipt)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.notchVoiceFeedback != nil {
            guard .now < deadline else {
                XCTFail("The panel owner's paste dwell did not expire the collapsed notch receipt")
                return
            }
            await Task.yield()
        }
        XCTAssertEqual(model.activeVoiceFeedback, receipt)
        XCTAssertEqual(model.dictationFeedback, receipt)
        XCTAssertFalse(model.notchExpanded)
    }
}

@MainActor
private final class NotchReceiptCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}
