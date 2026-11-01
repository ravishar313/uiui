import AppKit
import XCTest
import UIUICore
@testable import UIUI

final class BackspaceEditingTests: XCTestCase {
    @MainActor
    private final class ScriptedCapture: TriggeredVoiceCapture {
        var onPartial: ((String) -> Void)?
        var onFinal: ((String) -> Void)?
        var onCompletion: ((SpeechCompletion) -> Void)?
        var onError: ((String) -> Void)?
        var onRecovery: ((String) -> Void)?
        var onAudioLevel: ((Float) -> Void)?
        var onFinalization: ((Double) -> Void)?
        var finalText = ""
        func requestAuthorization() async -> Bool { true }
        func start(locale: String, contextualStrings: [String]) async throws {}
        func stop() { onFinal?(finalText) }
        func cancel() {}
    }

    @MainActor
    func testDeletedWordStaysDeletedThroughRevisionsAndTheFinalResult() async throws {
        let capture = ScriptedCapture()
        let voice = TriggeredVoice(capture: capture)
        var seen: [String] = []
        var delivered: String?
        voice.onPartial = { seen.append($0) }
        voice.onCommand = { delivered = $0 }
        try await voice.start(locale: "en-IN", contextualStrings: [])
        XCTAssertTrue(voice.acceptsWordErasure)

        capture.onPartial?("kal meeting hai Tuesday")
        voice.eraseLastWord()
        XCTAssertEqual(voice.partialCommand, "kal meeting hai")
        XCTAssertEqual(seen.last, "kal meeting hai", "Drafts and cleanup see the edit too")

        capture.onPartial?("kal meeting hai Tuesday Wednesday")
        XCTAssertEqual(voice.partialCommand, "kal meeting hai Wednesday")

        capture.finalText = "Kal meeting hai, Tuesday Wednesday ko."
        voice.finish()
        XCTAssertEqual(delivered, "kal meeting hai Wednesday ko.")
    }

    @MainActor
    func testErasureNeverCarriesIntoTheNextCaptureAndNeedsAnOpenMicrophone() async throws {
        let capture = ScriptedCapture()
        let voice = TriggeredVoice(capture: capture)
        voice.eraseLastWord()
        XCTAssertFalse(voice.acceptsWordErasure, "With the microphone off, Backspace stays with the app")

        try await voice.start(locale: "en-IN", contextualStrings: [])
        capture.onPartial?("one two")
        voice.eraseLastWord()
        capture.finalText = "one two"
        voice.finish()
        XCTAssertFalse(voice.acceptsWordErasure)

        try await voice.start(locale: "en-IN", contextualStrings: [])
        capture.onPartial?("fresh words")
        XCTAssertEqual(voice.partialCommand, "fresh words")
    }

    @MainActor
    func testOnlyPlainBackspaceIsConsumedAndOnlyWhileEnabled() throws {
        let shortcuts = GlobalShortcuts(observesSystemEvents: false)
        var presses = 0
        shortcuts.onBackspace = { presses += 1 }
        func event(_ key: CGKeyCode, down: Bool = true, flags: CGEventFlags = []) throws -> CGEvent {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down))
            event.flags = flags
            return event
        }

        XCTAssertTrue(shortcuts.filterEscapeEvent(type: .keyDown, event: try event(51)) != nil, "Off: passes through")
        XCTAssertEqual(presses, 0)

        shortcuts.setBackspaceEditingEnabled(true)
        XCTAssertTrue(shortcuts.filterEscapeEvent(type: .keyDown, event: try event(51)) == nil)
        XCTAssertTrue(shortcuts.filterEscapeEvent(type: .keyUp, event: try event(51, down: false)) == nil)
        XCTAssertEqual(presses, 1, "A release is consumed but is not another press")

        XCTAssertTrue(shortcuts.filterEscapeEvent(type: .keyDown, event: try event(51, flags: .maskCommand)) != nil)
        XCTAssertTrue(shortcuts.filterEscapeEvent(type: .keyDown, event: try event(0)) != nil, "Other keys pass through")
        XCTAssertEqual(presses, 1)

        shortcuts.setBackspaceEditingEnabled(false)
        XCTAssertTrue(shortcuts.filterEscapeEvent(type: .keyDown, event: try event(51)) != nil)
    }
}
