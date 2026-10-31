import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Explicit developer fixture runner, before application state is initialized.
/// Accepts a public/synthetic manifest; no microphone, history or clipboard access.
enum LocalSpeechCorpusSmoke {
    private struct Fixture: Decodable {
        let id: String
        let audio_path: String
        let samples: Int
        let sha256: String
        let reference: String
    }
    static func run(manifest: URL, output: URL, vocabulary: [String] = [], diagnostics: Bool = false) async throws {
        let data = try Data(contentsOf: manifest)
        let fixtures = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(Fixture.self, from: Data($0.utf8))
        }
        guard !fixtures.isEmpty, !FileManager.default.fileExists(atPath: output.path) else { throw CleanupFailure.unavailable }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        func emit(_ row: [String: Any]) throws {
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
            try handle.synchronize()
        }
        let prepare = ContinuousClock.now
        await LocalSpeechModel.warmIfInstalled()
        try emit(["event": "ready", "asr": LocalSpeechModel.name,
                  "prepare_ms": milliseconds(prepare.duration(to: .now)), "microphone": "not-opened"])
        for (index, fixture) in fixtures.enumerated() {
            let audioURL = fixture.audio_path.hasPrefix("/") ? URL(fileURLWithPath: fixture.audio_path) : manifest.deletingLastPathComponent().appendingPathComponent(fixture.audio_path)
            let audio = try Data(contentsOf: audioURL)
            guard SHA256.hash(data: audio).map({ String(format: "%02x", $0) }).joined() == fixture.sha256 else { throw CleanupFailure.unavailable }
            let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length == fixture.samples, file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else { throw CleanupFailure.unavailable }
            let decoder = LocalSpeechModel.makeDecoder(vocabulary: vocabulary)
            let trigger = ContinuousClock.now
            do {
                try await decoder.loadModel(from: LocalSpeechModel.directory)
                let checkoutMS = milliseconds(trigger.duration(to: .now))
                var firstPreviewMS: Double?, firstPreviewAudioMS: Double?
                var submitted = 0
                var snapshots = SnapshotDiagnostics()
                let decode = ContinuousClock.now
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_280)!
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw CleanupFailure.unavailable }
                    submitted += Int(buffer.frameLength)
                    let partial = try await decoder.appendAndDecode(.init(buffer: buffer))
                    if diagnostics { snapshots.append(partial) }
                    if !partial.isEmpty && firstPreviewMS == nil {
                        firstPreviewMS = milliseconds(trigger.duration(to: .now))
                        firstPreviewAudioMS = Double(file.framePosition) / 16
                    }
                }
                let stop = ContinuousClock.now
                let recognized = try await decoder.finish()
                let stopMS = milliseconds(stop.duration(to: .now))
                await decoder.cleanup()
                let actual = words(recognized), reference = words(fixture.reference)
                var row: [String: Any] = ["event": "fixture", "id": fixture.id, "asr": LocalSpeechModel.name,
                    "first_use": index == 0, "pacing": "accelerated", "checkout_ms": checkoutMS,
                    "decode_ms": milliseconds(decode.duration(to: .now)), "stop_ms": stopMS,
                    "source_samples": fixture.samples, "submitted_samples": submitted,
                    "reference_words": reference.count, "recognized_words": actual.count,
                    "word_edits": distance(reference, actual), "exact_words": actual == reference,
                    "microphone": "not-opened", "delivery": "none"]
                if diagnostics {
                    row["recognized_text_sha256"] = digest(recognized)
                    row["recognized_words_sha256"] = digest(actual.joined(separator: " "))
                    row["partial_snapshots_sha256"] = snapshots.digest
                    row["nonempty_snapshots"] = snapshots.nonemptySnapshots
                    row["nonempty_updates"] = snapshots.nonemptyUpdates
                    row["nonprefix_revisions"] = snapshots.revisions
                    row["samples_exact"] = submitted == fixture.samples
                }
                guard submitted == fixture.samples else { throw CleanupFailure.unavailable }
                if let firstPreviewMS { row["first_preview_compute_ms"] = firstPreviewMS }
                if let firstPreviewAudioMS { row["first_preview_audio_ms"] = firstPreviewAudioMS }
                try emit(row)
            } catch {
                await decoder.cleanup(); await LocalSpeechModel.clear(); throw error
            }
        }
        await LocalSpeechModel.clear()
        report("LOCAL_SPEECH_CORPUS passed engine=\(LocalSpeechModel.name) fixtures=\(fixtures.count) microphone=not-opened")
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    private static func words(_ text: String) -> [String] { text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
    private static func distance(_ a: [String], _ b: [String]) -> Int {
        var row = Array(0...b.count)
        for (i, word) in a.enumerated() {
            var next = [i + 1]
            for (j, other) in b.enumerated() { next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (word == other ? 0 : 1))) }
            row = next
        }
        return row.last!
    }
}

extension LocalSpeechCorpusSmoke {
    /// Pace a fixed fixture through the actual bounded capture transport. Unlike
    /// a decoder-only accelerated loop, producer work does not await inference.
    static func runTransport(audio: URL, reference: URL, vocabulary: [String] = [], diagnostics: Bool = false, withMiniLM: Bool = false) async throws {
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else { throw CleanupFailure.unavailable }
        let expected = words(try String(contentsOf: reference, encoding: .utf8))
        let cleanup = withMiniLM ? LocalCleanupModel.makeEngine() : nil
        defer { cleanup?.release() }
        let preparation = ContinuousClock.now
        async let speechReady: Void = LocalSpeechModel.warmIfInstalled()
        await cleanup?.prepare()
        await speechReady
        if withMiniLM {
            guard cleanup?.isReady == true else { throw CleanupFailure.unavailable }
            report(String(format: "LOCAL_SPEECH_TRANSPORT_DIAGNOSTICS minilm_resident=true models_ready_ms=%.3f", milliseconds(preparation.duration(to: .now))))
        }
        let failures = CorpusSmokeFailure()
        let decoder = CorpusSmokeReportingDecoder(native: LocalSpeechModel.makeDecoder(vocabulary: vocabulary), failures: failures)
        do { try await decoder.loadModel(from: LocalSpeechModel.directory) }
        catch { await decoder.cleanup(); await LocalSpeechModel.clear(); throw error }
        let lease = SpeechAudioLease()
        let pair = AsyncStream<SpeechRecognitionEvent>.makeStream()
        let pipeline = ParakeetRecognitionPipeline(decoder: decoder, lease: lease, onRecognition: { pair.continuation.yield($0) })
        let start = ContinuousClock.now
        pipeline.start()
        let feeder = Task.detached(priority: .userInitiated) {
            do {
                var submitted = 0
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_280)!
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw CleanupFailure.unavailable }
                    submitted += Int(buffer.frameLength)
                    pipeline.append(.init(buffer: buffer))
                    try await Task.sleep(until: start.advanced(by: .nanoseconds(Int64(submitted) * 1_000_000_000 / 16_000)), clock: .continuous)
                }
                pipeline.finishInput()
                return submitted
            } catch {
                await failures.record(error)
                pipeline.fail()
                throw error
            }
        }
        defer { feeder.cancel(); pipeline.cancel(); pair.continuation.finish() }
        var partials = 0
        var snapshots = SnapshotDiagnostics()
        var firstPreviewMS: Double?
        do {
            for await event in pair.stream {
                if event.failed || event.incomplete {
                    if let error = await failures.error { throw error }
                    throw CleanupFailure.unavailable
                }
                if !event.isFinal {
                    partials += 1
                    if diagnostics { snapshots.append(event.text ?? "") }
                    if let text = event.text, !text.isEmpty, firstPreviewMS == nil { firstPreviewMS = milliseconds(start.duration(to: .now)) }
                    continue
                }
                let submitted = try await feeder.value
                let recognized = event.text ?? ""
                let actual = words(recognized)
                let elapsed = milliseconds(start.duration(to: .now))
                let sourceMS = Double(file.length) / 16
                let edits = distance(expected, actual)
                let head = Array(actual.prefix(12)) == Array(expected.prefix(12))
                let tail = Array(actual.suffix(12)) == Array(expected.suffix(12))
                report(String(format: "LOCAL_SPEECH_TRANSPORT engine=%@ audio_ms=%.3f first_preview_ms=%.3f end_to_final_ms=%.3f", LocalSpeechModel.name, sourceMS, firstPreviewMS ?? -1, elapsed - sourceMS))
                report("LOCAL_SPEECH_TRANSPORT source_samples=\(file.length) submitted_samples=\(submitted) incomplete=\(lease.hasIncompleteAudio) reference_words=\(expected.count) recognized_words=\(actual.count) word_edits=\(edits) head_present=\(head) tail_present=\(tail) partials=\(partials) microphone=not-opened clipboard=untouched")
                if diagnostics {
                    report("LOCAL_SPEECH_TRANSPORT_DIAGNOSTICS recognized_text_sha256=\(digest(recognized)) recognized_words_sha256=\(digest(actual.joined(separator: " "))) partial_snapshots_sha256=\(snapshots.digest) nonempty_snapshots=\(snapshots.nonemptySnapshots) nonempty_updates=\(snapshots.nonemptyUpdates) nonprefix_revisions=\(snapshots.revisions)")
                }
                guard submitted == file.length, !lease.hasIncompleteAudio,
                      Double(edits) / Double(max(1, expected.count)) <= 0.06, head, tail else { throw CleanupFailure.unavailable }
                await decoder.cleanup(); await LocalSpeechModel.clear()
                return
            }
            throw CleanupFailure.unavailable
        } catch {
            pipeline.cancel(); await decoder.cleanup(); await LocalSpeechModel.clear(); throw error
        }
    }
}

extension LocalSpeechCorpusSmoke {
    /// Real native work is cancelled, then the same prepared-model pool is used
    /// immediately for a new utterance. No microphone or OS text delivery.
    static func runCancellation(audio: URL, vocabulary: [String] = [], diagnostics: Bool = false,
                                restartAudio: URL? = nil, restartReference: URL? = nil) async throws {
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length > 16_000 * 30, file.length < 16_000 * 600 else { throw CleanupFailure.unavailable }
        let pcm = try readAllSamples(file)
        await LocalSpeechModel.warmIfInstalled()
        let decoder = LocalSpeechModel.makeDecoder(vocabulary: vocabulary)
        do {
            try await decoder.loadModel(from: LocalSpeechModel.directory)
            let work = Task { try await decoder.appendAndDecode(.init(buffer: pcm)) }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { work.cancel(); await decoder.cleanup(); _ = try? await work.value; throw error }
            let cancelled = ContinuousClock.now
            work.cancel()
            await decoder.cleanup()
            do { _ = try await work.value; throw CleanupFailure.unavailable }
            catch is CancellationError {}
            let drainedMS = milliseconds(cancelled.duration(to: .now))
            let restart = LocalSpeechModel.makeDecoder(vocabulary: vocabulary)
            do { try await restart.loadModel(from: LocalSpeechModel.directory) }
            catch { await restart.cleanup(); throw error }
            let restartMS = milliseconds(cancelled.duration(to: .now))
            if let restartAudio, let restartReference {
                do {
                    let nextFile = try AVAudioFile(forReading: restartAudio, commonFormat: .pcmFormatFloat32, interleaved: false)
                    guard nextFile.processingFormat.sampleRate == 16_000, nextFile.processingFormat.channelCount == 1 else { throw CleanupFailure.unavailable }
                    let nextPCM = try readAllSamples(nextFile)
                    _ = try await restart.appendAndDecode(.init(buffer: nextPCM))
                    let nextText = try await restart.finish()
                    guard words(nextText) == words(try String(contentsOf: restartReference, encoding: .utf8)) else { throw CleanupFailure.unavailable }
                    report("LOCAL_SPEECH_CANCEL_DIAGNOSTICS restart_transcription_exact=true restart_source_samples=\(nextPCM.frameLength)")
                } catch { await restart.cleanup(); throw error }
            }
            await restart.cleanup()
            await LocalSpeechModel.clear()
            if diagnostics {
                report("LOCAL_SPEECH_CANCEL_DIAGNOSTICS source_samples=\(file.length) read_samples=\(pcm.frameLength) samples_exact=\(Int64(pcm.frameLength) == file.length)")
            }
            report(String(format: "LOCAL_SPEECH_CANCEL passed=true cancelled_result_rejected=true drain_ms=%.3f restart_ready_ms=%.3f microphone=not-opened clipboard=untouched", drainedMS, restartMS))
        } catch {
            await decoder.cleanup(); await LocalSpeechModel.clear(); throw error
        }
    }

    /// AVAudioFile.read may return fewer frames than requested. Assemble the
    /// complete fixed fixture before starting cancellation timing.
    private static func readAllSamples(_ file: AVAudioFile) throws -> AVAudioPCMBuffer {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let destination = pcm.floatChannelData?[0] else { throw CleanupFailure.unavailable }
        var read = 0
        while file.framePosition < file.length {
            let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)!
            try file.read(into: chunk)
            guard chunk.frameLength > 0, let source = chunk.floatChannelData?[0],
                  read + Int(chunk.frameLength) <= Int(pcm.frameCapacity) else { throw CleanupFailure.unavailable }
            destination.advanced(by: read).update(from: source, count: Int(chunk.frameLength))
            read += Int(chunk.frameLength)
        }
        pcm.frameLength = AVAudioFrameCount(read)
        guard Int64(read) == file.length else { throw CleanupFailure.unavailable }
        return pcm
    }
}

private extension LocalSpeechCorpusSmoke {
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func report(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// Hash every ordered partial snapshot with length framing, including empty
    /// and repeated snapshots; the counters describe distinct visible changes.
    struct SnapshotDiagnostics {
        private var hash = SHA256()
        private var previous = ""
        private(set) var nonemptySnapshots = 0
        private(set) var nonemptyUpdates = 0
        private(set) var revisions = 0

        mutating func append(_ snapshot: String) {
            let bytes = Data(snapshot.utf8)
            hash.update(data: Data("\(bytes.count):".utf8))
            hash.update(data: bytes)
            if !snapshot.isEmpty {
                nonemptySnapshots += 1
                if snapshot != previous {
                    nonemptyUpdates += 1
                    if !previous.isEmpty, !snapshot.hasPrefix(previous) { revisions += 1 }
                }
                previous = snapshot
            }
        }

        var digest: String {
            var copy = hash
            return copy.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// The production transport reports a content-free failure event. Preserve the
/// original error only inside this explicit developer runner for propagation.
private actor CorpusSmokeFailure {
    private(set) var error: (any Error)?
    func record(_ error: any Error) { if self.error == nil { self.error = error } }
}

private struct CorpusSmokeReportingDecoder: ParakeetStreamingDecoding {
    let native: any ParakeetStreamingDecoding
    let failures: CorpusSmokeFailure
    func loadModel(from directory: URL) async throws { try await native.loadModel(from: directory) }
    func appendAndDecode(_ input: ParakeetPCMBuffer) async throws -> String {
        do { return try await native.appendAndDecode(input) }
        catch { await failures.record(error); throw error }
    }
    func finish() async throws -> String {
        do { return try await native.finish() }
        catch { await failures.record(error); throw error }
    }
    func cleanup() async { await native.cleanup() }
}
