import Foundation

/// Backspace while dictating. The recogniser keeps revising its text, so a deleted word
/// could otherwise come straight back. Pressing Backspace freezes everything spoken so
/// far, and from then on only words after that point can come from the recogniser.
/// Until the first press the text passes through untouched.
public struct TranscriptErasure: Equatable, Sendable {
    /// How far the recogniser may have shifted earlier words between two hypotheses.
    private static let alignmentWindow = 5
    private static let anchorLength = 3

    private var kept: String?
    private var frozenWordCount = 0
    private var anchor: [String] = []

    public init() {}

    /// What the person should see for this recogniser hypothesis.
    public func apply(to raw: String) -> String {
        guard let kept else { return raw }
        let words = wordRanges(in: raw)
        let position = alignedPosition(in: words.map { normalized(raw[$0]) })
        guard position < words.count else { return kept }
        let tail = String(raw[words[position].lowerBound...])
        return kept.isEmpty ? tail : kept + " " + tail
    }

    /// Removes the last visible word. Editing commands are resolved first, so this
    /// removes the word the person can see rather than part of "scratch that".
    public mutating func eraseLastWord(from raw: String) {
        let visible = DictationEditing.applyingCommands(to: apply(to: raw))
        let words = wordRanges(in: raw).map { normalized(raw[$0]) }
        frozenWordCount = kept == nil ? words.count : max(alignedPosition(in: words), words.count)
        anchor = Array(words.suffix(Self.anchorLength))
        kept = wordRanges(in: visible).last.map {
            String(visible[..<$0.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
    }

    /// Where the words after the freeze begin in this hypothesis. Prefers the position
    /// whose preceding words match what came before the freeze, closest to where it was.
    private func alignedPosition(in words: [String]) -> Int {
        let lower = max(0, frozenWordCount - Self.alignmentWindow)
        let upper = min(words.count, frozenWordCount + Self.alignmentWindow)
        guard lower <= upper else { return words.count }
        var best = min(frozenWordCount, words.count)
        var bestScore = 0
        for position in lower...upper {
            var score = 0
            for (offset, word) in anchor.reversed().enumerated() {
                guard position - 1 - offset >= 0, words[position - 1 - offset] == word else { break }
                score += 1
            }
            let closer = abs(position - frozenWordCount) < abs(best - frozenWordCount)
            if score > bestScore || (score == bestScore && score > 0 && closer) {
                best = position
                bestScore = score
            }
        }
        return best
    }

    private func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let begun = start { ranges.append(begun..<index); start = nil }
            } else if start == nil { start = index }
            index = text.index(after: index)
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// Punctuation and case often change between hypotheses of the same word.
    private func normalized(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
