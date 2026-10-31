import Foundation
import XCTest
import UIUICore
@testable import UIUI

@MainActor
final class SettingsWordingTests: XCTestCase {
    func testTrackpadFeedbackIsOffByDefaultAndOlderSettingsStillDecode() throws {
        XCTAssertFalse(UIUISettings().trackpadFeedbackEnabled)
        let old = try JSONDecoder().decode(UIUISettings.self, from: Data(#"{"soundFeedbackEnabled":false,"speechLocale":"hi-IN"}"#.utf8))
        XCTAssertFalse(old.trackpadFeedbackEnabled)
        XCTAssertFalse(old.soundFeedbackEnabled)
        var on = UIUISettings(); on.trackpadFeedbackEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(UIUISettings.self, from: JSONEncoder().encode(on)).trackpadFeedbackEnabled)
    }

    func testEverySavedLanguageStaysSelectableAndHonestlyLabelled() {
        for saved in ["en-IN", "en-US", "en-GB", "hi-IN", "en_AU", "ta-IN"] {
            let all = [SpeechLanguageOptions.primary] + SpeechLanguageOptions.others(including: saved)
            XCTAssertTrue(all.contains { $0.locale == saved }, "\(saved) has no picker row")
        }
        XCTAssertEqual(SpeechLanguageOptions.primary.title, "English + Hinglish")
        XCTAssertTrue(SpeechLanguageOptions.others(including: "hi-IN").first { $0.locale == "hi-IN" }!.title.contains("Apple"))
        XCTAssertTrue(SpeechLanguageOptions.others(including: "en-US").first { $0.locale == "en-US" }!.title.contains("uiui S1"))
    }

    func testSetupButtonNamesWhatItDoes() {
        XCTAssertEqual(SpeechLanguageOptions.setupButtonTitle(locale: "en-IN", modelInstalled: false), "Download speech model")
        XCTAssertEqual(SpeechLanguageOptions.setupButtonTitle(locale: "en-IN", modelInstalled: true), "Check speech model")
        XCTAssertEqual(SpeechLanguageOptions.setupButtonTitle(locale: "hi-IN", modelInstalled: true), "Set up speech")
    }

    func testPracticeSampleToleratesPunctuationAndSmallMisses() {
        XCTAssertEqual(PracticeSample.match(heard: "Kal Rahul se baat karo, then send the Q3 deck to Priya."), .close)
        XCTAssertEqual(PracticeSample.match(heard: "kal rahul se baat karo then send the q3 deck to priya"), .close)
        XCTAssertEqual(PracticeSample.match(heard: "Kal Rahul se baat karo, then send the deck to Pria"), .close)
        XCTAssertEqual(PracticeSample.match(heard: "Kal Rahul se baat karo then send"), .partial)
        XCTAssertEqual(PracticeSample.match(heard: "Hello there"), .different)
        XCTAssertEqual(PracticeSample.match(heard: ""), .different)
    }

    func testDeleteEverythingRemovesHistoryDraftsAndDictionaryButKeepsSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "uiui.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(dataDirectory: directory, defaults: defaults, persistSettings: false)
        await model.start(installSystemServices: false)
        model.settings.vocabulary = [VocabularyEntry(heard: "priya", replacement: "Priya")]
        model.settings.speechLocale = "hi-IN"
        let saved = await model.persist(CaptureItem(title: "Deck", body: "Send the Q3 deck", kind: .dictation))
        XCTAssertTrue(saved)
        XCTAssertEqual(model.items.count, 1)
        let message = await model.deleteEverythingStoredLocally()
        XCTAssertTrue(message.hasPrefix("Deleted"), message)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.settings.vocabulary.isEmpty)
        XCTAssertEqual(model.settings.speechLocale, "hi-IN")
        let stored = try await model.repository?.loadItems()
        XCTAssertEqual(stored?.count, 0)
    }
}
