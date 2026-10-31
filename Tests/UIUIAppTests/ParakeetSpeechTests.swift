import AVFoundation
import Foundation
import XCTest
@testable import UIUI

final class ParakeetSpeechTests: XCTestCase {
    func testExplicitFinalizationSuppliesValidSilentContextBeforeFlushingShortWords() async throws {
        let model = FinalContextModel()
        let text = try await ParakeetFinalizationContext.finish(
            hasAcceptedAudio: true,
            appendAudio: { try await model.append($0) },
            processBufferedAudio: { await model.process() },
            finish: { await model.finish() })
        let events = await model.events
        let frames = await model.frames
        let maximumSample = await model.maximumSample
        let sampleRate = await model.sampleRate
        let channels = await model.channels
        XCTAssertEqual(text, "Okay.", "A first short result may become available only after valid final context")
        XCTAssertEqual(events, ["append", "process", "finish"])
        XCTAssertEqual(frames, 17_920, "The pinned 1120 ms tier requires one chunk plus its right context")
        XCTAssertEqual(sampleRate, 16_000)
        XCTAssertEqual(channels, 1)
        XCTAssertEqual(maximumSample, 0)
    }

    func testNoAcceptedAudioFinishesWithoutInventingAContextBuffer() async throws {
        let model = FinalContextModel()
        let text = try await ParakeetFinalizationContext.finish(
            hasAcceptedAudio: false,
            appendAudio: { try await model.append($0) },
            processBufferedAudio: { await model.process() },
            finish: { await model.finish() })
        let events = await model.events
        XCTAssertEqual(events, ["finish"])
        XCTAssertEqual(text, "")
    }

    func testFinalContextAppendFailureCannotBecomeASuccessfulFinal() async {
        let model = FinalContextModel(rejectAppend: true)
        do {
            _ = try await ParakeetFinalizationContext.finish(
                hasAcceptedAudio: true,
                appendAudio: { try await model.append($0) },
                processBufferedAudio: { await model.process() },
                finish: { await model.finish() })
            XCTFail("A failed context append must remain a recognition failure")
        } catch FinalContextModel.Failure.rejected {} catch { XCTFail("Unexpected finalization error: \(error)") }
        let events = await model.events
        XCTAssertEqual(events, ["append"])
    }

    func testEveryRequiredCompiledArtifactAndValidJSONAreRequiredBeforeCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [URL] = []
        for name in ParakeetSpeechModel.requiredNames {
            if name.hasSuffix(".mlmodelc") {
                files += ParakeetSpeechModel.requiredBundleFiles.map { root.appendingPathComponent(name).appendingPathComponent($0) }
            } else { files.append(root.appendingPathComponent(name)) }
        }
        for file in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (file.pathExtension == "json" ? Data("{\"fixture\":1}".utf8) : Data([1])).write(to: file)
        }
        let revisionFile = root.appendingPathComponent(".fluidaudio-revision")
        try ParakeetSpeechModel.revision.write(to: revisionFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(ParakeetSpeechModel.isInstalled(at: root))
        try "unrecognized-revision".write(to: revisionFile, atomically: true, encoding: .utf8)
        XCTAssertFalse(ParakeetSpeechModel.isInstalled(at: root), "Capture must use the pinned weights, not an unrelated cached model")
        try ParakeetSpeechModel.revision.write(to: revisionFile, atomically: true, encoding: .utf8)
        for file in files {
            let saved = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            XCTAssertFalse(ParakeetSpeechModel.isInstalled(at: root), "A partial download cannot be advertised as installed")
            try saved.write(to: file)
        }
        try Data("not json".utf8).write(to: root.appendingPathComponent("vocab.json"))
        XCTAssertFalse(ParakeetSpeechModel.isInstalled(at: root))
        XCTAssertTrue(ParakeetSpeechModel.supports(locale: "en_IN"))
        XCTAssertFalse(ParakeetSpeechModel.supports(locale: "hi-IN"))
    }

    @MainActor
    func testContinuousThreeMinuteSessionKeepsAll1800WordsThroughPausesUntilExplicitStop() async throws {
        let words = (0..<1800).map { "word\($0)" }
        var snapshots: [String] = []
        for chunk in 0..<180 {
            snapshots.append(words[..<((chunk + 1) * 10)].joined(separator: " "))
            if chunk % 10 == 9 { snapshots.append(snapshots.last!) } // Silence emits no new words.
        }
        let decoder = FakeParakeetDecoder(snapshots: snapshots)
        let harness = ParakeetSessionHarness(decoder: decoder)
        let owner = SpeechAudioOwner { configuration in harness.makeSession(configuration: configuration) }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        var completions: [SpeechCompletion] = []
        speech.onCompletion = { completions.append($0) }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        let session = try XCTUnwrap(harness.session)
        for (index, snapshot) in snapshots.enumerated() {
            session.append(try pcm(frames: 16_000)) // One second of synthetic PCM, no microphone.
            try await waitUntilAsync { await decoder.appendCount == index + 1 }
            try await waitUntil { speech.transcript == snapshot }
            XCTAssertTrue(speech.isRecording, "Silence and completed decoder chunks must never stop capture")
            XCTAssertTrue(completions.isEmpty)
        }
        let beforeStop = await decoder.finishCount
        XCTAssertEqual(beforeStop, 0)
        speech.stop()
        try await waitUntil { completions.count == 1 }
        XCTAssertEqual(completions.first?.text, words.joined(separator: " "))
        XCTAssertEqual(completions.first?.reason, .final)
        XCTAssertTrue(completions.first?.wasExplicitlyStopped == true)
        let finishes = await decoder.finishCount
        XCTAssertEqual(finishes, 1)
        XCTAssertFalse(session.usedMainThread)
    }

    func testQueueOverflowReportsIncompleteOnceAndCannotBecomeSuccessfulFinal() async throws {
        let decoder = FakeParakeetDecoder(snapshots: ["must never be delivered"])
        let lease = SpeechAudioLease()
        let events = ParakeetEventRecorder()
        let pipeline = ParakeetRecognitionPipeline(decoder: decoder, lease: lease, maxQueuedFrames: 16_000, onRecognition: events.append)
        defer { pipeline.cancel() }
        // No worker yet: a blocked decoder cannot hide an unbounded audio queue.
        pipeline.append(try pcm(frames: 8_000))
        pipeline.append(try pcm(frames: 8_000))
        pipeline.append(try pcm(frames: 1))
        pipeline.append(try pcm(frames: 1))
        XCTAssertFalse(lease.mayStart)
        XCTAssertTrue(lease.hasIncompleteAudio)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertTrue(events.events[0].incomplete)
        XCTAssertTrue(events.events[0].failed)
        pipeline.finishInput()
        pipeline.start()
        let finishes = await decoder.finishCount
        XCTAssertEqual(finishes, 0)
        XCTAssertFalse(events.events.contains(where: \.isFinal))
    }

    @MainActor
    func testLateFinishAfterCancelCannotCompleteOrMutateNewCapture() async throws {
        let entered = expectation(description: "Decoder reached final flush")
        let gate = ParakeetTestGate(onWait: { entered.fulfill() })
        let firstDecoder = FakeParakeetDecoder(snapshots: ["old full draft"], finishGate: gate)
        let firstHarness = ParakeetSessionHarness(decoder: firstDecoder)
        let secondDecoder = FakeParakeetDecoder(snapshots: ["new capture words"])
        let secondHarness = ParakeetSessionHarness(decoder: secondDecoder)
        var creations = 0
        let owner = SpeechAudioOwner { configuration in
            creations += 1
            return (creations == 1 ? firstHarness : secondHarness).makeSession(configuration: configuration)
        }
        let speech = SpeechCapture(audioOwner: owner, authorization: { true })
        defer { speech.cancel() }
        var completions: [SpeechCompletion] = []
        speech.onCompletion = { completions.append($0) }
        try await speech.start(locale: "en-IN", contextualStrings: [])
        try XCTUnwrap(firstHarness.session).append(try pcm(frames: 1600))
        try await waitUntil { speech.transcript == "old full draft" }
        speech.stop()
        await fulfillment(of: [entered], timeout: 2)
        speech.cancel()
        try await speech.start(locale: "en-IN", contextualStrings: [])
        try XCTUnwrap(secondHarness.session).append(try pcm(frames: 1600))
        try await waitUntil { speech.transcript == "new capture words" }
        await gate.release()
        try await waitUntilAsync { await firstDecoder.didReturnFinish }
        XCTAssertEqual(speech.transcript, "new capture words")
        XCTAssertTrue(speech.isRecording)
        XCTAssertTrue(completions.isEmpty)
    }

    func testResamplerCopiesBorrowedTapMemoryAndDrainsAcceptedResidualAfterStop() async throws {
        try await verifyResampler(sampleRate: 48_000, channels: 1)
    }

    func testHeadsetRateInputReachesDecoderWithoutResamplingOrBorrowingAudio() async throws {
        try await verifyResampler(sampleRate: 16_000, channels: 1)
    }

    func testStereoInputReachesMonoDecoderWithoutDroppingFrames() async throws {
        try await verifyResampler(sampleRate: 48_000, channels: 2)
    }

    private func verifyResampler(sampleRate: Double, channels: AVAudioChannelCount) async throws {
        let decoder = FakeParakeetDecoder(snapshots: ["decoded"])
        let lease = SpeechAudioLease()
        let events = ParakeetEventRecorder()
        let pipeline = ParakeetRecognitionPipeline(decoder: decoder, lease: lease, onRecognition: events.append)
        defer { pipeline.cancel() }
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target))
        let pump = ParakeetPCMConversionPump(converter: converter, outputFormat: target, pipeline: pipeline, lease: lease)
        let framesIn = AVAudioFrameCount(sampleRate / 10)
        let borrowed = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: framesIn))
        borrowed.frameLength = framesIn
        for channel in 0..<Int(channels) {
            borrowed.floatChannelData![channel].initialize(repeating: 0.25, count: Int(framesIn))
        }
        pump.append(borrowed)
        // Simulates the tap reusing its memory immediately after callback return.
        for channel in 0..<Int(channels) {
            borrowed.floatChannelData![channel].update(repeating: 0, count: Int(framesIn))
        }
        lease.closeInput()
        pump.finishInput()
        pipeline.finishInput()
        pipeline.start()
        try await waitUntilAsync { events.events.contains(where: \.isFinal) }
        let maxSample = await decoder.maximumSample
        let frames = await decoder.totalFrames
        XCTAssertGreaterThan(maxSample, 0.2)
        XCTAssertEqual(frames, 1_600, "Resampler residual accepted before Fn-stop must not disappear")
        XCTAssertFalse(lease.hasIncompleteAudio)
    }

    private func pcm(frames: AVAudioFrameCount) throws -> ParakeetPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
        return .init(buffer: buffer)
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        try await waitUntilAsync { condition() }
    }
    private func waitUntilAsync(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard clock.now < deadline else { throw WaitFailure.deadline }
            await Task.yield()
        }
    }
    private enum WaitFailure: Error { case deadline }
}

/// Models an RNNT result delayed beyond the last real speech frame. Its result
/// is observable only after the caller actually supplies and processes context.
private actor FinalContextModel {
    enum Failure: Error { case rejected }
    private let rejectAppend: Bool
    private(set) var events: [String] = []
    private(set) var frames = 0
    private(set) var maximumSample: Float = 0
    private(set) var sampleRate: Double = 0
    private(set) var channels: AVAudioChannelCount = 0
    private var processed = false
    init(rejectAppend: Bool = false) { self.rejectAppend = rejectAppend }
    func append(_ input: ParakeetPCMBuffer) throws {
        events.append("append")
        if rejectAppend { throw Failure.rejected }
        frames += Int(input.buffer.frameLength)
        sampleRate = input.buffer.format.sampleRate
        channels = input.buffer.format.channelCount
        if let samples = input.buffer.floatChannelData?[0] {
            for frame in 0..<Int(input.buffer.frameLength) { maximumSample = max(maximumSample, abs(samples[frame])) }
        }
    }
    func process() { events.append("process"); processed = true }
    func finish() -> String {
        events.append("finish")
        return processed && frames >= 17_920 ? "Okay." : ""
    }
}

private actor FakeParakeetDecoder: ParakeetStreamingDecoding {
    private let snapshots: [String]
    private let finishGate: ParakeetTestGate?
    private(set) var appendCount = 0
    private(set) var finishCount = 0
    private(set) var maximumSample: Float = 0
    private(set) var totalFrames = 0
    private(set) var didReturnFinish = false
    init(snapshots: [String], finishGate: ParakeetTestGate? = nil) { self.snapshots = snapshots; self.finishGate = finishGate }
    func loadModel(from directory: URL) async throws {}
    func appendAndDecode(_ input: ParakeetPCMBuffer) async throws -> String {
        appendCount += 1
        totalFrames += Int(input.buffer.frameLength)
        if let samples = input.buffer.floatChannelData?[0] {
            for frame in 0..<Int(input.buffer.frameLength) { maximumSample = max(maximumSample, abs(samples[frame])) }
        }
        return snapshots[min(appendCount - 1, snapshots.count - 1)]
    }
    func finish() async throws -> String {
        finishCount += 1
        if let finishGate { await finishGate.wait() }
        didReturnFinish = true
        return snapshots.last ?? ""
    }
    func cleanup() async {}
}
private actor ParakeetTestGate {
    private let onWait: () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    init(onWait: @escaping () -> Void) { self.onWait = onWait }
    func wait() async { await withCheckedContinuation { continuation = $0; onWait() } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class ParakeetEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SpeechRecognitionEvent] = []
    var events: [SpeechRecognitionEvent] { lock.withLock { stored } }
    func append(_ event: SpeechRecognitionEvent) { lock.withLock { stored.append(event) } }
}
private final class ParakeetSessionHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder: any ParakeetStreamingDecoding
    private var stored: PipelineSpeechSession?
    init(decoder: any ParakeetStreamingDecoding) { self.decoder = decoder }
    var session: PipelineSpeechSession? { lock.withLock { stored } }
    func makeSession(configuration: SpeechAudioConfiguration) -> PipelineSpeechSession {
        let session = PipelineSpeechSession(configuration: configuration, decoder: decoder)
        lock.withLock { stored = session }
        return session
    }
}
private final class PipelineSpeechSession: SpeechAudioSession, @unchecked Sendable {
    private let configuration: SpeechAudioConfiguration
    private let decoder: any ParakeetStreamingDecoding
    private let lock = NSLock()
    private var stored: ParakeetRecognitionPipeline?
    private var mainThread = false
    var usedMainThread: Bool { lock.withLock { mainThread } }
    init(configuration: SpeechAudioConfiguration, decoder: any ParakeetStreamingDecoding) {
        self.configuration = configuration; self.decoder = decoder
    }
    func start(lease: SpeechAudioLease) throws {
        let pipeline = ParakeetRecognitionPipeline(decoder: decoder, lease: lease, onRecognition: configuration.onRecognition)
        lock.withLock { stored = pipeline; mainThread = mainThread || Thread.isMainThread }
        pipeline.start()
    }
    func append(_ input: ParakeetPCMBuffer) { lock.withLock { stored }?.append(input) }
    func stopAudio() { lock.withLock { mainThread = mainThread || Thread.isMainThread } }
    func finishRecognition() { lock.withLock { stored }?.finishInput() }
    func cancel() { lock.withLock { stored }?.cancel() }
}
