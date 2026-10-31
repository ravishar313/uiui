import Foundation
import XCTest
import UIUICore
@testable import UIUI

final class VoiceGestureIntegrationTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> (AppModel, GestureCapture, GestureDelivery) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-gesture-\(UUID().uuidString)")
        let suite = "uiui-gesture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let capture = GestureCapture()
        let voice = TriggeredVoice(capture: capture)
        let delivery = GestureDelivery()
        let model = AppModel(dataDirectory: root, defaults: defaults,
                             persistSettings: false,
                             delivery: delivery, cleanup: GestureCleanup(), voice: voice)
        // The test has no external editor destination, microphone, speech synthesis,
        // native inference, or installed system services.
        voice.onTrigger = {}
        voice.onRecordingSound = nil
        await model.start(installSystemServices: false)
        model.captureEnabled = true // Admit only this injected capture.
        model.settings.voiceTriggerMode = .toggle
        model.settings.saveDictationHistory = false
        model.voiceGesture = VoiceGestureState()
        addTeardownBlock {
            await MainActor.run { model.shutdown() }
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (model, capture, delivery)
    }

    @MainActor
    private func waitFor(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                         until condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(description, file: file, line: line)
        throw GestureWaitFailure.conditionNotReached
    }

    @MainActor
    func testChangingVisualStylePreservesActiveCaptureAndFinalDelivery() async throws {
        let (model, capture, delivery) = try await fixture()
        model.handleVoiceGesture(.pressed, at: 5)
        model.handleVoiceGesture(.released, at: 5.05)
        try await waitFor("Injected capture did not start") { capture.startCount == 1 }
        capture.resumeStart()
        try await waitFor("Injected capture did not become ready") { model.voice.state == "capturing" }
        capture.onPartial?("Synthetic words remain while the lights change")
        let generation = model.dictationCaptureGeneration
        for style in NotchVisualStyle.allCases {
            model.settings.notchVisualStyle = style
            XCTAssertEqual(model.voice.state, "capturing")
            XCTAssertEqual(model.notchFeedbackPhase, .recording)
            XCTAssertEqual(model.voiceTranscript, "Synthetic words remain while the lights change")
            XCTAssertEqual(model.dictationCaptureGeneration, generation)
            XCTAssertEqual(capture.startCount, 1)
            XCTAssertEqual(capture.stopCount, 0)
        }
        model.handleVoiceGesture(.pressed, at: 6)
        model.handleVoiceGesture(.released, at: 6.05)
        capture.emitFinal("Synthetic words remain while the lights change")
        try await waitFor("Final words were not delivered after style changes") {
            delivery.delivered == ["Synthetic words remain while the lights change"]
        }
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.startCount, 1)
    }

    @MainActor
    func testStyleSwitchDuringCleanupWithShortcutDisabledDoesNotReleaseOrLoseDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-style-cleanup-\(UUID().uuidString)")
        let suite = "uiui-style-cleanup-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let capture = GestureCapture()
        let voice = TriggeredVoice(capture: capture)
        let delivery = GestureDelivery()
        let cleanup = StyleBlockingCleanup()
        let model = AppModel(dataDirectory: root, defaults: defaults, persistSettings: false,
                             delivery: delivery, cleanup: cleanup, voice: voice)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        voice.onTrigger = {}; voice.onRecordingSound = nil
        await model.start(installSystemServices: false)
        model.captureEnabled = true
        var speechChanges = 0
        // This is the application's speech-preference boundary. With Fn off,
        // refreshing warmth releases cleanup; visual settings must never call it.
        model.onSpeechPreferencesChanged = { speechChanges += 1; cleanup.release() }
        model.settings.voiceTriggerEnabled = false
        model.settings.saveDictationHistory = false
        XCTAssertEqual(speechChanges, 1)
        let releasesBeforeCapture = cleanup.releaseCount
        model.beginVoiceCapture()
        try await waitFor("Home-style capture did not start with Fn off") { capture.startCount == 1 }
        capture.resumeStart()
        try await waitFor("Home-style capture did not become ready") { model.voice.state == "capturing" }
        model.finishVoiceCapture()
        capture.emitFinal("Synthetic words survive visual changes")
        try await waitFor("Cleanup did not suspend") { cleanup.isWaiting }
        for style in NotchVisualStyle.allCases {
            model.settings.notchVisualStyle = style
            XCTAssertEqual(speechChanges, 1)
            XCTAssertEqual(cleanup.releaseCount, releasesBeforeCapture)
            XCTAssertEqual(model.notchFeedbackPhase, .processing)
            XCTAssertTrue(delivery.delivered.isEmpty)
        }
        cleanup.complete()
        try await waitFor("Appearance changes lost the pending paste") {
            delivery.delivered == ["Synthetic words survive visual changes"]
        }
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 1)
    }

    @MainActor
    func testEachCapturePassesOnlyCurrentProjectReplacementSpellings() async throws {
        let (model, capture, _) = try await fixture()
        model.settings.vocabulary = [
            VocabularyEntry(heard: "global heard", replacement: "GlobalSpelling", project: "All projects"),
            VocabularyEntry(heard: "personal heard", replacement: "PersonalSpelling", project: "Personal"),
            VocabularyEntry(heard: "research heard", replacement: "ResearchSpelling", project: "Research")
        ]
        model.captureProject = "Personal"
        model.beginVoiceCapture()
        try await waitFor("Personal capture did not enter startup") { capture.startCount == 1 }
        XCTAssertEqual(capture.vocabularySnapshots, [["GlobalSpelling", "PersonalSpelling", "uiui"]])
        model.cancelTriggeredVoice()
        model.captureProject = "Research"
        model.beginVoiceCapture()
        try await waitFor("Research capture did not enter startup") { capture.startCount == 2 }
        XCTAssertEqual(capture.vocabularySnapshots, [["GlobalSpelling", "PersonalSpelling", "uiui"], ["GlobalSpelling", "ResearchSpelling", "uiui"]])
        model.cancelTriggeredVoice()
        model.settings.vocabulary = []
        model.beginVoiceCapture()
        try await waitFor("Empty dictionary capture did not enter startup") { capture.startCount == 3 }
        // The app's own name is always a recognition hint, once.
        XCTAssertEqual(capture.vocabularySnapshots.last, ["uiui"])
        model.cancelTriggeredVoice()
    }

    @MainActor
    func testRapidSecondTapCancelsPendingStartupWithoutOpeningAnotherCapture() async throws {
        let (model, capture, delivery) = try await fixture()
        model.handleVoiceGesture(.pressed, at: 10)
        model.handleVoiceGesture(.released, at: 10.05)
        XCTAssertTrue(model.voiceCaptureRequested, "The first tap must request capture synchronously")
        let captureID = model.dictationCaptureGeneration
        try await waitFor("Injected capture did not enter suspended startup") { capture.startCount == 1 }
        let staleFinal = capture.onCompletion
        XCTAssertEqual(model.voice.state, "starting")

        model.handleVoiceGesture(.pressed, at: 10.10)
        model.handleVoiceGesture(.released, at: 10.15)
        XCTAssertFalse(model.voiceCaptureRequested)
        XCTAssertFalse(model.voiceIsRecording)
        XCTAssertEqual(model.dictationCaptureGeneration, captureID)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 0, "Pending startup is cancelled before audio is ready")
        XCTAssertFalse(capture.hasPendingStartup)
        staleFinal?(SpeechCompletion(text: "status", reason: .final, wasExplicitlyStopped: true))
        XCTAssertTrue(delivery.delivered.isEmpty)
    }

    @MainActor
    func testRapidSecondTapFinishesReadyDictationAndDeliversCommandWordsLiterally() async throws {
        let (model, capture, delivery) = try await fixture()
        model.handleVoiceGesture(.pressed, at: 20)
        model.handleVoiceGesture(.released, at: 20.05)
        try await waitFor("Dictation did not enter startup") { capture.startCount == 1 }
        capture.resumeStart()
        try await waitFor("Dictation did not become ready") { model.voice.state == "capturing" }

        model.handleVoiceGesture(.pressed, at: 20.10)
        model.handleVoiceGesture(.released, at: 20.15)
        XCTAssertFalse(model.voiceIsRecording)
        XCTAssertEqual(model.voice.state, "finishing")
        XCTAssertEqual(capture.stopCount, 1)
        capture.emitFinal("status")
        try await waitFor("Stopped dictation was not delivered") { delivery.delivered == ["status"] }
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 1)
    }

    @MainActor
    func testHoldStartsAtThresholdAndFinishesOnRelease() async throws {
        let (model, capture, delivery) = try await fixture()
        model.settings.voiceTriggerMode = .hold
        model.handleVoiceGesture(.pressed, at: 30)
        XCTAssertFalse(model.voiceCaptureRequested)
        model.handleVoiceGesture(.holdThreshold, at: 30.159)
        XCTAssertFalse(model.voiceCaptureRequested)
        model.handleVoiceGesture(.holdThreshold, at: 30.160)
        XCTAssertTrue(model.voiceCaptureRequested)
        try await waitFor("Held dictation did not enter startup") { capture.startCount == 1 }
        capture.resumeStart()
        try await waitFor("Held dictation did not become ready") { model.voice.state == "capturing" }
        model.handleVoiceGesture(.released, at: 30.2)
        XCTAssertFalse(model.voiceIsRecording)
        XCTAssertEqual(capture.stopCount, 1)
        capture.emitFinal("held words")
        try await waitFor("Held dictation was not delivered") { delivery.delivered == ["held words"] }
    }

    @MainActor
    func testSecondRapidTapCancelsQueuedRequestWithoutStartingMicrophone() async throws {
        let (model, capture, delivery) = try await fixture()
        model.manualCleanupInProgress = true
        model.handleVoiceGesture(.pressed, at: 40)
        model.handleVoiceGesture(.released, at: 40.05)
        XCTAssertEqual(model.queuedVoiceCaptureKind, .dictation)
        XCTAssertFalse(model.voiceCaptureRequested)
        XCTAssertEqual(capture.startCount, 0)
        model.handleVoiceGesture(.pressed, at: 40.10)
        model.handleVoiceGesture(.released, at: 40.15)
        XCTAssertNil(model.queuedVoiceCaptureKind)
        model.manualCleanupInProgress = false
        model.resumeQueuedVoiceCaptureIfReady()
        XCTAssertFalse(model.voiceCaptureRequested)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertTrue(delivery.delivered.isEmpty)
    }

    @MainActor
    func testCancelledHoldCannotFinishOrRestartOnItsStaleRelease() async throws {
        let (model, capture, delivery) = try await fixture()
        model.settings.voiceTriggerMode = .hold
        model.handleVoiceGesture(.pressed, at: 50)
        model.handleVoiceGesture(.holdThreshold, at: 50.160)
        try await waitFor("Held dictation did not enter startup") { capture.startCount == 1 }
        let staleFinal = capture.onCompletion
        model.handleVoiceGesture(.cancelled, at: 50.17)
        model.handleVoiceGesture(.released, at: 50.18)
        XCTAssertFalse(model.voiceCaptureRequested)
        XCTAssertFalse(model.voiceIsRecording)
        XCTAssertFalse(capture.hasPendingStartup)
        staleFinal?(SpeechCompletion(text: "cancelled words", reason: .final, wasExplicitlyStopped: true))
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertTrue(delivery.delivered.isEmpty)
    }

}

private enum GestureWaitFailure: Error { case conditionNotReached }

@MainActor
private final class GestureCapture: TriggeredVoiceCapture {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onCompletion: ((SpeechCompletion) -> Void)?
    var onError: ((String) -> Void)?
    var onRecovery: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onFinalization: ((Double) -> Void)?
    private var startup: CheckedContinuation<Void, Error>?
    var hasPendingStartup: Bool { startup != nil }
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var vocabularySnapshots: [[String]] = []

    func requestAuthorization() async -> Bool { true }
    func start(locale: String, contextualStrings: [String]) async throws {
        startCount += 1
        vocabularySnapshots.append(contextualStrings)
        try await withCheckedThrowingContinuation { startup = $0 }
        try Task.checkCancellation()
    }
    func resumeStart() {
        let pending = startup
        startup = nil
        pending?.resume()
    }
    func stop() { stopCount += 1 }
    func cancel() {
        let pending = startup
        startup = nil
        pending?.resume(throwing: CancellationError())
    }
    func emitFinal(_ text: String) {
        onCompletion?(SpeechCompletion(text: text, reason: .final, wasExplicitlyStopped: true))
    }
}

@MainActor
private final class GestureDelivery: TextDelivering {
    private(set) var delivered: [String] = []
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        delivered.append(text)
        return .pasteSent
    }
    func cancel() {}
}

@MainActor
private final class GestureCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}

@MainActor
private final class StyleBlockingCleanup: DictationCleaning {
    private var pending: CheckedContinuation<String, Error>?
    private var text = ""
    private(set) var releaseCount = 0
    var isWaiting: Bool { pending != nil }
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String {
        self.text = text
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete() { let result = pending; pending = nil; result?.resume(returning: text) }
    func cancel() { let result = pending; pending = nil; result?.resume(throwing: CancellationError()) }
    func release() { releaseCount += 1; cancel() }
}
