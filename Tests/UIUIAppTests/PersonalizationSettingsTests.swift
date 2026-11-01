import XCTest
import UIUICore
@testable import UIUI

final class PersonalizationSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> UIUISettings {
        try JSONDecoder().decode(UIUISettings.self, from: Data(json.utf8))
    }

    func testOlderSettingsKeepLimeAndSoftSound() throws {
        let settings = try decode("{}")
        XCTAssertEqual(settings.accent, .lime)
        XCTAssertEqual(settings.soundPack, .soft)
        XCTAssertEqual(settings.soundVolume, 1)
    }

    func testUnknownValuesFallBackAndVolumeIsBounded() throws {
        let settings = try decode(#"{"accent":"neon","soundPack":"airhorn","soundVolume":9}"#)
        XCTAssertEqual(settings.accent, .lime)
        XCTAssertEqual(settings.soundPack, .soft)
        XCTAssertEqual(settings.soundVolume, 1)
    }

    func testChoicesSurviveSaving() throws {
        var settings = UIUISettings()
        settings.accent = .custom; settings.accentCustomHex = "12AB34"
        settings.soundPack = .marimba; settings.soundVolume = 0.5
        let saved = try JSONDecoder().decode(UIUISettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.accent, .custom); XCTAssertEqual(saved.accentCustomHex, "12AB34")
        XCTAssertEqual(saved.soundPack, .marimba); XCTAssertEqual(saved.soundVolume, 0.5)
    }
}
