import AppKit
import IOKit.hidsystem
import XCTest
import UIUICore
@testable import UIUI

final class GlobalShortcutsTests: XCTestCase {
    @MainActor
    private func key(_ keyCode: UInt16, type: NSEvent.EventType = .keyDown,
                     flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: isRepeat, keyCode: keyCode))
    }

    @MainActor
    private func scroll(momentumPhase: Int64 = 0, phase: Int64 = 0, delta: Int32 = 8) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
        event.flags = .maskSecondaryFn
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    @MainActor
    func testFirstFnTapStartsWhilePreviousTrackpadScrollEnds() throws {
        // Quartz scroll phases differ from NSEvent.Phase raw values:
        // ended = 4 and cancelled = 8. Exercise the AppKit conversion too.
        let phases: [(Int64, NSEvent.Phase)] = [(4, .ended), (8, .cancelled)]
        for (phase, expected) in phases {
            let shortcuts = GlobalShortcuts(observesSystemEvents: false)
            shortcuts.install(key: .fn, enabled: true)
            var gesture = VoiceGestureState()
            var actions: [VoiceGestureAction] = []
            shortcuts.onVoicePressed = {
                actions += gesture.handle(.pressed, mode: .toggle, activeCapture: nil, now: 1)
            }
            shortcuts.onVoiceReleased = {
                actions += gesture.handle(.released, mode: .toggle, activeCapture: nil, now: 1.05)
            }
            shortcuts.onVoiceCancelled = {
                actions += gesture.handle(.cancelled, mode: .toggle, activeCapture: nil, now: 1.02)
            }
            shortcuts.handle(try key(63, type: .flagsChanged, flags: .function))
            let completion = try scroll(phase: phase, delta: 0)
            XCTAssertEqual(completion.phase, expected)
            XCTAssertTrue(completion.momentumPhase.isEmpty)
            XCTAssertFalse(shortcuts.handle(completion))
            XCTAssertTrue(actions.isEmpty, "A previous scroll's completion must not cancel the clean Fn gesture")
            shortcuts.handle(try key(63, type: .flagsChanged))
            XCTAssertEqual(actions, [.startDictation])
            shortcuts.remove()
        }
    }

    @MainActor
    func testFirstFnTapStillStartsDictationWhilePreviousScrollMomentumContinues() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        shortcuts.install(key: .fn, enabled: true)
        var gesture = VoiceGestureState()
        var actions: [VoiceGestureAction] = []
        shortcuts.onVoicePressed = {
            actions += gesture.handle(.pressed, mode: .toggle, activeCapture: nil, now: 1)
        }
        shortcuts.onVoiceReleased = {
            actions += gesture.handle(.released, mode: .toggle, activeCapture: nil, now: 1.05)
        }
        shortcuts.onVoiceCancelled = {
            actions += gesture.handle(.cancelled, mode: .toggle, activeCapture: nil, now: 1.02)
        }
        shortcuts.handle(try key(63, type: .flagsChanged, flags: .function))
        // Quartz momentum phases: begin = 1, continue = 2, end = 3.
        for phase: Int64 in [1, 2, 3] {
            let event = try scroll(momentumPhase: phase)
            XCTAssertEqual(event.type, .scrollWheel)
            XCTAssertFalse(event.momentumPhase.isEmpty, "The regression must exercise AppKit momentum events")
            XCTAssertFalse(shortcuts.handle(event))
        }
        XCTAssertTrue(actions.isEmpty, "Previous scrolling must not cancel the clean Fn gesture")
        shortcuts.handle(try key(63, type: .flagsChanged))
        XCTAssertEqual(actions, [.startDictation], "A clean first tap must start immediately on release")
        shortcuts.remove()
    }

    @MainActor
    func testIntentionalScrollAndKeyChordsCancelFnThenNextCleanTapWorks() throws {
        for chord in [try scroll(), try scroll(phase: 1), try scroll(phase: 2), try key(0, flags: .function)] {
            let shortcuts = GlobalShortcuts(observesSystemEvents: false)
            shortcuts.install(key: .fn, enabled: true)
            var transitions: [VoiceTriggerTransition] = []
            shortcuts.onVoicePressed = { transitions.append(.pressed) }
            shortcuts.onVoiceReleased = { transitions.append(.released) }
            shortcuts.onVoiceCancelled = { transitions.append(.cancelled) }
            shortcuts.handle(try key(63, type: .flagsChanged, flags: .function))
            XCTAssertFalse(shortcuts.handle(chord))
            shortcuts.handle(try key(63, type: .flagsChanged))
            XCTAssertEqual(transitions, [.pressed, .cancelled])
            shortcuts.handle(try key(63, type: .flagsChanged, flags: .function))
            shortcuts.handle(try key(63, type: .flagsChanged))
            XCTAssertEqual(transitions, [.pressed, .cancelled, .pressed, .released])
            shortcuts.remove()
        }
    }

    @MainActor
    func testEscapeCancelsSynchronouslyOnlyDuringActiveCapture() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        var cancellations = 0
        shortcuts.onEscape = {
            cancellations += 1
            shortcuts.setEscapeCancellationEnabled(false)
        }
        XCTAssertFalse(shortcuts.handleEscape(try key(53)))
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertFalse(shortcuts.handleEscape(try key(0)))
        XCTAssertFalse(shortcuts.handleEscape(try key(53, type: .keyUp)))
        XCTAssertEqual(cancellations, 0)
        XCTAssertTrue(shortcuts.handleEscape(try key(53)))
        XCTAssertEqual(cancellations, 1) // No run-loop hop or delayed task.
        XCTAssertFalse(shortcuts.escapeCancellationEnabled)
        XCTAssertTrue(shortcuts.handleEscape(try key(53, isRepeat: true)))
        XCTAssertTrue(shortcuts.handleEscape(try key(53, type: .keyUp)))
        XCTAssertFalse(shortcuts.handleEscape(try key(53)))
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testCancelledEscapeConsumesRepeatsAndReleaseAfterSynchronousTeardown() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        var cancellations = 0
        shortcuts.onEscape = {
            cancellations += 1
            shortcuts.setEscapeCancellationEnabled(false)
        }
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertTrue(shortcuts.handleEscape(try key(53)))
        XCTAssertFalse(shortcuts.escapeCancellationEnabled)
        XCTAssertTrue(shortcuts.handleEscape(try key(53, isRepeat: true)))
        XCTAssertFalse(shortcuts.handleEscape(try key(0)))
        XCTAssertFalse(shortcuts.handleEscape(try key(0, type: .keyUp)))
        XCTAssertTrue(shortcuts.handleEscape(try key(53, type: .keyUp)))
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(shortcuts.handleEscape(try key(53)))
        XCTAssertFalse(shortcuts.handleEscape(try key(53, type: .keyUp)))
    }

    @MainActor
    func testEscapeDoesNotRequireTheVoiceTriggerToBeEnabled() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        shortcuts.install(key: .fn, enabled: false)
        shortcuts.setEscapeCancellationEnabled(true)
        var cancelled = false
        shortcuts.onEscape = { cancelled = true }
        XCTAssertTrue(shortcuts.handleEscape(try key(53)))
        XCTAssertTrue(cancelled)
        shortcuts.remove()
        XCTAssertTrue(shortcuts.handleEscape(try key(53, type: .keyUp)))
        XCTAssertFalse(shortcuts.handleEscape(try key(53)))
    }

    @MainActor
    func testEscapeWhileHoldingFnCannotEmitAReleaseThatFinishesCapture() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        shortcuts.install(key: .fn, enabled: true)
        var presses = 0
        var releases = 0
        shortcuts.onVoicePressed = { presses += 1 }
        shortcuts.onVoiceReleased = { releases += 1 }
        shortcuts.handle(try key(63, type: .flagsChanged, flags: .function))
        XCTAssertEqual(presses, 1)
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertTrue(shortcuts.handleEscape(try key(53)))
        shortcuts.handle(try key(63, type: .flagsChanged))
        XCTAssertEqual(releases, 0)
        shortcuts.handle(try key(63, type: .flagsChanged, flags: .function))
        shortcuts.handle(try key(63, type: .flagsChanged))
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(releases, 1)
    }

    @MainActor
    func testTriggerMonitorReceivingEscapeFirstUsesFullCancellation() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        shortcuts.install(key: .fn, enabled: true)
        var escapeCancellations = 0
        var chordCancellations = 0
        shortcuts.onVoiceCancelled = { chordCancellations += 1 }
        shortcuts.onEscape = {
            escapeCancellations += 1
            shortcuts.setEscapeCancellationEnabled(false)
        }
        shortcuts.handle(try key(63, type: .flagsChanged, flags: .function))
        shortcuts.setEscapeCancellationEnabled(true)
        shortcuts.handle(try key(53))
        XCTAssertEqual(escapeCancellations, 1)
        XCTAssertEqual(chordCancellations, 0)
        XCTAssertTrue(shortcuts.handleEscape(try key(53, type: .keyUp)))
        XCTAssertFalse(shortcuts.handleEscape(try key(53)))
    }
    @MainActor
    func testQuartzCallbackConsumesOnlyEscapeAndPreservesOrdinaryEvents() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        let escapeDown = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        let escapeUp = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false))
        let ordinary = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        var cancellations = 0
        shortcuts.onEscape = {
            cancellations += 1
            shortcuts.setEscapeCancellationEnabled(false)
        }
        XCTAssertTrue(shortcuts.filterEscapeEvent(type: .keyDown, event: escapeDown)?.takeUnretainedValue() === escapeDown)
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertTrue(shortcuts.filterEscapeEvent(type: .keyDown, event: ordinary)?.takeUnretainedValue() === ordinary)
        XCTAssertNil(shortcuts.filterEscapeEvent(type: .keyDown, event: escapeDown))
        escapeDown.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(shortcuts.filterEscapeEvent(type: .keyDown, event: escapeDown))
        XCTAssertTrue(shortcuts.filterEscapeEvent(type: .keyUp, event: ordinary)?.takeUnretainedValue() === ordinary)
        XCTAssertNil(shortcuts.filterEscapeEvent(type: .keyUp, event: escapeUp))
        XCTAssertNotNil(shortcuts.filterEscapeEvent(type: .keyDown, event: escapeDown))
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testOneCancellationPerSessionEvenBeforeOwnerDisablesIt() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        var cancellations = 0
        shortcuts.onEscape = { cancellations += 1 }
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertTrue(shortcuts.handleEscape(try key(53)))
        XCTAssertTrue(shortcuts.handleEscape(try key(53, isRepeat: true)))
        XCTAssertTrue(shortcuts.handleEscape(try key(53, type: .keyUp)))
        shortcuts.setEscapeCancellationEnabled(true) // An activity refresh is not a new session.
        XCTAssertFalse(shortcuts.handleEscape(try key(53)))
        XCTAssertEqual(cancellations, 1)
        shortcuts.setEscapeCancellationEnabled(false)
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertTrue(shortcuts.handleEscape(try key(53)))
        XCTAssertEqual(cancellations, 2)
    }

    @MainActor
    func testNewSessionWaitsForCancelledKeysReleaseBeforeCancellingAgain() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        var cancellations = 0
        shortcuts.onEscape = {
            cancellations += 1
            shortcuts.setEscapeCancellationEnabled(false)
        }
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertTrue(shortcuts.handleEscape(try key(53)))
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertTrue(shortcuts.handleEscape(try key(53, isRepeat: true)))
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(shortcuts.handleEscape(try key(53, type: .keyUp)))
        XCTAssertTrue(shortcuts.handleEscape(try key(53)))
        XCTAssertEqual(cancellations, 2)
    }

    @MainActor
    func testNonconsumingGlobalMonitorCannotDeliverEscapeCancellation() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        var cancellations = 0
        shortcuts.onEscape = { cancellations += 1 }
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertFalse(shortcuts.handle(try key(53), canConsumeEscape: false))
        XCTAssertEqual(cancellations, 0)
        XCTAssertTrue(shortcuts.handle(try key(53)))
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testTapFailureIsReportedAndIdleNeverCreatesATap() throws {
        var attempts = 0
        var receivedMask: CGEventMask = 0
        let shortcuts = GlobalShortcuts(globalAccessCheck: { true }, createEscapeTap: { mask, _, _ in
            attempts += 1
            receivedMask = mask
            return nil
        })
        XCTAssertEqual(attempts, 0)
        shortcuts.setEscapeCancellationEnabled(false)
        XCTAssertEqual(attempts, 0)
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(receivedMask, (CGEventMask(1) << CGEventType.keyDown.rawValue)
                       | (CGEventMask(1) << CGEventType.keyUp.rawValue))
        XCTAssertTrue(shortcuts.status.contains("Global Escape cancellation unavailable"))
        XCTAssertTrue(shortcuts.status.contains("only while uiui is active"))
        let event = try XCTUnwrap(CGEvent(source: nil))
        XCTAssertNotNil(shortcuts.filterEscapeEvent(type: .tapDisabledByTimeout, event: event))
        XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(shortcuts.filterEscapeEvent(type: .tapDisabledByUserInput, event: event))
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(shortcuts.status.contains("Global Escape cancellation unavailable"))
        shortcuts.setEscapeCancellationEnabled(false)
        XCTAssertFalse(shortcuts.status.contains("Global Escape cancellation unavailable"))
        XCTAssertNotNil(shortcuts.filterEscapeEvent(type: .tapDisabledByTimeout, event: event))
        XCTAssertEqual(attempts, 3) // A late timeout cannot resurrect an idle filter.
        shortcuts.remove()
    }

    @MainActor
    func testNoAccessibilityAccessNeverAttemptsGlobalTapOrClaimsGlobalCancellation() {
        var attempts = 0
        let shortcuts = GlobalShortcuts(globalAccessCheck: { false }, createEscapeTap: { _, _, _ in
            attempts += 1
            return nil
        })
        shortcuts.setEscapeCancellationEnabled(true)
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(shortcuts.status.contains("Escape cancels only while uiui is active"))
        shortcuts.remove()
    }

    @MainActor
    func testActivationRefreshWithoutGlobalAccessPreservesHeldSecondFnTap() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false, globalAccessCheck: { false })
        shortcuts.install(key: .fn, enabled: true)
        var presses = 0
        var releases = 0
        var cancellations = 0
        shortcuts.onVoicePressed = { presses += 1 }
        shortcuts.onVoiceReleased = { releases += 1 }
        shortcuts.onVoiceCancelled = { cancellations += 1 }
        shortcuts.handle(try key(63, type: .flagsChanged, flags: .function))
        shortcuts.handle(try key(63, type: .flagsChanged))
        shortcuts.handle(try key(63, type: .flagsChanged, flags: .function))
        shortcuts.refreshGlobalAccess() // Same path as didBecomeActive.
        shortcuts.handle(try key(63, type: .flagsChanged))
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(releases, 2)
        XCTAssertEqual(cancellations, 0)
        shortcuts.remove()
    }


    @MainActor
    func testAnySingleModifierCanBeTheTriggerAndTheOtherSideIsAChord() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        shortcuts.install(key: .rightCommand, enabled: true)
        var transitions: [String] = []
        shortcuts.onVoicePressed = { transitions.append("pressed") }
        shortcuts.onVoiceReleased = { transitions.append("released") }
        shortcuts.onVoiceCancelled = { transitions.append("cancelled") }
        let rightCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICERCMDKEYMASK))
        shortcuts.handle(try key(54, type: .flagsChanged, flags: rightCommand))
        shortcuts.handle(try key(54, type: .flagsChanged))
        XCTAssertEqual(transitions, ["pressed", "released"])
        // Left Command is not the trigger and cannot start it.
        let leftCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICELCMDKEYMASK))
        shortcuts.handle(try key(55, type: .flagsChanged, flags: leftCommand))
        shortcuts.handle(try key(55, type: .flagsChanged))
        XCTAssertEqual(transitions, ["pressed", "released"])
        // Right Command pressed while Left Command is held is a chord, not a tap.
        shortcuts.handle(try key(55, type: .flagsChanged, flags: leftCommand))
        shortcuts.handle(try key(54, type: .flagsChanged, flags: NSEvent.ModifierFlags(rawValue: leftCommand.rawValue | UInt(NX_DEVICERCMDKEYMASK))))
        XCTAssertEqual(transitions, ["pressed", "released"])
        shortcuts.remove()
    }

    @MainActor
    func testCombinationTriggerUsesHotKeyEventsAndIgnoresItsOwnRepeat() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        let combo = VoiceTriggerKey(keyCode: 49, modifiers: [.control, .option])
        shortcuts.install(key: combo, enabled: true)
        var transitions: [String] = []
        shortcuts.onVoicePressed = { transitions.append("pressed") }
        shortcuts.onVoiceReleased = { transitions.append("released") }
        shortcuts.onVoiceCancelled = { transitions.append("cancelled") }
        shortcuts.handleHotKey(isDown: true)
        shortcuts.handle(try key(49, flags: .option, isRepeat: true))
        // Releasing Option before Space neither finishes nor cancels the hold.
        shortcuts.handle(try key(58, type: .flagsChanged))
        shortcuts.handleHotKey(isDown: false)
        XCTAssertEqual(transitions, ["pressed", "released"])
        // Another key during a hold is a chord and cancels.
        shortcuts.handleHotKey(isDown: true)
        shortcuts.handle(try key(0))
        shortcuts.handleHotKey(isDown: false)
        XCTAssertEqual(transitions, ["pressed", "released", "pressed", "cancelled"])
        shortcuts.remove()
        shortcuts.handleHotKey(isDown: true)
        XCTAssertEqual(transitions.count, 4, "A removed trigger delivers nothing")
    }
}
