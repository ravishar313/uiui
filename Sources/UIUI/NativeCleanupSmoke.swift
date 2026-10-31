import AVFoundation
import Darwin
import Foundation
import UIUICore

/// Explicit developer acceptance with synthetic audio, real local models,
/// the production application pipeline and a disposable native paste receiver.
/// It never opens a microphone or logs a prompt, transcript or generated text.
@MainActor
enum NativeCleanupSmoke {
    static func run(shortAudio: URL, shortReference: URL, longAudio: URL, longReference: URL,
                    vocabulary: [String] = [], diagnostics: Bool = false) async throws {
        let loadStarted = ContinuousClock.now
        let engine = MeasuredCleanupEngine()
        do {
            async let speechReady: Void = LocalSpeechModel.warmIfInstalled()
            await engine.prepare()
            await speechReady
            guard engine.isReady else { throw CleanupFailure.unavailable }
            if diagnostics {
                report(String(format: "CLEANUP_FLOW_DIAGNOSTICS models_ready_ms=%.3f", milliseconds(loadStarted.duration(to: .now))))
            }
            reportMemory(stage: "models-ready", diagnostics: diagnostics)
            try await verifyStableTail(engine: engine)
            try await TextDeliveryNativeSmoke.runFlows([
                { target, registration in try await capture(audio: shortAudio, reference: shortReference, target: target, registration: registration, engine: engine, insertPause: false, vocabulary: vocabulary, diagnostics: diagnostics) },
                { target, registration in try await capture(audio: longAudio, reference: longReference, target: target, registration: registration, engine: engine, insertPause: true, vocabulary: vocabulary, diagnostics: diagnostics) }
            ])
            let stats = engine.stats
            guard stats.calls > 0, stats.accepted > 0 else { throw CleanupFailure.unavailable }
            report("CLEANUP_FLOW engine=\(LocalCleanupModel.name) native_calls=\(stats.calls) accepted=\(stats.accepted) not_accepted_attempts=\(stats.calls - stats.accepted) microphone=not-opened network=none")
            reportMemory(stage: "after-flow", diagnostics: diagnostics)
            await engine.shutdown()
            await LocalSpeechModel.clear()
        } catch {
            await engine.shutdown()
            await LocalSpeechModel.clear()
            throw error
        }
    }

    /// Synthetic, explicit timing at the cleanup boundary. No microphone, OS
    /// delivery or user content is involved in either matched case.
    private static func verifyStableTail(engine: MeasuredCleanupEngine) async throws {
        let source = "where should we meet after the product review tomorrow"
        let immediate = DictationCleanup(engine: engine)
        let immediateID = UUID()
        immediate.begin(immediateID)
        immediate.update(source, captureID: immediateID)
        let immediateCalls = engine.stats.calls
        let immediateStart = ContinuousClock.now
        let immediateOutput = try await immediate.finish(source, captureID: immediateID)
        let immediateElapsed = immediateStart.duration(to: .now)
        let immediateFinalCalls = engine.stats.calls - immediateCalls
        immediate.cancel()

        let paused = DictationCleanup(engine: engine)
        defer { paused.cancel() }
        let pausedID = UUID()
        let beforePause = engine.stats
        paused.begin(pausedID)
        paused.update(source, captureID: pausedID)
        let waitLimit = ContinuousClock.now.advanced(by: .seconds(4))
        while engine.stats.completed == beforePause.completed, ContinuousClock.now < waitLimit {
            try await Task.sleep(for: .milliseconds(25))
        }
        // Completion resumes the coordinator on MainActor; yield before testing
        // its cached path, so this measures completed background work.
        await Task.yield()
        let beforeFinish = engine.stats
        guard beforeFinish.completed == beforePause.completed + 1,
              beforeFinish.accepted == beforePause.accepted + 1 else { throw CleanupFailure.unavailable }
        let pausedStart = ContinuousClock.now
        let pausedOutput = try await paused.finish(source, captureID: pausedID)
        let pausedElapsed = pausedStart.duration(to: .now)
        let pausedFinalCalls = engine.stats.calls - beforeFinish.calls
        let exact = immediateOutput == pausedOutput && words(pausedOutput) == words(source)
        guard immediateFinalCalls == 1, pausedFinalCalls == 0, exact,
              pausedOutput.hasSuffix("?") else { throw CleanupFailure.unavailable }
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }
        report(String(format: "CLEANUP_TAIL immediate_finish_ms=%.3f paused_finish_ms=%.3f immediate_final_calls=%d paused_final_calls=%d exact_output=true question_mark=true stable_delay_ms=900", milliseconds(immediateElapsed), milliseconds(pausedElapsed), immediateFinalCalls, pausedFinalCalls))
    }

    private static func capture(audio: URL, reference: URL, target: DeliveryTarget,
                                registration: TextDeliveryNativeSmoke.PayloadRegistration, engine: MeasuredCleanupEngine, insertPause: Bool,
                                vocabulary: [String], diagnostics: Bool) async throws -> String {
        let expected = words(try String(contentsOf: reference, encoding: .utf8))
        let file = try AVAudioFile(forReading: audio)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else { throw CleanupFailure.unavailable }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-cleanup-flow-\(UUID().uuidString)")
        let defaultsName = "uiui-cleanup-flow-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else { throw CleanupFailure.unavailable }
        let cleanup = DictationCleanup(engine: engine)
        let model = AppModel(dataDirectory: root, defaults: defaults,
                             persistSettings: false, delivery: RegisteredFlowDelivery(registration: registration), cleanup: cleanup)
        await model.start(installSystemServices: false)
        let id = UUID(); model.dictationCaptureGeneration = id
        model.settings.speechLocale = "en-IN"
        model.voiceDestination = target
        cleanup.begin(id)
        let decoder = LocalSpeechModel.makeDecoder(vocabulary: vocabulary)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let checkoutStarted = ContinuousClock.now
            try await decoder.loadModel(from: LocalSpeechModel.directory)
            let checkoutMS = milliseconds(checkoutStarted.duration(to: .now))
            let decodingStarted = ContinuousClock.now
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000)!
            silence.frameLength = 4_000
            silence.floatChannelData![0].initialize(repeating: 0, count: 4_000)
            var paused = false
            var partials = 0
            var sourceSamples = 0, submittedSamples = 0, pauseSamples = 0
            var nonemptySnapshots = 0, nonemptyUpdates = 0, revisions = 0
            var previousSnapshot = ""
            var firstPreviewComputeMS: Double?, firstPreviewAudioMS: Double?
            func receive(_ partial: String) {
                if diagnostics, !partial.isEmpty {
                    nonemptySnapshots += 1
                    if firstPreviewComputeMS == nil {
                        firstPreviewComputeMS = milliseconds(decodingStarted.duration(to: .now))
                        firstPreviewAudioMS = Double(submittedSamples) / 16
                    }
                    if partial != previousSnapshot {
                        nonemptyUpdates += 1
                        if !previousSnapshot.isEmpty, !partial.hasPrefix(previousSnapshot) { revisions += 1 }
                    }
                    previousSnapshot = partial
                }
                model.receiveVoicePartial(partial)
            }
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_000) else { throw CleanupFailure.unavailable }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw CleanupFailure.unavailable }
                sourceSamples += Int(buffer.frameLength); submittedSamples += Int(buffer.frameLength)
                let partial = try await decoder.appendAndDecode(.init(buffer: buffer))
                receive(partial); partials += 1
                if insertPause, !paused, file.framePosition >= file.length / 2 {
                    for _ in 0..<40 {
                        submittedSamples += Int(silence.frameLength); pauseSamples += Int(silence.frameLength)
                        let partial = try await decoder.appendAndDecode(.init(buffer: silence))
                        receive(partial)
                    }
                    paused = true
                }
            }
            let samplesExact = sourceSamples == file.length && submittedSamples == sourceSamples + pauseSamples
                && pauseSamples == (insertPause ? 160_000 : 0)
            guard samplesExact else { throw CleanupFailure.unavailable }
            let stopped = ContinuousClock.now
            let recognized = try await decoder.finish()
            let decoded = decodingStarted.duration(to: .now)
            report("CLEANUP_FLOW decode_seconds=\(Double(decoded.components.seconds) + Double(decoded.components.attoseconds) / 1e18)")
            await decoder.cleanup()
            let recognizedWords = words(recognized)
            let edits = wordDistance(expected, recognizedWords)
            let headPresent = Array(recognizedWords.prefix(12)) == Array(expected.prefix(12))
            let tailPresent = Array(recognizedWords.suffix(12)) == Array(expected.suffix(12))
            let errorRate = Double(edits) / Double(max(1, expected.count))
            report("CLEANUP_FLOW recognition_reference_words=\(expected.count) recognized_words=\(recognizedWords.count) word_edits=\(edits) head_present=\(headPresent) tail_present=\(tailPresent)")
            // Recognition accuracy and cleanup fidelity are different boundaries.
            // A long natural-language fixture may have an ASR substitution, but
            // may not lose its beginning/end or large portions. Every recognized
            // lexical token must then survive cleanup, checked exactly below.
            guard headPresent, tailPresent, insertPause ? errorRate <= 0.05 : edits == 0 else { throw CleanupFailure.unavailable }
            model.voiceFinishedAt = DispatchTime.now().uptimeNanoseconds
            model.voice.onCommand?(recognized)
            guard let work = model.voiceActionTask else { throw CleanupFailure.unavailable }
            await work.value
            let output = model.lastTypedText
            let wordsRetained = words(output) == recognizedWords
            let historyMatches = model.items.first?.body == output
            if model.dictationDeliveryIssue != nil || model.dictationFeedback?.state != .information || !wordsRetained || !historyMatches {
                report("CLEANUP_FLOW delivery_issue=\(model.dictationDeliveryIssue ?? "none") receipt=\(String(describing: model.dictationFeedback?.state)) words_retained=\(wordsRetained) history_matches=\(historyMatches)")
                throw CleanupFailure.unavailable
            }
            let elapsed = stopped.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if diagnostics {
                report(String(format: "CLEANUP_FLOW_DIAGNOSTICS checkout_ms=%.3f first_preview_compute_ms=%.3f first_preview_audio_ms=%.3f nonempty_snapshots=%d nonempty_updates=%d nonprefix_revisions=%d", checkoutMS, firstPreviewComputeMS ?? -1, firstPreviewAudioMS ?? -1, nonemptySnapshots, nonemptyUpdates, revisions))
                report("CLEANUP_FLOW_DIAGNOSTICS source_samples=\(file.length) read_source_samples=\(sourceSamples) submitted_samples=\(submittedSamples) inserted_pause_samples=\(pauseSamples) samples_exact=\(samplesExact)")
            }
            report(String(format: "CLEANUP_FLOW audio_seconds=%.3f stop_to_flow_complete_ms=%.3f", Double(file.length) / 16_000 + (paused ? 10 : 0), seconds * 1_000))
            report("CLEANUP_FLOW source_words=\(recognizedWords.count) output_words=\(words(output).count) all_recognized_words_retained=true partial_buffers=\(partials) inserted_pause=\(paused) question_mark=\(output.hasSuffix("?")) original_recoverable=\(output == recognized || model.items.first?.rawText == recognized)")
            return output
        } catch { await decoder.cleanup(); throw error }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func wordDistance(_ expected: [String], _ actual: [String]) -> Int {
        var row = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: actual.count)
            for (j, heard) in actual.enumerated() {
                next[j + 1] = min(row[j + 1] + 1, next[j] + 1, row[j] + (word == heard ? 0 : 1))
            }
            row = next
        }
        return row.last ?? expected.count
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func report(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private static func reportMemory(stage: String, diagnostics: Bool) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS { report("CLEANUP_FLOW memory_stage=\(stage) resident_bytes=\(info.resident_size)") }
        guard diagnostics else { return }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        if vmStatus == KERN_SUCCESS {
            // The ledger peak is an independent high-water mark, never added to
            // phys_footprint (which already includes the task's accounted memory).
            report("CLEANUP_FLOW_DIAGNOSTICS memory_stage=\(stage) resident_bytes=\(vm.resident_size) resident_peak_bytes=\(vm.resident_size_peak) physical_footprint_bytes=\(vm.phys_footprint) physical_footprint_peak_bytes=\(vm.ledger_phys_footprint_peak)")
        } else {
            report("CLEANUP_FLOW_DIAGNOSTICS memory_stage=\(stage) task_vm_info_status=\(vmStatus)")
        }
    }
}

private final class MeasuredCleanupEngine: CleanupGenerating, @unchecked Sendable {
    private let native: any CleanupGenerating = LocalCleanupModel.makeEngine()
    private let lock = NSLock()
    private var calls = 0
    private var accepted = 0
    private var completed = 0
    var isReady: Bool { native.isReady }
    var stats: (calls: Int, accepted: Int, completed: Int) { lock.withLock { (calls, accepted, completed) } }
    func prepare() async { await native.prepare() }
    func release() {} // The smoke owns this shared model through both captures.
    func shutdown() async { await native.shutdown() }
    func generate(_ text: String, cancellation: CleanupCancellation) async throws -> String {
        lock.withLock { calls += 1 }
        defer { lock.withLock { completed += 1 } }
        let result = try await native.generate(text, cancellation: cancellation)
        if DictationCleanupText.accepted(result, for: text) != nil { lock.withLock { accepted += 1 } }
        return result
    }
    deinit { native.release() }
}


@MainActor
private final class RegisteredFlowDelivery: TextDelivering {
    private let native = TextDelivery()
    private let registration: TextDeliveryNativeSmoke.PayloadRegistration
    init(registration: TextDeliveryNativeSmoke.PayloadRegistration) { self.registration = registration }
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        do { try registration.willDeliver(text) }
        catch { return .held("The clipboard changed during the test. Delivery was cancelled.") }
        return await native.deliver(text, to: target)
    }
    func cancel() { native.cancel() }
}
