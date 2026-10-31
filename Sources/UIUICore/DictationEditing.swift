import Foundation

/// Local editing commands for one current dictation hypothesis. This function has
/// no history and must never receive text from a previously completed capture.
public enum DictationEditing {
    public static func applyingCommands(to transcript: String) -> String {
        let word = "[\\p{L}\\p{N}\\p{M}_-]"
        let pattern = "(?<!" + word + ")(?:(?:no[ \\t,]+actually|actually|no)[ \\t,]+)?scratch[ \\t]+that(?!" + word + ")"
        guard let command = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return transcript }
        let quoted = quotedRanges(in: transcript)
        var result = ""
        var cursor = transcript.startIndex
        var correctionFloor = 0
        var edited = false

        for match in command.matches(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)) {
            guard let range = Range(match.range, in: transcript),
                  !quoted.contains(where: { $0.overlaps(range) }),
                  !isLiteralMention(before: range.lowerBound, in: transcript),
                  !isNegatedMention(before: range.lowerBound, in: transcript) else { continue }
            let preceding = String(transcript[cursor..<range.lowerBound])
            result = edited ? joining(result, preceding) : preceding
            let floor = result.index(result.startIndex, offsetBy: correctionFloor)
            result = String(result[..<floor]) + keepingEarlierSentences(in: String(result[floor...]))
            correctionFloor = result.count
            cursor = range.upperBound
            // ASR commonly attaches a comma or full stop to the editing command.
            // Consume its separator punctuation, preserving replacement punctuation.
            while cursor < transcript.endIndex,
                  transcript[cursor].isWhitespace || ",.!?:;".contains(transcript[cursor]) {
                cursor = transcript.index(after: cursor)
            }
            edited = true
        }
        guard edited else { return transcript }
        return joining(result, String(transcript[cursor...])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func keepingEarlierSentences(in text: String) -> String {
        var end = text.endIndex
        // A command immediately after a sentence's final punctuation corrects that
        // sentence, rather than merely deleting the empty gap after its full stop.
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace || isBoundary(at: previous, in: text) else { break }
            end = previous
        }
        let quotes = quotedRanges(in: text)
        var boundary: String.Index?
        for index in text.indices where index < end {
            if isBoundary(at: index, in: text), !quotes.contains(where: { $0.contains(index) }) {
                boundary = index
            }
        }
        guard let boundary else { return "" }
        return String(text[...boundary])
    }

    private static func isBoundary(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if character.isNewline || character == "!" || character == "?" { return true }
        guard character == "." else { return false }
        // A period inside a URL, email address, version or decimal is not a
        // sentence boundary. Sentence-ending periods require a following gap/end.
        let next = text.index(after: index)
        guard next == text.endIndex || text[next].isWhitespace else { return false }
        let token = String(text[..<index].reversed().prefix { $0.isLetter || $0 == "." }.reversed()).lowercased()
        return !abbreviations.contains(token)
    }

    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "st",
        "e.g", "i.e", "vs", "etc", "a.m", "p.m"
    ]

    private static func joining(_ prefix: String, _ suffix: String) -> String {
        let tail = suffix.drop(while: \.isWhitespace)
        guard !prefix.isEmpty else { return String(tail) }
        guard !tail.isEmpty else { return prefix }
        if prefix.last?.isWhitespace == true { return prefix + tail }
        return prefix + " " + tail
    }

    private static func isLiteralMention(before index: String.Index, in text: String) -> Bool {
        let prefix = String(text[..<index])
        return prefix.range(of: "(?<![\\p{L}\\p{N}\\p{M}_])the[ \\t]+phrase[ \\t:]+$",
                            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Treat immediate negation as dictated text, including common contractions
    /// and bounded instructions about saying/using/writing the command's words.
    /// The optional positive "no actually" prefix belongs to the command match,
    /// so "no actually scratch that" remains an explicit correction.
    private static func isNegatedMention(before index: String.Index, in text: String) -> Bool {
        let gap = "[ \\t,-]+"
        let negator = "(?:not|never|cannot|[\\p{L}]+n['’]t)"
        let modifiers = "(?:(?:actually|ever)" + gap + ")?(?:(?:say|use|write)" + gap + ")?"
        let pattern = "(?<![\\p{L}\\p{N}\\p{M}_])" + negator + gap + modifiers + "$"
        return String(text[..<index]).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Unclosed opening quotes protect the rest of the hypothesis conservatively.
    /// Apostrophes inside words (I'm, don't, Sarah's) are not quotation marks.
    private static func quotedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var opening: String.Index?
        var closing: Character?
        for index in text.indices {
            let character = text[index]
            let next = text.index(after: index)
            let previousIsWord = index > text.startIndex && isWord(text[text.index(before: index)])
            let nextIsWord = next < text.endIndex && isWord(text[next])
            let apostrophe = (character == "'" || character == "’") && previousIsWord && nextIsWord
            let escaped = index > text.startIndex && text[text.index(before: index)] == "\\"
            if let expected = closing {
                if character == expected, !apostrophe, !escaped, let start = opening {
                    ranges.append(start..<next)
                    opening = nil
                    closing = nil
                }
            } else {
                let pair: Character?
                switch character {
                case "\"": pair = "\""
                case "'" where !apostrophe && !previousIsWord: pair = "'"
                case "“": pair = "”"
                case "‘" where !apostrophe: pair = "’"
                case "`": pair = "`"
                default: pair = nil
                }
                if let pair { opening = index; closing = pair }
            }
        }
        if let opening { ranges.append(opening..<text.endIndex) }
        return ranges
    }

    private static func isWord(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || $0 == "_"
        }
    }
}
