import XCTest
@testable import PhononCoreML
final class BiasPhrasesTests: XCTestCase {
    let vocab = ["<unk>", "<pad>", "<|blank|>", "▁Lauki", "▁lauki", "▁L", "au", "ki", "▁Kw", "ill", "on", "▁hello"]
    func testSpellingOnlyHasWholeAndSplitPaths() throws {
        let b = try BiasPhrases(words: [.init(word: "Lauki")], vocabulary: vocab, strength: 2)
        XCTAssertTrue(b.phrases.contains([3])); XCTAssertTrue(b.phrases.contains([4])); XCTAssertTrue(b.phrases.contains([5,6,7]))
        XCTAssertEqual(b.acceptedTerms, 1); XCTAssertEqual(b.unspellableTerms, 0)
        XCTAssertFalse(b.phrases.contains { $0.contains(0) || $0.contains(1) || $0.contains(2) })
    }
    func testEmptyZeroUnknownTermsDoNotCreatePaths() throws {
        XCTAssertTrue(try BiasPhrases(words: [], vocabulary: vocab, strength: 2).phrases.isEmpty)
        XCTAssertTrue(try BiasPhrases(words: [.init(word:"Lauki")], vocabulary: vocab, strength: 0).phrases.isEmpty)
        let unknown = try BiasPhrases(words: [.init(word: "unspellable")], vocabulary: vocab, strength: 2)
        XCTAssertEqual(unknown.unspellableTerms, 1); XCTAssertTrue(unknown.phrases.isEmpty)
    }
    func testDuplicateAliasesAndBounds() throws {
        let b = try BiasPhrases(words: [.init(word:" Lauki ",spoken:["Kwillon"]), .init(word:"lauki")], vocabulary:vocab,strength:2)
        XCTAssertEqual(b.acceptedTerms, 1); XCTAssertTrue(b.phrases.contains([8,9,10]))
        let terms = (0..<130).map { BiasTerm(word: "term\($0)") }
        XCTAssertEqual(try BiasPhrases(words: terms, vocabulary: vocab, strength:2).acceptedTerms,100)
    }
    func testStrengthRejectsNonFiniteAndExcessiveValues() {
        for s: Float in [.nan,.infinity,-1,8.01] { XCTAssertThrowsError(try BiasPhrases(words: [], vocabulary:vocab,strength:s)) }
    }
}

import PilotTDT
final class BiasScoreTests: XCTestCase {
    func choose(_ scores: [Float], emitted: [Int32] = [], strength: Float = 2) -> (Int32, [Float]) {
        var seq: [Int32] = [0, 1], lengths: [Int32] = [2], e = emitted, s = scores, bonuses = [Float](repeating:0,count:4)
        let selected = seq.withUnsafeMutableBufferPointer { tp in lengths.withUnsafeMutableBufferPointer { lp in e.withUnsafeMutableBufferPointer { ep in s.withUnsafeMutableBufferPointer { sp in bonuses.withUnsafeMutableBufferPointer { bp in
            pilot_bias_probe(tp.baseAddress,lp.baseAddress,1,ep.baseAddress,Int32(ep.count),sp.baseAddress,4,3,strength,bp.baseAddress)
        }}}}}
        return (selected, bonuses)
    }
    func testOnlyAdvancingPiecesReceivePositiveBonus() {
        let start = choose([0,0,0,0]); XCTAssertEqual(start.0,0); XCTAssertEqual(start.1,[2,0,0,0])
        let after = choose([0,0,0,0],emitted:[0]); XCTAssertEqual(after.0,1); XCTAssertEqual(after.1,[0,2,0,0])
        XCTAssertEqual(choose([0,0,0,0],emitted:[0,3]).1,after.1) // blank preserves phrase state
    }
    func testUnrelatedSpeechAndBlankCanWinAndZeroStrengthPreservesArgmax() {
        XCTAssertEqual(choose([0,0,5,0]).0,2)
        XCTAssertEqual(choose([0,0,0,5]).0,3)
        XCTAssertEqual(choose([0,1,0,0],strength:0).0,1)
        XCTAssertEqual(choose([0,1,0,0],strength:0).1,[0,0,0,0])
    }
    func testMismatchResetsAndNoPenaltyApplied() {
        XCTAssertEqual(choose([0,0,0,0],emitted:[0,2]).1,[2,0,0,0])
        XCTAssertTrue(choose([0,0,0,0],emitted:[0,1]).1.allSatisfy { $0 >= 0 })
    }
}

final class BiasCapacityTests: XCTestCase {
    func testOversizedNativeTrieRejectsInsteadOfSilentlyUnbiasing() {
        // 100 disjoint 100-piece paths exceed 8192 states while staying within
        // the sequence and per-sequence limits; no model or speech is loaded.
        var tokens = (0..<100).flatMap { first in [Int32(first)] + [Int32](repeating:101,count:99) }
        var lengths = [Int32](repeating:100,count:100), scores = [Float](repeating:0,count:104), bonuses=scores
        let result = tokens.withUnsafeMutableBufferPointer { tp in lengths.withUnsafeMutableBufferPointer { lp in scores.withUnsafeMutableBufferPointer { sp in bonuses.withUnsafeMutableBufferPointer { bp in
            pilot_bias_probe(tp.baseAddress,lp.baseAddress,100,nil,0,sp.baseAddress,104,103,2,bp.baseAddress)
        }}}}
        XCTAssertEqual(result,-2)
    }
}

extension BiasCapacityTests {
    func testBoundedSpellingOnlyListCanExceedNativeTrieAndFailsClosed() throws {
        var package = URL(fileURLWithPath:#filePath)
        for _ in 0..<3 { package.deleteLastPathComponent() }
        var repository = package
        for _ in 0..<2 { repository.deleteLastPathComponent() }
        let data = try Data(contentsOf:repository.appendingPathComponent("resources/Phonon/decoder.bin"),options:.alwaysMapped)
        let header = try DecoderTables.validatedHeader(in:data)
        let words = try JSONDecoder().decode([String].self,from:Data(contentsOf:package.appendingPathComponent("fixtures/capacity-terms.json")))
        XCTAssertEqual(words.count,25);XCTAssertTrue(words.allSatisfy { $0.count == 80 })
        let compiled = try BiasPhrases(words:words.map { .init(word:$0) },vocabulary:header.vocab,strength:2)
        var tokens = compiled.phrases.flatMap { $0 },lengths=compiled.phrases.map { Int32($0.count) }
        var scores=[Float](repeating:0,count:Int(header.V)),bonuses=scores
        let result = tokens.withUnsafeMutableBufferPointer { tp in lengths.withUnsafeMutableBufferPointer { lp in scores.withUnsafeMutableBufferPointer { sp in bonuses.withUnsafeMutableBufferPointer { bp in
            pilot_bias_probe(tp.baseAddress,lp.baseAddress,Int32(lp.count),nil,0,sp.baseAddress,header.V,header.blank,2,bp.baseAddress)
        }}}}
        XCTAssertEqual(result,-2,"Even a list within term/character limits must reject automaton state overflow")
    }
}

extension BiasPhrasesTests {
    func testBoundedDevelopmentStrengthSixAndEightAreAccepted() throws {
        for strength: Float in [6,8] {
            XCTAssertFalse(try BiasPhrases(words:[.init(word:"Lauki")],vocabulary:vocab,strength:strength).phrases.isEmpty)
        }
    }
}
extension BiasScoreTests {
    func testNativeStrengthEightMatchesSwiftPilotCeiling() {
        XCTAssertEqual(choose([0,0,7,0],strength:8).0,0)
        XCTAssertEqual(choose([0,0,7,0],strength:8).1,[8,0,0,0])
        XCTAssertEqual(choose([0,0,7,0],strength:8.01).0,-2)
    }
}
final class DurationReportingTests: XCTestCase {
    func testSymbolCapRetainsPredictedZeroAndForcesOnlyAdvancement() {
        var advance: Int32 = -1, nextSymbols: Int32 = -1
        let reported=pilot_tdt_timing_probe(0,0,9,10,&advance,&nextSymbols)
        XCTAssertEqual(reported,0);XCTAssertEqual(advance,1);XCTAssertEqual(nextSymbols,0)
    }
    func testOrdinaryPositiveZeroAndBlankAdvancementRemainUnchanged() {
        var advance: Int32 = -1, nextSymbols: Int32 = -1
        XCTAssertEqual(pilot_tdt_timing_probe(0,0,2,10,&advance,&nextSymbols),0)
        XCTAssertEqual(advance,0);XCTAssertEqual(nextSymbols,3)
        XCTAssertEqual(pilot_tdt_timing_probe(2,0,9,10,&advance,&nextSymbols),2)
        XCTAssertEqual(advance,2);XCTAssertEqual(nextSymbols,0)
        XCTAssertEqual(pilot_tdt_timing_probe(0,1,9,10,&advance,&nextSymbols),0)
        XCTAssertEqual(advance,1);XCTAssertEqual(nextSymbols,0)
    }
}
