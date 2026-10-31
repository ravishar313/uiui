import Foundation
import XCTest
@testable import UIUI

final class SpeechCaptureCompletionLifetimeTests: XCTestCase {
    @MainActor
    func testBlockedTeardownKeepsSessionActiveThroughTerminalCallbackThenEndsOnce() async throws {
        let teardownEntered = expectation(description: "Synthetic terminal teardown entered")
        let teardownGate = DispatchSemaphore(value: 0)
        let session = CompletionLifetimeSession(teardownGate: teardownGate, onCancel: { teardownEntered.fulfill() })
        let harness = CompletionLifetimeHarness(sessions: [session])
        let owner = SpeechAudioOwner { harness.makeSession(configuration: $0) }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { teardownGate.signal(); speech.cancel() }
        let ended = expectation(description: "Terminal callback finished before session ended")
        var order: [String] = []
        var completions: [SpeechCompletion] = []
        speech.onCompletion = { [weak speech] completion in
            guard let speech else { return XCTFail("Capture disappeared during completion") }
            XCTAssertTrue(speech.hasActiveSession, "The admitted result still owns the session while its callback runs")
            XCTAssertTrue(speech.isFinalizing)
            XCTAssertFalse(speech.isRecording)
            completions.append(completion)
            order.append("completion")
        }
        speech.onSessionEnded = { [weak speech] in
            guard let speech else { return XCTFail("Capture disappeared before session ended") }
            XCTAssertFalse(speech.hasActiveSession)
            XCTAssertFalse(speech.isFinalizing)
            order.append("ended")
            ended.fulfill()
        }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        speech.stop()
        harness.emit(.init(text: "synthetic final words", isFinal: true, failed: false, fullSnapshot: true))
        await fulfillment(of: [teardownEntered], timeout: 2)
        XCTAssertTrue(speech.hasActiveSession, "A queued capture must wait until old teardown and result admission finish")
        XCTAssertTrue(speech.isFinalizing)
        XCTAssertFalse(speech.isRecording)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertTrue(order.isEmpty)

        teardownGate.signal()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(completions, [.init(text: "synthetic final words", reason: .final, wasExplicitlyStopped: true)])
        XCTAssertEqual(order, ["completion", "ended"])
        XCTAssertFalse(speech.hasActiveSession)
        XCTAssertFalse(speech.isFinalizing)
        XCTAssertFalse(session.teardownTimedOut)
        // Draining the owner again must not publish another end notification.
        await owner.cancelAndWait(try XCTUnwrap(session.startedLease))
        XCTAssertEqual(order, ["completion", "ended"])
    }

    @MainActor
    func testCancellationDuringPendingTerminalTeardownCannotReviveOldCallbackOrEndNewSession() async throws {
        let teardownEntered = expectation(description: "Old terminal teardown entered")
        let teardownGate = DispatchSemaphore(value: 0)
        let oldSession = CompletionLifetimeSession(teardownGate: teardownGate, onCancel: { teardownEntered.fulfill() })
        let newSession = CompletionLifetimeSession()
        let harness = CompletionLifetimeHarness(sessions: [oldSession, newSession])
        let owner = SpeechAudioOwner { harness.makeSession(configuration: $0) }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { teardownGate.signal(); speech.cancel() }
        let newSessionEnded = expectation(description: "Only the new result ends a completed session")
        var completions: [SpeechCompletion] = []
        var endedCount = 0
        speech.onCompletion = { completions.append($0) }
        speech.onSessionEnded = {
            endedCount += 1
            newSessionEnded.fulfill()
        }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        speech.stop()
        harness.emit(.init(text: "cancelled old result", isFinal: true, failed: false, fullSnapshot: true), session: 0)
        await fulfillment(of: [teardownEntered], timeout: 2)
        XCTAssertTrue(speech.hasActiveSession)
        XCTAssertTrue(speech.isFinalizing)
        speech.cancel()
        XCTAssertFalse(speech.hasActiveSession)
        XCTAssertFalse(speech.isFinalizing)
        teardownGate.signal()

        // Starting a new fake session also passes the old owner's teardown barrier.
        // A stale completion task must neither publish its result nor clear the new session.
        try await speech.start(locale: "en-IN", contextualStrings: [])
        harness.emit(.init(text: "late old result", isFinal: true, failed: false, fullSnapshot: true), session: 0)
        harness.emit(.init(text: "new session words", isFinal: false, failed: false, fullSnapshot: true), session: 1)
        try await waitUntil { speech.transcript == "new session words" }
        XCTAssertTrue(speech.hasActiveSession)
        XCTAssertTrue(speech.isRecording)
        XCTAssertFalse(speech.isFinalizing)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(endedCount, 0)
        speech.stop()
        harness.emit(.init(text: "new session words", isFinal: true, failed: false, fullSnapshot: true), session: 1)
        await fulfillment(of: [newSessionEnded], timeout: 2)
        XCTAssertEqual(completions, [.init(text: "new session words", reason: .final, wasExplicitlyStopped: true)])
        XCTAssertEqual(endedCount, 1)
        XCTAssertFalse(speech.hasActiveSession)
        XCTAssertFalse(speech.isFinalizing)
        XCTAssertFalse(oldSession.teardownTimedOut)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Synthetic session did not publish its partial result")
                throw CompletionLifetimeFailure.deadline
            }
            await Task.yield()
        }
    }
}

private enum CompletionLifetimeFailure: Error { case deadline }

private final class CompletionLifetimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let sessions: [CompletionLifetimeSession]
    private var callbacks: [(SpeechRecognitionEvent) -> Void] = []

    init(sessions: [CompletionLifetimeSession]) { self.sessions = sessions }
    func makeSession(configuration: SpeechAudioConfiguration) -> CompletionLifetimeSession {
        lock.withLock {
            let session = sessions[callbacks.count]
            callbacks.append(configuration.onRecognition)
            return session
        }
    }
    func emit(_ event: SpeechRecognitionEvent, session: Int = 0) {
        let callback = lock.withLock { callbacks[session] }
        callback(event)
    }
}

/// Blocks only the serial audio queue, modelling slow native teardown without any engine.
private final class CompletionLifetimeSession: SpeechAudioSession, @unchecked Sendable {
    private let lock = NSLock()
    private let teardownGate: DispatchSemaphore?
    private let onCancel: (() -> Void)?
    private var lease: SpeechAudioLease?
    private var timedOut = false
    var startedLease: SpeechAudioLease? { lock.withLock { lease } }
    var teardownTimedOut: Bool { lock.withLock { timedOut } }

    init(teardownGate: DispatchSemaphore? = nil, onCancel: (() -> Void)? = nil) {
        self.teardownGate = teardownGate
        self.onCancel = onCancel
    }
    func start(lease: SpeechAudioLease) throws { lock.withLock { self.lease = lease } }
    func stopAudio() {}
    func finishRecognition() {}
    func cancel() {
        onCancel?()
        if let teardownGate, teardownGate.wait(timeout: .now() + 5) != .success {
            lock.withLock { timedOut = true }
        }
    }
}
