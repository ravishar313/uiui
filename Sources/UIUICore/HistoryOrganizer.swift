import Foundation

public struct HistorySection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let items: [CaptureItem]
}

/// Pure presentation grouping for saved history: pinned first, then Today,
/// Yesterday and older days. Nothing here reads or writes storage.
public enum HistoryOrganizer {
    public static let pinnedID = "pinned"

    public static func sections(for items: [CaptureItem], now: Date = Date(),
                                calendar: Calendar = .current, locale: Locale = .current) -> [HistorySection] {
        func newestFirst(_ a: CaptureItem, _ b: CaptureItem) -> Bool {
            a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id.uuidString < b.id.uuidString
        }
        var result: [HistorySection] = []
        let pinned = items.filter(\.isPinned).sorted(by: newestFirst)
        if !pinned.isEmpty { result.append(HistorySection(id: pinnedID, title: "Pinned", items: pinned)) }
        let rest = items.filter { !$0.isPinned }.sorted(by: newestFirst)
        let today = calendar.startOfDay(for: now)
        var order: [Date] = []
        var buckets: [Date: [CaptureItem]] = [:]
        for item in rest {
            let day = calendar.startOfDay(for: item.createdAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        for day in order {
            result.append(HistorySection(id: String(Int(day.timeIntervalSince1970)),
                                         title: title(for: day, today: today, calendar: calendar, locale: locale),
                                         items: buckets[day] ?? []))
        }
        return result
    }

    static func title(for day: Date, today: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(day, inSameDayAs: today) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEE d MMMM" : "d MMMM yyyy")
        return formatter.string(from: day)
    }

    /// Destination apps present in history, without blanks or case-only duplicates.
    public static func apps(in items: [CaptureItem]) -> [String] {
        var seen = Set<String>()
        var apps: [String] = []
        for item in items {
            guard let name = item.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  seen.insert(name.lowercased()).inserted else { continue }
            apps.append(name)
        }
        return apps.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A nil filter keeps everything, including items with no recorded app.
    public static func filter(_ items: [CaptureItem], app: String?) -> [CaptureItem] {
        guard let app else { return items }
        return items.filter { $0.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(app) == .orderedSame }
    }
}

/// Words dictated and an honest, rounded estimate of typing time avoided.
/// Computed from the items passed in, so deleted items are never counted.
public struct DictationStats: Equatable, Sendable {
    public static let assumedTypingWordsPerMinute = 40
    public let words: Int
    public let dictations: Int

    public init(words: Int, dictations: Int) { self.words = words; self.dictations = dictations }

    /// Nil when there is nothing to report.
    public static func compute(from items: [CaptureItem], since: Date? = nil) -> DictationStats? {
        var words = 0, dictations = 0
        for item in items where item.kind == .dictation && (since.map { item.createdAt >= $0 } ?? true) {
            let count = TextProcessing.wordCount(item.body)
            guard count > 0 else { continue }
            words += count; dictations += 1
        }
        return words == 0 ? nil : DictationStats(words: words, dictations: dictations)
    }

    public var minutesOfTyping: Double { Double(words) / Double(Self.assumedTypingWordsPerMinute) }

    /// "about 31 min" or "about 1.5 hours". Never claims precision.
    public var typingTimeDescription: String {
        let minutes = minutesOfTyping
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "about \(Int(minutes.rounded())) min" }
        let hours = (minutes / 6).rounded() / 10
        let text = hours.rounded() == hours ? String(Int(hours)) : String(hours)
        return "about \(text) \(hours == 1 ? "hour" : "hours")"
    }

    public var summary: String {
        let noun = words == 1 ? "word" : "words"
        return "\(words.formatted()) \(noun) dictated · \(typingTimeDescription) of typing saved"
    }
}
