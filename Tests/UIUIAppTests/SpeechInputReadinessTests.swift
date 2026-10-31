import Foundation
import XCTest
@testable import UIUI

final class SpeechInputReadinessTests: XCTestCase {
    func testFirstAudioCanArriveBeforeWaiter() async throws {
        let readiness = SpeechInputReadiness()
        readiness.receivedAudio()

        try await readiness.wait(timeout: .milliseconds(20))
    }

    @MainActor
    func testCaptureRemainsPreparingUntilFirstAudioArrives() async throws {
        let waiting = expectation(description: "Native start finished and is awaiting input")
        let session = InputReadinessSession(onWait: { waiting.fulfill() })
        let owner = SpeechAudioOwner { _ in session }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        var sounds: [RecordingSound] = []
        speech.onRecordingSound = { sounds.append($0) }
        let startup = Task { try await speech.start(locale: "en-IN", contextualStrings: []) }

        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertTrue(speech.isPreparing)
        XCTAssertTrue(speech.hasActiveSession)
        XCTAssertFalse(speech.isRecording)
        XCTAssertFalse(sounds.contains(.ready))

        session.readiness.receivedAudio()
        try await startup.value

        XCTAssertFalse(speech.isPreparing)
        XCTAssertTrue(speech.isRecording)
        XCTAssertTrue(speech.hasActiveSession)
        XCTAssertEqual(sounds, [.ready])
    }

    @MainActor
    func testCancellingPendingInputEndsPromptlyAndLateAudioCannotStartRecording() async {
        let waiting = expectation(description: "Capture is awaiting first input")
        let ended = expectation(description: "Cancellation ends the readiness wait")
        let session = InputReadinessSession(onWait: { waiting.fulfill() })
        let owner = SpeechAudioOwner { _ in session }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        var sounds: [RecordingSound] = []
        speech.onRecordingSound = { sounds.append($0) }
        let startup = Task {
            defer { ended.fulfill() }
            do {
                try await speech.start(locale: "en-IN", contextualStrings: [])
                XCTFail("Cancelled startup must not succeed")
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected startup error: \(error)")
                return false
            }
        }

        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertTrue(speech.isPreparing)
        XCTAssertFalse(speech.isRecording)
        speech.cancel()
        XCTAssertFalse(speech.isPreparing)
        XCTAssertFalse(speech.hasActiveSession)
        XCTAssertFalse(speech.isRecording)

        // The fake's normal readiness deadline is three seconds. Cancellation
        // must release it through the owner queue, without waiting for audio.
        await fulfillment(of: [ended], timeout: 0.5)
        let wasCancelled = await startup.value
        XCTAssertTrue(wasCancelled)
        session.readiness.receivedAudio()
        session.readiness.receivedAudio()
        XCTAssertFalse(speech.isPreparing)
        XCTAssertFalse(speech.isRecording)
        XCTAssertFalse(speech.hasActiveSession)
        XCTAssertFalse(sounds.contains(.ready))
        XCTAssertEqual(speech.stateDescription, "Ready")
    }

    func testMissingAudioTimesOutWithActionableMicrophoneError() async {
        let readiness = SpeechInputReadiness()
        do {
            try await readiness.wait(timeout: .milliseconds(20))
            XCTFail("Startup without input must time out")
        } catch {
            XCTAssertFalse(error is CancellationError)
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(message.contains("microphone"))
            XCTAssertTrue(message.contains("connection"))
            XCTAssertTrue(message.contains("try again"))
        }
    }

    @MainActor
    func testInputFailureAfterFirstAudioReportsFailureInsteadOfCancellation() async {
        let owner = SpeechAudioOwner { configuration in
            FailedInputReadinessSession(onRecognition: configuration.onRecognition)
        }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        var sounds: [RecordingSound] = []
        speech.onRecordingSound = { sounds.append($0) }

        do {
            try await speech.start(locale: "en-IN", contextualStrings: [])
            XCTFail("Input failure during startup must not start recording")
        } catch {
            XCTAssertFalse(error is CancellationError, "Incomplete audio is a microphone failure, not user cancellation")
            XCTAssertEqual(speech.stateDescription, error.localizedDescription)
        }

        let message = speech.stateDescription.lowercased()
        XCTAssertNotEqual(speech.stateDescription, "Ready")
        XCTAssertTrue(message.contains("microphone"))
        XCTAssertTrue(message.contains("check") || message.contains("try again"))
        XCTAssertFalse(speech.isPreparing)
        XCTAssertFalse(speech.isRecording)
        XCTAssertFalse(speech.hasActiveSession)
        XCTAssertFalse(sounds.contains(.ready))
    }

    func testRepeatedAudioAndCancelSignalsPreserveFirstReadyResult() async throws {
        let waiting = expectation(description: "Readiness waiter entered")
        let readiness = SpeechInputReadiness()
        let waiter = Task {
            waiting.fulfill()
            try await readiness.wait()
        }
        await fulfillment(of: [waiting], timeout: 2)

        readiness.receivedAudio()
        readiness.receivedAudio()
        readiness.cancel()
        readiness.cancel()
        try await waiter.value
        // The stored result also has to stay ready for a later observer.
        try await readiness.wait(timeout: .milliseconds(20))
    }

    func testRepeatedCancelAndLateAudioPreserveFirstCancelledResult() async {
        let readiness = SpeechInputReadiness()
        readiness.cancel()
        readiness.cancel()
        readiness.receivedAudio()
        readiness.receivedAudio()

        for _ in 0..<2 {
            do {
                try await readiness.wait(timeout: .milliseconds(20))
                XCTFail("Late audio must not replace cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected readiness error: \(error)")
            }
        }
    }
}

/// Synthetic input readiness only; never constructs audio hardware or a model.
private final class InputReadinessSession: SpeechAudioSession, @unchecked Sendable {
    let readiness = SpeechInputReadiness()
    private let onWait: () -> Void

    init(onWait: @escaping () -> Void) { self.onWait = onWait }
    func start(lease: SpeechAudioLease) throws {}
    func waitForInputReady(lease: SpeechAudioLease) async throws {
        onWait()
        try await readiness.wait()
    }
    func stopAudio() {}
    func finishRecognition() {}
    func cancel() { readiness.cancel() }
}

/// Reproduces a pipeline failing after PCM readiness but before startup returns.
private final class FailedInputReadinessSession: SpeechAudioSession, @unchecked Sendable {
    private let readiness = SpeechInputReadiness()
    private let onRecognition: (SpeechRecognitionEvent) -> Void

    init(onRecognition: @escaping (SpeechRecognitionEvent) -> Void) {
        self.onRecognition = onRecognition
    }
    func start(lease: SpeechAudioLease) throws {}
    func waitForInputReady(lease: SpeechAudioLease) async throws {
        readiness.receivedAudio()
        lease.markIncomplete()
        onRecognition(.init(text: nil, isFinal: false, failed: true, incomplete: true))
        try await readiness.wait()
    }
    func stopAudio() {}
    func finishRecognition() {}
    func cancel() { readiness.cancel() }
}
