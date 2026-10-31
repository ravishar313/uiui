import Foundation
import XCTest
@testable import PhononCoreML

final class VocabularyConfigurationTests: XCTestCase {
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func makePool(serialExecution: Bool = false) throws -> VocabularyDecoderPool {
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let tables = try DecoderTables(url: repository.appendingPathComponent("resources/Phonon/decoder.bin"))
        return try VocabularyDecoderPool(tables: tables, workerCount: 2, workerThreads: 1,
                                         fastThreads: 4, serialExecution: serialExecution, checkCancellation: nil)
    }

    func testSerialExecutionAllocatesOnlyFastHandleAcrossReconfigurationAndFallback() throws {
        let pool = try makePool(serialExecution: true), tables = pool.tables
        XCTAssertTrue(pool.handles.workers.isEmpty)
        XCTAssertTrue(pool.handles.fast.usesReferenceDecoder)
        try pool.configureVocabulary(["Lauki"])
        XCTAssertTrue(pool.handles.workers.isEmpty)
        XCTAssertEqual(pool.activeVocabularyCount, 1)
        XCTAssertFalse(pool.handles.fast.usesReferenceDecoder)
        XCTAssertTrue(pool.handles.fast.tables === tables)
        let configured = pool.handles.fast
        try pool.configureVocabulary(["Lauki"])
        XCTAssertTrue(pool.handles.fast === configured)
        let capacityWords = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: package.appendingPathComponent("fixtures/capacity-terms.json")))
        try pool.configureVocabulary(capacityWords)
        XCTAssertTrue(pool.handles.workers.isEmpty)
        XCTAssertEqual(pool.activeVocabularyCount, 0)
        XCTAssertTrue(pool.handles.fast.usesReferenceDecoder)
        try pool.configureVocabulary(["Phonon"])
        XCTAssertTrue(pool.handles.workers.isEmpty)
        XCTAssertFalse(pool.handles.fast.usesReferenceDecoder)
        try pool.configureVocabulary([])
        XCTAssertTrue(pool.handles.workers.isEmpty)
        XCTAssertTrue(pool.handles.fast.usesReferenceDecoder)
    }

    func testConcurrentExecutionRetainsSeparateWorkerAndFastHandles() throws {
        let pool = try makePool()
        XCTAssertEqual(pool.handles.workers.count, 2)
        XCTAssertFalse(pool.handles.workers[0] === pool.handles.workers[1])
        XCTAssertTrue(pool.handles.workers.allSatisfy { $0 !== pool.handles.fast })
    }

    func testVocabularyChangesCloneSharedTablesAndSameConfigurationReusesHandles() throws {
        let pool = try makePool(), tables = pool.tables
        let original = pool.handles.fast
        XCTAssertTrue(original.usesReferenceDecoder)
        try pool.configureVocabulary([" Lauki ", "lauki", "", "\u{10FFFF}"])
        XCTAssertEqual(pool.activeVocabularyCount, 1)
        XCTAssertFalse(pool.handles.fast.usesReferenceDecoder)
        XCTAssertFalse(pool.handles.fast === original)
        let configured = pool.handles.fast
        try pool.configureVocabulary(["Lauki", "lauki", "", "\u{10FFFF}"])
        XCTAssertTrue(pool.handles.fast === configured, "Unchanged sessions must not rebuild handles")
        XCTAssertTrue(pool.tables === tables)
        for decoder in pool.handles.workers + [pool.handles.fast] {
            XCTAssertTrue(decoder.tables === tables)
            XCTAssertFalse(decoder.usesReferenceDecoder)
            XCTAssertEqual(decoder.weightMemory["retained_float32_coefficient_bytes"], 0)
        }
        XCTAssertEqual(pool.handles.fast.weightMemory["maximum_gemv_scratch_bytes"], 262_144)
        try pool.configureVocabulary([])
        XCTAssertEqual(pool.activeVocabularyCount, 0)
        XCTAssertTrue(pool.handles.fast.usesReferenceDecoder)
        XCTAssertTrue(pool.tables === tables)
    }

    func testUnsupportedAndOversizedVocabularyFallsBackForAllHandles() throws {
        let pool = try makePool()
        try pool.configureVocabulary(["Lauki"])
        try pool.configureVocabulary(["\u{10FFFF}"])
        XCTAssertEqual(pool.activeVocabularyCount, 0)
        XCTAssertTrue(pool.handles.fast.usesReferenceDecoder)
        let capacityWords = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: package.appendingPathComponent("fixtures/capacity-terms.json")))
        try pool.configureVocabulary(capacityWords)
        XCTAssertEqual(pool.activeVocabularyCount, 0)
        for decoder in pool.handles.workers + [pool.handles.fast] {
            XCTAssertTrue(decoder.usesReferenceDecoder, "Capacity rejection must not publish a partially biased pool")
            XCTAssertTrue(decoder.tables === pool.tables)
        }
        let fallback = pool.handles.fast
        try pool.configureVocabulary(capacityWords)
        XCTAssertTrue(pool.handles.fast === fallback)
        try pool.configureVocabulary(["Lauki"])
        XCTAssertEqual(pool.activeVocabularyCount, 1)
        XCTAssertFalse(pool.handles.fast.usesReferenceDecoder)
    }

    func testActualHundredTermAccuracyControlStaysCustomAndSharesTables() throws {
        let words = ["Lauki", "Phonon", "MiniLM", "Parakeet", "Zelta", "Naksha"]
            + (0..<94).map { "Atlas" + String($0) }
        let pool = try makePool(), tables = pool.tables
        try pool.configureVocabulary(words)
        XCTAssertEqual(pool.activeVocabularyCount, 100,
                       "The actual larger-list accuracy control must activate all 100 terms; a lower count or reference fallback invalidates that claim")
        for decoder in pool.handles.workers + [pool.handles.fast] {
            XCTAssertFalse(decoder.usesReferenceDecoder,
                           "The actual larger-list accuracy control must exercise the custom decoder")
            XCTAssertTrue(decoder.tables === tables)
        }
        XCTAssertTrue(pool.tables === tables)
    }

    func testNativeAllocationFailurePropagatesWithoutPublishingOrReferenceFallback() throws {
        let pool = try makePool()
        try pool.configureVocabulary(["Lauki"])
        let before = pool.handles
        var constructionCalls = 0
        XCTAssertThrowsError(try pool.configureVocabulary(["Phonon"], makeHandles: { _ in
            constructionCalls += 1
            throw DecoderConfigurationError.nativeAllocationFailed
        })) { error in
            guard case DecoderConfigurationError.nativeAllocationFailed = error else {
                return XCTFail("Expected native allocation error, got \(type(of: error))")
            }
        }
        XCTAssertEqual(constructionCalls, 1, "Allocation failure must not attempt a reference fallback")
        XCTAssertTrue(pool.handles.fast === before.fast)
        XCTAssertEqual(pool.activeVocabularyCount, 1)
        for (old, current) in zip(before.workers, pool.handles.workers) {
            XCTAssertTrue(old === current)
        }
    }

    func testBoundedNormalizationPreservesFirstSpellingAndSkipsInvalidTerms() {
        let words = ["", "  Lauki  ", "lauki", String(repeating: "x", count: 81)]
            + (0..<150).map { "word\($0)" }
        let normalized = VocabularyDecoderPool.normalizedWords(words)
        XCTAssertEqual(normalized.count, 100)
        XCTAssertTrue(normalized.contains("Lauki"))
        XCTAssertFalse(normalized.contains("lauki"))
        XCTAssertFalse(normalized.contains("word99"))
        XCTAssertEqual(VocabularyDecoderPool.normalizedWords([" a   b ", "a b"]), ["a b"])
    }
}
