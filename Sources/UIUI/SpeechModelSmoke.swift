import AVFoundation
import FluidAudio
import Foundation

/// Historical Parakeet baseline only; product checks use LocalSpeechCorpusSmoke.
/// Developer-only, microphone-free validation using an explicitly supplied
/// synthetic fixture. Never prints the audio, reference or recognized words.
enum SpeechModelSmoke {
    /// Compares an immediate explicit stop with valid silent right context.
    /// The ordinary long-form check intentionally contains a pause and cannot
    /// diagnose a short utterance whose first result arrives only at finish.
    static func runShort(audioURL: URL, referenceURL: URL) async throws {
        ParakeetSpeechModel.configureLibraryLogging()
        guard ParakeetSpeechModel.isInstalled else {
            throw SpeechCaptureFailure.message("Prepare Speech before running the local model check.")
        }
        let expected = words(try String(contentsOf: referenceURL, encoding: .utf8))
        let file = try AVAudioFile(forReading: audioURL)
        let audioSeconds = Double(file.length) / file.processingFormat.sampleRate
        let pool = ParakeetModelPool.shared
        let tailFrames = ParakeetSpeechModel.config.chunkSamples + ParakeetSpeechModel.config.rightSamples
        var paddedMatches = false
        for paddingFrames in [0, tailFrames] {
            try Task.checkCancellation()
            file.framePosition = 0
            let loadStart = Date()
            let manager = try await pool.checkOut()
            let loadSeconds = Date().timeIntervalSince(loadStart)
            do {
                let decodeStart = Date()
                let capacity = AVAudioFrameCount(max(1, file.processingFormat.sampleRate * 0.25))
                var maximumPartialWords = 0
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                        throw SpeechCaptureFailure.message("Cannot allocate the synthetic speech buffer.")
                    }
                    try file.read(into: buffer)
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()
                    _ = await manager.consumeTokenTimings()
                    maximumPartialWords = max(maximumPartialWords, words(await manager.getPartialTranscript()).count)
                }
                let finishStart = Date()
                if paddingFrames > 0 {
                    guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                          let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(paddingFrames)) else {
                        throw SpeechCaptureFailure.message("Cannot allocate the synthetic finalization context.")
                    }
                    silence.frameLength = AVAudioFrameCount(paddingFrames)
                    silence.floatChannelData![0].initialize(repeating: 0, count: paddingFrames)
                    try await manager.appendAudio(silence)
                }
                let actual = words(try await manager.finish())
                _ = await manager.consumeTokenTimings()
                let finishSeconds = Date().timeIntervalSince(finishStart)
                let decodeSeconds = Date().timeIntervalSince(decodeStart)
                await pool.checkIn(manager)
                if paddingFrames > 0 { paddedMatches = actual == expected }
                let paddingMilliseconds = paddingFrames * 1000 / ParakeetSpeechModel.config.sampleRate
                print(String(format: "SPEECH_SHORT_SMOKE tail_ms=%d audio_seconds=%.3f load_seconds=%.3f decode_seconds=%.3f finish_seconds=%.3f", paddingMilliseconds, audioSeconds, loadSeconds, decodeSeconds, finishSeconds))
                print("SPEECH_SHORT_SMOKE tail_ms=\(paddingMilliseconds) reference_words=\(expected.count) result_words=\(actual.count) max_partial_words=\(maximumPartialWords) normalized_match=\(actual == expected) microphone=not-opened")
            } catch {
                await pool.checkIn(manager)
                await pool.clear()
                throw error
            }
        }
        // Exercise the application's actual adapter as a third, independent
        // lease. A helper-only comparison must not stand in for production wiring.
        let decoder = NativeParakeetStreamingDecoder()
        do {
            file.framePosition = 0
            let loadStart = Date()
            try await decoder.loadModel(from: ParakeetSpeechModel.directory)
            let loadSeconds = Date().timeIntervalSince(loadStart)
            let decodeStart = Date()
            let capacity = AVAudioFrameCount(max(1, file.processingFormat.sampleRate * 0.25))
            var maximumPartialWords = 0
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                    throw SpeechCaptureFailure.message("Cannot allocate the synthetic speech buffer.")
                }
                try file.read(into: buffer)
                let partial = try await decoder.appendAndDecode(.init(buffer: buffer))
                maximumPartialWords = max(maximumPartialWords, words(partial).count)
            }
            let finishStart = Date()
            let actual = words(try await decoder.finish())
            let finishSeconds = Date().timeIntervalSince(finishStart)
            let decodeSeconds = Date().timeIntervalSince(decodeStart)
            await decoder.cleanup()
            await pool.clear()
            print(String(format: "SPEECH_SHORT_SMOKE path=production audio_seconds=%.3f load_seconds=%.3f decode_seconds=%.3f finish_seconds=%.3f", audioSeconds, loadSeconds, decodeSeconds, finishSeconds))
            print("SPEECH_SHORT_SMOKE path=production reference_words=\(expected.count) result_words=\(actual.count) max_partial_words=\(maximumPartialWords) normalized_match=\(actual == expected) microphone=not-opened")
            guard paddedMatches, actual == expected else {
                throw SpeechCaptureFailure.message("The synthetic short speech finalization did not match its reference.")
            }
        } catch {
            await decoder.cleanup()
            await pool.clear()
            throw error
        }
    }

    static func run(audioURL: URL, referenceURL: URL) async throws {
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        guard ParakeetSpeechModel.isInstalled else {
            throw SpeechCaptureFailure.message("Prepare Speech before running the local model check.")
        }
        let reference = try String(contentsOf: referenceURL, encoding: .utf8)
        let file = try AVAudioFile(forReading: audioURL)
        let loadStart = Date()
        let pool = ParakeetModelPool.shared
        let manager = try await pool.checkOut()
        let loadSeconds = Date().timeIntervalSince(loadStart)
        do {
            let decodeStart = Date()
            let capacity = AVAudioFrameCount(max(1, file.processingFormat.sampleRate * 0.25))
            var partials = 0
            var maximumPartialWords = 0
            var insertedPause = false
            var firstPartialAudioSeconds: Double?
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                    throw SpeechCaptureFailure.message("Cannot allocate the synthetic speech buffer.")
                }
                try file.read(into: buffer)
                try await manager.appendAudio(buffer)
                try await manager.processBufferedAudio()
                _ = await manager.consumeTokenTimings()
                let partial = await manager.getPartialTranscript()
                let count = words(partial).count
                if count > 0, firstPartialAudioSeconds == nil {
                    firstPartialAudioSeconds = Double(file.framePosition) / file.processingFormat.sampleRate
                }
                if count > maximumPartialWords { partials += 1; maximumPartialWords = count }
                if !insertedPause, file.framePosition >= file.length / 2 {
                    // A ten-second pause must remain an ordinary part of the
                    // same stream, without resetting the transcript or decoder.
                    let silentFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                    let silence = AVAudioPCMBuffer(pcmFormat: silentFormat, frameCapacity: 4_000)!
                    silence.frameLength = 4_000
                    silence.floatChannelData![0].initialize(repeating: 0, count: 4_000)
                    for _ in 0..<40 {
                        try await manager.appendAudio(silence)
                        try await manager.processBufferedAudio()
                        _ = await manager.consumeTokenTimings()
                    }
                    insertedPause = true
                }
            }
            let finishStart = Date()
            let final = try await manager.finish()
            _ = await manager.consumeTokenTimings()
            let finishSeconds = Date().timeIntervalSince(finishStart)
            let decodeSeconds = Date().timeIntervalSince(decodeStart)
            await pool.checkIn(manager)
            let cachedStart = Date()
            let reused = try await pool.checkOut()
            let cachedSeconds = Date().timeIntervalSince(cachedStart)
            let sameModel = manager === reused
            file.framePosition = 0
            let shortCapacity = AVAudioFrameCount(file.processingFormat.sampleRate * 8)
            let shortInput = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: shortCapacity)!
            try file.read(into: shortInput)
            try await reused.appendAudio(shortInput)
            try await reused.processBufferedAudio()
            _ = await reused.consumeTokenTimings()
            let resetWords = words(try await reused.finish())
            _ = await reused.consumeTokenTimings()
            let resetClean = !resetWords.isEmpty && resetWords.count < words(reference).count / 2
                && !contains(Array(words(reference).suffix(12)), in: resetWords)
            await pool.checkIn(reused)
            await pool.clear()
            let expected = words(reference), actual = words(final)
            let head = Array(expected.prefix(12)), tail = Array(expected.suffix(12))
            let headPresent = contains(head, in: actual)
            let tailPresent = contains(tail, in: actual)
            let audioSeconds = Double(file.length) / file.processingFormat.sampleRate + 10
            let errorRate = Double(distance(expected, actual)) / Double(max(1, expected.count))
            print(String(format: "SPEECH_SMOKE engine=ParakeetUnified tier=1120ms audio_seconds=%.2f load_seconds=%.3f decode_seconds=%.3f finish_seconds=%.3f wer=%.4f", audioSeconds, loadSeconds, decodeSeconds, finishSeconds, errorRate))
            print(String(format: "SPEECH_SMOKE cached_checkout_seconds=%.6f reused_loaded_model=%@ reused_state_reset=%@", cachedSeconds, sameModel ? "true" : "false", resetClean ? "true" : "false"))
            print("SPEECH_SMOKE reference_words=\(expected.count) result_words=\(actual.count) partial_updates=\(partials) max_partial_words=\(maximumPartialWords) first_partial_audio_seconds=\(firstPartialAudioSeconds ?? -1) head_present=\(headPresent) tail_present=\(tailPresent) inserted_pause_seconds=10 microphone=not-opened")
            guard headPresent, tailPresent, actual.count >= expected.count / 2, sameModel, resetClean else {
                throw SpeechCaptureFailure.message("Synthetic long-form check did not preserve the expected beginning and ending.")
            }
        } catch { await manager.cleanup(); await pool.clear(); throw error }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    private static func contains(_ target: [String], in source: [String]) -> Bool {
        guard !target.isEmpty, source.count >= target.count else { return false }
        return (0...(source.count - target.count)).contains { Array(source[$0..<($0 + target.count)]) == target }
    }
    private static func distance(_ reference: [String], _ hypothesis: [String]) -> Int {
        var row = Array(0...hypothesis.count)
        for (i, word) in reference.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: hypothesis.count)
            for (j, heard) in hypothesis.enumerated() {
                next[j + 1] = min(row[j + 1] + 1, next[j] + 1, row[j] + (word == heard ? 0 : 1))
            }
            row = next
        }
        return row.last ?? reference.count
    }
}
