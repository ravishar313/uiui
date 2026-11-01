import XCTest
@testable import UIUICore

final class SoundsLikeVocabularyTests: XCTestCase {
    private let english: Set<String> = ["phone", "on", "delta", "call", "the", "deck", "send", "up", "surge", "labs", "meeting", "with", "client", "river", "karen"]

    private func fix(_ text: String, _ spellings: [String]) -> String {
        TextProcessing.applyingVocabulary(to: text, entries: spellings.map { VocabularyEntry(heard: $0, replacement: $0) },
                                          project: "All projects", isKnownWord: { self.english.contains($0) })
    }

    func testSpellingAloneCatchesWhatSoundsLikeIt() {
        for heard in ["Keeran", "Kieran", "kiran", "Kirin"] { XCTAssertEqual(fix("meeting with \(heard)", ["Kiran"]), "meeting with Kiran", heard) }
        for heard in ["Pria", "Preeya", "priya"] { XCTAssertEqual(fix("call \(heard) now", ["Priya"]), "call Priya now", heard) }
        XCTAssertEqual(fix("send to Upserge", ["Upsurge"]), "send to Upsurge")
        XCTAssertEqual(fix("Selta", ["Zelta"]), "Zelta")
        XCTAssertEqual(fix("ask Lowki", ["Lauki"]), "ask Lauki")
        XCTAssertEqual(fix("Sweta", ["Shweta"]), "Shweta")
    }

    func testPunctuationAndSurroundingTextSurvive() {
        XCTAssertEqual(fix("Hi Keeran, Keeran's deck?", ["Kiran"]), "Hi Kiran, Kiran's deck?")
    }

    func testAPhraseHeardInPiecesBecomesOneSpelling() {
        XCTAssertEqual(fix("ask ravi shanker today", ["Ravishankar"]), "ask Ravishankar today")
        XCTAssertEqual(fix("Upserge Labs", ["Upsurge Labs"]), "Upsurge Labs")
    }

    func testRealWordsAreNeverRewritten() {
        XCTAssertEqual(fix("phone on the deck", ["Phonon"]), "phone on the deck")
        XCTAssertEqual(fix("delta call", ["Zelta"]), "delta call")
        XCTAssertEqual(fix("the river", ["Rivar"]), "the river")
    }

    func testEverydayRomanHindiIsNeverRewritten() {
        let sentence = "kal client call karna hai, kaam kar lo, deck bhej dena yaar, kya baat hai"
        XCTAssertEqual(fix(sentence, ["Karan", "Kamal", "Dinesh", "Kiran", "Bhavna", "Kavya", "Dena"]).lowercased(), sentence)
    }

    func testDifferentNamesStaySeparate() {
        XCTAssertEqual(fix("Rohit and Rohan", ["Rohan"]), "Rohit and Rohan")
        XCTAssertEqual(fix("Ankita", ["Ankit"]), "Ankita")
        XCTAssertEqual(fix("Ravish", ["Ravi"]), "Ravish")
    }

    func testAShortNameNeedsTheSameSound() {
        XCTAssertEqual(fix("Anoo", ["Anu"]), "Anu")
        XCTAssertEqual(fix("Anil", ["Anu"]), "Anil")
    }

    func testTwoEquallyCloseEntriesAreLeftAlone() {
        XCTAssertEqual(fix("Karun", ["Karan", "Kirun"]), "Karun")
    }

    func testAnExactSpellingBeatsASoundAlike() {
        XCTAssertEqual(fix("Karan and Kiran", ["Karan", "Kiran"]), "Karan and Kiran")
    }

    func testShorthandAndBuiltInsDoNotListenForSoundAlikes() {
        let shorthand = VocabularyEntry(heard: "q three", replacement: "Quarter")
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "Kwarter and q three", entries: [shorthand], project: "All projects", isKnownWord: { _ in false }),
                       "Kwarter and Quarter")
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "ooiooi", entries: VocabularyEntry.builtIn, project: "All projects", isKnownWord: { _ in false }), "ooiooi")
    }

    func testOtherGroupsWordsAndOtherScriptsAreIgnored() {
        let scoped = VocabularyEntry(heard: "Kiran", replacement: "Kiran", project: "Work")
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "Keeran", entries: [scoped], project: "Home", isKnownWord: { _ in false }), "Keeran")
        XCTAssertEqual(fix("किरण", ["Kiran"]), "किरण")
    }

    func testWithoutAKnownWordCheckOnlyExactMatchesChange() {
        let entry = VocabularyEntry(heard: "Kiran", replacement: "Kiran")
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "Keeran kiran", entries: [entry], project: "All projects"), "Keeran Kiran")
    }
}
