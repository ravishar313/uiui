import Foundation
import UIUICore
import XCTest
@testable import UIUI

final class NotchStyleSettingsTests: XCTestCase {
    func testExistingSettingsKeepMosaicAndAllOtherPreferences() throws {
        var fixture = UIUISettings()
        fixture.speechLocale = "en-GB"
        fixture.quietMode = true
        fixture.notchEnabled = false
        fixture.customProjects = ["Synthetic work"]
        fixture.vocabulary = [VocabularyEntry(heard: "synthetic spelling", replacement: "SyntheticSpelling", project: "All projects")]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? [String: Any])
        object.removeValue(forKey: "notchVisualStyle")
        let restored = try JSONDecoder().decode(UIUISettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.notchVisualStyle, .mosaic)
        XCTAssertEqual(restored.speechLocale, "en-GB")
        XCTAssertTrue(restored.quietMode)
        XCTAssertFalse(restored.notchEnabled)
        XCTAssertEqual(restored.customProjects, fixture.customProjects)
        XCTAssertEqual(restored.vocabulary, fixture.vocabulary)
    }

    func testNotchSizeDefaultsToStandardAndRoundTrips() throws {
        for value: Any in ["huge", 7, NSNull()] {
            let data = try JSONSerialization.data(withJSONObject: ["notchSize": value, "quietMode": true])
            let restored = try JSONDecoder().decode(UIUISettings.self, from: data)
            XCTAssertEqual(restored.notchSize, .standard)
            XCTAssertTrue(restored.quietMode)
        }
        XCTAssertEqual(try JSONDecoder().decode(UIUISettings.self, from: Data("{}".utf8)).notchSize, .standard)
        for size in NotchSize.allCases {
            var settings = UIUISettings()
            settings.notchSize = size
            XCTAssertEqual(try JSONDecoder().decode(UIUISettings.self, from: JSONEncoder().encode(settings)).notchSize, size)
        }
    }

    func testUnknownAndMalformedStyleCannotDiscardOtherSettings() throws {
        for value: Any in ["future-style", 42, NSNull(), ["invalid": true]] {
            let data = try JSONSerialization.data(withJSONObject: ["notchVisualStyle": value,
                "speechLocale": "hi-IN", "quietMode": true, "customProjects": ["Synthetic work"]])
            let restored = try JSONDecoder().decode(UIUISettings.self, from: data)
            XCTAssertEqual(restored.notchVisualStyle, .mosaic)
            XCTAssertEqual(restored.speechLocale, "hi-IN")
            XCTAssertTrue(restored.quietMode)
            XCTAssertEqual(restored.customProjects, ["Synthetic work"])
        }
    }

    @MainActor
    func testEachStyleSurvivesEncodingAndAppSettingsReload() throws {
        let suite = "uiui-notch-style-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for style in NotchVisualStyle.allCases {
            var settings = UIUISettings()
            settings.notchVisualStyle = style
            settings.vocabulary = [VocabularyEntry(heard: "synthetic", replacement: "SyntheticName", project: "All projects")]
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: "uiui.settings")
            let reloaded = AppModel(defaults: defaults, persistSettings: false, cleanup: StyleSettingsCleanup())
            XCTAssertEqual(reloaded.settings.notchVisualStyle, style)
            XCTAssertEqual(reloaded.settings.vocabulary, settings.vocabulary)
            XCTAssertFalse(reloaded.voiceIsRecording)
            reloaded.shutdown()
        }
    }

    @MainActor
    func testStyleChangeDoesNotReplaceOrRestartDispatchReceipt() throws {
        let suite = "uiui-notch-style-receipt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, persistSettings: false, cleanup: StyleSettingsCleanup())
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        let receipt = VoiceActionFeedback(state: .information, title: "Synthetic dispatch", detail: "", presentation: .pasteDispatch)
        model.dictationFeedback = receipt
        let event = NotchFeedbackEvent(phase: model.notchFeedbackPhase, feedbackID: receipt.id)
        for style in NotchVisualStyle.allCases {
            model.settings.notchVisualStyle = style
            XCTAssertEqual(model.notchVoiceFeedback?.id, receipt.id)
            XCTAssertEqual(model.notchFeedbackPhase, .dispatched)
            XCTAssertEqual(NotchFeedbackEvent(phase: model.notchFeedbackPhase, feedbackID: model.notchVoiceFeedback?.id), event)
        }
    }
}

@MainActor
private final class StyleSettingsCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}
