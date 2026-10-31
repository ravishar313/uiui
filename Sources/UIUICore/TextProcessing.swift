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
