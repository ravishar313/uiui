import CryptoKit
import Foundation

/// Raw window-relative decoder output only. No PCM, encoder features, token
/// strings, rescued output, or stitched transcript is retained by the cache.
struct WindowRawDecode: Equatable {
    let tokens: [Int32]
    let frame: [Int32]
    let duration: [Int32]
    var tuple: (tokens: [Int32], frame: [Int32], duration: [Int32]) {
        (tokens, frame, duration)
    }
    var isValid: Bool { tokens.count == frame.count && tokens.count == duration.count }
}

/// Counts committed successful runs only. A failed/cancelled transaction does
/// not publish hits, misses, entries, or recency changes.
public struct WindowDecodeCacheStatistics {
    public let hits: UInt64
    public let misses: UInt64
    public let entries: Int
    public let tokenTriples: Int
}

struct WindowDecodeCache {
    static let maximumEntries = 16
    static let maximumTokenTriples = 8_192

    struct Key: Hashable {
        let epoch: UInt64
        let start: Int
        let end: Int
        let sampleCount: Int
        let function: Int
        let digest: [UInt8]
    }
    fileprivate struct State {
        var entries: [Key: WindowRawDecode] = [:]
        var oldestFirst: [Key] = []
        var tokenTriples = 0
        var hits: UInt64 = 0
        var misses: UInt64 = 0
    }
    private var epoch: UInt64 = 0
    private var state = State()

    var statistics: WindowDecodeCacheStatistics {
        .init(hits: state.hits, misses: state.misses, entries: state.entries.count,
              tokenTriples: state.tokenTriples)
    }
    func beginTransaction() -> Transaction { Transaction(epoch: epoch, state: state) }
    mutating func commit(_ transaction: Transaction) {
        // Also reject a stale transaction if a caller explicitly resets before
        // commit. Transcriber serializes these operations with its fast lock.
        guard transaction.epoch == epoch else { return }
        state = transaction.state
    }
    mutating func reset() {
        epoch &+= 1
        state = State()
    }

    struct Transaction {
        fileprivate let epoch: UInt64
        fileprivate var state: State

        func key(samples: [Float], start: Int, end: Int, function: Int,
                 checkCancellation: () throws -> Void = {}) throws -> Key {
            try key(window: samples[...], start: start, end: end, function: function,
                    checkCancellation: checkCancellation)
        }

        func key(window samples: ArraySlice<Float>, start: Int, end: Int, function: Int,
                 checkCancellation: () throws -> Void = {}) throws -> Key {
            try checkCancellation()
            var hash = SHA256()
            samples.withUnsafeBufferPointer { hash.update(bufferPointer: UnsafeRawBufferPointer($0)) }
            try checkCancellation()
            return Key(epoch: epoch, start: start, end: end, sampleCount: samples.count,
                       function: function, digest: Array(hash.finalize()))
        }

        /// decodeRaw returns nil for silence, which must skip the transform just
        /// as the uncached path skips rescue. A decoded-empty result is distinct
        /// and still runs the transform on both misses and hits.
        mutating func process<Value>(key: Key,
                                     decodeRaw: () throws -> WindowRawDecode?,
                                     transform: (WindowRawDecode) throws -> Value) throws -> Value? {
            let raw: WindowRawDecode
            if let cached = state.entries[key] {
                state.hits &+= 1
                touch(key)
                raw = cached
            } else {
                state.misses &+= 1
                guard let decoded = try decodeRaw() else { return nil }
                raw = decoded
                insert(decoded, for: key)
            }
            // Rescue/current-source processing is deliberately outside reuse.
            return try transform(raw)
        }

        private mutating func touch(_ key: Key) {
            state.oldestFirst.removeAll { $0 == key }
            state.oldestFirst.append(key)
        }
        private mutating func insert(_ raw: WindowRawDecode, for key: Key) {
            guard key.epoch == epoch, raw.isValid,
                  raw.tokens.count <= WindowDecodeCache.maximumTokenTriples else { return }
            while state.entries.count >= WindowDecodeCache.maximumEntries ||
                  state.tokenTriples + raw.tokens.count > WindowDecodeCache.maximumTokenTriples {
                guard let oldest = state.oldestFirst.first else { return }
                state.oldestFirst.removeFirst()
                if let removed = state.entries.removeValue(forKey: oldest) {
                    state.tokenTriples -= removed.tokens.count
                }
            }
            state.entries[key] = raw
            state.tokenTriples += raw.tokens.count
            touch(key)
        }
    }
}
