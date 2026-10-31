import Foundation
import UIUICore

/// What the main window and the menu bar say about the app. Read-only
/// projections of existing state, plus the history word fix.
struct LatestDictation: Equatable {
    var text: String
    var date: Date?
    var app: String?
}

@MainActor
extension AppModel {
    var microphoneIsActive: Bool { voice.state == "capturing" || isRecording }
    /// Held inside one capture: nothing is being transcribed, the words so far are kept.
    var isVoicePaused: Bool { voice.isPaused && voice.state == "capturing" }

    /// One honest sentence about the microphone, shared by Home and the menu bar.
    var voiceStatusSummary: String {
        if isVoicePaused { return "Paused · not transcribing" }
        if microphoneIsActive { return "Recording" }
        if voiceIsRecording { return "Preparing microphone" }
        if voice.state == "finishing" { return "Finishing · microphone off" }
        if voice.state == "working" { return "Working · microphone off" }
        return "Microphone off"
    }

    /// The newest dictation: the one just typed, or after a restart the newest saved one.
    var latestDictation: LatestDictation? {
        let newest = items.filter { $0.kind == .dictation && !$0.body.isEmpty }.max { $0.createdAt < $1.createdAt }
        if !lastTypedText.isEmpty {
            let match = newest?.body == lastTypedText ? newest : nil
            return LatestDictation(text: lastTypedText, date: match?.createdAt, app: match?.sourceApp)
        }
        return newest.map { LatestDictation(text: $0.body, date: $0.createdAt, app: $0.sourceApp) }
    }

    var canCopyLatestDictation: Bool {
        if !lastTypedText.isEmpty { return canCopyLastDictation }
        return latestDictation != nil && !voiceIsRecording
    }

    /// Copies through the normal, non-transient clipboard path.
    func copyLatestDictation() {
        if !lastTypedText.isEmpty { copyLastDictation(); return }
        if let latest = latestDictation { copy(latest.text) }
    }

    /// The most recent saved dictations, newest first, for the menu bar.
    func recentDictations(limit: Int = 5) -> [CaptureItem] {
        Array(items.filter { $0.kind == .dictation && !$0.body.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    /// Nil when history is off or nothing is saved. Counts only items still saved.
    func dictationStats(now: Date = Date()) -> DictationStats? {
        guard settings.saveDictationHistory else { return nil }
        return DictationStats.compute(from: items, since: now.addingTimeInterval(-7 * 86_400))
    }

    // MARK: Fix a word from history

    enum WordFixOutcome {
        case fixed(HistoryWordFix)
        case rejected(String)
    }

    static let wordFixUndoDepth = 20

    /// The newest fix to this item that Undo can still restore: nothing has changed
    /// the text since. It stays available from the item after its banner is dismissed.
    func undoableFix(for itemID: UUID) -> HistoryWordFix? {
        guard let fix = wordFixStacks[itemID]?.last,
              let current = items.first(where: { $0.id == itemID }), current.body == fix.after.body else { return nil }
        return fix
    }

    /// Fixes the clicked word (and, only if asked, its other exact matches) and
    /// optionally teaches the dictionary. The item is saved first; the dictionary
    /// changes only if that save succeeded.
    func fixWord(in item: CaptureItem, wordRange: NSRange, heard: String, correction: String,
                 alsoFixOtherMatches: Bool = false, addToDictionary: Bool = true) async -> WordFixOutcome {
        guard let current = items.first(where: { $0.id == item.id }) else { return .rejected("This text is no longer in history.") }
        let fix: HistoryWordFix
        do {
            fix = try HistoryCorrection.plan(item: current, wordRange: wordRange, expecting: heard, correction: correction,
                                             alsoFixOtherMatches: alsoFixOtherMatches, addToDictionary: addToDictionary,
                                             vocabulary: settings.vocabulary)
        }
        catch let rejection as HistoryCorrection.Rejection { return .rejected(rejection.message) }
        catch { return .rejected("That word couldn’t be fixed.") }
        guard await persist(fix.after) else { return .rejected("Couldn’t save the fix. Your text is unchanged.") }
        let vocabulary = HistoryCorrection.vocabularyAfter(fix, from: settings.vocabulary)
        if vocabulary != settings.vocabulary { settings.vocabulary = vocabulary }
        wordFixStacks[item.id, default: []].append(fix)
        if let count = wordFixStacks[item.id]?.count, count > Self.wordFixUndoDepth {
            wordFixStacks[item.id]?.removeFirst(count - Self.wordFixUndoDepth)
        }
        return .fixed(fix)
    }

    /// Restores only what the fix changed: the text, and the dictionary entry it added
    /// or replaced. Anything else about the item (a pin toggled since) is kept.
    func undoWordFix(_ fix: HistoryWordFix) async -> Bool {
        guard var current = items.first(where: { $0.id == fix.after.id }), current.body == fix.after.body else { return false }
        current.body = fix.before.body
        if current.title == fix.after.title { current.title = fix.before.title }
        current.rawText = fix.before.rawText
        guard await persist(current) else { return false }
        let vocabulary = HistoryCorrection.vocabularyBeforeFix(fix, from: settings.vocabulary)
        if vocabulary != settings.vocabulary { settings.vocabulary = vocabulary }
        wordFixStacks[fix.after.id]?.removeAll { $0 == fix }
        if wordFixStacks[fix.after.id]?.isEmpty == true { wordFixStacks[fix.after.id] = nil }
        return true
    }
}
