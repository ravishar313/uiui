import Foundation

/// A fix to one word of a saved item, together with the dictionary change that
/// makes the same mistake right next time. Pure value logic: callers persist the
/// item and the dictionary, and keep this value to undo both.
public struct HistoryWordFix: Equatable, Sendable {
    public enum DictionaryOutcome: Equatable, Sendable {
        /// The person chose not to teach the dictionary; it is untouched.
        case notRequested
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

    /// The UTF-16 range of the word under `offset`: the whitespace-delimited chunk
    /// around it, without edge punctuation. Nil on whitespace or punctuation-only chunks.
    public static func wordRange(in body: String, atUTF16Offset offset: Int) -> NSRange? {
        let utf16 = body.utf16
        guard offset >= 0, offset < utf16.count,
              let position = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let at = position.samePosition(in: body), !body[at].isWhitespace else { return nil }
        var start = at
        while start > body.startIndex {
            let previous = body.index(before: start)
            if body[previous].isWhitespace { break }
            start = previous
        }
        var end = body.index(after: at)
        while end < body.endIndex, !body[end].isWhitespace { end = body.index(after: end) }
        var core = start..<end
        while core.lowerBound < core.upperBound, !isWordCharacter(body[body.index(before: core.upperBound)]) {
            core = core.lowerBound..<body.index(before: core.upperBound)
        }
        while core.lowerBound < core.upperBound, !isWordCharacter(body[core.lowerBound]) {
            core = body.index(after: core.lowerBound)..<core.upperBound
        }
        guard !core.isEmpty else { return nil }
        return NSRange(core, in: body)
    }

    private static func boundedPattern(for word: String) -> NSRegularExpression? {
        let pattern = "(?<![\\p{L}\\p{N}\\p{M}_])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}\\p{M}_])"
        return try? NSRegularExpression(pattern: pattern)
    }

    /// Every whole-word, exact-case occurrence of `word` in `body`.
    public static func exactMatches(of word: String, in body: String) -> [NSRange] {
        guard !word.isEmpty, let regex = boundedPattern(for: word) else { return [] }
        return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).map(\.range)
    }

    /// Short words, all-caps words and common function words (English and Roman
    /// Hinglish) are usually a one-off mishearing, not a spelling to teach.
    private static let functionWords: Set<String> = [
        "us", "main", "ki", "ke", "ka", "ko", "hai", "hain", "par", "pe", "to", "toh", "me", "mein", "se", "ne", "ye", "yeh",
        "wo", "woh", "tha", "thi", "the", "kya", "aur", "nahi", "nahin", "bhi", "hi", "jo", "ab", "tab", "phir", "agar", "lekin",
        "kuch", "koi", "mera", "meri", "mere", "apna", "hum", "tum", "aap", "iss", "uss", "this", "that", "with", "from", "have",
        "they", "them", "then", "than", "were", "your", "what", "when", "where", "will", "would", "could", "should", "there",
        "their", "about", "which", "been", "into", "just", "also", "only", "some", "more", "very", "here", "does", "our"
    ]

    /// Whether "Use this spelling in future dictation" starts checked for this word.
    public static func suggestsDictionaryEntry(for word: String) -> Bool {
        let core = coreWord(of: word)
        guard core.count > 3 else { return false }
        if core == core.uppercased(), core != core.lowercased() { return false }
        return !functionWords.contains(core.lowercased())
    }

    /// Plans a fix to the word at `wordRange`. Only that occurrence changes unless
    /// `alsoFixOtherMatches` is set, which adds every other whole-word, exact-case
    /// match in this item. The dictionary changes only when `addToDictionary` is set.
    public static func plan(item: CaptureItem, wordRange: NSRange, expecting rawHeard: String, correction rawCorrection: String,
                            alsoFixOtherMatches: Bool = false, addToDictionary: Bool = true,
                            vocabulary: [VocabularyEntry], project: String = "All projects") throws -> HistoryWordFix {
        let expected = coreWord(of: rawHeard.trimmingCharacters(in: .whitespacesAndNewlines))
        let correction = rawCorrection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { throw Rejection.emptyWord }
        guard !correction.isEmpty else { throw Rejection.emptyCorrection }
        guard VocabularyEntry.isValidTerm(expected), VocabularyEntry.isValidTerm(correction),
              !correction.contains(where: \.isNewline) else { throw Rejection.invalidTerm }
        guard expected != correction else { throw Rejection.unchanged }
        let text = item.body as NSString
        guard wordRange.location != NSNotFound, wordRange.length > 0, NSMaxRange(wordRange) <= text.length,
              text.substring(with: wordRange) == expected,
              let swiftRange = Range(wordRange, in: item.body) else { throw Rejection.wordNotFound }
        // The range must be a whole word, never the middle of a longer one.
        if swiftRange.lowerBound > item.body.startIndex, isWordCharacter(item.body[item.body.index(before: swiftRange.lowerBound)]) {
            throw Rejection.wordNotFound
        }
        if swiftRange.upperBound < item.body.endIndex, isWordCharacter(item.body[swiftRange.upperBound]) { throw Rejection.wordNotFound }
        var ranges = [wordRange]
        if alsoFixOtherMatches {
            for match in exactMatches(of: expected, in: item.body) where !ranges.contains(where: { NSIntersectionRange($0, match).length > 0 }) {
                ranges.append(match)
            }
        }
        let body = NSMutableString(string: item.body)
        for range in ranges.sorted(by: { $0.location > $1.location }) { body.replaceCharacters(in: range, with: correction) }

        var after = item
        after.body = body as String
        if item.title == TextProcessing.title(for: item.body) { after.title = TextProcessing.title(for: after.body) }
        // The first correction keeps the text as it was recognised; later ones leave that record alone.
        if after.rawText == nil { after.rawText = item.body }

        let spoken = expected.lowercased()
        let outcome: HistoryWordFix.DictionaryOutcome
        if !addToDictionary { outcome = .notRequested }
        else if let existing = vocabulary.first(where: {
            $0.heard.caseInsensitiveCompare(spoken) == .orderedSame && $0.project.caseInsensitiveCompare(project) == .orderedSame
        }) {
            outcome = existing.replacement == correction ? .alreadyPresent : .updated(previous: existing)
        } else { outcome = .added }
        return HistoryWordFix(before: item, after: after, heard: spoken, heardAsWritten: expected, correction: correction,
                              project: project, outcome: outcome, replacedCount: ranges.count)
    }

    /// The dictionary after the fix. An existing identical entry is left untouched.
    public static func vocabularyAfter(_ fix: HistoryWordFix, from vocabulary: [VocabularyEntry]) -> [VocabularyEntry] {
        var result = vocabulary
        switch fix.outcome {
        case .alreadyPresent, .notRequested: break
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
        case .alreadyPresent, .notRequested: break
        case .added:
            result.removeAll(where: matches)
        case .updated(let previous):
            if let index = result.firstIndex(where: matches) { result[index] = previous }
        }
        return result
    }
}
