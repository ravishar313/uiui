import XCTest
@testable import UIUICore

final class TextProcessingTests: XCTestCase {
    func testTitleAndWordCountHandleWhitespaceAndUnicode() {
        XCTAssertEqual(TextProcessing.title(for: "\n \n Hello there\nsecond line"), "Hello there")
        XCTAssertEqual(TextProcessing.title(for: " \n "), "Untitled")
        XCTAssertEqual(TextProcessing.title(for: String(repeating: "🪷", count: 90)).count, 80)
        XCTAssertEqual(TextProcessing.wordCount("Hello, café! Don't stop. 123 🪷"), 5)
        XCTAssertEqual(TextProcessing.wordCount("किताब अच्छी cafe\u{301}"), 3)
        XCTAssertEqual(TextProcessing.wordCount("   🪷 -- "), 0)
    }

    func testVocabularyUsesLongestWholePhraseWithoutCascading() {
        let entries = [VocabularyEntry(heard: "new", replacement: "fresh"), VocabularyEntry(heard: "new york", replacement: "NYC"), VocabularyEntry(heard: "NYC", replacement: "city"), VocabularyEntry(heard: "cat", replacement: "dog"), VocabularyEntry(heard: "kit", replacement: "$1\\literal", project: "Work")]
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "New York, new! Cat concatenate cat_2 kit NYC", entries: entries, project: "Work"), "NYC, fresh! dog concatenate cat_2 $1\\literal city")
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "kit", entries: entries, project: "Home"), "kit")
    }

    func testProjectSpecificVocabularyWinsDuplicateAndEmptyEntriesAreIgnored() {
        let entries = [VocabularyEntry(heard: "", replacement: "bad"), VocabularyEntry(heard: "pi", replacement: "global"), VocabularyEntry(heard: "pi", replacement: "project", project: "Work")]
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "pi pilot π", entries: entries, project: "Work"), "project pilot π")
    }

    func testBuiltInSpellingsWriteTheAppNameAndUserEntriesWin() {
        let builtIn = VocabularyEntry.builtIn
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "Open UI UI and paste", entries: builtIn, project: "Personal"),
                       "Open uiui and paste")
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "I like you eye you eye.", entries: builtIn, project: "Personal"),
                       "I like uiui.")
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "the UI is clean", entries: builtIn, project: "Personal"),
                       "the UI is clean", "A single UI is ordinary speech")
        let user = [VocabularyEntry(heard: "UI UI", replacement: "UI/UI")]
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "UI UI", entries: user + builtIn, project: "Personal"), "UI/UI")
    }
}
