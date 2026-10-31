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

    /// The nth whole-word occurrence, as a click on that word would report it.
    private func range(of word: String, nth: Int = 0, in body: String) -> NSRange {
        HistoryCorrection.exactMatches(of: word, in: body)[nth]
    }

    private func plan(_ body: String, _ heard: String, nth: Int = 0, to correction: String, others: Bool = false, dictionary: Bool = true,
                      vocabulary: [VocabularyEntry] = [], raw: String? = nil) throws -> HistoryWordFix {
        try HistoryCorrection.plan(item: item(body, raw: raw), wordRange: range(of: heard, nth: nth, in: body), expecting: heard, correction: correction,
                                   alsoFixOtherMatches: others, addToDictionary: dictionary, vocabulary: vocabulary)
    }

    func testOnlyTheClickedOccurrenceChangesAndOriginalIsRetained() throws {
        let body = "Send it to Karan, today. Karan agrees."
        let fix = try plan(body, "Karan", nth: 1, to: "Kiran")
        XCTAssertEqual(fix.after.body, "Send it to Karan, today. Kiran agrees.")
        XCTAssertEqual(fix.replacedCount, 1)
        XCTAssertEqual(fix.after.rawText, body)
        XCTAssertEqual(fix.after.title, "Send it to Karan, today. Kiran agrees.")
        XCTAssertEqual(fix.after.updatedAt, fix.before.updatedAt)
        XCTAssertEqual(fix.heard, "karan")
        XCTAssertEqual(fix.project, "All projects")
        XCTAssertEqual(fix.outcome, .added)
        let vocabulary = HistoryCorrection.vocabularyAfter(fix, from: [])
        XCTAssertEqual(vocabulary.map(\.heard), ["karan"])
        XCTAssertEqual(vocabulary.map(\.replacement), ["Kiran"])
    }

    func testAlsoFixOthersIsExactCaseWholeWordOnly() throws {
        let body = "Karan met karan and KARAN near Karanpur, then Karan left."
        let fix = try plan(body, "Karan", to: "Kiran", others: true)
        XCTAssertEqual(fix.after.body, "Kiran met karan and KARAN near Karanpur, then Kiran left.")
        XCTAssertEqual(fix.replacedCount, 2)
        let single = try plan(body, "Karan", to: "Kiran", others: false)
        XCTAssertEqual(single.after.body, "Kiran met karan and KARAN near Karanpur, then Karan left.")
    }

    func testClickedWordChangesEvenWhenSurroundedByPunctuation() throws {
        let fix = try plan("Say (Karan), please.", "Karan", to: "Kiran", others: true)
        XCTAssertEqual(fix.after.body, "Say (Kiran), please.")
    }

    func testStaleRangeIsRejectedAndTextNeverChangesOutsideTheRange() {
        let base = item("hello world")
        XCTAssertThrowsError(try HistoryCorrection.plan(item: base, wordRange: NSRange(location: 0, length: 5), expecting: "world",
                                                        correction: "x", vocabulary: [])) {
            XCTAssertEqual($0 as? HistoryCorrection.Rejection, .wordNotFound)
        }
        XCTAssertThrowsError(try HistoryCorrection.plan(item: base, wordRange: NSRange(location: 8, length: 9), expecting: "world",
                                                        correction: "x", vocabulary: [])) {
            XCTAssertEqual($0 as? HistoryCorrection.Rejection, .wordNotFound)
        }
    }

    func testRangeInsideALongerWordIsRejected() {
        let base = item("Cat catalog")
        XCTAssertThrowsError(try HistoryCorrection.plan(item: base, wordRange: NSRange(location: 4, length: 3), expecting: "cat",
                                                        correction: "Dog", vocabulary: [])) {
            XCTAssertEqual($0 as? HistoryCorrection.Rejection, .wordNotFound)
        }
    }

    func testExistingRawTextIsNotOverwritten() throws {
        let fix = try plan("Cat catalog cat", "cat", to: "Cat", raw: "kat catalog kat")
        XCTAssertEqual(fix.after.body, "Cat catalog Cat", "Only the whole word \"cat\" changes, not the start of catalog")
        XCTAssertEqual(fix.after.rawText, "kat catalog kat")
    }

    func testExactCaseIsKeptInDictionaryEntry() throws {
        let fix = try plan("use github now", "github", to: "GitHub")
        XCTAssertEqual(HistoryCorrection.vocabularyAfter(fix, from: []).first?.replacement, "GitHub")
    }

    func testDictionaryOptOutLeavesDictionaryAlone() throws {
        let existing = VocabularyEntry(heard: "karan", replacement: "Karen")
        let fix = try plan("hi karan", "karan", to: "Kiran", dictionary: false, vocabulary: [existing])
        XCTAssertEqual(fix.outcome, .notRequested)
        XCTAssertEqual(HistoryCorrection.vocabularyAfter(fix, from: [existing]), [existing])
        XCTAssertEqual(HistoryCorrection.vocabularyBeforeFix(fix, from: [existing]), [existing])
    }

    func testIdenticalExistingEntryIsNotDuplicated() throws {
        let existing = VocabularyEntry(heard: "Karan", replacement: "Kiran")
        let fix = try plan("hi karan", "karan", to: "Kiran", vocabulary: [existing])
        XCTAssertEqual(fix.outcome, .alreadyPresent)
        XCTAssertEqual(HistoryCorrection.vocabularyAfter(fix, from: [existing]), [existing])
        XCTAssertEqual(HistoryCorrection.vocabularyBeforeFix(fix, from: [existing]), [existing])
    }

    func testDifferentExistingEntryIsUpdatedAndRestoredOnUndo() throws {
        let existing = VocabularyEntry(heard: "karan", replacement: "Kiran Rao")
        let other = VocabularyEntry(heard: "uiui", replacement: "uiui")
        let fix = try plan("hi karan", "karan", to: "Kiran", vocabulary: [other, existing])
        XCTAssertEqual(fix.outcome, .updated(previous: existing))
        let after = HistoryCorrection.vocabularyAfter(fix, from: [other, existing])
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[1].id, existing.id)
        XCTAssertEqual(after[1].replacement, "Kiran")
        XCTAssertEqual(HistoryCorrection.vocabularyBeforeFix(fix, from: after), [other, existing])
    }

    func testUndoRemovesOnlyTheAddedEntryAndKeepsLaterEdits() throws {
        let fix = try plan("hi karan", "karan", to: "Kiran")
        let added = HistoryCorrection.vocabularyAfter(fix, from: [])
        let unrelated = VocabularyEntry(heard: "foo", replacement: "Foo")
        XCTAssertEqual(HistoryCorrection.vocabularyBeforeFix(fix, from: added + [unrelated]), [unrelated])
        var edited = added
        edited[0].replacement = "Kiran Rao"
        XCTAssertEqual(HistoryCorrection.vocabularyBeforeFix(fix, from: edited), edited)
    }

    func testScopedEntryDoesNotCountAsExistingGlobalEntry() throws {
        let scoped = VocabularyEntry(heard: "karan", replacement: "Other", project: "Work")
        XCTAssertEqual(try plan("hi karan", "karan", to: "Kiran", vocabulary: [scoped]).outcome, .added)
    }

    func testRejections() {
        let base = item("hello world")
        func reason(_ heard: String, _ correction: String) -> HistoryCorrection.Rejection? {
            do {
                _ = try HistoryCorrection.plan(item: base, wordRange: (base.body as NSString).range(of: "hello"), expecting: heard,
                                               correction: correction, vocabulary: [])
                return nil
            } catch { return error as? HistoryCorrection.Rejection }
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

    func testWordRangeAtOffset() {
        let body = "Ask (Karan), then  “well-known” चलो।"
        func word(at utf16Offset: Int) -> String? {
            HistoryCorrection.wordRange(in: body, atUTF16Offset: utf16Offset).map { (body as NSString).substring(with: $0) }
        }
        XCTAssertEqual(word(at: 0), "Ask")
        XCTAssertEqual(word(at: 5), "Karan")
        XCTAssertEqual(word(at: 10), "Karan", "the comma belongs to the chunk")
        XCTAssertNil(word(at: 3), "whitespace")
        XCTAssertNil(word(at: 100))
        XCTAssertEqual(word(at: (body as NSString).range(of: "well").location + 2), "well-known")
        XCTAssertEqual(word(at: (body as NSString).range(of: "चलो").location + 1), "चलो")
    }

    func testDictionarySuggestionDefaults() {
        for word in ["Kiran", "Karan", "uiui", "GitHub", "Priya", "Hinglish"] {
            XCTAssertTrue(HistoryCorrection.suggestsDictionaryEntry(for: word), word)
        }
        // Three letters or fewer, all-caps originals, and common function words default off.
        for word in ["us", "Raj", "I", "NASA", "OKR", "main", "ki", "ke", "ka", "hai", "par", "to", "me", "Mein", "this", "THEIR"] {
            XCTAssertFalse(HistoryCorrection.suggestsDictionaryEntry(for: word), word)
        }
    }

    func testDictionaryEntryAppliesToFutureText() throws {
        let fix = try plan("ask karan", "karan", to: "Kiran")
        let entries = HistoryCorrection.vocabularyAfter(fix, from: [])
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "tell Karan soon", entries: entries, project: "Personal"), "tell Kiran soon")
    }
}
