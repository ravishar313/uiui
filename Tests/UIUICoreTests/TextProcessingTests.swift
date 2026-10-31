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

    func testReminderGrammarRejectsPastAndUnsupportedInputs() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z"))
        XCTAssertEqual(ReminderParser.parse("in 10 minutes", now: now, calendar: calendar), now.addingTimeInterval(600))
        XCTAssertEqual(ReminderParser.parse("in 2 hours", now: now, calendar: calendar), now.addingTimeInterval(7200))
        XCTAssertEqual(ReminderParser.parse("today at 5 pm", now: now, calendar: calendar), now.addingTimeInterval(5 * 3600))
        XCTAssertEqual(ReminderParser.parse("tomorrow at 9 am", now: now, calendar: calendar), now.addingTimeInterval(21 * 3600))
        XCTAssertNotNil(ReminderParser.parse("2026-10-24", now: now, calendar: calendar))
        XCTAssertNotNil(ReminderParser.parse("2026-10-24T09:00:00Z", now: now, calendar: calendar))
        for text in ["today at 9 am", "in 0 minutes", "tomorrow at 13 pm", "tomorrow at 9:99 am", "next Tuesday", "2026-02-30", "2026-10-22", "2026-10-22T12:00:00Z"] {
            XCTAssertNil(ReminderParser.parse(text, now: now, calendar: calendar), text)
        }
    }

    func testExplicitReminderRequestExtractsRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(ReminderParser.parseRequest("Remind me to check build in 10 minutes", now: now), now.addingTimeInterval(600))
        XCTAssertEqual(ReminderParser.parseRequest("remind me in 10 minutes or in 2 hours", now: now), now.addingTimeInterval(7200))
    }

    func testExplicitReminderRequestExtractsWallClockBeforeTaskText() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z"))
        XCTAssertEqual(ReminderParser.parseRequest("remind me tomorrow at 9 am to review notes", now: now, calendar: calendar), now.addingTimeInterval(21 * 3600))
    }

    func testReminderRequestRejectsNegationAndUnsupportedUnits() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for request in ["not remind me in 10 minutes", "don't remind me in 10 minutes", "discuss remind me in 10 minutes", "remind me in 2 weeks", "remind me tomorrow at 25 pm", "in 10 minutes"] {
            XCTAssertNil(ReminderParser.parseRequest(request, now: now), request)
        }
    }

    func testSpokenReminderNumbersStayWithinSupportedTimeGrammar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z"))
        let durations: [(String, Int)] = [("one", 1), ("nineteen", 19), ("twenty", 20), ("twenty five", 25), ("thirty-nine", 39), ("fifty nine", 59), ("a", 1)]
        for (words, minutes) in durations {
            XCTAssertEqual(ReminderParser.parseRequest("remind me in \(words) minutes to check build", now: now, calendar: calendar), now.addingTimeInterval(Double(minutes * 60)))
        }
        XCTAssertEqual(ReminderParser.parseRequest("remind me in an hour to check build", now: now, calendar: calendar), now.addingTimeInterval(3600))
        XCTAssertEqual(ReminderParser.parseRequest("remind me tomorrow at nine AM to check build", now: now, calendar: calendar), now.addingTimeInterval(21 * 3600))
        XCTAssertEqual(ReminderParser.parse("in twenty five minutes", now: now, calendar: calendar), now.addingTimeInterval(1500))
        for request in ["remind me in sixty minutes", "remind me in twenty days", "remind me in twenty one hundred minutes", "don't remind me in twenty minutes", "discuss tomorrow at nine am", "not remind me in a minute"] {
            XCTAssertNil(ReminderParser.parseRequest(request, now: now, calendar: calendar), request)
        }
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
