import Foundation

/// A fix to one word of a saved item, together with the dictionary change that
/// makes the same mistake right next time. Pure value logic: callers persist the
/// item and the dictionary, and keep this value to undo both.
public struct HistoryWordFix: Equatable, Sendable {
    public enum DictionaryOutcome: Equatable, Sendable {
        case added
        /// An entry for the same spoken form and scope existed with another spelling.
        case updated(previous: VocabularyEntry)
        /// The same spoken form already maps to exactly this spelling.
        case alreadyPresent
    }
    public let before: CaptureItem
    public let after: CaptureItem
    public let heard: String
    /// The word as it appears in the text, for messages.
    public let heardAsWritten: String
    public let correction: String
    public let project: String
    public let outcome: DictionaryOutcome
    /// How many places in this item were changed.
    public let replacedCount: Int
}

public enum HistoryCorrection {
    public enum Rejection: Error, Equatable, Sendable {
        case emptyWord, emptyCorrection, unchanged, invalidTerm, wordNotFound
        public var message: String {
            switch self {
            case .emptyWord: "Choose a word to fix."
            case .emptyCorrection: "Type how the word should be written."
            case .unchanged: "That is already how it is written."
            case .invalidTerm: "Use plain text up to 120 characters."
            case .wordNotFound: "That word is no longer in this text."
            }
        }
    }

    /// Letters and digits form words; an apostrophe or hyphen joins letters inside a word.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark }
    }

    /// The word inside a whitespace-delimited chunk, without edge punctuation: "teh," becomes "teh".
    public static func coreWord(of chunk: String) -> String {
        var characters = Array(chunk)
        while let last = characters.last, !isWordCharacter(last) { characters.removeLast() }
        while let first = characters.first, !isWordCharacter(first) { characters.removeFirst() }
        return String(characters)
    }

    private static func boundedPattern(for word: String) -> NSRegularExpression? {
        let pattern = "(?<![\\p{L}\\p{N}\\p{M}_])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}\\p{M}_])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    public static func plan(item: CaptureItem, heard rawHeard: String, correction rawCorrection: String,
                            vocabulary: [VocabularyEntry], project: String = "All projects") throws -> HistoryWordFix {
        let heard = coreWord(of: rawHeard.trimmingCharacters(in: .whitespacesAndNewlines))
        let correction = rawCorrection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { throw Rejection.emptyWord }
        guard !correction.isEmpty else { throw Rejection.emptyCorrection }
        guard VocabularyEntry.isValidTerm(heard), VocabularyEntry.isValidTerm(correction),
              !correction.contains(where: \.isNewline) else { throw Rejection.invalidTerm }
        guard heard != correction else { throw Rejection.unchanged }
        guard let regex = boundedPattern(for: heard) else { throw Rejection.invalidTerm }
        let range = NSRange(item.body.startIndex..., in: item.body)
        let matches = regex.matches(in: item.body, range: range)
        guard !matches.isEmpty else { throw Rejection.wordNotFound }
        let body = NSMutableString(string: item.body)
        for match in matches.reversed() { body.replaceCharacters(in: match.range, with: correction) }

        var after = item
        after.body = body as String
        if item.title == TextProcessing.title(for: item.body) { after.title = TextProcessing.title(for: after.body) }
        // The first correction keeps the text as it was recognised; later ones leave that record alone.
        if after.rawText == nil { after.rawText = item.body }

        let spoken = heard.lowercased()
        let existing = vocabulary.first {
            $0.heard.caseInsensitiveCompare(spoken) == .orderedSame && $0.project.caseInsensitiveCompare(project) == .orderedSame
        }
        let outcome: HistoryWordFix.DictionaryOutcome
        if let existing {
            outcome = existing.replacement == correction ? .alreadyPresent : .updated(previous: existing)
        } else { outcome = .added }
        return HistoryWordFix(before: item, after: after, heard: spoken, heardAsWritten: heard, correction: correction,
                              project: project, outcome: outcome, replacedCount: matches.count)
    }

    /// The dictionary after the fix. An existing identical entry is left untouched.
    public static func vocabularyAfter(_ fix: HistoryWordFix, from vocabulary: [VocabularyEntry]) -> [VocabularyEntry] {
        var result = vocabulary
        switch fix.outcome {
        case .alreadyPresent: break
        case .added:
            result.append(VocabularyEntry(heard: fix.heard, replacement: fix.correction, project: fix.project))
        case .updated(let previous):
            if let index = result.firstIndex(where: { $0.id == previous.id }) {
                result[index].heard = fix.heard
                result[index].replacement = fix.correction
            } else {
                result.append(VocabularyEntry(heard: fix.heard, replacement: fix.correction, project: fix.project))
            }
        }
        return result
    }

    /// Undo removes only what the fix created, or restores only what it changed.
    /// An entry the user has since edited is left as they made it.
    public static func vocabularyBeforeFix(_ fix: HistoryWordFix, from vocabulary: [VocabularyEntry]) -> [VocabularyEntry] {
        var result = vocabulary
        func matches(_ entry: VocabularyEntry) -> Bool {
            entry.heard.caseInsensitiveCompare(fix.heard) == .orderedSame
                && entry.project.caseInsensitiveCompare(fix.project) == .orderedSame
                && entry.replacement == fix.correction
        }
        switch fix.outcome {
        case .alreadyPresent: break
        case .added:
            result.removeAll(where: matches)
        case .updated(let previous):
            if let index = result.firstIndex(where: matches) { result[index] = previous }
        }
        return result
    }
}
