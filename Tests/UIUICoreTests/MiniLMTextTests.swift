import XCTest
@testable import UIUICore

final class MiniLMTextTests: XCTestCase {
    private func restore(_ source: String, _ predictions: [MiniLMText.Prediction]) throws -> String {
        try MiniLMText.reconstruct(source: source, words: MiniLMText.words(in: source), predictions: predictions)
    }

    func testSourceGapsURLsAndSymbolsRemainExact() throws {
        let source = "  hello\tworld\nhttps://example.com/a?q=1,  `x` @ £₹👩🏽‍💻"
        XCTAssertEqual(MiniLMText.words(in: source).map(\.original), ["hello", "world", "x"])
        XCTAssertEqual(try restore(source, [
            .init(punctuation: .comma, casing: .capitalized),
            .init(punctuation: .period, casing: .lower),
            .init(punctuation: .none, casing: .upper)
        ]), "  Hello,\tworld.\nhttps://example.com/a?q=1,  `X` @ £₹👩🏽‍💻")
        XCTAssertEqual(try restore("\t👩🏽‍💻\n", []), "\t👩🏽‍💻\n")
        XCTAssertEqual(try restore("", []), "")
    }

    func testOrdinaryPunctuationClustersAreReplacedOnceBeforeQuotes() throws {
        XCTAssertEqual(try restore("\"hello?!...\"  \nworld!", [
            .init(punctuation: .comma, casing: .capitalized),
            .init(punctuation: .period, casing: .lower)
        ]), "\"Hello,\"  \nworld.")
        let quoted = "\"hello.\" HTTPS://example.com/a?q=1, \n🙂"
        XCTAssertEqual(try restore(quoted, [.init(punctuation: .period, casing: .capitalized)]),
                       "\"Hello.\" HTTPS://example.com/a?q=1, \n🙂")
    }

    func testNumbersNegationConnectorsAndRepeatedWordsAreNotRewritten() throws {
        let source = "don't  don't keep -5% −7‰ 1,000 3.14 twenty-one items"
        let words = MiniLMText.words(in: source)
        XCTAssertEqual(words.map(\.original), ["don't", "don't", "keep", "5", "7", "1,000", "3.14", "twenty-one", "items"])
        var predictions = words.map { _ in MiniLMText.Prediction(punctuation: .none, casing: .lower) }
        predictions[0] = .init(punctuation: .comma, casing: .capitalized)
        predictions[predictions.count - 1] = .init(punctuation: .period, casing: .lower)
        let candidate = try MiniLMText.reconstruct(source: source, words: words, predictions: predictions)
        XCTAssertEqual(candidate, "Don't,  don't keep -5% −7‰ 1,000 3.14 twenty-one items.")
        // Decimal structured input is intentionally bypassed by the coordinator.
        XCTAssertNil(DictationCleanupText.accepted(candidate, for: source))
        XCTAssertEqual(try restore("we we are ready", [
            .init(punctuation: .comma, casing: .capitalized),
            .init(punctuation: .none, casing: .lower),
            .init(punctuation: .none, casing: .lower),
            .init(punctuation: .period, casing: .lower)
        ]), "We, we are ready.")
    }

    func testUnicodeNormalizationIsInputOnlyAndCaseNeverExpandsLetters() throws {
        let source = "ＣＡＦÉ cafe\u{301} straße İ iPhone OpenAI macOS"
        let words = MiniLMText.words(in: source)
        XCTAssertEqual(words.map(\.normalized), ["café", "café", "straße", "i\u{307}", "iphone", "openai", "macos"])
        XCTAssertEqual(try restore(source, words.map { _ in .init(punctuation: .none, casing: .upper) }),
                       "ＣＡＦÉ CAFE\u{301} STRAßE İ iPhone OpenAI macOS")
        XCTAssertEqual(try restore("ÉLÈVE", [.init(punctuation: .period, casing: .capitalized)]), "Élève.")
        XCTAssertEqual(try restore("İ", [.init(punctuation: .none, casing: .lower)]), "İ")
    }

    func testControlBytesAreRetainedButProductionGuardRejectsThem() throws {
        let source = "hello\u{0}\u{200B}\r\nworld"
        let candidate = try restore(source, [
            .init(punctuation: .none, casing: .capitalized),
            .init(punctuation: .period, casing: .lower)
        ])
        XCTAssertEqual(candidate, "Hello\u{0}\u{200B}\r\nworld.")
        XCTAssertNil(DictationCleanupText.accepted(source, for: source))
        XCTAssertNil(DictationCleanupText.accepted(candidate, for: source))
    }

    func testMissingPredictionsAndForeignSourceRangesFailClosed() {
        XCTAssertThrowsError(try restore("keep all words", [.init(punctuation: .period, casing: .capitalized)]))
        XCTAssertThrowsError(try MiniLMText.reconstruct(source: "blue", words: MiniLMText.words(in: "word"),
                                                       predictions: [.init(punctuation: .period, casing: .lower)]))
    }

    func testPublisherWindowsHaveContextAndEmitEachWordExactlyOnce() throws {
        for counts in [[Int](repeating: 1, count: 600), [Int](repeating: 20, count: 50), [126], [90, 80, 1], [25, 126, 25], []] {
            let chunks = try MiniLMText.chunks(pieceCounts: counts)
            XCTAssertEqual(chunks.flatMap { Array($0.emission) }, Array(counts.indices))
            for chunk in chunks {
                XCTAssertLessThanOrEqual(counts[chunk.context].reduce(0, +), 126)
                XCTAssertFalse(chunk.emission.isEmpty)
                XCTAssertGreaterThanOrEqual(chunk.emission.lowerBound, chunk.context.lowerBound)
                XCTAssertLessThanOrEqual(chunk.emission.upperBound, chunk.context.upperBound)
                XCTAssertLessThanOrEqual(chunk.emission.lowerBound - chunk.context.lowerBound, 24)
            }
        }
        let chunks = try MiniLMText.chunks(pieceCounts: [Int](repeating: 1, count: 300))
        XCTAssertEqual(chunks[0].context, 0..<126)
        XCTAssertEqual(chunks[0].emission, 0..<102)
        XCTAssertEqual(chunks[1].context, 78..<204)
        XCTAssertEqual(chunks[1].emission, 102..<180)
    }

    func testZeroAndOversizedWordNeverSilentlyTruncate() {
        for counts in [[0], [-1], [127], [1, 127, 1], [Int.max]] {
            XCTAssertThrowsError(try MiniLMText.chunks(pieceCounts: counts))
        }
    }

    func testVariedWindowSizesRetainCoverageAndFullSourceOrder() throws {
        var seed: UInt64 = 0xC0FFEE
        for _ in 0..<100 {
            var counts: [Int] = []
            for _ in 0..<200 {
                seed = seed &* 6364136223846793005 &+ 1
                counts.append(Int(seed % 126) + 1)
            }
            let chunks = try MiniLMText.chunks(pieceCounts: counts)
            XCTAssertEqual(chunks.flatMap { Array($0.emission) }, Array(counts.indices))
            XCTAssertTrue(chunks.allSatisfy { counts[$0.context].reduce(0, +) <= 126 })
        }
    }
}
