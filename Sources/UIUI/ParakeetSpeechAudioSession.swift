import AVFoundation
import FluidAudio
import Foundation

/// An independent PCM allocation; borrowed tap storage never crosses an await.
struct ParakeetPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

protocol ParakeetStreamingDecoding: Sendable {
    func loadModel(from directory: URL) async throws
    func appendAndDecode(_ input: ParakeetPCMBuffer) async throws -> String
    func finish() async throws -> String
    func cleanup() async
}

/// This actor is the sole owner of one lease's decoder, including all awaits.
/// Capture never invokes any FluidAudio download or automatic recovery loader.
actor NativeParakeetStreamingDecoder: ParakeetStreamingDecoding {
    private let modelLease = ExclusiveSpeechModelLease<StreamingUnifiedAsrManager>(
        checkOut: { try await ParakeetModelPool.shared.checkOut() },
        checkIn: { await ParakeetModelPool.shared.checkIn($0) })
    private var hasAcceptedAudio = false

    func loadModel(from directory: URL) async throws {
        guard directory.standardizedFileURL == ParakeetSpeechModel.directory.standardizedFileURL else {
            throw SpeechCaptureFailure.message("The speech model directory does not match the prepared model.")
        }
        try await modelLease.load()
        hasAcceptedAudio = false
    }
    func appendAndDecode(_ input: ParakeetPCMBuffer) async throws -> String {
        let text = try await modelLease.withModel { manager in
            try Task.checkCancellation()
            try await manager.appendAudio(input.buffer)
            try await manager.processBufferedAudio()
            // The product uses complete text snapshots, not token timings.
            _ = await manager.consumeTokenTimings()
            try Task.checkCancellation()
            return await manager.getPartialTranscript()
        }
        if input.buffer.frameLength > 0 { hasAcceptedAudio = true }
        return text
    }
    func finish() async throws -> String {
        let needsFinalContext = hasAcceptedAudio
        let text = try await modelLease.withModel(finishing: true) { manager in
            try Task.checkCancellation()
            let text = try await ParakeetFinalizationContext.finish(
                hasAcceptedAudio: needsFinalContext,
                appendAudio: { try await manager.appendAudio($0.buffer) },
                processBufferedAudio: { try await manager.processBufferedAudio() },
                finish: { try await manager.finish() })
            _ = await manager.consumeTokenTimings()
            try Task.checkCancellation()
            return text
        }
        self.hasAcceptedAudio = false
        return text
    }
    func cleanup() async { hasAcceptedAudio = false; await modelLease.close() }
}

/// Encoder window padding is outside FluidAudio's valid mel length. Supply a
/// real silent chunk + look-ahead at explicit stop so delayed RNNT emissions,
/// including a first short word, can emerge before the final flush. This is
/// synthetic decoder input; the microphone has already stopped.
enum ParakeetFinalizationContext {
    static let frameCount = ParakeetSpeechModel.config.chunkSamples + ParakeetSpeechModel.config.rightSamples

    static func finish(hasAcceptedAudio: Bool,
                       appendAudio: @Sendable (ParakeetPCMBuffer) async throws -> Void,
                       processBufferedAudio: @Sendable () async throws -> Void,
                       finish: @Sendable () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        if hasAcceptedAudio {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                  let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
                  let samples = silence.floatChannelData?[0] else {
                throw SpeechCaptureFailure.message("Cannot allocate the speech finalization context.")
            }
            silence.frameLength = AVAudioFrameCount(frameCount)
            samples.initialize(repeating: 0, count: frameCount)
            try await appendAudio(.init(buffer: silence))
            try Task.checkCancellation()
            try await processBufferedAudio()
        }
        try Task.checkCancellation()
        return try await finish()
    }
}

/// Bounded transport and recognition lifecycle, independent of the microphone.
/// Silence leaves the input sequence open. Only explicit finish requests the
/// decoder's final flush; an input failure can never become a successful final.
final class ParakeetRecognitionPipeline: @unchecked Sendable {
    private let decoder: any ParakeetStreamingDecoding
    private let lease: SpeechAudioLease
    private let onRecognition: (SpeechRecognitionEvent) -> Void
    private let lock = NSLock()
    private let maxQueuedFrames: Int
    private var queuedFrames = 0
    private var explicitlyFinished = false
    private var reportedFailure = false
    private var started = false
    private let stream: AsyncStream<ParakeetPCMBuffer>
    private let continuation: AsyncStream<ParakeetPCMBuffer>.Continuation
    private var worker: Task<Void, Never>?

    init(decoder: any ParakeetStreamingDecoding, lease: SpeechAudioLease,
         maxQueuedFrames: Int = 4 * 16_000, onRecognition: @escaping (SpeechRecognitionEvent) -> Void) {
        self.decoder = decoder; self.lease = lease; self.onRecognition = onRecognition
        self.maxQueuedFrames = maxQueuedFrames
        // Count and frame limits both apply: many tiny buffers and large device
        // buffers cannot defeat the bound on undecoded audio.
        let pair = AsyncStream<ParakeetPCMBuffer>.makeStream(bufferingPolicy: .bufferingOldest(128))
        stream = pair.stream; continuation = pair.continuation
    }

    func start() {
        guard lock.withLock({ if started { return false }; started = true; return true }) else { return }
        let decoder = decoder, lease = lease, stream = stream
        worker = Task.detached(priority: .userInitiated) { [self] in
            var previous = ""
            do {
                for await input in stream {
                    lock.withLock { queuedFrames = max(0, queuedFrames - Int(input.buffer.frameLength)) }
                    guard lease.isValid, !lease.hasIncompleteAudio, !Task.isCancelled else { return }
                    let snapshot = try await decoder.appendAndDecode(input)
                    guard lease.isValid, !lease.hasIncompleteAudio, !Task.isCancelled else { return }
                    if snapshot != previous {
                        previous = snapshot
                        onRecognition(.init(text: snapshot, isFinal: false, failed: false, fullSnapshot: true))
                    }
                }
                guard lock.withLock({ explicitlyFinished }), lease.isValid,
                      !lease.hasIncompleteAudio, !Task.isCancelled else { return }
                let snapshot = try await decoder.finish()
                guard lease.isValid, !lease.hasIncompleteAudio, !Task.isCancelled else { return }
                onRecognition(.init(text: snapshot, isFinal: true, failed: false, fullSnapshot: true))
            } catch {
                guard lease.isValid, !Task.isCancelled else { return }
                fail()
            }
        }
    }

    /// Caller must supply its own PCM allocation in the model's 16 kHz format.
    func append(_ input: ParakeetPCMBuffer) {
        guard lease.mayStart else { return }
        enqueue(input)
    }

    func appendResidual(_ input: ParakeetPCMBuffer) {
        guard lease.isValid, !lease.hasIncompleteAudio else { return }
        enqueue(input)
    }

    private func enqueue(_ input: ParakeetPCMBuffer) {
        let frameCount = Int(input.buffer.frameLength)
        guard frameCount > 0 else { return }
        let admitted = lock.withLock { () -> Bool in
            guard !explicitlyFinished, !reportedFailure,
                  frameCount <= maxQueuedFrames, queuedFrames <= maxQueuedFrames - frameCount else { return false }
            queuedFrames += frameCount
            return true
        }
        guard admitted else { fail(); return }
        switch continuation.yield(input) {
        case .enqueued: break
        case .dropped: fail()
        case .terminated: if lease.isValid { fail() }
        @unknown default: fail()
        }
    }

    func finishInput() {
        lock.withLock { explicitlyFinished = true }
        continuation.finish()
    }

    func fail() {
        lease.markIncomplete()
        let report = lock.withLock { () -> Bool in
            guard !reportedFailure else { return false }
            reportedFailure = true
            return true
        }
        continuation.finish()
        if report, lease.isValid {
            onRecognition(.init(text: nil, isFinal: false, failed: true, fullSnapshot: true, incomplete: true))
        }
    }

    func cancel() {
        lease.invalidate()
        continuation.finish()
        worker?.cancel(); worker = nil
        let decoder = decoder
        Task.detached { await decoder.cleanup() }
    }
}

/// Native engine lifecycle methods are called exclusively by SpeechAudioOwner.
/// The decoder and its bounded queue run independently of that serial queue.
struct SpeechModelSessionDescriptor: Sendable {
    let directory: URL
    let isInstalled: @Sendable () -> Bool
    let modelDescription: String
    let setupMessage: String

    static let parakeet = SpeechModelSessionDescriptor(
        directory: ParakeetSpeechModel.directory,
        isInstalled: { ParakeetSpeechModel.isInstalled },
        modelDescription: ParakeetSpeechModel.modelDescription,
        setupMessage: "Download the speech model in Settings before recording. Models download only when you choose Download speech model.")
}

final class ParakeetSpeechAudioSession: SpeechAudioSession, @unchecked Sendable {
    let engineStatus: SpeechEngineStatus
    private let configuration: SpeechAudioConfiguration
    private let decoder: any ParakeetStreamingDecoding
    private let descriptor: SpeechModelSessionDescriptor
    private var engine: AVAudioEngine?
    private var hasTap = false
    private var pipeline: ParakeetRecognitionPipeline?
    private var pump: ParakeetPCMConversionPump?
    private let inputReady = SpeechInputReadiness()
    private var configurationObserver: NSObjectProtocol?

    init(configuration: SpeechAudioConfiguration, decoder: any ParakeetStreamingDecoding = NativeParakeetStreamingDecoder(),
         descriptor: SpeechModelSessionDescriptor = .parakeet) {
        self.configuration = configuration; self.decoder = decoder
        self.descriptor = descriptor
        engineStatus = SpeechEngineStatus(description: descriptor.modelDescription, warning: nil,
                                         finalizationWaitMilliseconds: 12_000, requiresCompleteFinalization: true)
    }

    func prepare(lease: SpeechAudioLease) async throws {
        guard lease.mayStart else { throw CancellationError() }
        guard descriptor.isInstalled() else {
            throw SpeechCaptureFailure.message(descriptor.setupMessage)
        }
        try await decoder.loadModel(from: descriptor.directory)
        guard lease.mayStart, !Task.isCancelled else { throw CancellationError() }
    }

    func start(lease: SpeechAudioLease) throws {
        guard lease.mayStart else { throw CancellationError() }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw SpeechCaptureFailure.message("The selected microphone cannot supply speech audio. Check System Settings → Sound.")
        }
        let configuration = configuration
        let pipeline = ParakeetRecognitionPipeline(decoder: decoder, lease: lease, onRecognition: configuration.onRecognition)
        self.pipeline = pipeline
        let inputReady = inputReady
        let pump = ParakeetPCMConversionPump(converter: converter, outputFormat: format, pipeline: pipeline, lease: lease,
                                             onAudio: { inputReady.receivedAudio() })
        self.pump = pump
        pipeline.start()
        let meter = CaptureLevelMeter()
        input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { buffer, _ in
            guard lease.mayStart else { return }
            pump.append(buffer)
            if configuration.reportLevels, let level = meter.measureIfDue(buffer) { configuration.onLevel(level) }
        }
        hasTap = true
        guard lease.mayStart else { throw CancellationError() }
        engine.prepare()
        try engine.start()
        try lease.requireActiveInput()
        // A hardware route change can stop AVAudioEngine without ending the
        // recognizer. Close this capture truthfully; the next trigger constructs
        // a new engine using the then-current system default microphone.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            guard lease.mayStart else { return }
            inputReady.fail("The system microphone changed while recording. Try recording again.")
            pipeline.fail()
        }
    }

    func waitForInputReady(lease: SpeechAudioLease) async throws {
        try await inputReady.wait()
        try lease.requireActiveInput()
    }

    func stopAudio() {
        inputReady.cancel()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        engine?.reset(); engine = nil
    }
    func finishRecognition() {
        pump?.finishInput()
        pipeline?.finishInput()
    }
    func cancel() {
        stopAudio()
        pump = nil
        if let pipeline { pipeline.cancel() }
        else { let decoder = decoder; Task.detached { await decoder.cleanup() } }
        pipeline = nil
    }
}

/// One tap owns this converter. Its output allocation, not the tap allocation,
/// is transferred to the asynchronous decoder. Stop drains resampler residue.
final class ParakeetPCMConversionPump {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let pipeline: ParakeetRecognitionPipeline
    private let lease: SpeechAudioLease
    private let onAudio: () -> Void
    private var finished = false
    init(converter: AVAudioConverter, outputFormat: AVAudioFormat, pipeline: ParakeetRecognitionPipeline, lease: SpeechAudioLease,
         onAudio: @escaping () -> Void = {}) {
        self.converter = converter; self.outputFormat = outputFormat; self.pipeline = pipeline; self.lease = lease
        self.onAudio = onAudio
    }
    func append(_ input: AVAudioPCMBuffer) {
        guard !finished, lease.mayStart else { return }
        let frames = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else { pipeline.fail(); return }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if delivered { status.pointee = .noDataNow; return nil }
            delivered = true; status.pointee = .haveData; return input
        }
        guard error == nil, status != .error else { pipeline.fail(); return }
        // The input gate was checked before conversion; preserve this already
        // admitted buffer if Fn-stop closes the gate during conversion.
        if output.frameLength > 0 {
            pipeline.appendResidual(.init(buffer: output))
            if lease.mayStart { onAudio() }
        }
    }
    func finishInput() {
        guard !finished, lease.isValid, !lease.hasIncompleteAudio else { return }
        finished = true
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { pipeline.fail(); return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            guard error == nil, status != .error else { pipeline.fail(); return }
            // Stop has closed lease.mayStart, but the converter still owns
            // accepted pre-stop samples. They must reach the final decoder flush.
            if output.frameLength > 0 { pipeline.appendResidual(.init(buffer: output)) }
            if status == .endOfStream || output.frameLength == 0 { return }
        }
        pipeline.fail()
    }
}
