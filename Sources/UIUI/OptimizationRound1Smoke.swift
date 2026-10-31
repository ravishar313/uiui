import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import UIUICore

/// Explicit local developer runner for public fixtures only. Production model,
/// formatting, guard, application and persistence owners remain unchanged.
/// Output may contain public fixture text; no existing library is ever opened.
@MainActor
enum OptimizationRound1Smoke {
    private struct TextFixture: Decodable { let id: String; let source: String; let reference: String }
    private struct AudioFixture: Decodable {
        let id: String
        let audio_path: String
        let samples: Int
        let sha256: String
        let reference: String
        let vocabulary: [String]?
    }

    static func runTextCorpus(manifest: URL, output: URL) async throws {
        let cases: [TextFixture] = try read(manifest)
        guard !cases.isEmpty, cases.count <= 5_000, Set(cases.map(\.id)).count == cases.count,
              cases.allSatisfy({ !$0.id.isEmpty && $0.source.utf8.count <= 128_000 }) else { throw CleanupFailure.unavailable }
        let journal = try Round1Journal(output)
        defer { journal.close() }
        let engine = Round1CleanupEngine()
        let cleanup = DictationCleanup(engine: engine)
        let start = ContinuousClock.now
        await engine.prepare()
        guard engine.isReady else { await engine.shutdown(); throw CleanupFailure.unavailable }
        do {
            try journal.emit(["event": "ready", "mode": "text", "cleanup": LocalCleanupModel.name,
                              "prepare_ms": ms(start.duration(to: .now)), "memory": memory(),
                              "speech_resident": false, "microphone": "not-opened", "delivery": "none"])
            try phase("ready", journal: journal)
            for fixture in cases {
                try Task.checkCancellation()
                let previous = engine.stats
                let id = UUID()
                cleanup.begin(id)
                let started = ContinuousClock.now
                // Match the production immediate-stop path with its real final
                // budget, segmentation, acceptance guard and punctuation owner.
                let result = try await cleanup.finish(fixture.source, captureID: id)
                let elapsed = ms(started.duration(to: .now))
                let stats = engine.stats.subtracting(previous)
                var row = stats.fields
                row.merge(["event": "text_quality", "id": fixture.id,
                           "output": result, "pre_vocabulary_output": result,
                           "dictionary_changed_output": false, "elapsed_ms": elapsed,
                           "word_sequence_preserved": words(fixture.source) == words(result),
                           "model_proposal_is_whole_source": stats.calls == 1 && stats.lastSource == fixture.source,
                           "formatter": "production-DictationCleanup+DictationPunctuation",
                           "final_budget_ms": 600], uniquingKeysWith: { _, new in new })
                if let proposal = stats.lastCandidate { row["model_proposal"] = proposal }
                try journal.emit(row)
            }
            try journal.emit(["event": "complete", "mode": "text", "cases": cases.count,
                              "memory": memory(), "elapsed_ms": ms(start.duration(to: .now))])
            try phase("after", journal: journal)
            cleanup.cancel()
            await engine.shutdown()
        } catch { cleanup.cancel(); await engine.shutdown(); throw error }
    }

    static func runAudioFlow(manifest: URL, output: URL, pace: Bool, renderUI: Bool) async throws {
        guard #available(macOS 15.0, *) else { throw CleanupFailure.unavailable }
        let cases: [AudioFixture] = try read(manifest)
        guard !cases.isEmpty, cases.count <= 500, Set(cases.map(\.id)).count == cases.count,
              cases.allSatisfy({ $0.samples > 0 && $0.samples <= 16_000 * 600 && $0.sha256.count == 64 }) else { throw CleanupFailure.unavailable }
        let journal = try Round1Journal(output)
        defer { journal.close() }
        let engine = Round1CleanupEngine()
        let cleanup = DictationCleanup(engine: engine)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-round1-public-\(UUID().uuidString)", isDirectory: true)
        let suite = "uiui-round1-public-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CleanupFailure.unavailable }
        defaults.removePersistentDomain(forName: suite)
        let delivery = Round1ReceiptDelivery()
        let capture = Round1VoiceCapture()
        let voice = TriggeredVoice(capture: capture)
        let model = AppModel(dataDirectory: root, defaults: defaults,
                             persistSettings: false, delivery: delivery, cleanup: cleanup, voice: voice)
        // The default trigger resolves an OS destination. The receipt fixture
        // deliberately owns no OS destination and never calls that callback.
        voice.onTrigger = {}
        var views: [NSView] = []
        defer {
            model.shutdown()
            views.removeAll()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await model.start(installSystemServices: false)
        guard model.repository != nil else { throw CleanupFailure.unavailable }
        model.settings.speechLocale = "en-IN"
        model.settings.saveDictationHistory = true
        let notchOnly = renderUI && CommandLine.arguments.contains("--optimization-round1-notch-only")
        let uiScope = !renderUI ? "none" : notchOnly ? "offscreen-NSHostingView-NotchView"
            : "offscreen-NSHostingViews-LibraryView+NotchView"
        if renderUI {
            if !notchOnly {
                let home = NSHostingView(rootView: LibraryView(model: model))
                home.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
                views.append(home)
            }
            let notch = NSHostingView(rootView: NotchView(model: model, expanded: true, onExpand: {}, onCollapse: {}))
            notch.frame = NSRect(x: 0, y: 0, width: 600, height: 190)
            views.append(notch)
            for view in views { view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
        }
        let preparation = ContinuousClock.now
        async let speechReady: Void = LocalSpeechModel.warmIfInstalled()
        await engine.prepare()
        await speechReady
        guard engine.isReady else { await engine.shutdown(); await LocalSpeechModel.clear(); throw CleanupFailure.unavailable }
        do {
            // warmIfInstalled intentionally swallows setup failure in the app.
            // Validate a real checkout before claiming both models are ready.
            let readyDecoder = LocalSpeechModel.makeDecoder(vocabulary: cases.first?.vocabulary ?? [])
            do { try await readyDecoder.loadModel(from: LocalSpeechModel.directory) }
            catch { await readyDecoder.cleanup(); throw error }
            await readyDecoder.cleanup()
            try journal.emit(["event": "ready", "mode": "audio-flow", "cleanup": LocalCleanupModel.name,
                              "asr": LocalSpeechModel.name, "models_ready_ms": ms(preparation.duration(to: .now)),
                              "memory": memory(), "speech_resident": true, "cleanup_resident": true,
                              "ui": uiScope,
                              "preview_publication": "changed-snapshot-only-initial-previous-empty",
                              "ui_layout_schedule": "initial-plus-published-preview-changes",
                              "visible_compositor": "unmeasured", "microphone": "not-opened",
                              "delivery": "non-OS-receipt-stub", "system_services": false])
            try phase("ready", journal: journal)
            for (index, fixture) in cases.enumerated() {
                try Task.checkCancellation()
                let audio = fixture.audio_path.hasPrefix("/") ? URL(fileURLWithPath: fixture.audio_path)
                    : manifest.deletingLastPathComponent().appendingPathComponent(fixture.audio_path)
                guard digest(try Data(contentsOf: audio)) == fixture.sha256 else { throw CleanupFailure.unavailable }
                let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard file.length == fixture.samples, file.processingFormat.sampleRate == 16_000,
                      file.processingFormat.channelCount == 1 else { throw CleanupFailure.unavailable }
                let id = UUID()
                model.dictationCaptureGeneration = id
                model.dictationDeliveryStartedFor = nil
                model.voiceInputKind = .dictation
                model.voiceDestination = nil
                cleanup.begin(id)
                let callsBefore = engine.stats
                let receiptsBefore = delivery.payloads.count
                let historyBefore = Set(model.items.map(\.id))
                let dictationStart = ContinuousClock.now
                // Inject only the capture hardware boundary; actual TriggeredVoice
                // observation and AppModel callbacks own preview/final/history.
                try await voice.start(locale: "en-IN", contextualStrings: fixture.vocabulary ?? [])
                let decoder = Round1SpeechDecoder(native: LocalSpeechModel.makeDecoder(vocabulary: fixture.vocabulary ?? []))
                do {
                    try await decoder.loadModel(from: LocalSpeechModel.directory)
                    let dictationPrepareMS = ms(dictationStart.duration(to: .now))
                    let decodeStart = ContinuousClock.now
                    var rawUpdates = Round1SnapshotDigest()
                    var firstPreviewMS: Double?
                    func receive(_ text: String) {
                        rawUpdates.append(text)
                        if !text.isEmpty, firstPreviewMS == nil { firstPreviewMS = ms(decodeStart.duration(to: .now)) }
                        capture.onPartial?(text)
                        if renderUI { for view in views { view.layoutSubtreeIfNeeded() } }
                    }
                    let decoded = try await decode(file: file, decoder: decoder, pace: pace,
                                                   receive: receive, stop: { voice.finish(userInitiated: true) })
                    let finalResultAt = ContinuousClock.now
                    capture.onCompletion?(SpeechCompletion(text: decoded.text, reason: .final, wasExplicitlyStopped: true))
                    if let work = model.voiceActionTask { await work.value }
                    let stopMS = ms(decoded.stoppedAt.duration(to: .now))
                    let finalResultToFlowMS = ms(finalResultAt.duration(to: .now))
                    let nonempty = !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let outputText = nonempty ? model.lastTypedText : ""
                    let newHistory = model.items.filter { !historyBefore.contains($0.id) }
                    let payloads = Array(delivery.payloads.dropFirst(receiptsBefore))
                    let receiptExact = nonempty ? payloads == [outputText] : payloads.isEmpty
                    let historyExact = nonempty ? newHistory.count == 1 && newHistory.first?.body == outputText : newHistory.isEmpty
                    let retained = !nonempty || words(outputText) == words(decoded.text)
                    let originalRecoverable = !nonempty || outputText == decoded.text || newHistory.first?.rawText == decoded.text
                    let actualWords = words(decoded.text), expectedWords = words(fixture.reference)
                    let head = Array(actualWords.prefix(12)) == Array(expectedWords.prefix(12))
                    let tail = Array(actualWords.suffix(12)) == Array(expectedWords.suffix(12))
                    let stats = engine.stats.subtracting(callsBefore)
                    var row = stats.fields
                    row.merge(["event": "audio_flow", "id": fixture.id, "first_dictation": index == 0,
                               "pacing": pace ? "independent-realtime-producer-production-transport" : "accelerated-serial-decoder",
                               "dictation_prepare_ms": dictationPrepareMS, "stop_to_flow_complete_ms": stopMS,
                               "final_result_to_flow_complete_ms": finalResultToFlowMS,
                               "decode_ms": ms(decodeStart.duration(to: .now)),
                               "source_samples": fixture.samples, "submitted_samples": decoded.samples,
                               "samples_exact": decoded.samples == fixture.samples, "transport_incomplete": decoded.incomplete,
                               "recognized_text_sha256": digest(Data(decoded.text.utf8)),
                               "recognized_words_sha256": digest(Data(actualWords.joined(separator: " ").utf8)),
                               "raw_snapshots_sha256": decoder.snapshots.digest,
                               "raw_snapshots": decoder.snapshots.count,
                               "raw_snapshot_sha256": decoder.snapshots.hashes,
                               "published_raw_updates_sha256": rawUpdates.digest,
                               "published_raw_update_sha256": rawUpdates.hashes,
                               "published_raw_updates": rawUpdates.count,
                               "cleaned_partial_updates": "production-AppModel-does-not-publish-cleaned-partials",
                               "cleaned_final_sha256": digest(Data(outputText.utf8)),
                               "reference_words": expectedWords.count, "recognized_words": actualWords.count,
                               "word_edits": distance(expectedWords, actualWords), "head_present": head, "tail_present": tail,
                               "all_recognized_words_retained": retained, "original_recoverable": originalRecoverable,
                               "stub_payload_count": payloads.count, "stub_exact_payload": receiptExact,
                               "history_exact": historyExact, "new_history_count": newHistory.count,
                               "memory": memory(), "microphone": "not-opened", "clipboard": "untouched"],
                              uniquingKeysWith: { _, new in new })
                    if let firstPreviewMS { row["first_preview_after_ready_ms"] = firstPreviewMS }
                    try journal.emit(row)
                    guard decoded.samples == fixture.samples, !decoded.incomplete, retained, originalRecoverable,
                          receiptExact, historyExact else { throw CleanupFailure.unavailable }
                    await decoder.cleanup()
                } catch { await decoder.cleanup(); throw error }
            }
            try journal.emit(["event": "complete", "mode": "audio-flow", "cases": cases.count, "memory": memory(),
                              "speech_resident": true, "cleanup_resident": true])
            try phase("after", journal: journal)
            await engine.shutdown()
            await LocalSpeechModel.clear()
        } catch { await engine.shutdown(); await LocalSpeechModel.clear(); throw error }
    }

    private static func decode(file: AVAudioFile, decoder: Round1SpeechDecoder, pace: Bool,
                               receive: (String) -> Void, stop: () -> Void) async throws -> (text: String, samples: Int, incomplete: Bool, stoppedAt: ContinuousClock.Instant) {
        if !pace {
            var submitted = 0
            // Match ParakeetRecognitionPipeline exactly: initial empty and
            // repeated snapshots are suppressed; a change to empty is emitted.
            // Round1SpeechDecoder still hashes every native append snapshot.
            var previous = ""
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_280) else { throw CleanupFailure.unavailable }
                try file.read(into: pcm)
                guard pcm.frameLength > 0 else { throw CleanupFailure.unavailable }
                submitted += Int(pcm.frameLength)
                let snapshot = try await decoder.appendAndDecode(.init(buffer: pcm))
                if snapshot != previous {
                    previous = snapshot
                    receive(snapshot)
                }
            }
            let stoppedAt = ContinuousClock.now
            stop()
            return (try await decoder.finish(), submitted, false, stoppedAt)
        }
        let lease = SpeechAudioLease()
        let pair = AsyncStream<Round1RecognitionMessage>.makeStream()
        let pipeline = ParakeetRecognitionPipeline(decoder: decoder, lease: lease,
                                                   onRecognition: { pair.continuation.yield(.recognition($0)) })
        pipeline.start()
        let start = ContinuousClock.now
        let stopMarker = Round1StopMarker()
        let feeder = Task.detached(priority: .userInitiated) {
            do {
                var submitted = 0
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_280) else { throw CleanupFailure.unavailable }
                    try file.read(into: pcm)
                    guard pcm.frameLength > 0 else { throw CleanupFailure.unavailable }
                    submitted += Int(pcm.frameLength)
                    pipeline.append(.init(buffer: pcm))
                    try await Task.sleep(until: start.advanced(by: .nanoseconds(Int64(submitted) * 1_000_000_000 / 16_000)), clock: .continuous)
                }
                stopMarker.mark()
                pair.continuation.yield(.stopped)
                pipeline.finishInput()
                return submitted
            } catch { pipeline.fail(); throw error }
        }
        defer { feeder.cancel(); pipeline.cancel(); pair.continuation.finish() }
        for await message in pair.stream {
            if case .stopped = message { stop(); continue }
            guard case .recognition(let event) = message else { continue }
            if event.failed || event.incomplete { throw CleanupFailure.unavailable }
            if event.isFinal {
                let submitted = try await feeder.value
                guard let stoppedAt = stopMarker.instant else { throw CleanupFailure.unavailable }
                return (event.text ?? "", submitted, lease.hasIncompleteAudio, stoppedAt)
            }
            receive(event.text ?? "")
        }
        throw CleanupFailure.unavailable
    }

    /// Optional external footprint sampling handshake. Explicit environment
    /// opt-in only; regular benchmark execution never waits for stdin.
    private static func phase(_ stage: String, journal: Round1Journal) throws {
        guard ProcessInfo.processInfo.environment["UIUI_ROUND1_PHASE_ACK"] == "1" else { return }
        try journal.flush()
        print("ROUND1_PHASE \(stage)")
        fflush(stdout)
        guard let byte = try FileHandle.standardInput.read(upToCount: 1), byte == Data([10]) else { throw CleanupFailure.unavailable }
    }

    private static func read<T: Decodable>(_ url: URL) throws -> [T] {
        let data = try Data(contentsOf: url)
        guard data.count <= 32 * 1_024 * 1_024 else { throw CleanupFailure.unavailable }
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
    private static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15 }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
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
    private static func memory() -> [String: Any] {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS else { return ["task_vm_info_status": status] }
        var result: [String: Any] = ["resident_bytes": vm.resident_size, "resident_peak_bytes": vm.resident_size_peak,
                "physical_footprint_bytes": vm.phys_footprint, "physical_footprint_peak_bytes": vm.ledger_phys_footprint_peak,
                "scope": "own-task-ledger-not-system-or-child-process-memory"]
        return result
    }
}

private final class Round1Journal {
    private let handle: FileHandle
    init(_ output: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path), FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CleanupFailure.unavailable }
        handle = try FileHandle(forWritingTo: output)
    }
    func emit(_ row: [String: Any]) throws { try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])) }
    func flush() throws { try handle.synchronize() }
    func close() { try? flush(); try? handle.close() }
}

private final class Round1CleanupEngine: CleanupGenerating, @unchecked Sendable {
    struct Stats {
        var calls = 0, completed = 0, accepted = 0, failed = 0
        var lastSource: String?, lastCandidate: String?
        func subtracting(_ old: Self) -> Self { .init(calls: calls - old.calls, completed: completed - old.completed,
            accepted: accepted - old.accepted, failed: failed - old.failed,
            lastSource: calls > old.calls ? lastSource : nil, lastCandidate: calls > old.calls ? lastCandidate : nil) }
        var fields: [String: Any] { ["raw_calls": calls, "raw_completed": completed, "raw_accepted": accepted,
                                    "raw_rejected": completed - accepted, "raw_failed": failed,
                                    "raw_accept_scope": "native-candidate-exact-production-guard-before-coordinator-budget",
                                    "fallback_or_rejected_calls": calls - accepted] }
    }
    private let native = LocalCleanupModel.makeEngine()
    private let lock = NSLock()
    private var counters = Stats()
    var stats: Stats { lock.withLock { counters } }
    var isReady: Bool { native.isReady }
    func prepare() async { await native.prepare() }
    // Shared by the corpus. Individual AppModel shutdown must not unload it.
    func release() {}
    func shutdown() async { await native.shutdown() }
    func generate(_ text: String, cancellation: CleanupCancellation) async throws -> String {
        lock.withLock { counters.calls += 1; counters.lastSource = text; counters.lastCandidate = nil }
        do {
            let result = try await native.generate(text, cancellation: cancellation)
            let accepted = DictationCleanupText.accepted(result, for: text) != nil
            lock.withLock { counters.completed += 1; counters.accepted += accepted ? 1 : 0; counters.lastCandidate = result }
            return result
        } catch { lock.withLock { counters.failed += 1 }; throw error }
    }
    deinit { native.release() }
}

private struct Round1SnapshotDigest {
    private var hash = SHA256()
    private(set) var count = 0
    private(set) var hashes: [String] = []
    mutating func append(_ text: String) {
        let bytes = Data(text.utf8)
        hash.update(data: Data("\(bytes.count):".utf8)); hash.update(data: bytes); count += 1
        hashes.append(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    var digest: String { var copy = hash; return copy.finalize().map { String(format: "%02x", $0) }.joined() }
}

private final class Round1SpeechDecoder: ParakeetStreamingDecoding, @unchecked Sendable {
    private let native: any ParakeetStreamingDecoding
    private let lock = NSLock()
    private var digestState = Round1SnapshotDigest()
    var snapshots: Round1SnapshotDigest { lock.withLock { digestState } }
    init(native: any ParakeetStreamingDecoding) { self.native = native }
    func loadModel(from directory: URL) async throws { try await native.loadModel(from: directory) }
    func appendAndDecode(_ input: ParakeetPCMBuffer) async throws -> String {
        let text = try await native.appendAndDecode(input)
        lock.withLock { digestState.append(text) }
        return text
    }
    func finish() async throws -> String { try await native.finish() }
    func cleanup() async { await native.cleanup() }
}

@MainActor private final class Round1ReceiptDelivery: TextDelivering {
    private(set) var payloads: [String] = []
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult { payloads.append(text); return .pasteSent }
    func cancel() {}
}

/// Only the hardware adapter is substituted. TriggeredVoice still publishes
/// real decoder snapshots and runs its normal final-capture state machine.
@MainActor private final class Round1VoiceCapture: TriggeredVoiceCapture {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onCompletion: ((SpeechCompletion) -> Void)?
    var onError: ((String) -> Void)?
    var onRecovery: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onFinalization: ((Double) -> Void)?
    func requestAuthorization() async -> Bool { true }
    func start(locale: String, contextualStrings: [String]) async throws {}
    func stop() {}
    func cancel() {}
}

private final class Round1StopMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousClock.Instant?
    var instant: ContinuousClock.Instant? { lock.withLock { value } }
    func mark() { lock.withLock { value = .now } }
}

private enum Round1RecognitionMessage: Sendable {
    case recognition(SpeechRecognitionEvent)
    case stopped
}
