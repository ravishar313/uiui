import Foundation
import XCTest
import UIUICore
@testable import UIUI

final class SpeechStartupEventBufferTests: XCTestCase {
    func testTextlessErrorKeepsHypothesisTimingAndTaskEpochTogether() {
        var buffer = SpeechStartupEventBuffer()
        let segment = TranscriptSegment(timestamp: 12, duration: 0.5, range: NSRange(location: 0, length: 5))
        buffer.append(SpeechRecognitionEvent(text: "draft", isFinal: false, failed: false, segments: [segment], recognitionEpoch: 7))
        buffer.append(SpeechRecognitionEvent(text: nil, isFinal: false, failed: true))
        XCTAssertEqual(buffer.take(), SpeechRecognitionEvent(text: "draft", isFinal: false, failed: true, segments: [segment], recognitionEpoch: 7))
    }
    func testTextlessStartupErrorPreservesLatestPartialForRecovery() {
        var buffer = SpeechStartupEventBuffer()
        buffer.append(SpeechRecognitionEvent(text: "remember the first", isFinal: false, failed: false))
        buffer.append(SpeechRecognitionEvent(text: "remember the latest draft", isFinal: false, failed: false))
        buffer.append(SpeechRecognitionEvent(text: nil, isFinal: false, failed: true))
        XCTAssertEqual(buffer.take(), SpeechRecognitionEvent(text: "remember the latest draft", isFinal: false, failed: true))
        XCTAssertNil(buffer.take())
    }

    func testLatePartialCannotEraseStartupFailure() {
        var buffer = SpeechStartupEventBuffer()
        buffer.append(SpeechRecognitionEvent(text: nil, isFinal: false, failed: true))
        buffer.append(SpeechRecognitionEvent(text: "late buffered words", isFinal: false, failed: false))
        XCTAssertEqual(buffer.take(), SpeechRecognitionEvent(text: "late buffered words", isFinal: false, failed: true))
    }

    func testConfirmedFinalTakesPrecedenceAndCannotBeOverwritten() {
        var buffer = SpeechStartupEventBuffer()
        buffer.append(SpeechRecognitionEvent(text: "partial", isFinal: false, failed: true))
        buffer.append(SpeechRecognitionEvent(text: "confirmed final", isFinal: true, failed: false))
        XCTAssertFalse(buffer.append(SpeechRecognitionEvent(text: "late partial", isFinal: false, failed: false)))
        XCTAssertFalse(buffer.append(SpeechRecognitionEvent(text: nil, isFinal: false, failed: true)))
        let event = buffer.take()
        XCTAssertEqual(event?.text, "confirmed final")
        XCTAssertEqual(event?.isFinal, true)
    }
}

final class SpeechAudioOwnerTests: XCTestCase {
    @MainActor
    func testFrozenStartupFinalCannotBeOverwrittenByLatePartial() async throws {
        let harness = SyntheticRecognitionHarness()
        let entered = expectation(description: "Fake startup reached driver stage")
        let gate = DispatchSemaphore(value: 0)
        let session = FakeAudioSession(startGate: gate, onStart: { entered.fulfill() })
        let owner = SpeechAudioOwner { configuration in
            harness.connect(configuration.onRecognition)
            return session
        }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel(); gate.signal() }
        var completions: [SpeechCompletion] = []
        speech.onCompletion = { completions.append($0) }
        let startup = Task { try await speech.start(locale: "en-IN", contextualStrings: []) }
        await fulfillment(of: [entered], timeout: 2)
        harness.emit(SpeechRecognitionEvent(text: "the confirmed words", isFinal: true, failed: false))
        try await waitUntil { speech.transcript == "the confirmed words" }
        harness.emit(SpeechRecognitionEvent(text: "late replacement", isFinal: false, failed: false))
        // A sentinel is delivered on MainActor after the late event's task.
        for _ in 0..<20 { await Task.yield() }
        gate.signal()
        try await startup.value
        try await waitUntil { completions.count == 1 }
        XCTAssertEqual(completions.first?.text, "the confirmed words")
        XCTAssertEqual(completions.first?.reason, .final)
        XCTAssertFalse(speech.hasActiveSession)
    }

    @MainActor
    func testUnalignedFinalRetainsFullTranscriptForRecoveryWithoutDispatchingCommand() async throws {
        for zeroTiming in [false, true] {
            let harness = SyntheticRecognitionHarness()
            let session = FakeAudioSession()
            let owner = SpeechAudioOwner { configuration in
                harness.connect(configuration.onRecognition)
                return session
            }
            let speech = SpeechCapture(audioOwner: owner, authorization: { true })
            let voice = TriggeredVoice(capture: speech)
            defer { voice.stop() }
            var commands: [String] = []
            var recoveries: [SpeechCompletion] = []
            voice.onCommand = { commands.append($0) }
            voice.onIncomplete = { recoveries.append($0) }
            try await voice.start(locale: "en-IN", contextualStrings: [])
            let words = (0..<180).map { "synthetic\($0)" }
            for start in [0, 60] {
                let window = words[start..<(start + 120)].joined(separator: " ")
                harness.emit(SpeechRecognitionEvent(text: window, isFinal: false, failed: false,
                                                   segments: syntheticSegments(window, start: Double(start) * 0.2)))
                let expected = words[..<(start + 120)].joined(separator: " ")
                try await waitUntil { voice.partialCommand == expected }
            }
            voice.finish()
            let tail = words[160...].joined(separator: " ")
            let timing = zeroTiming ? syntheticSegments(tail, start: 0).map {
                TranscriptSegment(timestamp: 0, duration: 0, range: $0.range)
            } : []
            harness.emit(SpeechRecognitionEvent(text: tail, isFinal: true, failed: false, segments: timing))
            try await waitUntil { recoveries.count == 1 }
            XCTAssertTrue(commands.isEmpty)
            XCTAssertEqual(recoveries.first?.text, words.joined(separator: " "))
            XCTAssertEqual(recoveries.first?.reason, .unreconciledFinal)
            XCTAssertEqual(recoveries.first?.wasExplicitlyStopped, true)
            XCTAssertEqual(voice.state, "incomplete")
            XCTAssertFalse(voice.isRecording)
            XCTAssertFalse(speech.hasActiveSession)
        }
    }

    @MainActor
    func testLongSessionFinalTailReachesTriggeredCommandAsFull480Words() async throws {
        let harness = SyntheticRecognitionHarness()
        let session = FakeAudioSession()
        let owner = SpeechAudioOwner { configuration in
            harness.connect(configuration.onRecognition)
            return session
        }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        let voice = TriggeredVoice(capture: speech)
        defer { voice.stop() }
        var commands: [String] = []
        voice.onCommand = { commands.append($0) }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        let words = (0..<480).map { "synthetic\($0)" }
        for start in stride(from: 0, through: 360, by: 60) {
            let window = words[start..<(start + 120)].joined(separator: " ")
            harness.emit(SpeechRecognitionEvent(text: window, isFinal: false, failed: false,
                                               segments: syntheticSegments(window, start: Double(start) * 0.2)))
            let expected = words[..<(start + 120)].joined(separator: " ")
            try await waitUntil { voice.partialCommand == expected }
        }
        voice.finish()
        let tail = words[460...].joined(separator: " ")
        harness.emit(SpeechRecognitionEvent(text: tail, isFinal: true, failed: false,
                                           segments: syntheticSegments(tail, start: 92)))
        try await waitUntil { commands.count == 1 }
        XCTAssertEqual(commands, [words.joined(separator: " ")])
        XCTAssertEqual(speech.transcript.split(separator: " ").count, 480)
        XCTAssertFalse(speech.isRecording)
        XCTAssertFalse(voice.isRecording)
        XCTAssertFalse(session.usedMainThread)
    }

    private func syntheticSegments(_ text: String, start: Double) -> [TranscriptSegment] {
        let regex = try! NSRegularExpression(pattern: "\\S+")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated().map {
            TranscriptSegment(timestamp: start + Double($0.offset) * 0.2, duration: 0.16, range: $0.element.range)
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else { XCTFail("Synthetic recognition did not reach expected full-session state"); throw SyntheticWait.deadline }
            await Task.yield()
        }
    }
    private enum SyntheticWait: Error { case deadline }

    private var configuration: SpeechAudioConfiguration {
        SpeechAudioConfiguration(locale: "en-IN", vocabulary: [], reportLevels: false,
                                 onRecognition: { _ in }, onLevel: { _ in })
    }

    func testLifecycleOperationsRunOffMainActorInSerialOrder() async throws {
        let session = FakeAudioSession()
        let owner = SpeechAudioOwner { _ in
            session.record("create")
            return session
        }
        let lease = SpeechAudioLease()
        try await owner.start(configuration, lease: lease)
        owner.finishInput(lease)
        XCTAssertFalse(lease.mayStart, "Stop intent immediately closes audio acceptance")
        XCTAssertTrue(lease.isValid, "A stopped request may still deliver final recognition")
        await owner.cancelAndWait(lease)
        XCTAssertEqual(session.events, ["create", "start", "started", "stop", "finish", "cancel"])
        XCTAssertFalse(session.usedMainThread)
    }

    func testCancelledStartupNeverConstructsNativeSession() async {
        let session = FakeAudioSession()
        let owner = SpeechAudioOwner { _ in session.record("create"); return session }
        let lease = SpeechAudioLease()
        owner.cancel(lease)
        do {
            try await owner.start(configuration, lease: lease)
            XCTFail("Cancelled startup must not succeed")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(session.events.isEmpty)
    }

    @MainActor
    func testCancellationDuringBlockedDriverStageKeepsMainActorResponsiveAndCleansUp() async {
        let entered = expectation(description: "Serial owner entered a native startup stage")
        let gate = DispatchSemaphore(value: 0)
        let session = FakeAudioSession(startGate: gate, onStart: { entered.fulfill() })
        let owner = SpeechAudioOwner { _ in session }
        let lease = SpeechAudioLease()
        let configuration = configuration
        let startup = Task { @MainActor in
            do { try await owner.start(configuration, lease: lease); return false }
            catch is CancellationError { return true }
            catch { XCTFail("Unexpected error: \(error)"); return false }
        }
        await fulfillment(of: [entered], timeout: 2)
        // This runs on MainActor while the fake native call is still blocked.
        owner.cancel(lease)
        XCTAssertFalse(lease.mayStart)
        XCTAssertFalse(lease.isValid)
        gate.signal()
        let cancelled = await startup.value
        await owner.cancelAndWait(lease)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(session.events, ["start", "started", "cancel"])
        XCTAssertFalse(session.usedMainThread)
    }

    @MainActor
    func testCancelledAsyncPreparationCannotStartOrCancelNewerLease() async throws {
        let entered = expectation(description: "Asynchronous model preparation suspended")
        let gate = AsyncSpeechPreparationGate(onWait: { entered.fulfill() })
        let first = FakeAudioSession(prepareGate: gate)
        let second = FakeAudioSession()
        var creations = 0
        let owner = SpeechAudioOwner { _ in
            creations += 1
            return creations == 1 ? first : second
        }
        let oldLease = SpeechAudioLease()
        let configuration = configuration
        let oldStart = Task {
            do { try await owner.start(configuration, lease: oldLease); return false }
            catch is CancellationError { return true }
            catch { XCTFail("Unexpected error: \(error)"); return false }
        }
        await fulfillment(of: [entered], timeout: 2)
        owner.cancel(oldLease)
        let newerLease = SpeechAudioLease()
        // This completes while the old preparation is still suspended. A model
        // load must never occupy the serial audio queue or the main actor.
        try await owner.start(configuration, lease: newerLease)
        XCTAssertEqual(second.events, ["start", "started"])
        await gate.resume()
        let wasCancelled = await oldStart.value
        XCTAssertTrue(wasCancelled)
        await owner.cancelAndWait(oldLease)
        XCTAssertFalse(first.events.contains("start"))
        XCTAssertEqual(second.events, ["start", "started"])
        XCTAssertTrue(newerLease.mayStart)
        await owner.cancelAndWait(newerLease)
    }

    func testOldLeaseCleanupCannotCancelNewCapture() async throws {
        let first = FakeAudioSession()
        let second = FakeAudioSession()
        var creations = 0
        let owner = SpeechAudioOwner { _ in
            creations += 1
            return creations == 1 ? first : second
        }
        let oldLease = SpeechAudioLease()
        try await owner.start(configuration, lease: oldLease)
        owner.cancel(oldLease)
        let newLease = SpeechAudioLease()
        try await owner.start(configuration, lease: newLease)
        await owner.cancelAndWait(oldLease)
        XCTAssertEqual(first.events, ["start", "started", "cancel"])
        XCTAssertEqual(second.events, ["start", "started"])
        XCTAssertTrue(newLease.mayStart)
        await owner.cancelAndWait(newLease)
        XCTAssertEqual(second.events, ["start", "started", "cancel"])
    }
}

private final class SyntheticRecognitionHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((SpeechRecognitionEvent) -> Void)?
    func connect(_ callback: @escaping (SpeechRecognitionEvent) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    func emit(_ event: SpeechRecognitionEvent) {
        lock.lock(); let callback = callback; lock.unlock()
        callback?(event)
    }
}

/// Models a potentially slow native call without constructing engines or providers.
private final class FakeAudioSession: SpeechAudioSession, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var mainThread = false
    private let prepareGate: AsyncSpeechPreparationGate?
    private let startGate: DispatchSemaphore?
    private let onStart: (() -> Void)?
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }

    init(startGate: DispatchSemaphore? = nil, onStart: (() -> Void)? = nil, prepareGate: AsyncSpeechPreparationGate? = nil) {
        self.prepareGate = prepareGate
        self.startGate = startGate
        self.onStart = onStart
    }
    func record(_ event: String) {
        lock.lock()
        recorded.append(event)
        mainThread = mainThread || Thread.isMainThread
        lock.unlock()
    }
    func prepare(lease: SpeechAudioLease) async throws {
        if let prepareGate { record("prepare"); await prepareGate.wait() }
    }
    func start(lease: SpeechAudioLease) throws {
        record("start")
        onStart?()
        if let startGate, startGate.wait(timeout: .now() + 2) != .success { throw FakeError.deadline }
        // Simulates a native call which returns only after cancellation has occurred.
        record("started")
    }
    func stopAudio() { record("stop") }
    func finishRecognition() { record("finish") }
    func cancel() { record("cancel") }
    private enum FakeError: Error { case deadline }
}

private actor AsyncSpeechPreparationGate {
    private let onWait: () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    init(onWait: @escaping () -> Void) { self.onWait = onWait }
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onWait()
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
