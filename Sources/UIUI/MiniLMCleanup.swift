import CMiniLM
import Dispatch
import Foundation
import UIUICore

/// All native state belongs to this serial queue. Admission, readiness and
/// cancellation share a lock so release invalidates active and queued requests
/// synchronously, before the ordered native unload.
final class MiniLMCleanupEngine: CleanupGenerating, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.uiui.cleanup.minilm", qos: .userInitiated)
    private let lock = NSLock()
    private let assets: MiniLMModel.Assets?
    private let inferenceFactory: (() throws -> any MiniLMWindowInference)?
    private var ready = false
    private var loadingID: UUID?
    private var pending: [UUID: CleanupCancellation] = [:]
    private var runtime: MiniLMFormattingRuntime? // queue only
    var isReady: Bool { lock.withLock { ready } }

    init() { assets = MiniLMModel.bundled; inferenceFactory = nil }

    init(modelURL: URL, tokenizerURL: URL, manifestURL: URL? = nil) {
        assets = MiniLMModel.explicit(modelURL: modelURL, tokenizerURL: tokenizerURL, manifestURL: manifestURL)
        inferenceFactory = nil
    }

    /// Research adapters share this serial owner and the production formatter.
    /// The normal initializer retains the verified ONNX assets and runtime.
    init(inferenceFactory: @escaping () throws -> any MiniLMWindowInference) {
        assets = nil
        self.inferenceFactory = inferenceFactory
    }

    func prepare() async {
        let cancellation = CleanupCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    guard !ready, loadingID == nil, assets != nil || inferenceFactory != nil else { continuation.resume(); return }
                    let id = UUID()
                    loadingID = id; pending[id] = cancellation
                    queue.async {
                        defer {
                            self.lock.withLock {
                                self.pending.removeValue(forKey: id)
                                if self.loadingID == id { self.loadingID = nil }
                            }
                            continuation.resume()
                        }
                        do {
                            let inference: any MiniLMWindowInference
                            if let factory = self.inferenceFactory {
                                inference = try factory()
                            } else if let assets = self.assets {
                                try MiniLMModel.verify(assets, cancellation: cancellation)
                                try Self.check(cancellation)
                                inference = try ONNXMiniLMWindowInference(assets: assets)
                            } else { throw CleanupFailure.unavailable }
                            try Self.check(cancellation)
                            let loaded = MiniLMFormattingRuntime(inference: inference)
                            // Fixed, public setup input; no person's content enters
                            // warmup. Prepare reports ready only after native work.
                            _ = try loaded.generate("ready", fallbackOnFailure: false, check: { try Self.check(cancellation) })
                            self.lock.withLock {
                                guard !cancellation.isCancelled, self.loadingID == id else { return }
                                self.runtime = loaded
                                self.ready = true
                            }
                        } catch {
                            // Errors are deliberately not logged: native runtimes
                            // may echo file paths or input into their messages.
                        }
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    func generate(_ text: String, cancellation: CleanupCancellation) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard ready else { continuation.resume(throwing: CleanupFailure.unavailable); return }
                    let id = UUID(), local = CleanupCancellation()
                    pending[id] = local
                    queue.async {
                        do {
                            let check = { try Self.check(local); try Self.check(cancellation) }
                            try check()
                            guard let runtime = self.runtime else { throw CleanupFailure.unavailable }
                            let result = try runtime.generate(text, check: check)
                            // Delivery and release admission are atomic. A
                            // released request never resumes with success.
                            self.lock.withLock {
                                self.pending.removeValue(forKey: id)
                                if local.isCancelled || cancellation.isCancelled || !self.ready {
                                    continuation.resume(throwing: CancellationError())
                                } else { continuation.resume(returning: result) }
                            }
                        } catch {
                            _ = self.lock.withLock { self.pending.removeValue(forKey: id) }
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    func release() {
        lock.withLock {
            ready = false; loadingID = nil
            for token in pending.values { token.cancel() }
            queue.async { self.runtime = nil }
        }
    }

    func shutdown() async {
        release()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    private static func check(_ cancellation: CleanupCancellation) throws {
        if cancellation.isCancelled { throw CancellationError() }
    }
}

/// One shared contract keeps tokenization/alignment/reconstruction identical
/// across ONNX and isolated model-free boundary tests.
protocol MiniLMWindowInference: AnyObject {
    func encode(_ text: String, check: () throws -> Void) throws -> [Int64]
    func predict(_ ids: [Int64], check: () throws -> Void) throws -> [Float]
}

private final class ONNXMiniLMWindowInference: MiniLMWindowInference {
    private let context: OpaquePointer

    init(assets: MiniLMModel.Assets) throws {
        var error = [CChar](repeating: 0, count: 256)
        let created = assets.modelURL.path.withCString { model in
            assets.tokenizerURL.path.withCString { tokenizer in
                uiui_minilm_create(model, tokenizer, &error, error.count)
            }
        }
        guard let created else { throw CleanupFailure.unavailable }
        context = created
    }

    deinit { uiui_minilm_destroy(context) }

    func encode(_ text: String, check: () throws -> Void) throws -> [Int64] {
        try check()
        var error = [CChar](repeating: 0, count: 256)
        // The formatter admits at most 126 content pieces. Supplying that
        // budget directly avoids tokenizing the same text to query its size.
        var ids = [Int64](repeating: 0, count: 126)
        let count = text.withCString { uiui_minilm_encode(context, $0, &ids, ids.count, &error, error.count) }
        try check()
        guard count > 0, Int(count) <= ids.count else { throw MiniLMText.Failure.unsupportedLength }
        ids.removeLast(ids.count - Int(count))
        guard ids.allSatisfy({ $0 >= 0 }) else { throw MiniLMText.Failure.alignment }
        return ids
    }

    func predict(_ ids: [Int64], check: () throws -> Void) throws -> [Float] {
        try check()
        var logits = [Float](repeating: 0, count: ids.count * 8)
        var error = [CChar](repeating: 0, count: 256)
        let status = uiui_minilm_predict(context, ids, ids.count, &logits, logits.count, &error, error.count)
        try check()
        guard status == 0 else { throw MiniLMText.Failure.alignment }
        return logits
    }
}

final class MiniLMFormattingRuntime {
    private let inference: any MiniLMWindowInference
    init(inference: any MiniLMWindowInference) { self.inference = inference }

    func generate(_ source: String, fallbackOnFailure: Bool = true, check: () throws -> Void) throws -> String {
        try check()
        guard DictationCleanupText.accepted(source, for: source) != nil else { return source }
        do {
            let words = MiniLMText.words(in: source)
            try check()
            guard !words.isEmpty else { return source }
            var pieces: [[Int64]] = []
            pieces.reserveCapacity(words.count)
            // Only this bounded request owns the memo. Its indices reference
            // existing piece arrays; no text or token state survives generate.
            var encodedWords: [String: Int] = [:]
            for word in words {
                try check()
                if let previous = encodedWords[word.normalized],
                   words[previous].normalized.utf8.elementsEqual(word.normalized.utf8) {
                    // Swift String equality is canonically equivalent; native
                    // reuse is stricter and requires the same UTF-8 bytes.
                    pieces.append(pieces[previous])
                } else {
                    let encoded = try encode(word.normalized, check: check)
                    encodedWords[word.normalized] = pieces.count
                    pieces.append(encoded)
                }
            }
            let chunks = try MiniLMText.chunks(pieceCounts: pieces.map(\.count))
            var predictions: [MiniLMText.Prediction] = []
            predictions.reserveCapacity(words.count)
            for chunk in chunks {
                try check()
                var ids = [Int64(0)]
                ids.reserveCapacity(128)
                var joined = ""
                for wordIndex in chunk.context {
                    ids.append(contentsOf: pieces[wordIndex])
                    if !joined.isEmpty { joined.append(" ") }
                    joined.append(words[wordIndex].normalized)
                }
                // The publisher's word-final offset depends on this equality.
                // A one-word chunk has exactly the already-encoded input; all
                // multiword chunks still verify the actual joined encoding.
                if chunk.context.count > 1 {
                    guard try encode(joined, check: check).elementsEqual(ids.dropFirst()) else {
                        throw MiniLMText.Failure.alignment
                    }
                }
                ids.append(2)
                guard ids.count <= 128 else { throw MiniLMText.Failure.unsupportedLength }
                let logits = try inference.predict(ids, check: check)
                try check()
                guard logits.count == ids.count * 8, logits.allSatisfy(\.isFinite) else { throw MiniLMText.Failure.alignment }
                var cursor = 0
                for wordIndex in chunk.context {
                    cursor += pieces[wordIndex].count
                    guard chunk.emission.contains(wordIndex) else { continue }
                    let offset = cursor * 8
                    let punctuation = Self.argmax(logits, in: offset..<(offset + 5)) - offset
                    let casing = Self.argmax(logits, in: (offset + 5)..<(offset + 8)) - offset - 5
                    guard let p = MiniLMText.Prediction.Punctuation(rawValue: punctuation),
                          let c = MiniLMText.Prediction.Casing(rawValue: casing) else { throw MiniLMText.Failure.alignment }
                    predictions.append(.init(punctuation: p, casing: c))
                }
            }
            try check()
            let candidate = try MiniLMText.reconstruct(source: source, words: words, predictions: predictions)
            try check()
            guard DictationCleanupText.accepted(candidate, for: source) != nil else { return source }
            return candidate
        } catch is CancellationError { throw CancellationError() }
        catch {
            try check()
            if !fallbackOnFailure { throw error }
            return source
        }
    }

    private func encode(_ text: String, check: () throws -> Void) throws -> [Int64] {
        try inference.encode(text, check: check)
    }

    private static func argmax(_ scores: [Float], in range: Range<Int>) -> Int {
        var best = range.lowerBound
        for index in range.dropFirst() where scores[index] > scores[best] { best = index }
        return best
    }
}
