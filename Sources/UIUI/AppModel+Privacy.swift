import Foundation
import UIUICore

extension AppModel {
    /// Deletes saved history, usage counts, recovery drafts and the dictionary.
    /// The repository performs the secure delete. Settings, shortcut, language,
    /// appearance and downloaded speech models stay.
    /// Returns a plain sentence for the interface; never includes saved text.
    @discardableResult
    func deleteEverythingStoredLocally() async -> String {
        guard !hasCancellableVoiceInput else { return "Finish or cancel the current dictation first." }
        guard let repository else { return "Your library is still opening. Try again in a moment." }
        // Drafts go through their own writer first so no queued write can bring one back.
        recordingRecovery.discardAll()
        await recordingRecovery.flush()
        do { try await repository.deleteAllContent() }
        catch {
            // The drafts are already gone and cannot be put back, so say exactly that.
            return "Recovery drafts were discarded, but saved history and the dictionary could not be deleted: \(error.localizedDescription) Nothing else was changed. Try again."
        }
        settings.vocabulary = []
        searchText = ""
        selectedItemID = nil
        explicitlyOpenedRecoveryDraftID = nil
        composerRecoveryDraftID = nil
        // Home, the menu and the notch read these; none may keep showing deleted text.
        lastTypedText = ""
        captureText = ""
        voice.discardHeldText()
        dictationFeedback = nil
        dictationDeliveryIssue = nil
        manualVoiceIssue = nil
        notchExtras.clearUndo()
        wordFixStacks = [:]
        await reload()
        statusMessage = "Deleted history, drafts and dictionary."
        onActivityChanged?()
        return "Deleted history, recovery drafts and dictionary words."
    }
}

/// What the language picker offers, and the plain sentences that go with it.
/// Saved locale identifiers never change; an unknown one is shown, not replaced.
enum SpeechLanguageOptions {
    static let defaultLocale = "en-IN"
    struct Option: Identifiable, Equatable {
        let locale: String
        let title: String
        var id: String { locale }
    }

    static var primary: Option { Option(locale: defaultLocale, title: "English + Hinglish") }

    /// Other languages, with honest labels for which engine hears them.
    static func others(including current: String) -> [Option] {
        var list = [
            Option(locale: "en-US", title: "English (US) · uiui S1"),
            Option(locale: "en-GB", title: "English (UK) · uiui S1"),
            Option(locale: "hi-IN", title: "Hindi · Apple on-device speech")
        ]
        let known = Set(list.map(\.locale) + [defaultLocale])
        if !known.contains(current) {
            let name = Locale.current.localizedString(forIdentifier: current) ?? current
            let engine = LocalSpeechModel.supports(locale: current) ? "uiui S1" : "Apple on-device speech"
            list.append(Option(locale: current, title: "\(name) · \(engine)"))
        }
        return list
    }

    static func detail(for locale: String) -> String {
        if locale == defaultLocale {
            return "uiui S1 hears English and Hinglish (Hindi in English letters) on this Mac."
        }
        if LocalSpeechModel.supports(locale: locale) {
            return "uiui S1 hears English on this Mac. It works the same as English + Hinglish."
        }
        return "Apple’s on-device speech hears this language. macOS may download its language data once."
    }

    /// The button that gets speech ready, named for what it does.
    static func setupButtonTitle(locale: String, modelInstalled: Bool) -> String {
        if !LocalSpeechModel.supports(locale: locale) { return "Set up speech" }
        return modelInstalled ? "Check speech model" : "Download speech model"
    }
}
