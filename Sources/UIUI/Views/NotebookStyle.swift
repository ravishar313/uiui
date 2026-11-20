import SwiftUI
import UIUICore

/// Small pieces shared by the notebook window: the person's words with learned
/// words underlined, a key cap, and the two eyes that show whether uiui listens.
enum NotebookText {
    /// The text as an attributed string with each learned spelling underlined in the accent.
    /// Whole words only; an entry the text does not contain costs nothing.
    @MainActor static func underlined(_ text: String, learned: [String]) -> AttributedString {
        var result = AttributedString(text)
        for word in learned where word.count > 1 {
            var start = text.startIndex
            while start < text.endIndex, let found = text.range(of: word, range: start..<text.endIndex) {
                start = found.upperBound
                let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
                let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
                if let before, before.isLetter || before.isNumber { continue }
                if let after, after.isLetter || after.isNumber { continue }
                guard let range = Range(found, in: result) else { continue }
                result[range].swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: UIUIStyle.accent)
            }
        }
        return result
    }

    /// The learned spellings in a dictionary, longest first so a longer phrase wins.
    static func learnedSpellings(_ vocabulary: [VocabularyEntry]) -> [String] {
        var seen = Set<String>()
        return vocabulary.map(\.replacement).filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }
}

/// A key on the keyboard: raised, no hard border.
struct NotebookKeycap: View {
    let label: String
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
        }.foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 8).frame(minWidth: 34, minHeight: 30)
            .uiuiCard(radius: 10).fixedSize()
            .accessibilityHidden(true)
    }
}

/// A trigger key drawn as a key cap, from the person's real setting.
struct VoiceKeycap: View {
    let key: VoiceTriggerKey
    var body: some View {
        if key == .fn {
            NotebookKeycap(label: "fn", symbol: "globe")
        } else if key.isModifierOnly {
            NotebookKeycap(label: key.title.hasPrefix("Left") ? "L" : "R", symbol: key.symbol)
        } else {
            NotebookKeycap(label: key.title)
        }
    }
}

/// Two small pills: flat and closed when nothing listens, upright and lit when it does.
struct MicEyes: View {
    var open: Bool
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule().fill(open ? UIUIStyle.accent : Color.secondary.opacity(0.45))
                    .frame(width: open ? 5 : 9, height: open ? 12 : 3)
            }
        }.frame(width: 22, height: 14).animation(.easeOut(duration: 0.18), value: open).accessibilityHidden(true)
    }
}
