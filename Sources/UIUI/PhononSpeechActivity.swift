import CoreML
import Foundation

/// Small, pinned Silero classifier. All state belongs to PhononNativeModel's
/// serial queue. It runs only on accepted recording PCM, never while idle.
/// Manual local loading cannot download or select an unrelated model cache.
final class PhononSpeechActivity {
    static let frameCount = 4_096
    private static let contextCount = 64
    private let model: MLModel
    private let audio: MLMultiArray
    private let hidden: MLMultiArray
    private let cell: MLMultiArray
    private let inputs: MLDictionaryFeatureProvider
    private var context = [Float](repeating: 0, count: contextCount)
    private(set) var calls = 0
    private(set) var processingSeconds: Double = 0

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        // Keep this ~1 MB activity model off the Neural Engine recognizer's
        // allocation path; measure CPU cost rather than adding another ANE load.
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: config)
        audio = try MLMultiArray(shape: [1, 4_160], dataType: .float32)
        hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        inputs = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: audio),
            "hidden_state": MLFeatureValue(multiArray: hidden),
            "cell_state": MLFeatureValue(multiArray: cell)
        ])
        reset()
        // First-use setup is paid once during model preparation. Throw away
        // synthetic warmup state so no session inherits a previous input.
        _ = try probability([Float](repeating: 0, count: Self.frameCount))
        reset()
    }

    func reset() {
        audio.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: 0, count: 4_160)
        hidden.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: 0, count: 128)
        cell.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: 0, count: 128)
        context = [Float](repeating: 0, count: Self.contextCount)
        calls = 0; processingSeconds = 0
    }

    func probability(_ samples: [Float]) throws -> Float {
        guard samples.count == Self.frameCount, samples.allSatisfy(\.isFinite) else { throw SpeechActivityFailure.invalidPCM }
        let start = ContinuousClock.now
        let probability: Float = try autoreleasepool {
            let destination = audio.dataPointer.assumingMemoryBound(to: Float.self)
            context.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: Self.contextCount) }
            samples.withUnsafeBufferPointer { (destination + Self.contextCount).update(from: $0.baseAddress!, count: Self.frameCount) }
            let result = try model.prediction(from: inputs)
            guard let probability = result.featureValue(for: "vad_output")?.multiArrayValue,
                  probability.dataType == .float32, probability.count == 1,
                  let nextHidden = result.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  nextHidden.dataType == .float32, nextHidden.count == 128,
                  let nextCell = result.featureValue(for: "new_cell_state")?.multiArrayValue,
                  nextCell.dataType == .float32, nextCell.count == 128 else { throw SpeechActivityFailure.invalidOutput }
            let value = probability.dataPointer.assumingMemoryBound(to: Float.self)[0]
            guard value.isFinite, (0...1).contains(value) else { throw SpeechActivityFailure.invalidOutput }
            hidden.dataPointer.assumingMemoryBound(to: Float.self).update(from: nextHidden.dataPointer.assumingMemoryBound(to: Float.self), count: 128)
            cell.dataPointer.assumingMemoryBound(to: Float.self).update(from: nextCell.dataPointer.assumingMemoryBound(to: Float.self), count: 128)
            return value
        }
        context = Array(samples.suffix(Self.contextCount))
        let elapsed = start.duration(to: .now)
        calls += 1
        processingSeconds += Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return probability
    }
}

enum SpeechActivityFailure: Error { case invalidPCM, invalidOutput }
