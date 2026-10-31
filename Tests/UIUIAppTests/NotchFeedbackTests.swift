import Foundation
import XCTest
@testable import UIUI

final class NotchFeedbackTests: XCTestCase {
    private func phase(state: String = "off", requested: Bool = false,
                       manualRecording: Bool = false, manualPreparing: Bool = false,
                       manualFinishing: Bool = false,
                       feedback: VoiceActionFeedback? = nil, error: Bool = false,
                       cancelled: Bool = false, triggerPressed: Bool = false,
                       queued: Bool = false) -> NotchFeedbackPhase {
        NotchFeedbackPhase.resolve(captureRequested: requested, captureState: state,
                                   manualRecording: manualRecording, manualPreparing: manualPreparing,
                                   manualFinishing: manualFinishing,
                                   feedback: feedback, hasError: error,
                                   cancelled: cancelled, triggerPressed: triggerPressed, queued: queued)
    }

    func testFirstTapAcknowledgmentAndPendingStartupNeverClaimRecording() {
        XCTAssertEqual(phase(triggerPressed: true), .preparing)
        XCTAssertEqual(phase(requested: true), .preparing, "Request admission precedes asynchronous microphone startup")
        XCTAssertEqual(phase(state: "starting", requested: true), .preparing)
        XCTAssertEqual(phase(manualPreparing: true), .preparing)
        XCTAssertEqual(phase(state: "capturing", requested: true), .recording)
        XCTAssertEqual(phase(manualRecording: true), .recording)
    }

    func testNextKeyPressCannotReplaceCurrentProcessingWithMicrophoneStartup() {
        let working = VoiceActionFeedback(state: .working, title: "Placing dictation", detail: "")
        XCTAssertEqual(phase(state: "finishing", triggerPressed: true), .processing)
        XCTAssertEqual(phase(manualFinishing: true, triggerPressed: true), .processing)
        XCTAssertEqual(phase(feedback: working, triggerPressed: true), .processing)
    }

    func testNewCaptureOwnsTheDisplayEvenWhenAnOlderPathRetainsAnError() {
        let oldFailure = VoiceActionFeedback(state: .failure, title: "Couldn’t paste", detail: "")
        XCTAssertEqual(phase(requested: true, feedback: oldFailure, error: true), .preparing)
        XCTAssertEqual(phase(state: "capturing", feedback: oldFailure, error: true), .recording)
        XCTAssertEqual(phase(manualPreparing: true, feedback: oldFailure, error: true), .preparing)
        XCTAssertEqual(phase(manualRecording: true, feedback: oldFailure, error: true), .recording)
    }

    func testCopyOnlyAndFailuresRemainActionableButDispatchDoesNotClaimSuccess() {
        let copyOnly = VoiceActionFeedback(state: .needsInput, title: "Copied · paste manually", detail: "", presentation: .copiedOnly)
        let failure = VoiceActionFeedback(state: .failure, title: "Couldn’t paste", detail: "")
        let sent = VoiceActionFeedback(state: .information, title: "Paste sent · copied", detail: "", presentation: .pasteDispatch)
        let saved = VoiceActionFeedback(state: .success, title: "Saved to history", detail: "")
        XCTAssertEqual(phase(feedback: copyOnly), .copied)
        XCTAssertEqual(phase(feedback: failure), .needsInput)
        XCTAssertEqual(phase(feedback: sent), .dispatched)
        XCTAssertEqual(phase(feedback: saved), .success)
        XCTAssertEqual(phase(error: true), .needsInput)
    }

    func testCancellationWithdrawsWithoutHidingAnActionableFailure() {
        XCTAssertEqual(phase(cancelled: true), .cancelled)
        XCTAssertEqual(phase(error: true, cancelled: true), .needsInput)
        XCTAssertEqual(phase(), .idle)
    }

    func testReceiptMeaningComesFromPresentationAndNeverFromDisplayCopy() {
        let typedCopy = VoiceActionFeedback(state: .needsInput, title: "Done", detail: "", presentation: .copiedOnly)
        let ordinaryAction = VoiceActionFeedback(state: .needsInput, title: "Copied · paste manually", detail: "")
        let typedCancellation = VoiceActionFeedback(state: .information, title: "A different localized label", detail: "", presentation: .cancellation)
        let ordinaryMessage = VoiceActionFeedback(state: .information, title: "Cancelled", detail: "")
        let failure = VoiceActionFeedback(state: .failure, title: "Copied", detail: "", presentation: .copiedOnly)
        XCTAssertEqual(phase(feedback: typedCopy), .copied)
        XCTAssertEqual(phase(feedback: ordinaryAction), .needsInput)
        XCTAssertEqual(phase(feedback: typedCancellation), .cancelled)
        XCTAssertEqual(phase(feedback: ordinaryMessage), .message)
        XCTAssertEqual(phase(feedback: failure), .needsInput)
        XCTAssertEqual(phase(feedback: typedCopy, error: true), .needsInput)
        XCTAssertEqual(phase(state: "capturing", feedback: typedCancellation), .recording)
        XCTAssertEqual(phase(requested: true, feedback: typedCopy), .preparing)
    }

    func testQueuedRequestStaysMicOffWithoutHidingActualMicrophoneActivity() {
        let receipt = VoiceActionFeedback(state: .needsInput, title: "Copied", detail: "", presentation: .copiedOnly)
        XCTAssertEqual(phase(queued: true), .queued)
        XCTAssertEqual(phase(requested: true, feedback: receipt, triggerPressed: true, queued: true), .queued)
        XCTAssertEqual(phase(state: "capturing", queued: true), .recording)
        XCTAssertEqual(phase(manualRecording: true, queued: true), .recording)
        XCTAssertEqual(phase(state: "starting", queued: true), .preparing)
        XCTAssertEqual(phase(state: "finishing", queued: true), .processing)
        XCTAssertEqual(NotchFeedbackPhase.queued.label, "Queued · mic off")
    }

    func testUnrelatedReceiptsCannotReplayCaptureArrivalButNewReceiptsGetTheirOwnGesture() {
        let first = UUID()
        let second = UUID()
        for capturePhase in [NotchFeedbackPhase.idle, .preparing, .recording, .queued] {
            XCTAssertEqual(NotchFeedbackEvent(phase: capturePhase, feedbackID: first),
                           NotchFeedbackEvent(phase: capturePhase, feedbackID: second))
        }
        XCTAssertEqual(NotchFeedbackEvent(phase: .dispatched, feedbackID: first),
                       NotchFeedbackEvent(phase: .dispatched, feedbackID: first))
        XCTAssertNotEqual(NotchFeedbackEvent(phase: .dispatched, feedbackID: first),
                          NotchFeedbackEvent(phase: .dispatched, feedbackID: second))
        XCTAssertNotEqual(NotchFeedbackEvent(phase: .preparing, feedbackID: nil),
                          NotchFeedbackEvent(phase: .recording, feedbackID: nil))
    }
}
