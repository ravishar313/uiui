import XCTest
@testable import UIUICore

final class TranscriptErasureTests: XCTestCase {
    func testTextPassesThroughExactlyUntilTheFirstPress() {
        let erasure = TranscriptErasure()
        XCTAssertEqual(erasure.apply(to: "  line one\nline two  "), "  line one\nline two  ")
    }

    func testRemovesLastWordAndNewWordsContinueFromThere() {
        var erasure = TranscriptErasure()
        erasure.eraseLastWord(from: "kal meeting hai Tuesday")
        XCTAssertEqual(erasure.apply(to: "kal meeting hai Tuesday"), "kal meeting hai")
        XCTAssertEqual(erasure.apply(to: "kal meeting hai Tuesday Wednesday ko"), "kal meeting hai Wednesday ko")
    }

    func testRepeatedPressesKeepRemovingWords() {
        var erasure = TranscriptErasure()
        let raw = "one two three four"
        erasure.eraseLastWord(from: raw)
        erasure.eraseLastWord(from: raw)
        XCTAssertEqual(erasure.apply(to: raw), "one two")
        XCTAssertEqual(erasure.apply(to: raw + " five"), "one two five")
    }

    func testEditingAfterNewWordsRemovesTheNewWordsFirst() {
        var erasure = TranscriptErasure()
        erasure.eraseLastWord(from: "one two three")
        erasure.eraseLastWord(from: "one two three four")
        XCTAssertEqual(erasure.apply(to: "one two three four"), "one two")
        XCTAssertEqual(erasure.apply(to: "one two three four five"), "one two five")
    }

    func testDeletingEverythingIsEmptyAndExtraPressesAreHarmless() {
        var erasure = TranscriptErasure()
        erasure.eraseLastWord(from: "hello")
        erasure.eraseLastWord(from: "hello")
        XCTAssertEqual(erasure.apply(to: "hello"), "")
        XCTAssertEqual(erasure.apply(to: "hello there"), "there")
    }

    func testRevisedEarlierWordsCannotBringADeletedWordBack() {
        var erasure = TranscriptErasure()
        erasure.eraseLastWord(from: "send the report today")
        XCTAssertEqual(erasure.apply(to: "send a report today"), "send the report")
        XCTAssertEqual(erasure.apply(to: "Send the report, today."), "send the report")
    }

    func testAlignsWhenTheRecogniserMergesOrSplitsEarlierWords() {
        var erasure = TranscriptErasure()
        erasure.eraseLastWord(from: "for the time being we wait")
        // "the time" merges into one word: "wait" must not leak, and "tomorrow" must not be lost.
        XCTAssertEqual(erasure.apply(to: "for thetime being we wait tomorrow"), "for the time being we tomorrow")
        // A word splits in two.
        XCTAssertEqual(erasure.apply(to: "for the time be ing we wait tomorrow"), "for the time being we tomorrow")
    }

    func testAShorterHypothesisShowsOnlyWhatWasKept() {
        var erasure = TranscriptErasure()
        erasure.eraseLastWord(from: "one two three")
        XCTAssertEqual(erasure.apply(to: "one"), "one two")
        XCTAssertEqual(erasure.apply(to: ""), "one two")
    }

    func testFinalPunctuationIsCarriedOnTheNewWords() {
        var erasure = TranscriptErasure()
        erasure.eraseLastWord(from: "call priya tomorrow")
        XCTAssertEqual(erasure.apply(to: "Call Priya tomorrow. Monday works."), "call priya Monday works.")
    }

    func testScratchThatIsResolvedBeforeRemovingAWord() {
        var erasure = TranscriptErasure()
        erasure.eraseLastWord(from: "First one. Second one scratch that")
        XCTAssertEqual(erasure.apply(to: "First one. Second one scratch that"), "First")
    }
}
