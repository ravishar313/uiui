import XCTest
@testable import UIUICore

final class PersonalizationTests: XCTestCase {
    func testEveryPackRendersDistinctValidCues() {
        for cue in SoundCue.allCases {
            let rendered = SoundPack.allCases.map { SoundCueSynth.samples(for: cue, pack: $0) }
            XCTAssertEqual(Set(rendered).count, SoundPack.allCases.count)
            for samples in rendered {
                XCTAssertFalse(samples.isEmpty)
                XCTAssertLessThan(Double(samples.count) / Double(SoundCueSynth.sampleRate), 0.6)
                XCTAssertLessThan(abs(Int(samples.last!)), 400)
            }
        }
    }

    func testDefaultPackKeepsTheExistingSound() {
        XCTAssertEqual(SoundCueSynth.samples(for: .start), SoundCueSynth.samples(for: .start, pack: .soft))
    }

    func testAnyAccentStaysLegibleOnNotchAndWindow() {
        let black = AccentRGB(red: 0, green: 0, blue: 0)
        let paper = AccentRGB(red: 0.975, green: 0.974, blue: 0.96)
        for hex in ["000000", "FFFFFF", "0000FF", "FFFF00", "800000", "12AB34"] {
            let accent = UIUIAccent.custom.resolved(customHex: hex)
            XCTAssertGreaterThanOrEqual(accent.contrast(with: black), 7)
            XCTAssertGreaterThanOrEqual(UIUIAccent.custom.resolvedInk(customHex: hex).contrast(with: paper), 4.5)
        }
    }

    func testInvalidCustomColourFallsBackToLime() {
        XCTAssertEqual(UIUIAccent.custom.resolved(customHex: "nope"), UIUIAccent.lime.resolved(customHex: ""))
        XCTAssertEqual(AccentRGB(hex: "#102030")?.hex, "102030")
        XCTAssertNil(AccentRGB(hex: "12345"))
    }
}
