import Foundation

/// Finds recognised words that sound like a spelling in the user's dictionary,
/// with rules for romanised Indian names and English. A wrong swap is worse than
/// a missed one, so ordinary words are never changed: the speech model's bias
/// toward dictionary spellings handles those.
enum SoundsLikeVocabulary {
    struct Match { let range: NSRange; let replacement: String }

    private struct Word { let range: NSRange; let text: String; let key: [Character] }
    private struct Candidate { let spelling: String; let words: Set<String>; let wordCount: Int; let key: [Character]; let limit: Double }

    /// Longest phrase considered: a two-word entry may be heard as three words.
    private static let maximumPhraseWords = 3

    static func matches(in text: String, entries: [VocabularyEntry], skipping taken: [NSRange],
                        isKnownWord: (String) -> Bool) -> [Match] {
        let candidates = entries.compactMap(candidate)
        guard !candidates.isEmpty, let regex = try? NSRegularExpression(pattern: "\\p{L}+") else { return [] }
        return matchWords(wordsWithRanges(regex: regex, text: text), candidates: candidates, taken: taken, isKnownWord: isKnownWord)
    }

    private static func wordsWithRanges(regex: NSRegularExpression, text: String) -> [Word] {
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { result in
            let word = source.substring(with: result.range)
            guard let key = key(for: word) else { return nil }
            return Word(range: result.range, text: word, key: key)
        }
    }

    private static func matchWords(_ words: [Word], candidates: [Candidate], taken: [NSRange],
                                   isKnownWord: (String) -> Bool) -> [Match] {
        var result: [Match] = []
        var index = 0
        while index < words.count {
            var best: (length: Int, cost: Double, spelling: String, tied: Bool)?
            for length in 1...maximumPhraseWords where index + length <= words.count {
                let phrase = Array(words[index..<(index + length)])
                let range = NSUnionRange(phrase[0].range, phrase[length - 1].range)
                guard !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                let key = phrase.flatMap(\.key)
                for candidate in candidates where length <= candidate.wordCount + 1 {
                    guard abs(key.count - candidate.key.count) <= 3,
                          !phrase.contains(where: { blocks($0.text, candidate: candidate, isKnownWord: isKnownWord) }),
                          let cost = cost(key, candidate.key, limit: candidate.limit) else { continue }
                    if let current = best, abs(current.cost - cost) < 0.001, current.spelling != candidate.spelling {
                        best = (current.length, current.cost, current.spelling, true)
                    } else if best == nil || cost < best!.cost {
                        best = (length, cost, candidate.spelling, false)
                    }
                }
            }
            // Two entries equally close: guessing could write the wrong name.
            if let best, !best.tied {
                let last = words[index + best.length - 1].range
                result.append(Match(range: NSUnionRange(words[index].range, last), replacement: best.spelling))
                index += best.length
            } else { index += 1 }
        }
        return result
    }

    /// Only entries that are just a spelling. "q three" to "Q3" is a deliberate shorthand.
    private static func candidate(_ entry: VocabularyEntry) -> Candidate? {
        let spelling = entry.replacement.trimmingCharacters(in: .whitespaces)
        guard entry.isSpellingOnly, !VocabularyEntry.builtIn.contains(entry), let key = key(for: spelling) else { return nil }
        let words = spelling.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
        let letters = words.reduce(0) { $0 + $1.count }
        let limit: Double = switch letters { case ...3: 0; case 4...5: 0.75; case 6...8: 1; default: 2 }
        return Candidate(spelling: spelling, words: Set(words), wordCount: words.count, key: key, limit: limit)
    }

    private static func blocks(_ word: String, candidate: Candidate, isKnownWord: (String) -> Bool) -> Bool {
        let lowered = word.lowercased()
        if candidate.words.contains(lowered) { return false }
        return lowered.count < 3 || commonRomanHindi.contains(lowered) || isKnownWord(lowered)
    }

    /// A rough sound spelling. nil for text that isn't written in Latin letters.
    static func key(for text: String) -> [Character]? {
        var value = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        value.removeAll { $0 == " " || $0 == "-" || $0 == "'" || $0 == "’" }
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        for (from, to) in soundRules { value = value.replacingOccurrences(of: from, with: to) }
        // A leading y is a consonant; later it sounds like i.
        if let first = value.first { value = String(first) + value.dropFirst().replacingOccurrences(of: "y", with: "i") }
        for (from, to) in vowelRules { value = value.replacingOccurrences(of: from, with: to) }
        var characters: [Character] = []
        for character in value where characters.last != character { characters.append(character) }
        if characters.count > 2, characters.last == "h" { characters.removeLast() }
        return characters
    }

    private static let soundRules: [(String, String)] = [
        ("ow", "o"), ("aw", "o"), ("tch", "C"), ("ch", "C"), ("sh", "s"), ("ph", "f"), ("gh", "g"), ("kh", "k"), ("bh", "b"), ("dh", "d"), ("th", "t"),
        ("ck", "k"), ("qu", "k"), ("q", "k"), ("x", "ks"), ("z", "j"), ("w", "v"),
        ("ce", "se"), ("ci", "si"), ("cy", "si"), ("c", "k")
    ]
    private static let vowelRules: [(String, String)] = [
        ("aa", "a"), ("ee", "i"), ("ii", "i"), ("oo", "u"), ("uu", "u"), ("ou", "u"),
        ("ei", "e"), ("ai", "e"), ("au", "o"), ("ie", "i"), ("ea", "i")
    ]
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    private static let similar: [Set<Character>] = [["t", "d"], ["p", "b"], ["k", "g"], ["s", "j", "C"], ["f", "v"], ["n", "m"]]

    private static func areSimilar(_ a: Character, _ b: Character) -> Bool { similar.contains { $0.contains(a) && $0.contains(b) } }

    /// Weighted edit distance over sound keys, or nil when past `limit`.
    /// Vowels are cheap because speech models vary them most. A different first
    /// sound or a changed ending usually means a different word, so those cost more.
    static func cost(_ a: [Character], _ b: [Character], limit: Double) -> Double? {
        guard let firstA = a.first, let firstB = b.first else { return nil }
        guard firstA == firstB || (vowels.contains(firstA) && vowels.contains(firstB)) || areSimilar(firstA, firstB) else { return nil }
        func removal(_ character: Character, isLast: Bool) -> Double {
            (vowels.contains(character) ? 0.5 : 1) + (isLast ? 1 : 0)
        }
        var previous = [0.0]
        for (j, character) in b.enumerated() { previous.append(previous[j] + removal(character, isLast: j == b.count - 1)) }
        for (i, x) in a.enumerated() {
            var row = [previous[0] + removal(x, isLast: i == a.count - 1)]
            for (j, y) in b.enumerated() {
                let swap: Double = x == y ? 0 : vowels.contains(x) && vowels.contains(y) ? 0.5 : areSimilar(x, y) ? 0.75 : 1
                row.append(min(previous[j] + swap,
                               previous[j + 1] + removal(x, isLast: i == a.count - 1),
                               row[j] + removal(y, isLast: j == b.count - 1)))
            }
            previous = row
            if row.min()! > limit { return nil }
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }

    /// Everyday Roman Hindi that sounds close to many names, like "karna" and Karan.
    private static let commonRomanHindi: Set<String> = Set("""
    hai hain ho hoon hun tha thi the raha rahi rahe kar karo karna karne karni karke kiya kiye kya kyun kyon kab kahan kaise kaisa \
    kaun kitna kitne kitni koi kuch sab aur par bhi nahi nahin mat haan han acha accha achha theek thik bahut bohot abhi phir fir \
    kal aaj parso subah shaam raat din waqt yaar bhai behen dost ghar kaam baat log liye lekin magar agar toh tab jab bas bhej bhejo \
    bhejna bheja dena dedo diya lena liya lana laana jana jaana jao aana aao aaya aayi chalo chal chalna chalana dekho dekh dekhna \
    bolo bol bolna suno sunna likho likh likhna samajh pata chahiye sakta sakte sakti gaya gayi gaye hua hui hue apna apni apne mera \
    meri mere tera teri tere tumhara tumhari uska uski uske unka unki unke hamara humara hamari humari isko usko inko unko isme usme \
    iska iske iski paas saath baad pehle upar neeche niche andar bahar zyada jyada thoda thodi bada badi bade chota choti chote naya \
    nayi purana purani sahi galat naam paisa paise khana pani kitab sir madam tum aap hum main mein yeh woh kaha kahi kahin yahan \
    wahan idhar udhar kyunki isliye matlab shayad zaroor jaldi dheere sirf wala wali wale karenge karega karegi hoga hogi honge
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}
