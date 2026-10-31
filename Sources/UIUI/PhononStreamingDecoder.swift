import AVFoundation
import Foundation

/// Optional context applied uniformly to decoder input, never to microphone
/// samples or word output. Defaults leave the selected model's PCM unchanged.
struct PhononPCMConditioning: Equatable, Sendable {
    let leadingSilenceFrames: Int
    let trailingSilenceFrames: Int

    init(leadingSilenceFrames: Int = 0, trailingSilenceFrames: Int = 0) {
        self.leadingSilenceFrames = max(0, leadingSilenceFrames)
        self.trailingSilenceFrames = max(0, trailingSilenceFrames)
    }

    func apply(to samples: [Float]) -> [Float] {
        guard leadingSilenceFrames > 0 || trailingSilenceFrames > 0 else { return samples }
        var result = [Float]()
        result.reserveCapacity(leadingSilenceFrames + samples.count + trailingSilenceFrames)
        result.append(contentsOf: repeatElement(0, count: leadingSilenceFrames))
        result.append(contentsOf: samples)
        result.append(contentsOf: repeatElement(0, count: trailingSilenceFrames))
        return result
    }
}

/// Speech probabilities are produced by the recurrent classifier on the same
/// serial model queue as ASR. Only confirmed speech extends decoder input;
/// intermediate confidence permits a bounded hangover before phrase closure.
struct PhononSpeechActivityConfiguration: Sendable {
    var speechThreshold: Float = 0.5
    var negativeThreshold: Float = 0.3
    var prerollFrames = 8_192
    var tailFrames = 3_200
    var quietFrames = 11_200
}

/// Pure phrase bookkeeping, called only on the native model's serial queue.
/// All accepted speech is retained until a successful final decode. Quiet may
/// close one phrase, but the session remains open until explicit finish.
///
/// There is deliberately no 30-second speech cutoff: cutting there could lose
/// a boundary word. An uninterrupted phrase retains PCM and re-decodes its
/// growing prefix using the vendor's long-audio windows. Its memory and preview
/// latency therefore grow with phrase duration; unconfirmed noise is bounded.
final class PhononPhraseSession {
    typealias Transcribe = ([Float]) throws -> String
    typealias SpeechProbability = ([Float]) throws -> Float
    static let classificationFrames = 4_096
    private let transcribe: Transcribe
    private let conditioning: PhononPCMConditioning
    private let checkCancellation: () throws -> Void
    private let speechProbability: SpeechProbability?
    private let activity: PhononSpeechActivityConfiguration
    private var classificationPending: [Float] = []
    private var classifiedSamples = 0
    private var processedSamples = 0
    private var segmentStart = 0
    private var confirmedSpeechEnd: Int?
    private var lastDecodedSpeechEnd = 0
    private var pending: [Float] = []
    private var segment: [Float] = []
    private var voiced = false
    private var lastVoice = 0
    private var peakRMS: Float = 0
    private var peakMagnitude: Float = 0
    private var nextPartial = 5_600
    private var finals: [String] = []
    private var currentHypothesis = ""
    private var finished = false
    private(set) var acceptedSamples = 0
    private(set) var finalizedSamples = 0
    private(set) var discardedQuietSamples = 0

    /// Native production sessions inject the prepared speech classifier. The
    /// nil path preserves isolated legacy tests and decoder-only benchmarks.
    init(conditioning: PhononPCMConditioning = .init(),
         speechProbability: SpeechProbability? = nil,
         activity: PhononSpeechActivityConfiguration = .init(),
         checkCancellation: @escaping () throws -> Void = {},
         transcribe: @escaping Transcribe) {
        self.conditioning = conditioning
        self.speechProbability = speechProbability
        self.activity = activity
        self.checkCancellation = checkCancellation
        self.transcribe = transcribe
    }

    var snapshot: String {
        (finals + (currentHypothesis.isEmpty ? [] : [currentHypothesis])).joined(separator: " ")
    }
    var retainedSamples: Int { segment.count + pending.count }

    func append(_ samples: [Float]) throws -> String {
        try checkCancellation()
        guard !finished else { throw CancellationError() }
        acceptedSamples += samples.count
        pending.append(contentsOf: samples)
        var consumed = 0
        defer { if consumed > 0 { pending.removeFirst(consumed) } }
        while pending.count - consumed >= 800 {
            try checkCancellation()
            let block = pending[consumed..<(consumed + 800)]
            consumed += 800
            try feed(block)
        }
        return snapshot
    }

    func finish() throws -> String {
        try checkCancellation()
        if finished { return finals.joined(separator: " ") }
        // A failed append may leave more than one residual block. Keep the
        // same source cadence as append so a phrase close cannot trim future,
        // still-unclassified speech. Retain the unconsumed suffix on failure.
        var consumed = 0
        do {
            defer { if consumed > 0 { pending.removeFirst(consumed) } }
            while consumed < pending.count {
                try checkCancellation()
                let end = min(pending.count, consumed + 800)
                let block = pending[consumed..<end]
                consumed = end
                try feed(block)
            }
        }
        if let speechProbability {
            // Padding is classifier context only: ASR and source accounting see
            // exactly the original microphone PCM, including a short last word.
            try classifyPendingFrames(using: speechProbability)
            if !classificationPending.isEmpty {
                let count = classificationPending.count
                let frame = classificationPending + [Float](repeating: 0, count: Self.classificationFrames - count)
                _ = try classify(frame, sourceCount: count, using: speechProbability)
                classificationPending.removeAll(keepingCapacity: false)
            }
            if confirmedSpeechEnd != nil { try finalizeSpeech() }
            discardQuiet()
            try checkCancellation()
            finished = true
            return finals.joined(separator: " ")
        }
        // Endpointing is a preview/phrase heuristic, not permission to discard
        // accepted quiet speech. Residual or low-energy nonzero PCM still gets
        // an explicit-stop decode even if no block passed the RMS gate.
        if voiced || peakMagnitude >= 0.0001 { try finalize() }
        else { discardQuiet() }
        try checkCancellation()
        finished = true
        return finals.joined(separator: " ")
    }

    private func feed(_ block: ArraySlice<Float>) throws {
        guard !block.isEmpty else { return }
        if let speechProbability {
            try feedSpeechActivity(block, using: speechProbability)
            return
        }
        segment.append(contentsOf: block)
        var squareSum: Float = 0
        for sample in block {
            squareSum += sample * sample
            peakMagnitude = max(peakMagnitude, abs(sample))
        }
        let rms = (squareSum / Float(block.count)).squareRoot()
        peakRMS = max(peakRMS, rms)
        if rms > max(0.0001, 0.18 * peakRMS) {
            voiced = true
            lastVoice = segment.count
        }
        if voiced && segment.count - lastVoice >= 11_200 {
            try finalize()
        } else if !voiced && peakMagnitude < 0.0001 && segment.count >= 480_000 {
            let keep = Array(segment.suffix(16_000))
            discardedQuietSamples += segment.count - keep.count
            resetSegment()
            segment = keep
        } else if voiced && segment.count >= nextPartial {
            let text = try decode()
            // A transient empty preview must not erase the last hypothesis.
            if !text.isEmpty { currentHypothesis = text }
            nextPartial = segment.count + 8_000
        }
    }

    private func feedSpeechActivity(_ block: ArraySlice<Float>, using classifySpeech: SpeechProbability) throws {
        segment.append(contentsOf: block)
        processedSamples += block.count
        classificationPending.append(contentsOf: block)
        try classifyPendingFrames(using: classifySpeech)
        if let end = confirmedSpeechEnd {
            // A preview needs new confirmed speech. Additional room noise alone
            // cannot repeatedly grow or revise the recognized words.
            if segment.count >= nextPartial && end > lastDecodedSpeechEnd {
                let text = try decodeSpeech()
                if !text.isEmpty { currentHypothesis = text }
                lastDecodedSpeechEnd = end
                nextPartial = segment.count + 8_000
            }
        } else {
            // Keep the current classifier window plus bounded context before it
            // so the first positive decision retains the opening syllables.
            trimUnconfirmedPrefix(keeping: activity.prerollFrames + Self.classificationFrames)
        }
    }

    private func classifyPendingFrames(using classifySpeech: SpeechProbability) throws {
        while classificationPending.count >= Self.classificationFrames {
            let frame = Array(classificationPending.prefix(Self.classificationFrames))
            let probability = try classify(frame, sourceCount: Self.classificationFrames, using: classifySpeech)
            classificationPending.removeFirst(Self.classificationFrames)
            // Consume a successful classifier decision before final ASR. A
            // failed final decode may retry without classifying that frame twice.
            if let end = confirmedSpeechEnd {
                let quiet = classifiedSamples - end
                // An intermediate score can delay closure by one classifier
                // window, but cannot grow the decoded tail or hold PCM forever.
                if quiet >= activity.quietFrames &&
                    (probability < activity.negativeThreshold || quiet >= activity.quietFrames + Self.classificationFrames) {
                    try finalizeSpeech()
                }
            }
        }
    }

    private func classify(_ frame: [Float], sourceCount: Int, using classifySpeech: SpeechProbability) throws -> Float {
        try checkCancellation()
        let probability = try classifySpeech(frame)
        try checkCancellation()
        guard probability.isFinite else {
            throw SpeechCaptureFailure.message("The speech activity classifier returned an invalid probability.")
        }
        let frameStart = classifiedSamples
        classifiedSamples += sourceCount
        if probability >= activity.speechThreshold {
            if confirmedSpeechEnd == nil {
                let start = max(segmentStart, frameStart - activity.prerollFrames)
                trimUnconfirmedPrefix(keeping: processedSamples - start)
                nextPartial = 5_600
            }
            confirmedSpeechEnd = classifiedSamples
        }
        return probability
    }

    private var speechDecodeCount: Int {
        guard let end = confirmedSpeechEnd else { return 0 }
        return min(segment.count, max(0, end - segmentStart) + activity.tailFrames)
    }

    private func decodeSpeech() throws -> String {
        try checkCancellation()
        let text = try transcribe(conditioning.apply(to: Array(segment.prefix(speechDecodeCount))))
        try checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalizeSpeech() throws {
        // Preserve the source and hypothesis when prediction fails or cancels.
        let count = speechDecodeCount
        let text = try decodeSpeech()
        let accepted = text.isEmpty ? currentHypothesis : text
        if !accepted.isEmpty { finals.append(accepted) }
        finalizedSamples += count
        segment.removeFirst(count)
        segmentStart += count
        confirmedSpeechEnd = nil
        currentHypothesis = ""
        lastDecodedSpeechEnd = 0
        nextPartial = 5_600
        // Trailing non-speech may precede the next phrase. It remains bounded,
        // and is counted as discarded only when it is actually removed.
        trimUnconfirmedPrefix(keeping: activity.prerollFrames)
    }

    private func trimUnconfirmedPrefix(keeping count: Int) {
        let remove = max(0, segment.count - max(0, count))
        guard remove > 0 else { return }
        discardedQuietSamples += remove
        segment.removeFirst(remove)
        segmentStart += remove
    }

    private func decode() throws -> String {
        try checkCancellation()
        let text = try transcribe(conditioning.apply(to: segment))
        try checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalize() throws {
        // Keep source PCM and hypothesis intact if prediction fails or cancels.
        let text = try decode()
        // A blank final does not retract an already recognized phrase. A
        // nonempty final still replaces the entire preview, including edits.
        let accepted = text.isEmpty ? currentHypothesis : text
        if !accepted.isEmpty { finals.append(accepted) }
        finalizedSamples += segment.count
        resetSegment()
    }

    private func discardQuiet() {
        discardedQuietSamples += segment.count
        resetSegment()
    }

    private func resetSegment() {
        segment.removeAll(keepingCapacity: false)
        voiced = false; lastVoice = 0; peakRMS = 0; peakMagnitude = 0
        nextPartial = 5_600; currentHypothesis = ""
    }
}

/// The existing transport fences publication with the capture lease. This
/// decoder additionally fences model reuse until any old native call returns.
@available(macOS 15.0, *)
actor PhononStreamingDecoder: ParakeetStreamingDecoding {
    private let modelLease: ExclusiveSpeechModelLease<PhononNativeModel>
    private let conditioning: PhononPCMConditioning
    // A capture owns this snapshot. The warm pooled model never owns project
    // selection or a mutable dictionary that could change during recognition.
    let vocabulary: [String]

    init(vocabulary: [String] = [], conditioning: PhononPCMConditioning = .init(),
         modelLease: ExclusiveSpeechModelLease<PhononNativeModel>? = nil) {
        self.conditioning = conditioning
        self.vocabulary = Self.boundedVocabulary(vocabulary)
        self.modelLease = modelLease ?? ExclusiveSpeechModelLease(
            checkOut: { try await PhononModelPool.shared.checkOut() },
            checkIn: { await PhononModelPool.shared.checkIn($0) })
    }

    func loadModel(from directory: URL) async throws {
        guard directory.standardizedFileURL == PhononSpeechModel.directory.standardizedFileURL else {
            throw SpeechCaptureFailure.message("The speech model directory does not match the prepared model.")
        }
        try await modelLease.load()
        let conditioning = conditioning, vocabulary = vocabulary
        try await modelLease.withModel { try await $0.beginSession(conditioning: conditioning, vocabulary: vocabulary) }
    }

    func appendAndDecode(_ input: ParakeetPCMBuffer) async throws -> String {
        try Task.checkCancellation()
        let buffer = input.buffer
        guard buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
              let channel = buffer.floatChannelData?[0] else {
            throw SpeechCaptureFailure.message("The speech decoder requires mono 16 kHz floating-point audio.")
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return try await modelLease.withModel { try await $0.append(samples) }
    }

    func finish() async throws -> String {
        try await modelLease.withModel(finishing: true) { try await $0.finish() }
    }

    func cleanup() async { await modelLease.close() }

    private static func boundedVocabulary(_ words: [String]) -> [String] {
        var remainingBytes = 8_192
        return words.prefix(100).filter { word in
            let bytes = word.utf8.count
            guard bytes > 0, bytes <= 256, bytes <= remainingBytes else { return false }
            remainingBytes -= bytes
            return true
        }
    }
}
