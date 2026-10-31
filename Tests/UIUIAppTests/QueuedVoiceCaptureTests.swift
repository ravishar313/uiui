import Foundation
import XCTest
import UIUICore
@testable import UIUI

final class QueuedVoiceCaptureTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> QueuedVoiceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-queued-voice-\(UUID().uuidString)")
        let suite = "uiui-queued-voice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let trace = QueuedVoiceTrace(), capture = QueuedVoiceFakeCapture()
        let cleanup = QueuedVoiceFakeCleanup(), delivery = QueuedVoiceFakeDelivery()
        capture.onStart = { trace.events.append("capture-start") }
        delivery.onDeliver = { trace.events.append("paste-attempt") }
        let voice = TriggeredVoice(capture: capture)
        let model = AppModel(dataDirectory: root, defaults: defaults,
                             persistSettings: false,
                             delivery: delivery, cleanup: cleanup, voice: voice)
        // Synthetic boundaries only: no destination lookup, microphone, speech
        // synthesis, native models, clipboard, notifications, or provider calls.
        voice.onTrigger = {}; voice.onRecordingSound = nil
        await model.start(installSystemServices: false)
        model.captureEnabled = true // Admit only the injected capture.
        model.settings.voiceTriggerMode = .toggle
        model.settings.saveDictationHistory = false
        model.voiceGesture = VoiceGestureState()
        model.onActivityChanged = { [weak model] in model?.resumeQueuedVoiceCaptureIfReady() }
        addTeardownBlock {
            await MainActor.run { model.shutdown(); cleanup.cancel(); delivery.cancel() }
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return QueuedVoiceFixture(model: model, capture: capture, cleanup: cleanup, delivery: delivery, trace: trace)
    }

    @MainActor
    private func waitFor(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                         until condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard .now < deadline else {
                XCTFail(description, file: file, line: line)
                throw QueuedVoiceWaitFailure.conditionNotReached
            }
            await Task.yield()
        }
    }

    @MainActor
    private func tap(_ model: AppModel, at timestamp: TimeInterval) {
        model.handleVoiceGesture(.pressed, at: timestamp)
        model.handleVoiceGesture(.released, at: timestamp + 0.05)
    }

    @MainActor
    private func finishOldCapture(_ fixture: QueuedVoiceFixture) async throws {
        fixture.model.beginVoiceCapture()
        try await waitFor("Synthetic old capture did not start") { fixture.model.voice.state == "capturing" }
        fixture.model.finishVoiceCapture()
        XCTAssertEqual(fixture.model.voice.state, "finishing")
        XCTAssertEqual(fixture.capture.startCount, 1)
        XCTAssertEqual(fixture.capture.stopCount, 1)
    }

    @MainActor
    func testFinalizingCaptureDispatchesItsOnlyPasteBeforeQueuedFnStarts() async throws {
        let fixture = try await fixture(), model = fixture.model
        try await finishOldCapture(fixture)
        let previousGeneration = model.dictationCaptureGeneration
        let previousCompletion = fixture.capture.onCompletion
        let queuedAt = DispatchTime.now().uptimeNanoseconds
        model.voiceKeyPressedAt = queuedAt
        tap(model, at: 10)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        XCTAssertEqual(model.queuedVoiceTriggerAt, queuedAt)
        XCTAssertFalse(model.voiceCaptureRequested)
        XCTAssertEqual(model.dictationCaptureGeneration, previousGeneration)

        // TriggeredVoice publishes "working" before onCommand. The queue must
        // not replace that generation and suppress the old final callback.
        fixture.capture.emitFinal("keep the previous dictation")
        XCTAssertEqual(model.dictationDeliveryStartedFor, previousGeneration)
        XCTAssertEqual(model.dictationCaptureGeneration, previousGeneration)
        try await waitFor("Old final was lost before paste dispatch") { fixture.delivery.hasPending }
        XCTAssertEqual(fixture.cleanup.inputs, ["keep the previous dictation"])
        XCTAssertEqual(fixture.delivery.delivered, ["keep the previous dictation."])
        XCTAssertEqual(fixture.capture.startCount, 1)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        previousCompletion?(SpeechCompletion(text: "late duplicate final", reason: .final, wasExplicitlyStopped: true))
        XCTAssertEqual(fixture.delivery.delivered.count, 1)

        fixture.delivery.completePending()
        try await waitFor("Queued capture did not resume after the prior paste became idle") {
            fixture.capture.startCount == 2 && model.voice.state == "capturing"
        }
        XCTAssertNil(model.queuedVoiceCaptureKind)
        XCTAssertNil(model.queuedVoiceTriggerAt)
        XCTAssertEqual(model.voiceRequestedAt, queuedAt)
        XCTAssertNotEqual(model.dictationCaptureGeneration, previousGeneration)
        XCTAssertEqual(fixture.delivery.delivered, ["keep the previous dictation."])
        XCTAssertEqual(fixture.trace.events, ["capture-start", "paste-attempt", "capture-start"])
        previousCompletion?(SpeechCompletion(text: "another late old final", reason: .final, wasExplicitlyStopped: true))
        XCTAssertEqual(fixture.delivery.delivered.count, 1)
    }

    @MainActor
    func testExplicitTimedOutPartialPastesBeforeQueuedCaptureDespiteTransientIdle() async throws {
        let fixture = try await fixture(), model = fixture.model
        try await finishOldCapture(fixture)
        let previousGeneration = model.dictationCaptureGeneration
        tap(model, at: 15)
        fixture.capture.onCompletion?(SpeechCompletion(text: "keep the explicitly stopped partial",
                                                       reason: .timedOut, wasExplicitlyStopped: true))
        // Accepting a stopped partial briefly publishes idle while acknowledging
        // the incomplete state. It must still belong to the old capture until
        // its onIncomplete handler has admitted the one paste operation.
        XCTAssertEqual(model.dictationDeliveryStartedFor, previousGeneration)
        XCTAssertEqual(model.dictationCaptureGeneration, previousGeneration)
        XCTAssertFalse(model.voiceCaptureRequested)
        try await waitFor("Explicit stopped partial was preempted before its paste") { fixture.delivery.hasPending }
        XCTAssertEqual(fixture.delivery.delivered, ["keep the explicitly stopped partial."])
        XCTAssertEqual(fixture.capture.startCount, 1)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        fixture.delivery.completePending()
        try await waitFor("Queue did not resume after the stopped partial's paste") {
            fixture.capture.startCount == 2 && model.voice.state == "capturing"
        }
        XCTAssertEqual(fixture.trace.events, ["capture-start", "paste-attempt", "capture-start"])
        XCTAssertNil(model.queuedVoiceCaptureKind)
    }

    @MainActor
    func testNextTapCancelsOnlyQueuedStartAndKeepsOldFinalDelivery() async throws {
        let fixture = try await fixture(), model = fixture.model
        try await finishOldCapture(fixture)
        let previousGeneration = model.dictationCaptureGeneration
        tap(model, at: 30)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        tap(model, at: 31) // A later single tap, outside the promotion interval.
        XCTAssertNil(model.queuedVoiceCaptureKind)
        XCTAssertNil(model.queuedVoiceTriggerAt)
        XCTAssertEqual(model.voice.state, "finishing")
        XCTAssertEqual(model.dictationCaptureGeneration, previousGeneration)
        XCTAssertEqual(fixture.capture.stopCount, 1)
        fixture.capture.emitFinal("the old final still belongs here")
        try await waitFor("Cancelling only the queued start lost the old final") { fixture.delivery.hasPending }
        fixture.delivery.completePending()
        await model.voiceActionTask?.value
        model.resumeQueuedVoiceCaptureIfReady()
        XCTAssertEqual(fixture.delivery.delivered, ["the old final still belongs here."])
        XCTAssertEqual(fixture.capture.startCount, 1)
        XCTAssertFalse(model.voiceIsRecording)
    }

    @MainActor
    func testEscapeClearsQueueBeforeCancellationStateCanResumeIt() async throws {
        let fixture = try await fixture(), model = fixture.model
        try await finishOldCapture(fixture)
        let previousCompletion = fixture.capture.onCompletion
        tap(model, at: 40)
        XCTAssertNotNil(model.queuedVoiceCaptureKind)
        model.cancelVoiceInputFromEscape()
        XCTAssertNil(model.queuedVoiceCaptureKind)
        XCTAssertNil(model.queuedVoiceTriggerAt)
        XCTAssertFalse(model.voiceCaptureRequested)
        XCTAssertFalse(model.hasCancellableVoiceInput)
        previousCompletion?(SpeechCompletion(text: "cancelled old final", reason: .final, wasExplicitlyStopped: true))
        model.resumeQueuedVoiceCaptureIfReady(afterCommand: true)
        await model.voiceStartTask?.value
        XCTAssertEqual(fixture.capture.startCount, 1)
        XCTAssertTrue(fixture.delivery.delivered.isEmpty)
        XCTAssertFalse(model.voiceIsRecording)
    }

    @MainActor
    func testHoldChordCancellationClearsQueuedStartWithoutLateCapture() async throws {
        let fixture = try await fixture(), model = fixture.model
        model.settings.voiceTriggerMode = .hold
        model.manualCleanupInProgress = true
        model.handleVoiceGesture(.pressed, at: 50)
        model.handleVoiceGesture(.holdThreshold, at: 50.2)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        model.handleVoiceGesture(.cancelled, at: 50.3)
        XCTAssertNil(model.queuedVoiceCaptureKind)
        XCTAssertNil(model.queuedVoiceTriggerAt)
        model.manualCleanupInProgress = false
        model.resumeQueuedVoiceCaptureIfReady()
        await model.voiceStartTask?.value
        XCTAssertEqual(fixture.capture.startCount, 0)
        XCTAssertFalse(model.voiceCaptureRequested)
        XCTAssertTrue(fixture.delivery.delivered.isEmpty)
    }

    @MainActor
    func testManualCleanupResumesQueuedCaptureOnlyAfterActivityPublishesCompletion() async throws {
        let fixture = try await fixture(), model = fixture.model
        model.manualCleanupInProgress = true
        tap(model, at: 60)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        model.resumeQueuedVoiceCaptureIfReady()
        XCTAssertFalse(model.voiceCaptureRequested)
        XCTAssertEqual(fixture.capture.startCount, 0)
        model.manualCleanupInProgress = false
        model.onActivityChanged?()
        XCTAssertTrue(model.voiceCaptureRequested)
        try await waitFor("Manual completion did not resume queued capture") { fixture.capture.startCount == 1 }
        XCTAssertNil(model.queuedVoiceCaptureKind)
    }

    @MainActor
    func testTapDuringCleanupAndHeldPasteWaitsForBothBoundaries() async throws {
        let fixture = try await fixture(), model = fixture.model
        fixture.cleanup.hold = true
        try await finishOldCapture(fixture)
        fixture.capture.emitFinal("wait until the old work finishes")
        try await waitFor("Synthetic cleanup did not suspend") { fixture.cleanup.hasPending }
        tap(model, at: 70)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        XCTAssertEqual(fixture.capture.startCount, 1)
        model.resumeQueuedVoiceCaptureIfReady(afterCommand: true)
        XCTAssertFalse(model.voiceCaptureRequested)
        fixture.cleanup.completePending()
        try await waitFor("Synthetic paste did not suspend after cleanup") { fixture.delivery.hasPending }
        XCTAssertEqual(fixture.capture.startCount, 1)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        fixture.delivery.completePending()
        try await waitFor("Queued capture did not resume after cleanup and paste") { fixture.capture.startCount == 2 }
        XCTAssertNil(model.queuedVoiceCaptureKind)
        XCTAssertEqual(fixture.delivery.delivered, ["wait until the old work finishes."])
    }

    @MainActor
    func testQueuedHoldChordCancelsOnlyNextRequestWhilePreviousResultAndPasteSurvive() async throws {
        // Cover both pending recognition and an already-dispatched held paste.
        for cancelDuringPaste in [false, true] {
            let fixture = try await fixture(), model = fixture.model
            model.settings.voiceTriggerMode = .hold
            try await finishOldCapture(fixture)
            let previousGeneration = model.dictationCaptureGeneration
            if cancelDuringPaste {
                fixture.capture.emitFinal("preserve the previous result")
                try await waitFor("Old paste did not reach its synthetic boundary") { fixture.delivery.hasPending }
            }
            model.handleVoiceGesture(.pressed, at: 90)
            model.handleVoiceGesture(.holdThreshold, at: 90.2)
            XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
            let cleanupCancellations = fixture.cleanup.cancelCount
            let deliveryCancellations = fixture.delivery.cancelCount
            model.handleVoiceGesture(.cancelled, at: 90.3)
            XCTAssertNil(model.queuedVoiceCaptureKind)
            XCTAssertNil(model.queuedVoiceTriggerAt)
            XCTAssertEqual(model.dictationCaptureGeneration, previousGeneration)
            XCTAssertEqual(fixture.cleanup.cancelCount, cleanupCancellations)
            XCTAssertEqual(fixture.delivery.cancelCount, deliveryCancellations)
            XCTAssertEqual(fixture.capture.stopCount, 1)
            if !cancelDuringPaste {
                XCTAssertEqual(model.voice.state, "finishing")
                fixture.capture.emitFinal("preserve the previous result")
                try await waitFor("Chord cancellation discarded the old final") { fixture.delivery.hasPending }
            }
            XCTAssertEqual(fixture.delivery.delivered, ["preserve the previous result."])
            fixture.delivery.completePending()
            await model.voiceActionTask?.value
            model.resumeQueuedVoiceCaptureIfReady()
            XCTAssertEqual(fixture.capture.startCount, 1)
            XCTAssertFalse(model.voiceIsRecording)
            XCTAssertEqual(fixture.delivery.delivered, ["preserve the previous result."])
            XCTAssertEqual(fixture.trace.events, ["capture-start", "paste-attempt"])
        }
    }

    @MainActor
    func testManualCompletionAdmitsCleanupAndPasteBeforeActivityCanStartQueuedCapture() async throws {
        let fixture = try await fixture(), model = fixture.model
        model.captureMode = .dictation
        fixture.cleanup.hold = true
        // Queue through the public gesture while the previous manual result is
        // blocked, then model the recognizer clearing its busy flag immediately
        // before invoking the completion callback. No microphone is involved.
        model.manualCleanupInProgress = true
        tap(model, at: 110)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        model.manualCleanupInProgress = false
        model.receiveManualSpeechCompletion(SpeechCompletion(text: "finish the manual dictation first",
                                                              reason: .final, wasExplicitlyStopped: true))
        XCTAssertTrue(model.manualCleanupInProgress)
        XCTAssertFalse(model.voiceCaptureRequested)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        XCTAssertEqual(fixture.capture.startCount, 0)
        try await waitFor("Manual result did not admit its cleanup") { fixture.cleanup.hasPending }
        XCTAssertEqual(fixture.cleanup.inputs, ["finish the manual dictation first"])
        model.onActivityChanged?()
        XCTAssertFalse(model.voiceCaptureRequested)
        fixture.cleanup.completePending()
        try await waitFor("Manual result did not admit its paste") { fixture.delivery.hasPending }
        XCTAssertEqual(fixture.delivery.delivered, ["finish the manual dictation first."])
        XCTAssertEqual(fixture.capture.startCount, 0)
        model.onActivityChanged?()
        XCTAssertFalse(model.voiceCaptureRequested)
        fixture.delivery.completePending()
        try await waitFor("Queued capture did not start after manual paste") {
            fixture.capture.startCount == 1 && model.voice.state == "capturing"
        }
        XCTAssertFalse(model.manualCleanupInProgress)
        XCTAssertNil(model.queuedVoiceCaptureKind)
        XCTAssertEqual(fixture.delivery.delivered, ["finish the manual dictation first."])
        XCTAssertEqual(fixture.trace.events, ["paste-attempt", "capture-start"])
    }

    @MainActor
    func testUnsupportedCleanupLocaleStillBlocksQueuedCaptureUntilManualPasteFinishes() async throws {
        let fixture = try await fixture(), model = fixture.model
        model.settings.speechLocale = "fr-FR"
        model.captureMode = .dictation
        fixture.cleanup.hold = true // Any accidental cleanup call would suspend.
        model.manualCleanupInProgress = true
        tap(model, at: 120)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        model.manualCleanupInProgress = false
        model.receiveManualSpeechCompletion(SpeechCompletion(text: "bonjour tout le monde",
                                                              reason: .final, wasExplicitlyStopped: true))
        // The manual blocker owns the whole result even when S1 is unsupported.
        XCTAssertTrue(model.manualCleanupInProgress)
        XCTAssertFalse(model.voiceCaptureRequested)
        try await waitFor("Unsupported-locale manual result did not dispatch its paste") { fixture.delivery.hasPending }
        XCTAssertTrue(fixture.cleanup.inputs.isEmpty)
        XCTAssertFalse(fixture.cleanup.hasPending)
        XCTAssertEqual(fixture.delivery.delivered, ["bonjour tout le monde"])
        XCTAssertEqual(fixture.capture.startCount, 0)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        model.onActivityChanged?()
        model.resumeQueuedVoiceCaptureIfReady(afterCommand: true)
        XCTAssertFalse(model.voiceCaptureRequested)
        fixture.delivery.completePending()
        try await waitFor("Queued capture did not start after unsupported-locale manual paste") {
            fixture.capture.startCount == 1 && model.voice.state == "capturing"
        }
        XCTAssertFalse(model.manualCleanupInProgress)
        XCTAssertNil(model.queuedVoiceCaptureKind)
        XCTAssertTrue(fixture.cleanup.inputs.isEmpty)
        XCTAssertEqual(fixture.delivery.delivered, ["bonjour tout le monde"])
        XCTAssertEqual(fixture.trace.events, ["paste-attempt", "capture-start"])
    }

    @MainActor
    func testIdleFirstTapStillRequestsCaptureSynchronously() async throws {
        let fixture = try await fixture(), model = fixture.model
        tap(model, at: 80)
        XCTAssertTrue(model.voiceCaptureRequested)
        XCTAssertNil(model.queuedVoiceCaptureKind)
        XCTAssertEqual(model.voiceInputKind, .dictation)
        try await waitFor("Idle first tap did not start its capture") { fixture.capture.startCount == 1 }
        XCTAssertTrue(fixture.delivery.delivered.isEmpty)
    }
}

private enum QueuedVoiceWaitFailure: Error { case conditionNotReached }

@MainActor
private struct QueuedVoiceFixture {
    let model: AppModel
    let capture: QueuedVoiceFakeCapture
    let cleanup: QueuedVoiceFakeCleanup
    let delivery: QueuedVoiceFakeDelivery
    let trace: QueuedVoiceTrace
}

@MainActor
private final class QueuedVoiceTrace { var events: [String] = [] }

@MainActor
private final class QueuedVoiceFakeCapture: TriggeredVoiceCapture {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onCompletion: ((SpeechCompletion) -> Void)?
    var onError: ((String) -> Void)?
    var onRecovery: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onFinalization: ((Double) -> Void)?
    var onStart: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func requestAuthorization() async -> Bool { true }
    func start(locale: String, contextualStrings: [String]) async throws {
        try Task.checkCancellation()
        startCount += 1; onStart?()
    }
    func stop() { stopCount += 1 }
    func cancel() {}
    func emitFinal(_ text: String) {
        onCompletion?(SpeechCompletion(text: text, reason: .final, wasExplicitlyStopped: true))
    }
}

@MainActor
private final class QueuedVoiceFakeCleanup: DictationCleaning {
    var hold = false
    private(set) var inputs: [String] = []
    private(set) var cancelCount = 0
    private var pending: (String, CheckedContinuation<String, Error>)?
    var hasPending: Bool { pending != nil }
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String {
        inputs.append(text)
        if hold { return try await withCheckedThrowingContinuation { pending = (text, $0) } }
        return DictationPunctuation.finalize(text)
    }
    func completePending() {
        let work = pending; pending = nil
        if let (text, continuation) = work { continuation.resume(returning: DictationPunctuation.finalize(text)) }
    }
    func cancel() {
        cancelCount += 1
        let work = pending; pending = nil
        work?.1.resume(throwing: CancellationError())
    }
    func release() { cancel() }
}

@MainActor
private final class QueuedVoiceFakeDelivery: TextDelivering {
    var onDeliver: (() -> Void)?
    private(set) var delivered: [String] = []
    private(set) var cancelCount = 0
    private var pending: CheckedContinuation<DeliveryResult, Never>?
    var hasPending: Bool { pending != nil }
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        delivered.append(text); onDeliver?()
        return await withCheckedContinuation { pending = $0 }
    }
    func completePending() {
        let work = pending; pending = nil; work?.resume(returning: .pasteSent)
    }
    func cancel() {
        cancelCount += 1
        let work = pending; pending = nil
        work?.resume(returning: .held("Synthetic delivery cancelled"))
    }
}
