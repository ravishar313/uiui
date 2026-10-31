import Foundation

public struct DictationCleanupSegment: Sendable, Equatable {
    public let text: String
    public let separator: String
    public var original: String { text + separator }

    public init(text: String, separator: String) {
        self.text = text
        self.separator = separator
    }
}

/// Lossless chunking and a conservative acceptance boundary for model cleanup.
/// These functions never call a model or discard source text.
public enum DictationCleanupText {
    /// Splits only between whole whitespace-delimited words. All segments except
    /// the last are stable when more text is appended to the source. A word over
    /// the budget is returned intact so the caller can leave it unmodified.
    public static func segments(for text: String, maximumUTF8Bytes: Int = 900) -> [DictationCleanupSegment] {
        guard !text.isEmpty else { return [] }
        let budget = max(1, maximumUTF8Bytes)
        var result: [DictationCleanupSegment] = []
        var cursor = text.startIndex
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        if cursor > text.startIndex {
            result.append(.init(text: "", separator: String(text[..<cursor])))
        }
        var start = cursor
        var bodyEnd = cursor
        var bodyBytes = 0
        var gapBytes = 0
        while cursor < text.endIndex {
            let wordStart = cursor
            var wordBytes = 0
            while cursor < text.endIndex, !text[cursor].isWhitespace {
                wordBytes += text[cursor].utf8.count
                cursor = text.index(after: cursor)
            }
            // Subtraction avoids overflow for a caller-supplied Int.max budget.
            if bodyBytes > 0, gapBytes > budget - min(bodyBytes, budget)
                || wordBytes > budget - min(bodyBytes + gapBytes, budget) {
                result.append(.init(text: String(text[start..<bodyEnd]),
                                    separator: String(text[bodyEnd..<wordStart])))
                start = wordStart
                bodyBytes = 0
                gapBytes = 0
            }
            bodyBytes += gapBytes + wordBytes
            bodyEnd = cursor
            gapBytes = 0
            while cursor < text.endIndex, text[cursor].isWhitespace {
                gapBytes += text[cursor].utf8.count
                cursor = text.index(after: cursor)
            }
        }
        if bodyBytes > 0 {
            result.append(.init(text: String(text[start..<bodyEnd]),
                                separator: String(text[bodyEnd...])))
        }
        return result
    }

    /// Speech models that already punctuate and capitalise (Phonon 2, Parakeet)
    /// are better at it than text-only cleanup, which re-derives every mark from
    /// bare words and cannot hear pauses or intonation. Such text keeps its own
    /// formatting; only all-lowercase text without any of `.,?!` goes to the
    /// cleanup model. A single capital or mark is enough to count as formatted,
    /// because the model rewrites casing and punctuation of whatever it receives.
    /// Callers must pass the raw recognised text, not dictionary-adjusted text.
    public static func isFormatted(_ text: String) -> Bool {
        text.contains(where: { $0.isUppercase || ".,?!".contains($0) })
    }

    /// Returns only candidates with exactly the original lexical tokens, in
    /// order. Rejection means the caller must retain the original segment.
    public static func accepted(_ candidate: String, for original: String) -> String? {
        // Chunk cleanup is bounded; this limit never limits source segmentation.
        let sourceBytes = original.utf8.count
        guard sourceBytes > 0, sourceBytes <= 16_384,
              candidate.utf8.count <= sourceBytes * 2 + 64,
              !isStructured(original), !isStructured(candidate) else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sourceTokens = tokens(in: original)
        guard original.contains(where: { $0.isLetter || $0.isNumber }),
              !sourceTokens.isEmpty, sourceTokens == tokens(in: trimmed) else { return nil }
        return trimmed
    }

    private static func isStructured(_ text: String) -> Bool {
        guard !text.contains(where: { "/\\@`<>[]{}|=_+*$#".contains($0) }),
              !text.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control && !CharacterSet.whitespacesAndNewlines.contains($0)
              }),
              !text.contains(where: { character in
                  character.unicodeScalars.contains(where: { scalar in
                      scalar.properties.generalCategory == .format
                          && !(scalar.value == 0x200D && character.unicodeScalars.contains(where: {
                              $0.properties.generalCategory == .otherSymbol
                          }))
                  })
              }) else { return true }
        // Protect domains, filenames, versions, decimal literals and invocation
        // syntax. False negatives cost source fidelity; false positives only skip
        // optional cleanup.
        if text.range(of: #"[\p{L}\p{N}][.][\p{L}\p{N}]|\d[:：]\d|[\p{L}\p{N}_][(]|(?:^|\s)--[\p{L}]"#,
                      options: .regularExpression) != nil { return true }
        let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if firstLine.range(of: #"^(?:[-•]\s|\d+[.)]\s|(?:let|var|const|func|function|def|class|struct|enum|import|guard|throw|return|if|for|while|go|git|npm|pnpm|yarn|bun|swift|python|python3|node|cargo|cd|ls|mkdir|rm|mv|cp|chmod|sh|zsh|bash|sudo|brew|gh|curl|ssh|kubectl|docker)\s)"#,
                           options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return ["true", "false", "nil", "null"].contains(firstLine.lowercased())
    }

    private static func tokens(in text: String) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            result.append(word.replacingOccurrences(of: "’", with: "'")
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping)
            word = ""
        }
        for index in characters.indices {
            let character = characters[index]
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let insideWord = previous.map(isLexical) == true && next.map(isLexical) == true
            let connector = insideWord && "'’-.".contains(character)
            let numericComma = character == "," && previous?.isNumber == true && next?.isNumber == true
            let numericSign = (character == "-" || character == "−") && next?.isNumber == true
            let numericSuffix = (character == "%" || character == "‰") && previous?.isNumber == true
            if isLexical(character) || connector || numericComma || numericSign || numericSuffix {
                word.append(character)
            } else {
                flush()
                // Symbols, including emoji and mathematical signs, are content.
                // Only whitespace and ordinary punctuation may be rewritten.
                if !character.isWhitespace && !character.isPunctuation {
                    result.append(String(character))
                }
            }
        }
        flush()
        return result
    }

    private static func isLexical(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character.unicodeScalars.allSatisfy {
            CharacterSet.nonBaseCharacters.contains($0)
        }
    }
}
