import XCTest
@testable import UIUICore

final class VoiceTriggerTests: XCTestCase {
    func testChosenPhysicalKeyDeliversExactlyOnePressAndRelease() {
        for key in VoiceTriggerKey.allCases {
            var filter = VoiceTriggerFilter(key: key)
            XCTAssertEqual(filter.handle(keyCode: key.keyCode, isDown: true, hasOtherModifiers: false), .pressed)
            XCTAssertNil(filter.handle(keyCode: key.keyCode, isDown: true, hasOtherModifiers: false))
            XCTAssertTrue(filter.isPressed)
            XCTAssertEqual(filter.handle(keyCode: key.keyCode, isDown: false, hasOtherModifiers: false), .released)
            XCTAssertNil(filter.handle(keyCode: key.keyCode, isDown: false, hasOtherModifiers: false))
            XCTAssertFalse(filter.isPressed)
        }
    }

    func testOppositeControlAndNormalKeysCannotTriggerOrReleaseChosenKey() {
        var filter = VoiceTriggerFilter(key: .rightControl)
        for code: UInt16 in [VoiceTriggerKey.leftControl.keyCode, 0, 49] {
            XCTAssertNil(filter.handle(keyCode: code, isDown: true, hasOtherModifiers: false))
        }
        XCTAssertEqual(filter.handle(keyCode: VoiceTriggerKey.rightControl.keyCode, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertNil(filter.handle(keyCode: VoiceTriggerKey.leftControl.keyCode, isDown: false, hasOtherModifiers: false))
        XCTAssertTrue(filter.isPressed)
        XCTAssertEqual(filter.handle(keyCode: VoiceTriggerKey.rightControl.keyCode, isDown: false, hasOtherModifiers: false), .released)
    }

    func testChordDoesNotStartWhenOtherModifiersAreAlreadyHeld() {
        var filter = VoiceTriggerFilter()
        XCTAssertNil(filter.handle(keyCode: 63, isDown: true, hasOtherModifiers: true))
        XCTAssertNil(filter.handle(keyCode: 63, isDown: false, hasOtherModifiers: false))
        XCTAssertFalse(filter.isPressed)
        XCTAssertEqual(filter.handle(keyCode: 63, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertEqual(filter.handle(keyCode: 63, isDown: false, hasOtherModifiers: true), .cancelled)
    }

    func testReconfigurationCancelsOldKeyAndAcceptsOnlyNewKey() {
        var filter = VoiceTriggerFilter()
        XCTAssertEqual(filter.handle(keyCode: 63, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertEqual(filter.configure(key: .rightOption), .cancelled)
        XCTAssertFalse(filter.isPressed)
        XCTAssertNil(filter.handle(keyCode: 63, isDown: false, hasOtherModifiers: false))
        XCTAssertNil(filter.handle(keyCode: 63, isDown: true, hasOtherModifiers: false))
        XCTAssertEqual(filter.handle(keyCode: 61, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertEqual(filter.reset(), .cancelled)
        XCTAssertNil(filter.reset())
        XCTAssertNil(filter.handle(keyCode: 61, isDown: false, hasOtherModifiers: false))
    }

    func testOrdinaryKeyChordCancelsAndCannotCompleteOnRelease() {
        var filter = VoiceTriggerFilter(key: .leftControl)
        XCTAssertNil(filter.cancelChord())
        XCTAssertEqual(filter.handle(keyCode: 59, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertEqual(filter.cancelChord(), .cancelled)
        XCTAssertFalse(filter.isPressed)
        XCTAssertNil(filter.cancelChord())
        XCTAssertNil(filter.handle(keyCode: 59, isDown: false, hasOtherModifiers: false), "A cancelled chord's release never finishes")
        XCTAssertEqual(filter.handle(keyCode: 59, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertEqual(filter.handle(keyCode: 59, isDown: false, hasOtherModifiers: false), .released)
    }

    func testRemovingOrChangingCancelledChordCannotReleaseAnAction() {
        var filter = VoiceTriggerFilter()
        XCTAssertEqual(filter.handle(keyCode: 63, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertEqual(filter.cancelChord(), .cancelled)
        XCTAssertNil(filter.configure(key: .rightOption))
        XCTAssertNil(filter.handle(keyCode: 63, isDown: false, hasOtherModifiers: false))
        XCTAssertEqual(filter.handle(keyCode: 61, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertEqual(filter.cancelChord(), .cancelled)
        XCTAssertNil(filter.reset())
    }

    func testConfigurationPersistsStableChoices() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for key in VoiceTriggerKey.allCases {
            XCTAssertEqual(try decoder.decode(VoiceTriggerKey.self, from: encoder.encode(key)), key)
        }
        for mode in VoiceTriggerMode.allCases {
            XCTAssertEqual(try decoder.decode(VoiceTriggerMode.self, from: encoder.encode(mode)), mode)
        }
        XCTAssertEqual(VoiceTriggerFilter().key, .fn)
    }

    func testEarlierSavedTriggerNamesStillLoad() throws {
        let decoder = JSONDecoder()
        for (name, key) in [("fn", VoiceTriggerKey.fn), ("leftControl", .leftControl),
                            ("rightControl", .rightControl), ("rightOption", .rightOption)] {
            XCTAssertEqual(try decoder.decode(VoiceTriggerKey.self, from: Data("\"\(name)\"".utf8)), key)
        }
        XCTAssertThrowsError(try decoder.decode(VoiceTriggerKey.self, from: Data("\"capsLock\"".utf8)))
    }

    func testRecordedCombinationRoundTripsAndDisplays() throws {
        let key = VoiceTriggerKey(keyCode: 49, modifiers: [.control, .option], label: " ")
        XCTAssertFalse(key.isModifierOnly)
        XCTAssertEqual(key.title, "⌃⌥Space")
        XCTAssertNil(key.unsuitableReason)
        XCTAssertEqual(try JSONDecoder().decode(VoiceTriggerKey.self, from: JSONEncoder().encode(key)), key)
        let letter = VoiceTriggerKey(keyCode: 2, modifiers: [.control, .command], label: "d")
        XCTAssertEqual(letter.title, "⌃⌘D")
        XCTAssertEqual(VoiceTriggerKey(keyCode: 96).title, "F5")
        // A lone modifier never carries modifier bits or a label.
        XCTAssertEqual(VoiceTriggerKey(keyCode: 54, modifiers: [.shift], label: "x"), .rightCommand)
    }

    func testCombinationsThatWouldBreakTypingOrPasteAreRejected() {
        XCTAssertNotNil(VoiceTriggerKey(keyCode: 0, label: "a").unsuitableReason, "A bare letter can no longer be typed")
        XCTAssertNotNil(VoiceTriggerKey(keyCode: 49).unsuitableReason, "A bare Space can no longer be typed")
        XCTAssertNotNil(VoiceTriggerKey(keyCode: 0, modifiers: [.shift], label: "a").unsuitableReason)
        XCTAssertNotNil(VoiceTriggerKey(keyCode: 9, modifiers: [.command], label: "v").unsuitableReason, "uiui's own paste would retrigger")
        XCTAssertNotNil(VoiceTriggerKey(keyCode: 53, modifiers: [.command]).unsuitableReason, "Escape cancels dictation")
        XCTAssertNil(VoiceTriggerKey(keyCode: 9, modifiers: [.command, .shift], label: "v").unsuitableReason)
        XCTAssertNotNil(VoiceTriggerKey(keyCode: 47, modifiers: [.command], label: "v").unsuitableReason, "⌘V on Dvorak is key code 47")
        XCTAssertNotNil(VoiceTriggerKey(keyCode: 49, modifiers: [.option]).unsuitableReason, "macOS 15 refuses ⌥-only hot keys")
        XCTAssertNotNil(VoiceTriggerKey(keyCode: 49, modifiers: [.option, .shift]).unsuitableReason)
        XCTAssertNotNil(VoiceTriggerKey(keyCode: 96, modifiers: [.option]).unsuitableReason)
        XCTAssertNil(VoiceTriggerKey(keyCode: 96, modifiers: [.control, .option]).unsuitableReason)
        XCTAssertNil(VoiceTriggerKey(keyCode: 105).unsuitableReason, "F13 alone is fine")
        for key in VoiceTriggerKey.allCases { XCTAssertNil(key.unsuitableReason) }
    }

    func testSwallowedReleaseDoesNotCostTheNextPress() {
        // ⌘Tab: Command goes down (a press), Tab cancels it as a chord, and the
        // app switcher swallows Command's release.
        var filter = VoiceTriggerFilter(key: .leftCommand)
        XCTAssertEqual(filter.handle(keyCode: 55, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertEqual(filter.cancelChord(), .cancelled)
        // The next real press must start dictation immediately, not on the second try.
        XCTAssertEqual(filter.handle(keyCode: 55, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertEqual(filter.handle(keyCode: 55, isDown: false, hasOtherModifiers: false), .released)
        // A repeated down while a press is active is still deduplicated.
        XCTAssertEqual(filter.handle(keyCode: 55, isDown: true, hasOtherModifiers: false), .pressed)
        XCTAssertNil(filter.handle(keyCode: 55, isDown: true, hasOtherModifiers: false))
    }
}
