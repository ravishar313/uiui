import Foundation

public enum TextProcessing {
    public static func title(for text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return first.isEmpty ? "Untitled" : String(first.prefix(80))
    }

    public static func wordCount(_ text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}\\p{M}]*(?:['’][\\p{L}\\p{N}\\p{M}]+)*") else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Restore the user's exact written forms after a casing/punctuation model.
    /// Matching only replacements prevents a second pass through heard aliases.
    public static func preservingVocabularySpelling(in text: String, entries: [VocabularyEntry], project: String) -> String {
        applyingVocabulary(to: text, entries: entries.map {
            VocabularyEntry(heard: $0.replacement, replacement: $0.replacement, project: $0.project)
        }, project: project)
    }

    /// Replacements are selected from the original text, so replacement output is never reprocessed.
    public static func applyingVocabulary(to text: String, entries: [VocabularyEntry], project: String) -> String {
        let candidates = entries.enumerated().filter {
            !$0.element.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            ($0.element.project == "All projects" || $0.element.project == project)
        }.sorted {
            if $0.element.heard.count != $1.element.heard.count { return $0.element.heard.count > $1.element.heard.count }
            // A project-specific spelling wins a duplicate phrase before a global spelling.
            if ($0.element.project == project) != ($1.element.project == project) { return $0.element.project == project }
            return $0.offset < $1.offset
        }
        struct Replacement { let range: NSRange; let value: String }
        var replacements: [Replacement] = []
        for candidate in candidates {
            let pattern = "(?<![\\p{L}\\p{N}\\p{M}_])" + NSRegularExpression.escapedPattern(for: candidate.element.heard) + "(?![\\p{L}\\p{N}\\p{M}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if !replacements.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
                    replacements.append(Replacement(range: match.range, value: candidate.element.replacement))
                }
            }
        }
        let result = NSMutableString(string: text)
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: replacement.range, with: replacement.value)
        }
        return result as String
    }
}

/// A deliberately small grammar. Unsupported or already elapsed dates require explicit user editing.
public enum ReminderParser {
    /// Only explicit reminder requests are eligible. The last supported time clause wins.
    public static func parseRequest(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let original = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        guard original.hasPrefix("remind me ") else { return nil }
        let request = normalizeTimeClauses(original)
        let pattern = "\\b(?:in [0-9]{1,6} (?:minutes?|hours?)|(?:today|tomorrow) at [0-9]{1,2}(?::[0-9]{2})? ?(?:am|pm))\\b"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(in: request, range: NSRange(request.startIndex..., in: request)).last,
              let range = Range(match.range, in: request) else { return nil }
        return parse(String(request[range]), now: now, calendar: calendar)
    }

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let input = normalizeTimeClauses(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased())
        func groups(_ pattern: String) -> [String]? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return nil }
            return (1..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: input) else { return "" }
                return String(input[range])
            }
        }
        if let parts = groups("^in ([0-9]{1,6}) (minute|minutes|hour|hours)$"), let amount = Int(parts[0]), amount > 0 {
            let component: Calendar.Component = parts[1].hasPrefix("minute") ? .minute : .hour
            guard let date = calendar.date(byAdding: component, value: amount, to: now), date > now else { return nil }
            return date
        }
        if let parts = groups("^(today|tomorrow) at ([0-9]{1,2})(?::([0-9]{2}))? ?(am|pm)$"),
           let hour = Int(parts[1]), (1...12).contains(hour) {
            let minute = Int(parts[2]) ?? 0
            guard (0...59).contains(minute),
                  let day = calendar.date(byAdding: .day, value: parts[0] == "tomorrow" ? 1 : 0, to: now) else { return nil }
            let hour24 = hour % 12 + (parts[3] == "pm" ? 12 : 0)
            let start = calendar.startOfDay(for: day)
            // Strict matching rejects nonexistent wall-clock times at daylight-saving transitions.
            let components = DateComponents(hour: hour24, minute: minute, second: 0)
            guard let date = calendar.nextDate(after: start.addingTimeInterval(-1), matching: components, matchingPolicy: .strict),
                  calendar.isDate(date, inSameDayAs: day), date > now else { return nil }
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var date = formatter.date(from: isoInput)
        if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: isoInput) }
        if date == nil, let parts = groups("^([0-9]{4})-([0-9]{2})-([0-9]{2})$"),
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            var components = DateComponents(); components.year = year; components.month = month; components.day = day
            if let candidate = calendar.date(from: components),
               calendar.component(.year, from: candidate) == year,
               calendar.component(.month, from: candidate) == month,
               calendar.component(.day, from: candidate) == day { date = candidate }
        }
        guard let date, date > now else { return nil }
        return date
    }

    /// Converts number words only inside complete supported time clauses, never stored reminder content.
    private static func normalizeTimeClauses(_ text: String) -> String {
        let units = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let words = "(?:" + units + "|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|(?:twenty|thirty|forty|fifty)(?:[ -]" + units + ")?)"
        let number = "(?:[0-9]{1,6}|" + words + ")"
        func replacing(_ source: String, pattern: String, transform: ([String]) -> String?) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
            let original = source as NSString
            let output = NSMutableString(string: source)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
                let groups = (1..<match.numberOfRanges).map { index in
                    match.range(at: index).location == NSNotFound ? "" : original.substring(with: match.range(at: index))
                }
                if let replacement = transform(groups) { output.replaceCharacters(in: match.range, with: replacement) }
            }
            return output as String
        }
        let relative = replacing(text, pattern: "\\bin (" + number + "|a|an) (minutes?|hours?)\\b") { groups in
            guard let value = spokenNumber(groups[0]) else { return nil }
            return "in \(value) \(groups[1])"
        }
        return replacing(relative, pattern: "\\b(today|tomorrow) at (" + number + ")(?::(" + number + "))? ?(am|pm)\\b") { groups in
            guard let hour = spokenNumber(groups[1]) else { return nil }
            let minute: String
            if groups[2].isEmpty { minute = "" }
            else {
                guard let value = spokenNumber(groups[2]) else { return nil }
                minute = String(format: ":%02d", value)
            }
            return "\(groups[0]) at \(hour)\(minute) \(groups[3])"
        }
    }

    private static func spokenNumber(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        if text == "a" || text == "an" { return 1 }
        let small = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]
        if let value = small[text] ?? tens[text] { return value }
        let pieces = text.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
        guard pieces.count == 2, let ten = tens[pieces[0]], let unit = small[pieces[1]], unit < 10 else { return nil }
        return ten + unit
    }
}
