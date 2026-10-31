import Foundation

/// Source ranges survive tokenization. Normalization is model input only: it is
/// never used to rebuild the person's words, spacing, symbols, or URL bytes.
public enum MiniLMText {
    public struct Word: Sendable, Equatable {
        public let range: NSRange
        public let original: String
        public let normalized: String
    }

    public struct Prediction: Sendable, Equatable {
        public enum Punctuation: Int, Sendable { case none, comma, period, question, exclamation }
        public enum Casing: Int, Sendable { case lower, capitalized, upper }
        public let punctuation: Punctuation
        public let casing: Casing
        public init(punctuation: Punctuation, casing: Casing) {
            self.punctuation = punctuation; self.casing = casing
        }
    }

    public struct Chunk: Sendable, Equatable {
        public let context: Range<Int>
        public let emission: Range<Int>
    }

    public enum Failure: Error { case unsupportedLength, alignment }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\p{L}[\p{L}\p{M}\p{N}'’\-]*|\p{N}+(?:[.,]\p{N}+)*"#)
    private static let urlPattern = try! NSRegularExpression(pattern: #"(?:https?://|www\.)\S+"#, options: .caseInsensitive)
    private static let ordinaryPunctuation = CharacterSet(charactersIn: ".,!?;:")

    public static func words(in source: String) -> [Word] {
        let fullRange = NSRange(source.startIndex..., in: source)
        let urls = urlPattern.matches(in: source, range: fullRange).map(\.range)
        return wordPattern.matches(in: source, range: fullRange).compactMap { match in
            guard !urls.contains(where: { NSLocationInRange(match.range.location, $0) }),
                  let range = Range(match.range, in: source) else { return nil }
            let original = String(source[range])
            return Word(range: match.range, original: original,
                        normalized: original.precomposedStringWithCompatibilityMapping.lowercased())
        }
    }

    /// Publisher windowing: 126 content pieces, up to 25 context pieces and 24
    /// overlapping words on either side. Each source word is emitted once.
    public static func chunks(pieceCounts counts: [Int]) throws -> [Chunk] {
        guard counts.allSatisfy({ $0 > 0 && $0 <= 126 }) else { throw Failure.unsupportedLength }
        var chunks: [Chunk] = []
        var emitStart = 0
        while emitStart < counts.count {
            var start = emitStart, left = 0
            while start > 0, emitStart - start < 24, left + counts[start - 1] <= 25 {
                start -= 1; left += counts[start]
            }
            var end = start, used = 0
            while end < counts.count, used + counts[end] <= 126 {
                used += counts[end]; end += 1
            }
            // A large next word can leave no room after the left context.
            if end <= emitStart { start = emitStart; end = emitStart + 1 }
            var emitEnd = end
            if end < counts.count {
                var right = 0
                while emitEnd > emitStart + 1, end - emitEnd < 24,
                      right + counts[emitEnd - 1] <= 25 {
                    emitEnd -= 1; right += counts[emitEnd]
                }
            }
            chunks.append(Chunk(context: start..<end, emission: emitStart..<emitEnd))
            emitStart = emitEnd
        }
        return chunks
    }

    /// Only ordinary ASCII punctuation in gaps is replaced. A punctuation run
    /// is removed once, and predictions are inserted before the unchanged gap.
    /// Lexical punctuation inside words/numbers never enters that path.
    public static func reconstruct(source: String, words: [Word], predictions: [Prediction]) throws -> String {
        guard words.count == predictions.count, words == self.words(in: source) else { throw Failure.alignment }
        guard let first = words.first, let firstRange = Range(first.range, in: source) else { return source }
        let urls = urlPattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).map(\.range)
        var output = String(source[..<firstRange.lowerBound])
        for index in words.indices {
            let word = words[index]
            guard let range = Range(word.range, in: source) else { throw Failure.alignment }
            let gapEnd = index + 1 < words.count ? words[index + 1].range.location : source.utf16.count
            let gapRange = NSRange(location: NSMaxRange(word.range), length: gapEnd - NSMaxRange(word.range))
            guard let gap = Range(gapRange, in: source) else { throw Failure.alignment }
            output += applyCase(String(source[range]), predictions[index].casing)
            output += ["", ",", ".", "?", "!"][predictions[index].punctuation.rawValue]
            var offset = gapRange.location
            for scalar in source[gap].unicodeScalars {
                let inURL = urls.contains { NSLocationInRange(offset, $0) }
                if !ordinaryPunctuation.contains(scalar) || inURL { output.unicodeScalars.append(scalar) }
                offset += scalar.utf16.count
            }
        }
        return output
    }

    private static func applyCase(_ word: String, _ casing: Prediction.Casing) -> String {
        // Keep intentional internal capitals (iPhone, OpenAI, macOS). Personal
        // dictionary restoration remains the coordinator's responsibility.
        var sawLower = false
        for scalar in word.unicodeScalars {
            if scalar.properties.isLowercase { sawLower = true }
            if sawLower && scalar.properties.isUppercase { return word }
        }
        var result = "", firstLetter = true
        for scalar in word.unicodeScalars {
            let isLetter = CharacterSet.letters.contains(scalar)
            let upper = casing == .upper || (casing == .capitalized && firstLetter && isLetter)
            let value = upper ? String(scalar).uppercased() : String(scalar).lowercased()
            // Unicode case expansions (ß -> SS, İ -> i + dot) alter lexical
            // content. Preserve that scalar's original representation instead.
            result += value.unicodeScalars.count == 1 ? value : String(scalar)
            if isLetter { firstLetter = false }
        }
        return result
    }
}
