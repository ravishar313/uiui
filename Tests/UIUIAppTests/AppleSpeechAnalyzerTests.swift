import AVFoundation
import Foundation
import Speech
import XCTest
@testable import UIUI

final class AppleSpeechAnalyzerTests: XCTestCase {
    func testStableHistorySurvivesVolatileRevisionsRetractionsAndRepeatedRanges() {
        var ledger = SpeechRangeTranscriptLedger()
        typealias Piece = SpeechRangeTranscriptLedger.Piece
        XCTAssertEqual(ledger.update(start: 0, end: 2, pieces: [.init(start: 0, end: 2, text: "first words")], isFinal: true), "first words")
        ledger.update(start: 2, end: 6, pieces: [.init(start: 2, end: 6, text: "a mistaken ending")], isFinal: false)
        XCTAssertEqual(ledger.update(start: 2, end: 6, pieces: [.init(start: 2, end: 6, text: "correct middle")], isFinal: false), "first words correct middle")
        XCTAssertEqual(ledger.update(start: 2, end: 6, pieces: [], isFinal: false), "first words")
        let words: [Piece] = [.init(start: 0, end: 2, text: "first words"), .init(start: 2, end: 6, text: "correct middle")]
        XCTAssertEqual(ledger.update(start: 0, end: 6, pieces: words, isFinal: true), "first words correct middle")
        XCTAssertEqual(ledger.update(start: 0, end: 6, pieces: words, isFinal: true), "first words correct middle")
        XCTAssertEqual(ledger.update(start: 6, end: 8, pieces: [.init(start: 6, end: 8, text: "last words")], isFinal: false), "first words correct middle last words")
        // A stale volatile prefix cannot erase or duplicate the committed history.
        XCTAssertEqual(ledger.update(start: 0, end: 6, pieces: [.init(start: 0, end: 6, text: "stale prefix")], isFinal: false), "first words correct middle last words")
    }

    func testPartialFinalizationKeepsUntouchedVolatileSuffixAndSuffixRevisionKeepsPendingPrefix() {
        var state = SpeechAnalyzerTranscriptState()
        let first = state.receive(start: 0, end: 10, pieces: [
            .init(start: 0, end: 2, text: "A"), .init(start: 2, end: 4, text: "B"),
            .init(start: 6, end: 8, text: "C"), .init(start: 8, end: 10, text: "D")
        ], isFinal: false)
        XCTAssertEqual(first.text, "A B C D")
        XCTAssertEqual(state.receive(start: 8, end: 10, pieces: [.init(start: 8, end: 10, text: "revised D")], isFinal: false).text, "A B C revised D")
        XCTAssertEqual(state.receive(start: 0, end: 4, pieces: [.init(start: 0, end: 2, text: "A"), .init(start: 2, end: 4, text: "B")], isFinal: true).text, "A B C revised D")
        XCTAssertEqual(state.completionEvent.text, "A B C revised D", "Finalization must keep suffixes Apple never reissues as final")
        XCTAssertTrue(state.completionEvent.isFinal)
        XCTAssertFalse(state.completionEvent.incomplete)
    }

    func testAttributeRunsKeepOriginalWordBoundariesPunctuationAndNumberFormatting() {
        var ledger = SpeechRangeTranscriptLedger()
        let pieces: [SpeechRangeTranscriptLedger.Piece] = [
            .init(start: 0, end: 1, text: "We"),
            .init(start: 1, end: 2, text: "’re ", joinsPrevious: true),
            .init(start: 2, end: 3, text: "1", joinsPrevious: true),
            .init(start: 3, end: 4, text: ",", joinsPrevious: true),
            .init(start: 4, end: 5, text: "000", joinsPrevious: true),
            .init(start: 5, end: 6, text: " people.", joinsPrevious: true)
        ]
        XCTAssertEqual(ledger.update(start: 0, end: 6, pieces: pieces, isFinal: true), "We’re 1,000 people.")
        XCTAssertEqual(ledger.update(start: 7, end: 8, pieces: [.init(start: 7, end: 8, text: "Next sentence.")], isFinal: true), "We’re 1,000 people. Next sentence.")
    }

    func testIndivisibleOverlapKeepsStableWordsAndMarksIncomplete() {
        var state = SpeechAnalyzerTranscriptState()
        _ = state.receive(start: 0, end: 2, pieces: [.init(start: 0, end: 2, text: "stable prefix")], isFinal: true)
        _ = state.receive(start: 1, end: 3, pieces: [.init(start: 1, end: 3, text: "unsplittable revision")], isFinal: true)
        XCTAssertEqual(state.completionEvent.text, "stable prefix")
        XCTAssertFalse(state.completionEvent.isFinal)
        XCTAssertTrue(state.completionEvent.incomplete)
    }

    @MainActor
    func testSixMinute1500WordSessionKeepsHeadMiddleTailAndStaysListeningAcrossSegmentFinals() async throws {
        let harness = AnalyzerEventHarness()
        let session = AnalyzerFakeSession()
        let owner = SpeechAudioOwner { configuration in harness.connect(configuration.onRecognition); return session }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        var completions: [SpeechCompletion] = []
        speech.onCompletion = { completions.append($0) }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        let words = (0..<1500).map { "word\($0)" }
        var state = SpeechAnalyzerTranscriptState()
        for chunk in 0..<15 {
            let start = chunk * 100
            let end = start + 100
            let text = words[start..<end].joined(separator: " ")
            // Each committed range is separated by silence in audio time. None
            // is a session final; no model, recording, or wall-clock wait is used.
            let event = state.receive(start: Double(chunk) * 30, end: Double(chunk) * 30 + 20,
                                      pieces: [.init(start: Double(chunk) * 30, end: Double(chunk) * 30 + 20, text: text)], isFinal: true)
            XCTAssertFalse(event.isFinal)
            harness.emit(event)
            try await waitUntil { speech.transcript.split(separator: " ").count == end }
            XCTAssertTrue(speech.isRecording)
            XCTAssertTrue(completions.isEmpty)
        }
        speech.stop()
        XCTAssertFalse(speech.isRecording)
        harness.emit(state.completionEvent)
        try await waitUntil { completions.count == 1 }
        harness.emit(state.completionEvent)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].text, words.joined(separator: " "))
        XCTAssertEqual(completions[0].reason, .final)
        XCTAssertTrue(completions[0].wasExplicitlyStopped)
    }

    @MainActor
    func testBufferFailurePreservesSnapshotAsIncompleteAndLateFinalCannotComplete() async throws {
        let harness = AnalyzerEventHarness()
        let owner = SpeechAudioOwner { configuration in harness.connect(configuration.onRecognition); return AnalyzerFakeSession() }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        var completions: [SpeechCompletion] = []
        speech.onCompletion = { completions.append($0) }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        harness.emit(.init(text: "kept first middle and last", isFinal: false, failed: false, fullSnapshot: true))
        try await waitUntil { !speech.transcript.isEmpty }
        speech.stop()
        harness.emit(.init(text: nil, isFinal: false, failed: true, fullSnapshot: true, incomplete: true))
        try await waitUntil { completions.count == 1 }
        harness.emit(.init(text: "late shortened result", isFinal: true, failed: false, fullSnapshot: true))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(completions.map(\.reason), [.unreconciledFinal])
        XCTAssertEqual(completions.first?.text, "kept first middle and last")
        XCTAssertEqual(speech.transcript, "kept first middle and last")
    }

    @MainActor
    func testCancelledCaptureIgnoresLateAnalyzerFinal() async throws {
        let harness = AnalyzerEventHarness()
        let owner = SpeechAudioOwner { configuration in harness.connect(configuration.onRecognition); return AnalyzerFakeSession() }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        var count = 0
        speech.onCompletion = { _ in count += 1 }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        speech.cancel()
        harness.emit(.init(text: "late final", isFinal: true, failed: false, fullSnapshot: true))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(count, 0)
        XCTAssertTrue(speech.transcript.isEmpty)
        XCTAssertFalse(speech.hasActiveSession)
    }

    @MainActor
    func testCompleteSnapshotsCanRetractVolatileWordsWithoutLegacyContractionGuard() async throws {
        let harness = AnalyzerEventHarness()
        let owner = SpeechAudioOwner { configuration in harness.connect(configuration.onRecognition); return AnalyzerFakeSession() }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        var state = SpeechAnalyzerTranscriptState()
        harness.emit(state.receive(start: 0, end: 2, pieces: [.init(start: 0, end: 2, text: "stable first words")], isFinal: true))
        let volatile = (0..<150).map { "pending\($0)" }.joined(separator: " ")
        harness.emit(state.receive(start: 2, end: 100, pieces: [.init(start: 2, end: 100, text: volatile)], isFinal: false))
        try await waitUntil { speech.transcript.split(separator: " ").count == 153 }
        harness.emit(state.receive(start: 2, end: 100, pieces: [], isFinal: false))
        try await waitUntil { speech.transcript == "stable first words" }
        XCTAssertTrue(speech.isRecording)
    }

    @MainActor
    func testModernFinalizationTimeoutRequiresReview() async throws {
        let harness = AnalyzerEventHarness()
        let session = AnalyzerFakeSession(engineStatus: .init(description: "Synthetic long-form", warning: nil,
                                                              finalizationWaitMilliseconds: 1, requiresCompleteFinalization: true))
        let owner = SpeechAudioOwner { configuration in harness.connect(configuration.onRecognition); return session }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        var completions: [SpeechCompletion] = []
        speech.onCompletion = { completions.append($0) }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        harness.emit(.init(text: "unconfirmed full draft", isFinal: false, failed: false, fullSnapshot: true))
        try await waitUntil { !speech.transcript.isEmpty }
        speech.stop()
        try await waitUntil { completions.count == 1 }
        XCTAssertEqual(completions.first?.reason, .unreconciledFinal)
        XCTAssertEqual(completions.first?.text, "unconfirmed full draft")
    }

    @MainActor
    func testAudioFailureReceiptPreventsRacingFinalFromBeingAccepted() async throws {
        let harness = AnalyzerEventHarness()
        let session = AnalyzerFakeSession()
        let owner = SpeechAudioOwner { configuration in harness.connect(configuration.onRecognition); return session }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        var completions: [SpeechCompletion] = []
        speech.onCompletion = { completions.append($0) }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        speech.stop()
        let lease = try XCTUnwrap(session.startedLease)
        lease.markIncomplete()
        // Simulates a final callback racing ahead of the failure callback on MainActor.
        harness.emit(.init(text: "full retained draft", isFinal: true, failed: false, fullSnapshot: true))
        try await waitUntil { completions.count == 1 }
        XCTAssertEqual(completions.first?.reason, .unreconciledFinal)
    }

    func testClassicFinalBeforeExplicitStopIsIncompleteRatherThanAnImplicitCommand() {
        let lease = SpeechAudioLease()
        let event = SpeechRecognitionEvent.legacy(text: "words before silence", isFinal: true, failed: false, segments: [], lease: lease)
        XCTAssertFalse(event.isFinal)
        XCTAssertTrue(event.failed)
        XCTAssertTrue(event.incomplete)
        XCTAssertTrue(lease.hasIncompleteAudio)
        XCTAssertFalse(lease.mayStart)
        let stopped = SpeechAudioLease()
        stopped.closeInput()
        XCTAssertTrue(SpeechRecognitionEvent.legacy(text: "explicitly stopped words", isFinal: true, failed: false, segments: [], lease: stopped).isFinal)
    }

    func testBoundedAudioQueueOverflowClosesInputAndReportsExactlyOneFailure() throws {
        if #available(macOS 26.0, *) {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
            let converter = try XCTUnwrap(AVAudioConverter(from: format, to: format))
            let (stream, continuation) = AsyncStream<Speech.AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(1))
            _ = stream // Deliberately no consumer: the second buffer must overflow.
            let lease = SpeechAudioLease()
            var failures = 0
            let pump = SpeechAnalyzerAudioPump(converter: converter, outputFormat: format, continuation: continuation,
                                               lease: lease, onFailure: { failures += 1 })
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            buffer.int16ChannelData![0].initialize(repeating: 0, count: 160)
            for _ in 0..<4 { pump.append(buffer) }
            XCTAssertEqual(failures, 1)
            XCTAssertFalse(lease.mayStart)
            XCTAssertTrue(lease.hasIncompleteAudio)
            XCTAssertTrue(lease.isValid, "Keep transcript recovery callbacks available until owner teardown")
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else { throw WaitError.deadline }
            await Task.yield()
        }
    }
    private enum WaitError: Error { case deadline }
}

private final class AnalyzerEventHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((SpeechRecognitionEvent) -> Void)?
    func connect(_ callback: @escaping (SpeechRecognitionEvent) -> Void) { lock.withLock { self.callback = callback } }
    func emit(_ event: SpeechRecognitionEvent) { lock.withLock { callback }?(event) }
}
private final class AnalyzerFakeSession: SpeechAudioSession, @unchecked Sendable {
    let engineStatus: SpeechEngineStatus
    private let lock = NSLock()
    private var lease: SpeechAudioLease?
    var startedLease: SpeechAudioLease? { lock.withLock { lease } }
    init(engineStatus: SpeechEngineStatus = .legacy) { self.engineStatus = engineStatus }
    func start(lease: SpeechAudioLease) throws { lock.withLock { self.lease = lease } }
    func stopAudio() {}
    func finishRecognition() {}
    func cancel() {}
}
