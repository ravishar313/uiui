import Foundation
import SQLite3
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

    func testDeleteEverythingAlsoClearsWhatHomeAndTheMenuShow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "uiui.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(dataDirectory: directory, defaults: defaults, persistSettings: false)
        await model.start(installSystemServices: false)
        let saved = await model.persist(CaptureItem(title: "Deck", body: "Send the Q3 deck", kind: .dictation))
        XCTAssertTrue(saved)
        model.lastTypedText = "Send the Q3 deck"
        model.captureText = "an unfinished draft"
        XCTAssertNotNil(model.latestDictation)
        XCTAssertTrue(model.canCopyLatestDictation)
        _ = await model.deleteEverythingStoredLocally()
        XCTAssertEqual(model.lastTypedText, "")
        XCTAssertEqual(model.captureText, "")
        XCTAssertNil(model.latestDictation)
        XCTAssertFalse(model.canCopyLatestDictation)
        XCTAssertTrue(model.recentDictations().isEmpty)
        XCTAssertNil(model.dictationFeedback)
    }

    func testDeleteEverythingFailureSaysDraftsWereAlreadyDiscardedAndKeepsWhatWasNotDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "uiui.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(dataDirectory: directory, defaults: defaults, persistSettings: false)
        await model.start(installSystemServices: false)
        let saved = await model.persist(CaptureItem(title: "Deck", body: "Send the Q3 deck", kind: .dictation))
        XCTAssertTrue(saved)
        model.lastTypedText = "Send the Q3 deck"
        model.settings.vocabulary = [VocabularyEntry(heard: "priya", replacement: "Priya")]
        // Make the repository delete fail by removing a table it must clear.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DROP TABLE usage_events", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let message = await model.deleteEverythingStoredLocally()
        XCTAssertTrue(message.hasPrefix("Recovery drafts were discarded, but"), message)
        XCTAssertFalse(message.hasPrefix("Couldn’t delete everything"), "The old wording implied nothing had changed")
        XCTAssertEqual(model.items.count, 1, "History was not deleted")
        XCTAssertEqual(model.lastTypedText, "Send the Q3 deck", "What still exists is still shown")
        XCTAssertEqual(model.settings.vocabulary.count, 1)
    }
}
