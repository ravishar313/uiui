// UIUI bounded native pilot. Port of Fermion's published hotwords.py algorithm;
// adds tighter pilot input limits. Apache-2.0, see LICENSE and NOTICE.
import Foundation
public struct BiasTerm: Codable { public let word: String; public let spoken: [String]?
    public init(word: String, spoken: [String]? = nil) { self.word = word; self.spoken = spoken }
}
public struct BiasPhrases {
    // A boundary marker may be a standalone token in a spelling. This optional
    // pilot filter changes its bonus only; the automaton still consumes it.
    static func boundaryOnlyTokenIDs(in vocabulary: [String]) -> [Int32] {
        vocabulary.enumerated().compactMap { index, piece in
            guard !piece.isEmpty, piece.unicodeScalars.allSatisfy({ $0.value == 0x2581 || $0.properties.isWhitespace }) else { return nil }
            return Int32(index)
        }
    }
    static func wordBoundaryTokenIDs(in vocabulary: [String]) -> [Int32] {
        vocabulary.enumerated().compactMap { index, piece in
            guard let first = piece.unicodeScalars.first else { return nil }
            return first.value == 0x2581 || first.properties.isWhitespace || (CharacterSet.punctuationCharacters.contains(first) && !"'’‘-‐‑‒–—_".unicodeScalars.contains(first)) ? Int32(index) : nil
        }
    }
    static func wordStartTokenIDs(in vocabulary: [String]) -> [Int32] {
        vocabulary.enumerated().compactMap { i, s in
            guard let first=s.unicodeScalars.first else { return nil }
            return first.value == 0x2581 || first.properties.isWhitespace ? Int32(i) : nil
        }
    }
    public let phrases: [[Int32]]
    public let acceptedTerms: Int
    public let unspellableTerms: Int
    public init(words: [BiasTerm], vocabulary: [String], strength: Float) throws {
        guard strength.isFinite, (0...8).contains(strength) else { throw NSError(domain: "NativeBiasPilot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pilot strength must be finite and 0...8"]) }
        var index: [String: Int32] = [:]
        for (i, p) in vocabulary.enumerated() where !p.isEmpty && p != "<unk>" && p != "<pad>" && !(p.hasPrefix("<|") && p.hasSuffix("|>")) { if index[p] == nil { index[p] = Int32(i) } }
        func clean(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        func segment(_ s: String) -> [[Int32]] {
            let chars = Array(s); var memo: [Int: [[Int32]]] = [chars.count: [[]]]
            func rec(_ pos: Int) -> [[Int32]] {
                if let value = memo[pos] { return value }
                var out: [[Int32]] = []
                for end in stride(from: min(chars.count, pos + 128), through: pos + 1, by: -1) {
                    guard let token = index[String(chars[pos..<end])] else { continue }
                    for tail in rec(end) { out.append([token] + tail); if out.count >= 24 { break } }
                    if out.count >= 24 { break }
                }
                out.sort { $0.count < $1.count }; memo[pos] = Array(out.prefix(6)); return memo[pos]!
            }
            return rec(0)
        }
        var seen = Set<String>(), seqs = Set<[Int32]>(), accepted = 0, missed = 0
        for term in words {
            let word = clean(term.word)
            guard !word.isEmpty, word.count <= 80, seen.insert(word.lowercased()).inserted, accepted < 100 else { continue }
            accepted += 1; var found = false
            for raw in ([word] + Array((term.spoken ?? []).prefix(4))) {
                let surface = clean(raw); guard !surface.isEmpty, surface.count <= 80 else { continue }
                let capitalized = surface.split(separator: " ").map { String($0.prefix(1)).uppercased() + $0.dropFirst() }.joined(separator: " ")
                for variant in Set([surface, surface.lowercased(), capitalized]) {
                    let spelled = "▁" + variant.split(separator: " ").joined(separator: "▁")
                    for seq in segment(spelled) where seq.count <= 128 { seqs.insert(seq); found = true }
                }
            }
            if !found { missed += 1 }
        }
        // No more than 100 terms x 5 surfaces x 3 casings x 6 spellings.
        // The C automaton additionally enforces its 8192-state limit.
        phrases = strength > 0 ? seqs.sorted { $0.lexicographicallyPrecedes($1) } : []
        acceptedTerms = accepted; unspellableTerms = missed
    }
}
