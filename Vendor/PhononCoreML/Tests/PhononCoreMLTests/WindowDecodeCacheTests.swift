import Foundation
import XCTest
@testable import PhononCoreML

final class WindowDecodeCacheTests: XCTestCase {
    private enum Failure: Error { case prediction, rescue }
    private func raw(_ token: Int32 = 7, count: Int = 1) -> WindowRawDecode {
        .init(tokens: [Int32](repeating: token, count: count),
              frame: (0..<count).map { Int32($0) },
              duration: [Int32](repeating: 1, count: count))
    }
    private func key(_ transaction: WindowDecodeCache.Transaction, _ identity: Int) throws -> WindowDecodeCache.Key {
        try transaction.key(samples: [Float(identity)], start: identity, end: identity + 1, function: 15)
    }
    @discardableResult
    private func access(_ cache: inout WindowDecodeCache, _ identity: Int,
                        value: WindowRawDecode? = nil) throws -> Int32? {
        var transaction = cache.beginTransaction()
        let k = try key(transaction, identity)
        let result = try transaction.process(key: k, decodeRaw: { value ?? self.raw(Int32(identity)) },
                                             transform: { $0.tokens.first })
        cache.commit(transaction)
        return result ?? nil
    }

    func testKeysDistinguishEverySampleBitWindowCountFunctionAndCaptureEpoch() throws {
        var cache = WindowDecodeCache()
        let transaction = cache.beginTransaction()
        let original = try transaction.key(samples: [0, 1], start: 0, end: 2, function: 15)
        XCTAssertEqual(original, try transaction.key(samples: [0, 1], start: 0, end: 2, function: 15))
        for changed in [
            try transaction.key(samples: [-Float.zero, 1], start: 0, end: 2, function: 15),
            try transaction.key(samples: [0, Float(bitPattern: Float(1).bitPattern + 1)], start: 0, end: 2, function: 15),
            try transaction.key(samples: [0], start: 0, end: 2, function: 15),
            try transaction.key(samples: [0, 1], start: 1, end: 3, function: 15),
            try transaction.key(samples: [0, 1], start: 0, end: 3, function: 15),
            try transaction.key(samples: [0, 1], start: 0, end: 2, function: 25)
        ] { XCTAssertNotEqual(original, changed) }
        cache.reset()
        XCTAssertNotEqual(original, try cache.beginTransaction().key(samples: [0, 1], start: 0, end: 2, function: 15))
    }

    func testBorrowedWindowKeysIgnoreOutsidePCMButInvalidateEveryChangedWindowBit() throws {
        let transaction = WindowDecodeCache().beginTransaction()
        var backing: [Float] = [99, 0, -0.0, 0.25, -0.5, 98]
        let copied = Array(backing[1..<5])
        let expected = try transaction.key(samples: copied, start: 10, end: 14, function: 15)
        func key(_ samples: [Float]) throws -> WindowDecodeCache.Key {
            try transaction.key(window: samples[1..<5], start: 10, end: 14, function: 15)
        }
        XCTAssertEqual(try key(backing), expected)
        backing[0] = -99; backing[5] = -98
        XCTAssertEqual(try key(backing), expected, "Context outside this window is not part of its raw decode")
        for index in 1..<5 {
            var changed = backing
            changed[index] = Float(bitPattern: changed[index].bitPattern ^ 1)
            XCTAssertNotEqual(try key(changed), expected, "Changed bit at window sample \(index - 1)")
        }
        XCTAssertNotEqual(try transaction.key(window: backing[1..<4], start: 10, end: 14, function: 15), expected)
        XCTAssertEqual(try transaction.key(window: backing[5..<5], start: 0, end: 0, function: 15),
                       try transaction.key(samples: [], start: 0, end: 0, function: 15))
    }

    func testUnchangedWindowReusesExactRawTokensFramesAndDurations() throws {
        var cache = WindowDecodeCache(), decodeCalls = 0
        let expected = WindowRawDecode(tokens: [8, 3], frame: [0, 11], duration: [0, 4])
        for _ in 0..<2 {
            var transaction = cache.beginTransaction()
            let k = try key(transaction, 1)
            let result = try transaction.process(key: k, decodeRaw: { decodeCalls += 1; return expected }, transform: { $0 })
            XCTAssertEqual(result, expected)
            cache.commit(transaction)
        }
        XCTAssertEqual(decodeCalls, 1)
        XCTAssertEqual(cache.statistics.hits, 1)
        XCTAssertEqual(cache.statistics.misses, 1)
        XCTAssertEqual(cache.statistics.entries, 1)
        XCTAssertEqual(cache.statistics.tokenTriples, 2)
    }

    func testHitsAlwaysRunFreshRescueWithNewSourceAndSingleToLongEligibility() throws {
        var cache = WindowDecodeCache(), decodeCalls = 0, rescueCalls = 0
        let expected = raw()
        for sourceCount in [100, 300] {
            var transaction = cache.beginTransaction()
            let k = try transaction.key(samples: [1, 2], start: 0, end: 2, function: 15)
            let result = try transaction.process(key: k, decodeRaw: { decodeCalls += 1; return expected }, transform: { raw in
                XCTAssertEqual(raw, expected)
                // The same cached raw window can acquire fresh right context
                // and become rescue-eligible in the new multiwindow plan.
                if sourceCount > 100 { rescueCalls += 1; return sourceCount }
                return 0
            })
            XCTAssertEqual(result, sourceCount > 100 ? 300 : 0)
            cache.commit(transaction)
        }
        XCTAssertEqual(decodeCalls, 1)
        XCTAssertEqual(rescueCalls, 1)
    }

    func testSilenceDoesNotCacheOrRescueButDecodedEmptyDoesBoth() throws {
        var cache = WindowDecodeCache(), silentCalls = 0, emptyCalls = 0, transformations = 0
        for _ in 0..<2 {
            var transaction = cache.beginTransaction()
            let silent = try transaction.process(key: key(transaction, 1), decodeRaw: {
                silentCalls += 1; return nil
            }, transform: { _ in transformations += 1; return 1 })
            XCTAssertNil(silent)
            let empty = try transaction.process(key: key(transaction, 2), decodeRaw: {
                emptyCalls += 1; return self.raw(count: 0)
            }, transform: { raw in transformations += 1; return raw.tokens.count })
            XCTAssertEqual(empty, 0)
            cache.commit(transaction)
        }
        XCTAssertEqual(silentCalls, 2)
        XCTAssertEqual(emptyCalls, 1)
        XCTAssertEqual(transformations, 2)
        XCTAssertEqual(cache.statistics.entries, 1)
        XCTAssertEqual(cache.statistics.tokenTriples, 0)
    }

    func testEntryBoundEvictsLeastRecentlyUsedAndSuccessfulHitRefreshesRecency() throws {
        var cache = WindowDecodeCache()
        for identity in 0..<16 { try access(&cache, identity) }
        try access(&cache, 0)
        try access(&cache, 16)
        XCTAssertEqual(cache.statistics.entries, 16)
        let hits = cache.statistics.hits
        try access(&cache, 0)
        XCTAssertEqual(cache.statistics.hits, hits + 1)
        let misses = cache.statistics.misses
        try access(&cache, 1)
        XCTAssertEqual(cache.statistics.misses, misses + 1)
        XCTAssertEqual(cache.statistics.entries, 16)
    }

    func testTokenBudgetEvictsBeforeInsertionAndOversizedOrInvalidResultsAreNotRetained() throws {
        var cache = WindowDecodeCache()
        try access(&cache, 0, value: raw(count: 4_096))
        try access(&cache, 1, value: raw(count: 4_096))
        XCTAssertEqual(cache.statistics.tokenTriples, 8_192)
        try access(&cache, 2, value: raw(count: 1))
        XCTAssertEqual(cache.statistics.entries, 2)
        XCTAssertEqual(cache.statistics.tokenTriples, 4_097)
        try access(&cache, 3, value: raw(count: 8_193))
        XCTAssertEqual(cache.statistics.entries, 2)
        XCTAssertEqual(cache.statistics.tokenTriples, 4_097)
        try access(&cache, 4, value: .init(tokens: [1], frame: [], duration: [1]))
        XCTAssertEqual(cache.statistics.entries, 2)
    }

    func testPredictionAndRescueFailureDoNotPublishInsertsCountersOrRecency() throws {
        for failure in [Failure.prediction, .rescue] {
            var cache = WindowDecodeCache()
            for identity in 0..<16 { try access(&cache, identity) }
            let before = cache.statistics
            do {
                var transaction = cache.beginTransaction()
                _ = try transaction.process(key: key(transaction, 0), decodeRaw: { self.raw() }, transform: { $0 })
                _ = try transaction.process(key: key(transaction, 16), decodeRaw: {
                    if case .prediction = failure { throw failure }
                    return self.raw()
                }, transform: { _ -> Int in throw failure })
                XCTFail("Expected failed full run")
            } catch is Failure {}
            XCTAssertEqual(cache.statistics.hits, before.hits)
            XCTAssertEqual(cache.statistics.misses, before.misses)
            XCTAssertEqual(cache.statistics.entries, before.entries)
            try access(&cache, 17)
            let misses = cache.statistics.misses
            try access(&cache, 0)
            XCTAssertEqual(cache.statistics.misses, misses + 1, "The failed run must not refresh the oldest entry")
        }
    }

    func testCancellationAtHashBoundaryAndAfterAHitDiscardsEntireTransaction() throws {
        var cache = WindowDecodeCache()
        try access(&cache, 1)
        let before = cache.statistics
        var checks = 0
        let transaction = cache.beginTransaction()
        XCTAssertThrowsError(try transaction.key(samples: [1], start: 1, end: 2, function: 15, checkCancellation: {
            checks += 1
            if checks == 2 { throw CancellationError() }
        }))
        XCTAssertEqual(checks, 2)
        do {
            var staged = cache.beginTransaction()
            _ = try staged.process(key: key(staged, 1), decodeRaw: { XCTFail("Expected hit"); return nil },
                                   transform: { _ -> Int in throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(cache.statistics.hits, before.hits)
        XCTAssertEqual(cache.statistics.misses, before.misses)
        XCTAssertEqual(cache.statistics.entries, before.entries)
    }

    func testResetClearsConfigurationAndCaptureReuseAndRejectsStaleCommit() throws {
        var cache = WindowDecodeCache()
        try access(&cache, 1)
        var stale = cache.beginTransaction()
        _ = try stale.process(key: key(stale, 2), decodeRaw: { self.raw() }, transform: { $0 })
        // Transcriber uses reset for successful vocabulary configuration and
        // capture reset, even when the next input PCM is identical.
        cache.reset()
        cache.commit(stale)
        XCTAssertEqual(cache.statistics.entries, 0)
        XCTAssertEqual(cache.statistics.hits, 0)
        XCTAssertEqual(cache.statistics.misses, 0)
        try access(&cache, 1)
        XCTAssertEqual(cache.statistics.misses, 1)
        XCTAssertEqual(cache.statistics.hits, 0)
    }
}
