import Foundation
import XCTest
@testable import UIUI

final class SoundSettingsTests: XCTestCase {
    func testOlderSettingsEnableNewSoundFeedbackWithoutChangingQuietMode() throws {
        let settings = try JSONDecoder().decode(UIUISettings.self, from: Data(#"{"quietMode":true}"#.utf8))
        XCTAssertTrue(settings.soundFeedbackEnabled)
        XCTAssertTrue(settings.quietMode)
    }

    func testDisablingSoundFeedbackSurvivesSettingsReload() throws {
        var settings = UIUISettings()
        settings.soundFeedbackEnabled = false
        let restored = try JSONDecoder().decode(UIUISettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.soundFeedbackEnabled)
    }
}
