import Foundation
import XCTest
import UIUICore
@testable import UIUI

final class TriggeredVoiceTests: XCTestCase {
    @MainActor
    func testExplicitStopRetiresCaptureErrorBeforeLaterReceiptsAndCancellation() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        let suite = "uiui-stopped-error-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, persistSettings: false,
            delivery: StoppedErrorDelivery(), cleanup: StoppedErrorCleanup(), voice: voice)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        // Exercise the real state projection with silent injected capture. No
        // model lifecycle, destination lookup, audio hardware, or provider runs.
        voice.onTrigger = {}
        voice.onRecordingSound = nil
        try await voice.start(locale: "en-IN", contextualStrings: [])
        let staleError = capture.onError
        capture.onError?("Synthetic recognition failure")
        XCTAssertEqual(voice.lastError, "Synthetic recognition failure")
        XCTAssertEqual(voice.state, "error")
        XCTAssertEqual(model.notchFeedbackPhase, .needsInput, "A current failure remains actionable before an explicit stop")

        voice.stop()
        XCTAssertNil(voice.lastError)
        XCTAssertEqual(voice.state, "off")
        staleError?("Late failure from the stopped capture")
        XCTAssertNil(voice.lastError, "A stale callback cannot restore the stopped session's error")
        for presentation in [VoiceActionFeedback.Presentation.pasteDispatch, .copiedOnly] {
            model.dictationFeedback = VoiceActionFeedback(
                state: presentation == .copiedOnly ? .needsInput : .information,
                title: "Synthetic later manual receipt", detail: "", presentation: presentation)
            XCTAssertEqual(model.notchFeedbackPhase, presentation == .copiedOnly ? .copied : .dispatched)
        }

        try await voice.start(locale: "en-IN", contextualStrings: [])
        capture.onError?("Another current recognition failure")
        XCTAssertEqual(model.notchFeedbackPhase, .needsInput)
        model.cancelVoiceInputFromEscape()
        XCTAssertNil(voice.lastError)
        XCTAssertEqual(model.notchVoiceFeedback?.presentation, .cancellation)
        XCTAssertEqual(model.notchFeedbackPhase, .cancelled, "Cancellation must not inherit the stopped capture's error")
    }

    @MainActor
    func testRecordingSoundsWaitForReadinessAndFinishOnceBeforeFinalResult() async throws {
        let capture = FakeTriggeredCapture()
        capture.suspendStart = true
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var cues: [RecordingSound] = []
        voice.onRecordingSound = { cues.append($0) }
        let startup = Task { try await voice.start(locale: "en-IN", contextualStrings: []) }
        while capture.startCount == 0 { await Task.yield() }
        XCTAssertTrue(cues.isEmpty, "Preparing a microphone must not sound ready")
        capture.releaseAuthorization()
        try await startup.value
        XCTAssertEqual(cues, [.ready])
        voice.finish()
        voice.finish()
        XCTAssertEqual(cues, [.ready, .finished])
        capture.emitCompletion(SpeechCompletion(text: "hello", reason: .final, wasExplicitlyStopped: true))
        voice.stop()
        XCTAssertEqual(cues, [.ready, .finished], "Finalization and idle cleanup must not replay cues")
    }

    @MainActor
    func testEscapeDuringStartupHasCancelCueWithoutLateReadyCue() async throws {
        let capture = FakeTriggeredCapture()
        capture.suspendStart = true
        let voice = TriggeredVoice(capture: capture)
        var cues: [RecordingSound] = []
        voice.onRecordingSound = { cues.append($0) }
        let startup = Task { try await voice.start(locale: "en-IN", contextualStrings: []) }
        while capture.startCount == 0 { await Task.yield() }
        voice.stop()
        capture.releaseAuthorization()
        do { try await startup.value; XCTFail("Cancelled startup succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected startup failure: \(error)") }
        voice.stop()
        XCTAssertEqual(cues, [.cancelled])
    }

    @MainActor
    func testCancelWhileRecordingCannotPlayFinishForStaleRecognition() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        var cues: [RecordingSound] = []
        voice.onRecordingSound = { cues.append($0) }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        let oldFinal = capture.onFinal
        voice.stop()
        oldFinal?("stale words")
        XCTAssertEqual(cues, [.ready, .cancelled])
    }
    @MainActor
    func testReleaseDuringAuthorizationPreventsLateRecordingAndCommand() async throws {
        let capture = FakeTriggeredCapture()
        capture.suspendStart = true
        let enteredStart = expectation(description: "Capture awaits authorization")
        capture.onStart = { enteredStart.fulfill() }
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var commands: [String] = []
        voice.onCommand = { commands.append($0) }
        let start = Task { @MainActor in
            do {
                try await voice.start(locale: "en-IN", contextualStrings: [])
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected startup error: \(error)")
                return false
            }
        }
        await fulfillment(of: [enteredStart], timeout: 2)
        let staleFinal = capture.onFinal
        XCTAssertTrue(voice.isRecording)
        XCTAssertEqual(voice.state, "starting")
        voice.finish()
        XCTAssertFalse(voice.isRecording)
        XCTAssertEqual(voice.state, "idle")
        capture.releaseAuthorization()
        let cancelled = await start.value
        XCTAssertTrue(cancelled)
        staleFinal?("remember a cancelled capture")
        XCTAssertEqual(capture.engineStartCount, 0)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(capture.isRecording)
    }

    @MainActor
    func testFinalDeliversOnceAndNeverRestartsCapture() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var commands: [String] = []
        voice.onCommand = { commands.append($0) }
        try await voice.start(locale: "en-IN", contextualStrings: ["Sarah"])
        let final = capture.onFinal
        voice.finish()
        XCTAssertFalse(capture.isRecording)
        XCTAssertFalse(voice.isRecording)
        XCTAssertEqual(voice.state, "finishing")
        final?("remember the review")
        final?("remember duplicate")
        voice.setWorking(false)
        XCTAssertEqual(commands, ["remember the review"])
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertTrue(voice.isEnabled, "A completed session stays idle until another explicit start")
        XCTAssertFalse(voice.isRecording)
        XCTAssertEqual(voice.state, "idle")
    }

    @MainActor
    func testEmptyAudioProducesNoAction() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var commands: [String] = []
        voice.onCommand = { commands.append($0) }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        voice.finish()
        capture.onFinal?(" \n\t ")
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(voice.state, "idle")
        XCTAssertFalse(voice.isRecording)
        XCTAssertFalse(capture.isRecording)
    }

    @MainActor
    func testRepeatedFinishStopsOnceAndReportsOneFinalization() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var finalizations: [Double] = []
        var commands: [String] = []
        voice.onFinalization = { finalizations.append($0) }
        voice.onCommand = { commands.append($0) }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        voice.finish()
        voice.finish()
        voice.finish()
        XCTAssertEqual(capture.stopCount, 1)
        let final = capture.onFinal
        final?("status")
        voice.finish()
        final?("status")
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(finalizations.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(finalizations.first), 0)
        XCTAssertEqual(commands, ["status"])
    }

    @MainActor
    func testWakePhraseInsideRememberedSpeechIsPreserved() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var commands: [String] = []
        voice.onCommand = { commands.append($0) }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        let text = "remember Sarah said hey uiui cancel"
        capture.onPartial?("  \(text) \n")
        XCTAssertEqual(voice.partialCommand, text)
        voice.finish()
        capture.onFinal?(" \(text) \n")
        XCTAssertEqual(commands, [" \(text) \n"])
    }

    @MainActor
    func testDictatedWakePhraseRemainsLiteralText() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var command: String?
        voice.onCommand = { command = $0 }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        voice.finish()
        capture.onFinal?("type Hey uiui remind me to leave in 5 minutes")
        XCTAssertEqual(command, "type Hey uiui remind me to leave in 5 minutes")
    }

    @MainActor
    func testTriggerPrecedesCoherentStartingNotificationAndStopRejectsStaleFinal() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var order: [String] = []
        var commands: [String] = []
        voice.onTrigger = { order.append("trigger") }
        voice.onCommand = { commands.append($0) }
        voice.onStateChanged = {
            order.append(voice.state)
            if voice.state == "starting" { XCTAssertTrue(voice.isRecording) }
        }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        XCTAssertEqual(order, ["trigger", "starting", "capturing"])
        let staleFinal = capture.onFinal
        voice.stop()
        staleFinal?("cancel")
        XCTAssertFalse(voice.isEnabled)
        XCTAssertFalse(voice.isRecording)
        XCTAssertFalse(capture.isRecording)
        XCTAssertTrue(commands.isEmpty)
        // The callback above captures voice; release it before test teardown.
        voice.onStateChanged = nil
    }

    @MainActor
    func testStoppedPartialRecoveryIsSeparateFromCompletedText() async throws {
        for reason in [SpeechCompletion.Reason.timedOut, .recognitionError, .unreconciledFinal] {
            let capture = FakeTriggeredCapture()
            let voice = TriggeredVoice(capture: capture)
            defer { voice.stop() }
            var commands: [String] = []
            var recoveries: [SpeechCompletion] = []
            voice.onCommand = { commands.append($0) }
            voice.onIncomplete = { recoveries.append($0) }
            try await voice.start(locale: "en-IN", contextualStrings: [])
            voice.finish()
            let incomplete = SpeechCompletion(text: "remind me in ten", reason: reason, wasExplicitlyStopped: true)
            capture.emitCompletion(incomplete)
            capture.onFinal?("a late duplicate")
            XCTAssertTrue(commands.isEmpty)
            XCTAssertEqual(recoveries, [incomplete])
            XCTAssertFalse(voice.isRecording)
            XCTAssertFalse(capture.isRecording)
            XCTAssertEqual(voice.partialCommand, "remind me in ten")
            XCTAssertNotNil(voice.lastError)
            XCTAssertEqual(voice.state, "incomplete", "Recovery must not trigger fatal-stream rollback")
            voice.acknowledgeIncompleteDictation()
            XCTAssertNil(voice.lastError)
            XCTAssertEqual(voice.state, "idle")
            XCTAssertFalse(voice.isRecording)
        }
    }

    @MainActor
    func testRecognitionFailureRetainsUnstoppedReasonAndStaleRecoveryCannotAffectNextCapture() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var recoveries: [SpeechCompletion] = []
        var commands: [String] = []
        voice.onCommand = { commands.append($0) }
        voice.onIncomplete = { recoveries.append($0) }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        let stale = capture.onCompletion
        let failure = SpeechCompletion(text: "remember incomplete", reason: .recognitionError, wasExplicitlyStopped: false)
        capture.emitCompletion(failure)
        XCTAssertEqual(recoveries, [failure])
        XCTAssertFalse(voice.isRecording)
        try await voice.start(locale: "en-IN", contextualStrings: [])
        stale?(failure)
        XCTAssertTrue(voice.isRecording)
        XCTAssertEqual(voice.state, "capturing")
        XCTAssertEqual(recoveries, [failure])
        XCTAssertTrue(commands.isEmpty)
    }

    @MainActor
    func testEmptyIncompleteResultDoesNotDispatchCommandOrRecovery() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var dispatched = false
        voice.onCommand = { _ in dispatched = true }
        voice.onIncomplete = { _ in dispatched = true }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        voice.finish()
        capture.emitCompletion(SpeechCompletion(text: " \n", reason: .timedOut, wasExplicitlyStopped: true))
        XCTAssertFalse(dispatched)
        XCTAssertFalse(voice.isRecording)
        XCTAssertEqual(voice.state, "error")
        XCTAssertEqual(voice.lastError, "Speech recognition stopped before any words were captured. Check the system microphone and try again.")
    }

    @MainActor
    func testNonUserStopDoesNotAuthorizeCommittingIncompleteDictation() async throws {
        let capture = FakeTriggeredCapture()
        let voice = TriggeredVoice(capture: capture)
        defer { voice.stop() }
        var recovery: SpeechCompletion?
        var dispatchedCommand = false
        voice.onIncomplete = { recovery = $0 }
        voice.onCommand = { _ in dispatchedCommand = true }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        // A non-user stop cannot turn an incomplete result into a spoken command.
        voice.finish(userInitiated: false)
        capture.emitCompletion(SpeechCompletion(text: "unfinished words", reason: .timedOut, wasExplicitlyStopped: true))
        XCTAssertEqual(recovery?.text, "unfinished words")
        XCTAssertEqual(recovery?.wasExplicitlyStopped, false)
        XCTAssertFalse(dispatchedCommand)
        XCTAssertFalse(voice.isRecording)
    }
}

@MainActor
private final class StoppedErrorDelivery: TextDelivering {
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        XCTFail("This state regression must not deliver text")
        return .held("Unexpected delivery")
    }
    func cancel() {}
}

@MainActor
private final class StoppedErrorCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}

/// Exercises the owner's async lifecycle without authorization, engines or providers.
@MainActor
private final class FakeTriggeredCapture: TriggeredVoiceCapture {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onCompletion: ((SpeechCompletion) -> Void)?
    var onError: ((String) -> Void)?
    var onRecovery: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onFinalization: ((Double) -> Void)?
    var onStart: (() -> Void)?
    var suspendStart = false
    private var authorization: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var engineStartCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var isRecording = false

    func requestAuthorization() async -> Bool { true }

    func start(locale: String, contextualStrings: [String]) async throws {
        startCount += 1
        let token = cancelCount
        onStart?()
        if suspendStart {
            await withCheckedContinuation { authorization = $0 }
        }
        guard token == cancelCount, !Task.isCancelled else { throw CancellationError() }
        engineStartCount += 1
        isRecording = true
    }

    func releaseAuthorization() {
        let pending = authorization
        authorization = nil
        pending?.resume()
    }

    func stop() {
        stopCount += 1
        isRecording = false
    }

    func cancel() {
        cancelCount += 1
        isRecording = false
    }

    func emitCompletion(_ completion: SpeechCompletion) {
        isRecording = false
        onCompletion?(completion)
    }
}
