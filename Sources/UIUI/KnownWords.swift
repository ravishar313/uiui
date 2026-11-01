import AppKit

/// Real English words stay as heard, so a sounds-like match can't rewrite them.
/// Uses the system's on-device spelling dictionary.
@MainActor
enum KnownWords {
    static func contains(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}
