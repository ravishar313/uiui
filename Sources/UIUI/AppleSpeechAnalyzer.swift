import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Selects one engine before capture. Preparation never requests an asset download.
final class NativeSpeechAudioSession: SpeechAudioSession, @unchecked Sendable {
    private let configuration: SpeechAudioConfiguration
    private let lock = NSLock()
    private var selected: (any SpeechAudioSession)?
    private var status = SpeechEngineStatus.legacy

    init(configuration: SpeechAudioConfiguration) { self.configuration = configuration }
    var engineStatus: SpeechEngineStatus { lock.withLock { status } }

    func prepare(lease: SpeechAudioLease) async throws {
        let selection: (any SpeechAudioSession, SpeechEngineStatus)
        if LocalSpeechModel.supports(locale: configuration.locale) {
            let descriptor: SpeechModelSessionDescriptor
            if #available(macOS 15.0, *) {
                descriptor = SpeechModelSessionDescriptor(directory: PhononSpeechModel.directory,
                    isInstalled: { PhononSpeechModel.isInstalled }, modelDescription: PhononSpeechModel.modelDescription,
                    setupMessage: "uiui’s speech model (uiui S1) is missing. Reinstall the complete app bundle.")
            } else { descriptor = .parakeet }
            let parakeet = ParakeetSpeechAudioSession(configuration: configuration, decoder: LocalSpeechModel.makeDecoder(vocabulary: configuration.vocabulary), descriptor: descriptor)
            do { try await parakeet.prepare(lease: lease) }
            catch { parakeet.cancel(); throw error }
            selection = (parakeet, parakeet.engineStatus)
        } else if #available(macOS 26.0, *), SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: configuration.locale)) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            if await AssetInventory.status(forModules: [transcriber]) == .installed {
                let modern = AppleSpeechAnalyzerSession(configuration: configuration, transcriber: transcriber)
                do { try await modern.prepare(lease: lease) }
                catch { modern.cancel(); throw error }
                selection = (modern, modern.engineStatus)
            } else {
                throw SpeechCaptureFailure.message("Download the on-device long-form speech model for this language using Download speech model in Settings, then try again. No audio was captured or sent to a server.")
            }
        } else {
            selection = (try LegacySpeechAudioSession(configuration: configuration),
                         SpeechEngineStatus(description: "Classic on-device dictation",
                                            warning: "Classic on-device dictation may end early during silence; unfinished speech is kept for review. Long-form recognition requires macOS 26 and a supported language.",
                                            finalizationWaitMilliseconds: 1200))
        }
        // Cancellation may have released this wrapper while async preparation ran.
        guard lease.mayStart else { selection.0.cancel(); throw CancellationError() }
        lock.withLock { selected = selection.0; status = selection.1 }
        guard lease.mayStart else { cancel(); throw CancellationError() }
    }
    func start(lease: SpeechAudioLease) throws {
        guard let session = lock.withLock({ selected }) else { throw CancellationError() }
        try session.start(lease: lease)
    }
    func waitForInputReady(lease: SpeechAudioLease) async throws {
        guard let session = lock.withLock({ selected }) else { throw CancellationError() }
        try await session.waitForInputReady(lease: lease)
    }
    func stopAudio() { lock.withLock { selected }?.stopAudio() }
    func finishRecognition() { lock.withLock { selected }?.finishRecognition() }
    func cancel() { lock.withLock { selected }?.cancel() }
}

/// Pure time-indexed transcript state. A finalized interval is immutable. A new
/// hypothesis replaces overlapping volatile pieces, including an empty retraction.
/// Audio-time pieces let a revision straddling a stable boundary retain only its
/// new words without copying the stable prefix twice.
struct SpeechRangeTranscriptLedger {
    struct Piece: Equatable, Sendable {
        let start: Double
        let end: Double
        let text: String
        let joinsPrevious: Bool
        init(start: Double, end: Double, text: String, joinsPrevious: Bool = false) {
            self.start = start; self.end = end; self.text = text; self.joinsPrevious = joinsPrevious
        }
    }
    private struct Entry {
        let piece: Piece
        let isFinal: Bool
    }
    private struct Interval {
        let start: Double
        let end: Double
    }
    private var entries: [Entry] = []
    private var finalizedRanges: [Interval] = []
    private(set) var hasUnresolvedOverlap = false

    var text: String {
        var pieces: [Piece] = entries.map { $0.piece }
        pieces.sort { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }
        let joined = pieces.reduce(into: "") { output, piece in
            let text = piece.text
            guard !text.isEmpty else { return }
            let punctuation = CharacterSet(charactersIn: ".,!?;:)]}’'")
            let attaches = text.unicodeScalars.first.map { punctuation.contains($0) } ?? false
            let hasSeparator = text.first?.isWhitespace == true || output.last?.isWhitespace == true
            if !output.isEmpty, !piece.joinsPrevious, !hasSeparator, !attaches, !output.hasSuffix("(") { output += " " }
            output += text
        }
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    mutating func update(start: Double, end: Double, pieces: [Piece], isFinal: Bool) -> String {
        guard start.isFinite, end.isFinite, end >= start else { hasUnresolvedOverlap = true; return text }
        func overlaps(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Bool {
            (a < d - 0.000001 && c < b - 0.000001) || (a == c && b == d)
        }
        var retained: [Entry] = []
        var indivisible: [Piece] = []
        for entry in entries {
            let piece = entry.piece
            guard !entry.isFinal, overlaps(piece.start, piece.end, start, end) else {
                retained.append(entry); continue
            }
            if piece.start < start - 0.000001 || piece.end > end + 0.000001 {
                // No character-count guesses: retain the old complete run if
                // Apple's replacement cuts through it, and require recovery.
                retained.append(entry)
                indivisible.append(piece)
                hasUnresolvedOverlap = true
            }
            // Other overlapping volatile pieces are replaced or retracted.
            // Pieces outside this result range remain, even if never reissued.
        }
        entries = retained
        for piece in pieces {
            guard piece.start.isFinite, piece.end.isFinite, piece.end >= piece.start else {
                hasUnresolvedOverlap = true; continue
            }
            let stable = finalizedRanges.filter { overlaps($0.start, $0.end, piece.start, piece.end) }
            if !stable.isEmpty {
                if !stable.contains(where: { piece.start >= $0.start - 0.000001 && piece.end <= $0.end + 0.000001 }) {
                    hasUnresolvedOverlap = true
                }
                continue
            }
            if indivisible.contains(where: { overlaps($0.start, $0.end, piece.start, piece.end) }) { continue }
            entries.append(Entry(piece: piece, isFinal: isFinal))
        }
        if isFinal {
            finalizedRanges.append(Interval(start: start, end: end))
            // Coalesce stable intervals so a repeated result spanning adjacent
            // committed intervals is recognized as entirely finalized.
            finalizedRanges.sort { $0.start < $1.start }
            var merged: [Interval] = []
            for range in finalizedRanges {
                if let last = merged.last, range.start <= last.end + 0.000001 {
                    merged[merged.count - 1] = Interval(start: last.start, end: max(last.end, range.end))
                } else { merged.append(range) }
            }
            finalizedRanges = merged
        }
        return text
    }

}

/// Segment finality commits a range; only explicit end-of-input finalization
/// creates a session-final event. Kept pure so pauses and long sessions can be
/// tested without Apple services, audio files, or a microphone.
struct SpeechAnalyzerTranscriptState {
    private var ledger = SpeechRangeTranscriptLedger()
    mutating func receive(start: Double, end: Double, pieces: [SpeechRangeTranscriptLedger.Piece], isFinal: Bool) -> SpeechRecognitionEvent {
        let text = ledger.update(start: start, end: end, pieces: pieces, isFinal: isFinal)
        return .init(text: text, isFinal: false, failed: false, fullSnapshot: true)
    }
    var completionEvent: SpeechRecognitionEvent {
        .init(text: ledger.text, isFinal: !ledger.hasUnresolvedOverlap, failed: ledger.hasUnresolvedOverlap,
              fullSnapshot: true, incomplete: ledger.hasUnresolvedOverlap)
    }
}

/// This class never owns native engine lifecycle outside SpeechAudioOwner's queue.
/// Its analyzer tasks consume only independent PCM buffers and send transcript
/// snapshots; the real-time tap never queues unbounded work or retains tap memory.
@available(macOS 26.0, *)
final class AppleSpeechAnalyzerSession: SpeechAudioSession, @unchecked Sendable {
    let engineStatus = SpeechEngineStatus(description: "Apple on-device long-form speech", warning: nil,
                                           finalizationWaitMilliseconds: 8000, requiresCompleteFinalization: true)
    private let configuration: SpeechAudioConfiguration
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var format: AVAudioFormat?
    private var engine: AVAudioEngine?
    private var hasTap = false
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pump: SpeechAnalyzerAudioPump?
    private var analysisTask: Task<Void, Error>?
    private var resultTask: Task<SpeechAnalyzerTranscriptState, Error>?
    private var finishTask: Task<Void, Never>?
    private var lease: SpeechAudioLease?

    init(configuration: SpeechAudioConfiguration, transcriber: SpeechTranscriber) {
        self.configuration = configuration
        self.transcriber = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func prepare(lease: SpeechAudioLease) async throws {
        guard lease.mayStart else { throw CancellationError() }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechCaptureFailure.message("No compatible on-device speech audio format is available.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        guard lease.mayStart else { throw CancellationError() }
        self.format = format
    }

    func start(lease: SpeechAudioLease) throws {
        guard lease.mayStart, let format else { throw CancellationError() }
        self.lease = lease
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw SpeechCaptureFailure.message("The selected microphone cannot supply speech audio. Check System Settings → Sound.")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(96))
        self.continuation = continuation
        let analyzer = analyzer
        let transcriber = transcriber
        let configuration = configuration
        resultTask = Task.detached(priority: .userInitiated) {
            var state = SpeechAnalyzerTranscriptState()
            do {
                for try await result in transcriber.results {
                    guard lease.isValid, !Task.isCancelled else { throw CancellationError() }
                    let attributed = result.text
                    let pieces = attributed.runs.enumerated().map { index, run -> SpeechRangeTranscriptLedger.Piece in
                        let range = run.audioTimeRange ?? result.range
                        return .init(start: range.start.seconds, end: CMTimeRangeGetEnd(range).seconds,
                                     text: String(attributed[run.range].characters), joinsPrevious: index > 0)
                    }
                    let event = state.receive(start: result.range.start.seconds,
                                              end: CMTimeRangeGetEnd(result.range).seconds,
                                              pieces: pieces, isFinal: result.isFinal)
                    configuration.onRecognition(event)
                }
                return state
            } catch {
                if lease.isValid, !Task.isCancelled {
                    lease.markIncomplete()
                    configuration.onRecognition(.init(text: nil, isFinal: false, failed: true, fullSnapshot: true, incomplete: true))
                }
                throw error
            }
        }
        analysisTask = Task.detached(priority: .userInitiated) {
            do { try await analyzer.start(inputSequence: stream) }
            catch {
                if lease.isValid, !Task.isCancelled {
                    lease.markIncomplete()
                    configuration.onRecognition(.init(text: nil, isFinal: false, failed: true, fullSnapshot: true, incomplete: true))
                }
                throw error
            }
        }
        let meter = CaptureLevelMeter()
        let pump = SpeechAnalyzerAudioPump(converter: converter, outputFormat: format, continuation: continuation,
                                           lease: lease, onFailure: {
            configuration.onRecognition(.init(text: nil, isFinal: false, failed: true, fullSnapshot: true, incomplete: true))
        })
        self.pump = pump
        input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { buffer, _ in
            guard lease.mayStart else { return }
            // Conversion/copy occurs synchronously while tap storage is valid.
            pump.append(buffer)
            if configuration.reportLevels, let level = meter.measureIfDue(buffer) { configuration.onLevel(level) }
        }
        hasTap = true
        guard lease.mayStart else { throw CancellationError() }
        engine.prepare()
        try engine.start()
        guard lease.mayStart else { throw CancellationError() }
    }

    func stopAudio() {
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        engine?.reset()
        engine = nil
    }

    func finishRecognition() {
        guard finishTask == nil, let lease, let resultTask, let analysisTask else { return }
        pump?.finishInput()
        continuation?.finish()
        let analyzer = analyzer
        let configuration = configuration
        finishTask = Task.detached(priority: .userInitiated) {
            do {
                try await analysisTask.value
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let state = try await resultTask.value
                guard lease.isValid, !Task.isCancelled else { return }
                if lease.hasIncompleteAudio {
                    configuration.onRecognition(.init(text: state.completionEvent.text, isFinal: false, failed: true, fullSnapshot: true, incomplete: true))
                } else { configuration.onRecognition(state.completionEvent) }
            } catch {
                guard lease.isValid, !Task.isCancelled else { return }
                configuration.onRecognition(.init(text: nil, isFinal: false, failed: true, fullSnapshot: true, incomplete: true))
            }
        }
    }

    func cancel() {
        stopAudio()
        pump = nil
        continuation?.finish(); continuation = nil
        finishTask?.cancel(); finishTask = nil
        analysisTask?.cancel(); analysisTask = nil
        resultTask?.cancel(); resultTask = nil
        let analyzer = analyzer
        Task.detached { await analyzer.cancelAndFinishNow() }
    }
}

/// A finite input queue must fail visibly on overflow rather than silently create
/// a transcript with an audio hole. One tap serially owns converter and sample time.
@available(macOS 26.0, *)
final class SpeechAnalyzerAudioPump: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let lease: SpeechAudioLease
    private let onFailure: () -> Void
    private var sampleCount: Int64 = 0
    private var failed = false
    private var finished = false

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation, lease: SpeechAudioLease, onFailure: @escaping () -> Void) {
        self.converter = converter; self.outputFormat = outputFormat
        self.continuation = continuation; self.lease = lease; self.onFailure = onFailure
    }

    func append(_ input: AVAudioPCMBuffer) {
        guard !failed, !finished, lease.mayStart else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { fail(); return }
        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered { inputStatus.pointee = .noDataNow; return nil }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, status != .error else { fail(); return }
        guard output.frameLength > 0 else { return }
        enqueue(output)
    }

    /// Drain only the converter's bounded residual state before closing input.
    /// No live tap memory is retained and no microphone work happens here.
    func finishInput() {
        guard !failed, !finished, lease.isValid else { return }
        finished = true
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { fail(); return }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard conversionError == nil, status != .error else { fail(); return }
            if output.frameLength > 0 { enqueue(output) }
            if failed || status == .endOfStream || output.frameLength == 0 { return }
        }
        fail()
    }

    private func enqueue(_ output: AVAudioPCMBuffer) {
        guard lease.isValid else { return }
        let time = CMTime(value: sampleCount, timescale: CMTimeScale(outputFormat.sampleRate))
        sampleCount += Int64(output.frameLength)
        switch continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time)) {
        case .enqueued: break
        case .dropped: fail()
        case .terminated: if lease.isValid { fail() }
        @unknown default: fail()
        }
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        lease.markIncomplete()
        continuation.finish()
        onFailure()
    }
}
