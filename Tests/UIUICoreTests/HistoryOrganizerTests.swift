import XCTest
@testable import UIUICore

final class HistoryOrganizerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US")
    private func date(_ day: Int, month: Int = 10, year: Int = 2026, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func item(_ body: String, at created: Date, app: String? = nil, pinned: Bool = false, kind: CaptureKind = .dictation) -> CaptureItem {
        CaptureItem(title: body, body: body, kind: kind, createdAt: created, updatedAt: created, isPinned: pinned, sourceApp: app)
    }

    func testGroupsPinnedTodayYesterdayThenDates() {
        let now = date(31, hour: 15)
        let items = [
            item("old", at: date(20)), item("today a", at: date(31, hour: 9)), item("today b", at: date(31, hour: 14)),
            item("yesterday", at: date(30, hour: 23)), item("pinned", at: date(2), pinned: true),
            item("last year", at: date(5, month: 3, year: 2025))
        ]
        let sections = HistoryOrganizer.sections(for: items, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(sections.map(\.title), ["Pinned", "Today", "Yesterday", "Tuesday, October 20", "March 5, 2025"])
        XCTAssertEqual(sections[1].items.map(\.body), ["today b", "today a"])
    }

    func testEmptyInputHasNoSections() {
        XCTAssertTrue(HistoryOrganizer.sections(for: [], now: Date(), calendar: calendar, locale: locale).isEmpty)
    }

    func testAppsAreDistinctAndFilterHandlesMissingApp() {
        let items = [item("a", at: date(1), app: "Slack"), item("b", at: date(2), app: "slack"),
                     item("c", at: date(3), app: nil), item("d", at: date(4), app: "  "), item("e", at: date(5), app: "Mail")]
        XCTAssertEqual(HistoryOrganizer.apps(in: items), ["Mail", "Slack"])
        XCTAssertEqual(HistoryOrganizer.filter(items, app: nil).count, 5)
        XCTAssertEqual(HistoryOrganizer.filter(items, app: "SLACK").map(\.body), ["a", "b"])
        XCTAssertTrue(HistoryOrganizer.filter(items, app: "Notes").isEmpty)
    }

    func testStatsCountOnlySavedDictationWords() {
        let items = [item(String(repeating: "word ", count: 80), at: date(1)),
                     item("two words", at: date(2), kind: .note)]
        let stats = DictationStats.compute(from: items)
        XCTAssertEqual(stats, DictationStats(words: 80, dictations: 1))
        XCTAssertEqual(stats?.typingTimeDescription, "about 2 min")
        XCTAssertEqual(stats?.summary, "80 words dictated · about 2 min of typing saved")
        XCTAssertNil(DictationStats.compute(from: []))
        XCTAssertNil(DictationStats.compute(from: [item("   ", at: date(1))]))
    }

    func testStatsExcludeDeletedAndOlderItems() {
        let kept = item("one two three four", at: date(30))
        let deleted = item("five six seven eight", at: date(30))
        XCTAssertEqual(DictationStats.compute(from: [kept, deleted])?.words, 8)
        XCTAssertEqual(DictationStats.compute(from: [kept])?.words, 4)
        XCTAssertEqual(DictationStats.compute(from: [kept, item("old words here", at: date(1))], since: date(25))?.words, 4)
    }

    func testTimeDescriptionScales() {
        XCTAssertEqual(DictationStats(words: 10, dictations: 1).typingTimeDescription, "under a minute")
        XCTAssertEqual(DictationStats(words: 2_400, dictations: 5).typingTimeDescription, "about 1 hour")
        XCTAssertEqual(DictationStats(words: 3_600, dictations: 5).typingTimeDescription, "about 1.5 hours")
        XCTAssertEqual(DictationStats(words: 1, dictations: 1).summary, "1 word dictated · under a minute of typing saved")
    }
}

final class HistoryCorrectionTests: XCTestCase {
    private func item(_ body: String, raw: String? = nil) -> CaptureItem {
        CaptureItem(title: TextProcessing.title(for: body), body: body, kind: .dictation, rawText: raw)
    }

    func testFixesWordKeepsPunctuationAndRetainsOriginal() throws {
        let original = item("Send it to Zelda, today. Zelda agrees.")
        let fix = try HistoryCorrection.plan(item: original, heard: "Zelda,", correction: "Zelta", vocabulary: [])
        XCTAssertEqual(fix.after.body, "Send it to Zelta, today. Zelta agrees.")
        XCTAssertEqual(fix.replacedCount, 2)
        XCTAssertEqual(fix.after.rawText, "Send it to Zelda, today. Zelda agrees.")
        XCTAssertEqual(fix.after.title, "Send it to Zelta, today. Zelta agrees.")
        XCTAssertEqual(fix.after.updatedAt, original.updatedAt)
        XCTAssertEqual(fix.heard, "zelda")
        XCTAssertEqual(fix.project, "All projects")
        XCTAssertEqual(fix.outcome, .added)
        let vocabulary = HistoryCorrection.vocabularyAfter(fix, from: [])
        XCTAssertEqual(vocabulary.map(\.heard), ["zelda"])
        XCTAssertEqual(vocabulary.map(\.replacement), ["Zelta"])
        XCTAssertEqual(vocabulary.first?.project, "All projects")
    }

    func testExistingRawTextIsNotOverwrittenAndWholeWordsOnly() throws {
        let fix = try HistoryCorrection.plan(item: item("Cat catalog cat", raw: "kat catalog kat"), heard: "cat", correction: "Cat", vocabulary: [])
        XCTAssertEqual(fix.after.body, "Cat catalog Cat")
        XCTAssertEqual(fix.after.rawText, "kat catalog kat")
    }

    func testExactCaseIsKeptInDictionaryEntry() throws {
        let fix = try HistoryCorrection.plan(item: item("use github now"), heard: "github", correction: "GitHub", vocabulary: [])
        XCTAssertEqual(HistoryCorrection.vocabularyAfter(fix, from: []).first?.replacement, "GitHub")
    }

    func testIdenticalExistingEntryIsNotDuplicated() throws {
        let existing = VocabularyEntry(heard: "Zelda", replacement: "Zelta")
        let fix = try HistoryCorrection.plan(item: item("hi zelda"), heard: "zelda", correction: "Zelta", vocabulary: [existing])
        XCTAssertEqual(fix.outcome, .alreadyPresent)
        XCTAssertEqual(HistoryCorrection.vocabularyAfter(fix, from: [existing]), [existing])
        XCTAssertEqual(HistoryCorrection.vocabularyBeforeFix(fix, from: [existing]), [existing])
    }

    func testDifferentExistingEntryIsUpdatedAndRestoredOnUndo() throws {
        let existing = VocabularyEntry(heard: "zelda", replacement: "Zelta Health")
        let other = VocabularyEntry(heard: "uiui", replacement: "uiui")
        let fix = try HistoryCorrection.plan(item: item("hi zelda"), heard: "zelda", correction: "Zelta", vocabulary: [other, existing])
        XCTAssertEqual(fix.outcome, .updated(previous: existing))
        let after = HistoryCorrection.vocabularyAfter(fix, from: [other, existing])
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[1].id, existing.id)
        XCTAssertEqual(after[1].replacement, "Zelta")
        XCTAssertEqual(HistoryCorrection.vocabularyBeforeFix(fix, from: after), [other, existing])
    }

    func testUndoRemovesOnlyTheAddedEntryAndKeepsLaterEdits() throws {
        let fix = try HistoryCorrection.plan(item: item("hi zelda"), heard: "zelda", correction: "Zelta", vocabulary: [])
        let added = HistoryCorrection.vocabularyAfter(fix, from: [])
        let unrelated = VocabularyEntry(heard: "foo", replacement: "Foo")
        XCTAssertEqual(HistoryCorrection.vocabularyBeforeFix(fix, from: added + [unrelated]), [unrelated])
        var edited = added
        edited[0].replacement = "Zelta Health"
        XCTAssertEqual(HistoryCorrection.vocabularyBeforeFix(fix, from: edited), edited)
    }

    func testScopedEntryDoesNotCountAsExistingGlobalEntry() throws {
        let scoped = VocabularyEntry(heard: "zelda", replacement: "Other", project: "Work")
        let fix = try HistoryCorrection.plan(item: item("hi zelda"), heard: "zelda", correction: "Zelta", vocabulary: [scoped])
        XCTAssertEqual(fix.outcome, .added)
    }

    func testRejections() {
        let base = item("hello world")
        func reason(_ heard: String, _ correction: String) -> HistoryCorrection.Rejection? {
            do { _ = try HistoryCorrection.plan(item: base, heard: heard, correction: correction, vocabulary: []); return nil }
            catch { return error as? HistoryCorrection.Rejection }
        }
        XCTAssertEqual(reason("  ", "x"), .emptyWord)
        XCTAssertEqual(reason("...", "x"), .emptyWord)
        XCTAssertEqual(reason("hello", "  "), .emptyCorrection)
        XCTAssertEqual(reason("hello", "hello"), .unchanged)
        XCTAssertEqual(reason("hello", "a\nb"), .invalidTerm)
        XCTAssertEqual(reason("hello", String(repeating: "a", count: 121)), .invalidTerm)
        XCTAssertEqual(reason("absent", "x"), .wordNotFound)
        XCTAssertNil(reason("hello", "Hello"))
    }

    func testCoreWordStripsEdgePunctuationOnly() {
        XCTAssertEqual(HistoryCorrection.coreWord(of: "(don't)."), "don't")
        XCTAssertEqual(HistoryCorrection.coreWord(of: "“well-known,”"), "well-known")
        XCTAssertEqual(HistoryCorrection.coreWord(of: "किताब।"), "किताब")
    }

    func testDictionaryEntryAppliesToFutureText() throws {
        let fix = try HistoryCorrection.plan(item: item("ask zelda"), heard: "zelda", correction: "Zelta", vocabulary: [])
        let entries = HistoryCorrection.vocabularyAfter(fix, from: [])
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "tell Zelda soon", entries: entries, project: "Personal"), "tell Zelta soon")
    }
}
