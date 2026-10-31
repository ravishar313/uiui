import Foundation

/// The sentence the setup guide asks people to say, and a forgiving comparison
/// with what was heard. Nothing is stored or sent; it only picks which
/// reassurance to show.
enum PracticeSample {
    static let sentence = "Kal Rahul se baat karo, then send the Q3 deck to Priya"

    enum Match: Equatable { case close, partial, different }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Share of the sample's words that appear, in order, in what was heard.
    static func similarity(heard: String, expected: String = sentence) -> Double {
        let target = words(expected)
        let got = words(heard)
        guard !target.isEmpty else { return 0 }
        // Longest common subsequence, so reordered or repeated words don't count twice.
        var table = Array(repeating: Array(repeating: 0, count: got.count + 1), count: target.count + 1)
        for i in 1...target.count {
            for j in stride(from: 1, through: got.count, by: 1) {
                table[i][j] = target[i - 1] == got[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return Double(table[target.count][got.count]) / Double(target.count)
    }

    static func match(heard: String) -> Match {
        let score = similarity(heard: heard)
        if score >= 0.8 { return .close }
        if score >= 0.4 { return .partial }
        return .different
    }

    /// Plain, kind wording for each outcome. Differences are normal, not failure.
    static func message(for match: Match) -> String {
        switch match {
        case .close: "That’s what we hoped for. Capital letters, commas and names are added for you."
        case .partial: "Close. A few words differ, which is normal. Try again a little slower, or add a name to your dictionary later."
        case .different: "Those words were different from the sample, which can happen with background noise or a fast start. Try once more, or skip and try it in any app."
        }
    }
}
