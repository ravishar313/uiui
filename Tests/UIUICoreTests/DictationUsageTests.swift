import XCTest
@testable import UIUICore

final class DictationUsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDaysIncludeEmptyOnesAndEndToday() {
        let overview = DictationUsage.overview(of: [], now: now, calendar: calendar)
        XCTAssertEqual(overview.days.count, 14)
        XCTAssertEqual(overview.days.last?.date, calendar.startOfDay(for: now))
        XCTAssertTrue(overview.isEmpty)
    }

    func testCountsTodayWeekAndOlder() {
        let events = [
            UsageEvent(date: now, action: "paste_dispatched", wordCount: 10),
            UsageEvent(date: now, action: "dictation_copied", wordCount: 5),
            UsageEvent(date: now.addingTimeInterval(-3 * 86_400), action: "paste_dispatched", wordCount: 20),
            UsageEvent(date: now.addingTimeInterval(-10 * 86_400), action: "paste_dispatched", wordCount: 40),
            UsageEvent(date: now, action: "speech_finalize", durationMS: 50),
        ]
        let overview = DictationUsage.overview(of: events, now: now, calendar: calendar)
        XCTAssertEqual(overview.dictationsToday, 2)
        XCTAssertEqual(overview.wordsToday, 15)
        XCTAssertEqual(overview.dictationsThisWeek, 3)
        XCTAssertEqual(overview.wordsThisWeek, 35)
        XCTAssertEqual(overview.days.reduce(0) { $0 + $1.words }, 75)
    }

    func testPaceWaitsForEnoughTimedSpeech() {
        let paste = UsageEvent(date: now, action: "paste_dispatched", wordCount: 60)
        let short = UsageEvent(date: now, action: DictationUsage.spoken, durationMS: 10_000)
        XCTAssertNil(DictationUsage.overview(of: [paste, short], now: now, calendar: calendar).wordsPerMinute)
        let long = UsageEvent(date: now, action: DictationUsage.spoken, durationMS: 30_000)
        let overview = DictationUsage.overview(of: [paste, long], now: now, calendar: calendar)
        XCTAssertEqual(overview.wordsPerMinute, 120)
        XCTAssertEqual(overview.spokenSecondsThisWeek, 30)
    }

    func testPaceIsWithheldWhileOlderDictationsHaveNoTiming() {
        var events = (0..<5).map { _ in UsageEvent(date: now, action: "paste_dispatched", wordCount: 60) }
        events.append(UsageEvent(date: now, action: DictationUsage.spoken, durationMS: 40_000))
        XCTAssertNil(DictationUsage.overview(of: events, now: now, calendar: calendar).wordsPerMinute)
    }

    func testDurationText() {
        XCTAssertEqual(DictationUsage.durationText(0), "0s")
        XCTAssertEqual(DictationUsage.durationText(45), "45s")
        XCTAssertEqual(DictationUsage.durationText(600), "10m")
        XCTAssertEqual(DictationUsage.durationText(3_900), "1h 5m")
    }
}
