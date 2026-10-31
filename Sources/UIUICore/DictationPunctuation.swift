import Foundation

/// A deliberately small fallback for terminal punctuation, not a grammar or
/// sentence-reconstruction engine. It never changes words, casing or spacing.
public enum DictationPunctuation {
    public static func finalize(_ transcript: String) -> String {
        // Bound the work and leave long documents and structured input alone.
        guard transcript.prefix(16_385).count <= 16_384,
              let start = transcript.firstIndex(where: { !$0.isWhitespace }),
              let last = transcript.lastIndex(where: { !$0.isWhitespace }) else { return transcript }
        let end = transcript.index(after: last)
        let body = transcript[start..<end]
        guard isPlainProse(body) else { return transcript }

        let terminal = transcript[last]
        if terminal == "." {
            let beforePeriod = body.dropLast()
            // Ellipses and other existing punctuation express intent already.
            guard let previous = beforePeriod.last, previous != ".",
                  !previous.isPunctuation, isDirectQuestion(finalSentence(in: beforePeriod)) else { return transcript }
            return String(transcript[..<last]) + "?" + transcript[end...]
        }
        guard terminal.isLetter || terminal.isNumber else { return transcript }
        let punctuation = isDirectQuestion(finalSentence(in: body)) ? "?" : "."
        return String(transcript[..<end]) + punctuation + transcript[end...]
    }

    private static func finalSentence(in text: Substring) -> Substring {
        var start = text.startIndex
        for index in text.indices where ".?!".contains(text[index]) {
            let next = text.index(after: index)
            if next < text.endIndex, text[next].isWhitespace { start = next }
        }
        let tail = text[start...]
        guard let first = tail.firstIndex(where: { !$0.isWhitespace }) else { return tail }
        return tail[first...]
    }

    private static func isPlainProse(_ text: Substring) -> Bool {
        guard text.contains(where: \.isLetter),
              !text.contains(where: { $0.isNewline || "/\\@#`<>[]{}|=_+*;$".contains($0) }),
              let first = text.first, !"-•>".contains(first) else { return false }

        for index in text.indices {
            let character = text[index]
            if "\"“”«»".contains(character) { return false }
            if "'‘’".contains(character) {
                let next = text.index(after: index)
                let insideWord = index > text.startIndex && next < text.endIndex
                    && text[text.index(before: index)].isLetter && text[next].isLetter
                if !insideWord { return false }
            }
            // Domains, file names, versions and similar literals must not gain
            // punctuation. This also conservatively protects abbreviations.
            if character == "." {
                let next = text.index(after: index)
                if index > text.startIndex && next < text.endIndex,
                   text[text.index(before: index)].isLetter || text[text.index(before: index)].isNumber,
                   text[next].isLetter || text[next].isNumber { return false }
            }
            if "()".contains(character) { return false }
        }

        let firstWord = text.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
        if let marker = firstWord.last, marker == "." || marker == ")",
           !firstWord.dropLast().isEmpty, firstWord.dropLast().allSatisfy(\.isNumber) { return false }
        let codeStarts: Set<String> = [
            "let", "var", "const", "func", "function", "def", "return", "import",
            "class", "struct", "enum", "guard", "throw", "if", "for", "while",
            "git", "npm", "pnpm", "yarn", "bun", "swift", "python", "python3",
            "node", "cargo", "go", "cd", "ls", "mkdir", "rm", "mv", "cp",
            "chmod", "sh", "zsh", "bash", "sudo", "brew", "gh", "curl", "ssh",
            "kubectl", "docker"
        ]
        return !codeStarts.contains(firstWord)
            && !["true", "false", "null", "nil"].contains(text.lowercased())
    }

    private static func isDirectQuestion(_ text: Substring) -> Bool {
        // Never infer a question for a later clause from the first clause.
        guard !text.contains(where: { ".?!:;".contains($0) }) else { return false }
        var words = text.lowercased().split(maxSplits: 15, whereSeparator: {
            !$0.isLetter && $0 != "'" && $0 != "’"
        }).map(String.init)
        if let first = words.first, ["okay", "ok", "well", "so", "hey"].contains(first) {
            words.removeFirst()
        }
        guard words.count >= 3 else { return false }
        let auxiliaries: Set<String> = [
            "am", "is", "are", "was", "were", "can", "could", "will", "would",
            "shall", "should", "may", "might", "must", "do", "does", "did",
            "have", "has", "had", "isn't", "aren't", "wasn't", "weren't",
            "can't", "couldn't", "won't", "wouldn't", "shouldn't", "don't",
            "doesn't", "didn't", "haven't", "hasn't", "hadn't"
        ]
        let normalized = words.map { $0.replacingOccurrences(of: "’", with: "'") }
        let subjects: Set<String> = [
            "i", "you", "we", "he", "she", "it", "they", "this", "that", "these",
            "those", "there", "anyone", "someone", "everybody", "anybody"
        ]
        if auxiliaries.contains(normalized[0]) {
            // These can be imperatives or blessings. Prefer a period over
            // guessing a question for "do it", "have this ready", or "may you".
            if ["do", "have"].contains(normalized[0]),
               ["it", "this", "that", "these", "those"].contains(normalized[1]) { return false }
            if normalized[0] == "don't" { return false }
            if normalized[0] == "may", !["i", "we"].contains(normalized[1]) { return false }
            if subjects.contains(normalized[1]) { return true }
            // "Do the build" and "Have a look" are ordinary imperatives.
            return !["do", "have"].contains(normalized[0]) && words.count >= 4
                && ["the", "a", "an", "my", "your", "our"].contains(normalized[1])
        }
        guard ["what", "which", "who", "where", "when", "why", "how"].contains(normalized[0]) else { return false }
        if auxiliaries.contains(normalized[1]) {
            // A nominal what-clause can be the subject of a statement:
            // "what is important is preserving the words". Ambiguous repeated
            // copulas stay statements rather than changing their intent.
            let copulas: Set<String> = ["is", "are", "was", "were"]
            if normalized[0] == "what", copulas.contains(normalized[1]),
               normalized.dropFirst(3).contains(where: copulas.contains) { return false }
            return true
        }
        // Bounded noun/adverb phrases: "what time is ...", "how long does ...".
        // Reject indirect subjects such as "what we need is more time".
        guard !subjects.contains(normalized[1]) else { return false }
        if ["what", "which"].contains(normalized[0]) {
            let queryNouns: Set<String> = [
                "time", "day", "date", "year", "version", "model", "branch",
                "build", "app", "file", "project", "color", "colour", "size",
                "name", "number", "status", "language", "option", "one", "way"
            ]
            return normalized.count >= 4 && queryNouns.contains(normalized[1])
                && auxiliaries.contains(normalized[2])
        }
        return normalized[0] == "how"
            && ["long", "much", "many", "often", "far", "soon", "old"].contains(normalized[1])
            && normalized.count >= 4 && auxiliaries.contains(normalized[2])
    }
}
