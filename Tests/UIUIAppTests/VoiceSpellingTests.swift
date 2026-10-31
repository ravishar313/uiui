import Foundation
import XCTest
import UIUICore
@testable import UIUI

final class VoiceSpellingTests: XCTestCase {
    @MainActor
    private func model(defaults: UserDefaults? = nil, persist: Bool = false,
                       delivery: (any TextDelivering)? = nil, cleanup: (any DictationCleaning)? = nil) throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-spelling-\(UUID().uuidString)")
        let suiteName = "uiui-spelling-\(UUID().uuidString)"
        let store = try defaults ?? XCTUnwrap(UserDefaults(suiteName: suiteName))
        let ownsDefaults = defaults == nil
        let model = AppModel(dataDirectory: root, defaults: store, persistSettings: persist,
                             delivery: delivery, cleanup: cleanup)
        addTeardownBlock {
            await MainActor.run { model.shutdown() }
            try? FileManager.default.removeItem(at: root)
            if ownsDefaults { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        }
        return model
    }

    @MainActor
    func testDictionaryProfilePersistsAcrossRestartAndKeepsScopedRecognition() async throws {
        let suiteName = "uiui-dictionary-profile-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let first = try model(defaults: defaults, persist: true)
        XCTAssertTrue(first.addVocabulary(heard: "sound", replacement: "GlobalName", project: "All projects"))
        XCTAssertTrue(first.addVocabulary(heard: "sound", replacement: "ResearchName", project: "Research"))
        first.captureProject = "Research"
        let settingsData = try XCTUnwrap(defaults.data(forKey: "uiui.settings"))
        XCTAssertEqual(try JSONDecoder().decode(UIUISettings.self, from: settingsData).vocabularyScope, "Research")
        let delivery = SpellingDelivery(), cleanup = SpellingCleanup()
        let restarted = try model(defaults: defaults, delivery: delivery, cleanup: cleanup)
        XCTAssertEqual(restarted.captureProject, "Research")
        XCTAssertTrue(restarted.projects.contains("Research"))
        restarted.settings.saveDictationHistory = false
        restarted.performVoiceTyping("sound")
        await restarted.voiceActionTask?.value
        XCTAssertEqual(cleanup.received, ["ResearchName"])
        XCTAssertEqual(delivery.delivered, ["ResearchName"])
        XCTAssertEqual(try JSONDecoder().decode(UIUISettings.self, from: Data("{}".utf8)).vocabularyScope, "Personal")
    }

    @MainActor
    func testDictionaryEntryThenDictateReachesDeliveryWithTheExactSpelling() async throws {
        let delivery = SpellingDelivery()
        let cleanup = SpellingCleanup()
        let model = try model(delivery: delivery, cleanup: cleanup)
        model.settings.saveDictationHistory = false
        XCTAssertTrue(model.addVocabulary(heard: "musely", replacement: "Muesli", project: "All projects"))
        XCTAssertTrue(delivery.delivered.isEmpty)
        model.voiceInputKind = .dictation
        model.performVoiceTyping("I ate musely")
        await model.voiceActionTask?.value
        XCTAssertEqual(cleanup.received, ["I ate Muesli"])
        XCTAssertEqual(delivery.delivered, ["I ate Muesli"])
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testConfirmedCanonicalLaukiSpellingSurvivesCleanupCasing() async throws {
        let delivery = SpellingDelivery(), cleanup = SpellingCleanup()
        cleanup.result = "LAUKI said okay"
        let model = try model(delivery: delivery, cleanup: cleanup)
        model.settings.saveDictationHistory = false
        XCTAssertTrue(model.addVocabulary(heard: "locky", replacement: "Lauki", project: "All projects"))
        XCTAssertEqual(model.settings.vocabulary.first?.replacement, "Lauki")
        model.voiceInputKind = .dictation
        model.performVoiceTyping("locky said okay")
        await model.voiceActionTask?.value
        XCTAssertEqual(cleanup.received, ["Lauki said okay"])
        XCTAssertEqual(delivery.delivered, ["Lauki said okay"])
        XCTAssertEqual(model.lastTypedText, "Lauki said okay")
    }

    @MainActor
    func testCleanupCannotRecapitalizeCustomSpellingOrCascadeAHeardAlias() async throws {
        let delivery = SpellingDelivery()
        let cleanup = SpellingCleanup()
        cleanup.result = "Uiui makes notes"
        let model = try model(delivery: delivery, cleanup: cleanup)
        model.settings.saveDictationHistory = false
        model.addVocabulary(heard: "uiui", replacement: "Other", project: "All projects")
        XCTAssertTrue(model.addVocabulary(heard: "you you", replacement: "uiui", project: "All projects"))
        model.voiceInputKind = .dictation
        model.performVoiceTyping("you you makes notes")
        await model.voiceActionTask?.value
        XCTAssertEqual(cleanup.received, ["uiui makes notes"])
        XCTAssertEqual(delivery.delivered, ["uiui makes notes"])
        XCTAssertEqual(model.lastTypedText, "uiui makes notes")
    }

    @MainActor
    func testFormattedDecisionUsesRawSpeechNotDictionaryAdjustedText() async throws {
        let cleanup = SpellingCleanup()
        let model = try model(delivery: SpellingDelivery(), cleanup: cleanup)
        model.settings.saveDictationHistory = false
        XCTAssertTrue(model.addVocabulary(heard: "priya", replacement: "Priya", project: "All projects"))
        model.voiceInputKind = .dictation
        model.performVoiceTyping("send it to priya")
        await model.voiceActionTask?.value
        // The dictionary made the text contain a capital, but the speech was bare.
        XCTAssertEqual(cleanup.received, ["send it to Priya"])
        XCTAssertEqual(cleanup.formattedFlags, [false])
    }

    @MainActor
    func testManualDictationAlsoPreservesTheStoredSpellingAfterCleanup() async throws {
        let delivery = SpellingDelivery()
        let cleanup = SpellingCleanup(); cleanup.result = "Uiui makes notes"
        let model = try model(delivery: delivery, cleanup: cleanup)
        await model.start(installSystemServices: false)
        model.settings.saveDictationHistory = false
        XCTAssertTrue(model.addVocabulary(heard: "you you", replacement: "uiui", project: "All projects"))
        model.captureMode = .dictation
        model.captureText = "uiui makes notes"
        model.saveCapture(source: .dictationCompletion)
        await model.manualDeliveryTask?.value
        XCTAssertEqual(delivery.delivered, ["uiui makes notes"])
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testUpdatingDictionaryEntryUpdatesExistingEntryAndRemovesLegacyDuplicatesWithoutChangingOtherProjects() throws {
        let model = try model()
        let original = VocabularyEntry(heard: "musely", replacement: "Old")
        let scoped = VocabularyEntry(heard: "musely", replacement: "ProjectName", project: "Research")
        model.settings.vocabulary = [original, VocabularyEntry(heard: "MUSELY", replacement: "Duplicate"), scoped]
        XCTAssertTrue(model.addVocabulary(heard: "MUSELY", replacement: "MUESLI", project: "All projects"))
        XCTAssertEqual(model.settings.vocabulary.count, 2)
        XCTAssertEqual(model.settings.vocabulary.first?.id, original.id)
        XCTAssertEqual(model.settings.vocabulary.first?.replacement, "MUESLI")
        XCTAssertTrue(model.settings.vocabulary.contains(scoped))
        XCTAssertTrue(model.addVocabulary(heard: "musely", replacement: "Muesli", project: "All projects"))
        XCTAssertEqual(model.settings.vocabulary.count, 2)
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "musely", entries: model.settings.vocabulary, project: "Personal"), "Muesli")
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "musely", entries: model.settings.vocabulary, project: "Research"), "ProjectName")
        XCTAssertTrue(model.addVocabulary(heard: "MUSELY", replacement: "ProjectUpdated", project: "research"))
        XCTAssertEqual(model.settings.vocabulary.count, 2)
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "musely", entries: model.settings.vocabulary, project: "Research"), "ProjectUpdated")
        XCTAssertTrue(model.addVocabulary(heard: "musely bar", replacement: "Muesli Bar", project: "All projects"))
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "musely bar and musely", entries: model.settings.vocabulary, project: "Personal"), "Muesli Bar and Muesli")
    }

    @MainActor
    func testVocabularyBoundsAndControlsFailWithoutSuccessMutation() throws {
        let model = try model()
        for (heard, replacement) in [("", "Name"), ("sound", ""), ("sound", String(repeating: "x", count: 121)), ("sound\n", "Name"), ("sound", "Na\u{202e}me")] {
            XCTAssertFalse(model.addVocabulary(heard: heard, replacement: replacement, project: "All projects"))
            XCTAssertTrue(model.settings.vocabulary.isEmpty)
        }
    }

    @MainActor
    func testDictionarySpellingPersistsThroughExistingSettingsReload() throws {
        let suiteName = "uiui-spelling-persist-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let first = try model(defaults: defaults, persist: true)
        XCTAssertTrue(first.addVocabulary(heard: "musely", replacement: "Muesli", project: "All projects"))
        let stored = try XCTUnwrap(defaults.data(forKey: "uiui.settings"))
        XCTAssertEqual(try JSONDecoder().decode(UIUISettings.self, from: stored).vocabulary.first?.replacement, "Muesli")
        let restarted = try model(defaults: defaults)
        XCTAssertEqual(restarted.settings.vocabulary, first.settings.vocabulary)
        XCTAssertEqual(TextProcessing.applyingVocabulary(to: "musely", entries: restarted.settings.vocabulary, project: "Any project"), "Muesli")
    }
}

@MainActor
private final class SpellingDelivery: TextDelivering {
    var delivered: [String] = []
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        delivered.append(text)
        return .pasteSent
    }
    func cancel() {}
}

@MainActor
private final class SpellingCleanup: DictationCleaning {
    var received: [String] = []
    var result: String?
    func prepare() {}
    func begin(_ captureID: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    var formattedFlags: [Bool?] = []
    func finish(_ text: String, captureID: UUID) async throws -> String {
        received.append(text)
        return result ?? text
    }
    func finish(_ text: String, captureID: UUID, formatted: Bool?) async throws -> String {
        formattedFlags.append(formatted)
        return try await finish(text, captureID: captureID)
    }
    func cancel() {}
    func release() {}
}
