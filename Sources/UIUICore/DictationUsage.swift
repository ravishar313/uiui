import Foundation

/// The numbers on Home, worked out from local usage counts. Never reads any words.
public enum DictationUsage {
    /// How long one dictation took to say. The duration is all it holds.
    public static let spoken = "dictation_spoken"

    public struct Day: Identifiable, Equatable, Sendable {
        public var date: Date
        public var dictations = 0
        public var words = 0
        public var id: Date { date }
    }

    public struct Overview: Equatable, Sendable {
        /// Oldest first, ending today, with empty days included.
        public var days: [Day] = []
        public var dictationsToday = 0
        public var wordsToday = 0
        public var dictationsThisWeek = 0
        public var wordsThisWeek = 0
        public var spokenSecondsThisWeek: Double = 0
        /// Nil until there is enough timed speech to mean anything.
        public var wordsPerMinute: Int?
        public var isEmpty: Bool { days.allSatisfy { $0.dictations == 0 } }
    }

    public static func overview(of events: [UsageEvent], now: Date, calendar: Calendar = .current, dayCount: Int = 14) -> Overview {
        var overview = Overview()
        let today = calendar.startOfDay(for: now)
        guard dayCount > 0 else { return overview }
        overview.days = (0..<dayCount).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { Day(date: $0) }
        }
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var timedWords = 0
        var timedSeconds = 0.0
        var spokenCount = 0
        for event in events where event.date <= now {
            let day = calendar.startOfDay(for: event.date)
            switch event.action {
            case "paste_dispatched", "dictation_copied":
                if let index = overview.days.firstIndex(where: { $0.date == day }) {
                    overview.days[index].dictations += 1
                    overview.days[index].words += event.wordCount
                }
                if day == today { overview.dictationsToday += 1; overview.wordsToday += event.wordCount }
                if day >= weekStart {
                    overview.dictationsThisWeek += 1
                    overview.wordsThisWeek += event.wordCount
                    timedWords += event.wordCount
                }
            case spoken:
                if day >= weekStart, let duration = event.durationMS {
                    overview.spokenSecondsThisWeek += duration / 1000
                    timedSeconds += duration / 1000
                    spokenCount += 1
                }
            default: break
            }
        }
        // Only timed dictations can give a pace, and older ones have no timing, so a
        // week that mixes both would overstate it. Wait until nearly all are timed.
        if timedSeconds >= 30, spokenCount * 10 >= overview.dictationsThisWeek * 9 {
            overview.wordsPerMinute = Int((Double(timedWords) / timedSeconds * 60).rounded())
        }
        return overview
    }

    public static func durationText(_ seconds: Double) -> String {
        guard seconds >= 1 else { return "0s" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
