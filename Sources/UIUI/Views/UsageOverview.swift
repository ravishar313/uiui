import SwiftUI
import UIUICore

/// One quiet line about the week: words said and typing time saved.
/// Numbers come from saved history when it is on, else from the counts kept on this Mac.
struct UsageOverview: View {
    let model: AppModel

    /// Nil until something has been dictated this week.
    static func line(words: Int) -> String? {
        guard words > 0 else { return nil }
        let stats = DictationStats(words: words, dictations: 0)
        return "This week \(words.formatted()) \(words == 1 ? "word" : "words"), \(stats.typingTimeDescription) of typing saved"
    }

    private var weekWords: Int {
        if let stats = model.dictationStats() { return stats.words }
        return DictationUsage.overview(of: model.events, now: Date()).wordsThisWeek
    }

    var body: some View {
        if let text = Self.line(words: weekWords) {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .help("Estimated at \(DictationStats.assumedTypingWordsPerMinute) words per minute of typing")
                .accessibilityElement(children: .combine)
        }
    }
}
