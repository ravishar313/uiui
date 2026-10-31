import AppKit
import ApplicationServices
import XCTest
import UIUICore
@testable import UIUI

final class TextDeliveryTests: XCTestCase {
    func testBrowserEditorWithoutAXSettersRemainsAPasteDestination() {
        // Chromium's AXTextArea may be readable but expose no writable AX text
        // attributes. Cmd-V eligibility does not depend on those setters.
        XCTAssertTrue(TextDestinationPolicy.allowsPaste(role: kAXTextAreaRole, subrole: nil, enabled: true, containsProtectedContent: nil))
        XCTAssertTrue(TextDestinationPolicy.allowsPaste(role: kAXTextFieldRole, subrole: nil, enabled: nil, containsProtectedContent: false))
    }

    func testPastePolicyRejectsSecureDisabledProtectedAndNonTextControls() {
        XCTAssertFalse(TextDestinationPolicy.allowsPaste(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, enabled: true, containsProtectedContent: false))
        XCTAssertFalse(TextDestinationPolicy.allowsPaste(role: kAXTextAreaRole, subrole: nil, enabled: false, containsProtectedContent: false))
        XCTAssertFalse(TextDestinationPolicy.allowsPaste(role: kAXTextAreaRole, subrole: nil, enabled: true, containsProtectedContent: true))
        for role in [kAXButtonRole, kAXStaticTextRole] {
            XCTAssertFalse(TextDestinationPolicy.allowsPaste(role: role, subrole: nil, enabled: true, containsProtectedContent: false))
        }
    }

    @MainActor
    private func model(delivery: FakeDelivery, occupiedStorage: Bool = false, cleanup: (any DictationCleaning)? = nil) async throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-delivery-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = root.appendingPathComponent("data")
        if occupiedStorage { try Data("occupied".utf8).write(to: data) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "uiui-delivery-\(UUID().uuidString)"))
        let model = AppModel(dataDirectory: data, defaults: defaults, persistSettings: false, delivery: delivery, cleanup: cleanup)
        await model.start(installSystemServices: false)
        addTeardownBlock {
            await MainActor.run { model.shutdown() }
            try? FileManager.default.removeItem(at: root)
        }
        return model
    }

    @MainActor
    func testHistoryFailureCannotBlockCursorDelivery() async throws {
        let delivery = FakeDelivery()
        let model = try await model(delivery: delivery, occupiedStorage: true)
        model.performVoiceTyping("Keep these words.")
        await model.voiceActionTask?.value
        XCTAssertEqual(delivery.delivered, ["Keep these words."])
        XCTAssertEqual(model.captureText, "Keep these words.")
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testCursorDeliveryHappensBeforeHistoryIsWritten() async throws {
        let delivery = FakeDelivery()
        let model = try await model(delivery: delivery)
        var itemCountAtDelivery: Int?
        delivery.onDeliver = { itemCountAtDelivery = model.items.count }
        model.performVoiceTyping("Insert first and save second.")
        await model.voiceActionTask?.value
        XCTAssertEqual(itemCountAtDelivery, 0)
        XCTAssertEqual(model.items.map(\.body), ["Insert first and save second."])
    }

    @MainActor
    func testRecognitionPartialsStayLocalAndFinalCorrectionPastesOnce() async throws {
        let delivery = FakeDelivery()
        let model = try await model(delivery: delivery)
        model.receiveVoicePartial("First version")
        model.receiveVoicePartial("First version scratch that better version")
        XCTAssertTrue(delivery.delivered.isEmpty)
        model.performVoiceTyping("First version scratch that better version")
        await model.voiceActionTask?.value
        XCTAssertEqual(delivery.delivered, ["better version."])
        XCTAssertEqual(model.items.first?.body, "better version.")
    }

    @MainActor
    func testNewCaptureInvalidatesQueuedPasteBeforeItCanReachAnotherCursor() async throws {
        let delivery = FakeDelivery()
        let model = try await model(delivery: delivery)
        model.performVoiceTyping("Old recording")
        model.dictationCaptureGeneration = UUID()
        await model.voiceActionTask?.value
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testEscapeImmediatelyCancelsPendingCaptureAndQueuedPaste() async throws {
        let delivery = FakeDelivery()
        let model = try await model(delivery: delivery)
        model.performVoiceTyping("Cancelled words must not reach the cursor")
        let queuedPaste = try XCTUnwrap(model.voiceActionTask)
        let captureID = model.dictationCaptureGeneration
        model.voiceCaptureRequested = true
        XCTAssertTrue(model.hasCancellableVoiceInput)
        model.cancelVoiceInputFromEscape()
        XCTAssertFalse(model.voiceIsRecording)
        XCTAssertFalse(model.hasCancellableVoiceInput)
        XCTAssertNotEqual(captureID, model.dictationCaptureGeneration)
        XCTAssertTrue(queuedPaste.isCancelled)
        XCTAssertEqual(model.statusMessage, "Cancelled · microphone off")
        await queuedPaste.value
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testUnreconciledFinalKeepsFullDraftWithoutSilentlyPastingAnOlderEnding() async throws {
        let delivery = FakeDelivery()
        let model = try await model(delivery: delivery)
        let completion = SpeechCompletion(text: "The full best transcript from earlier windows", reason: .unreconciledFinal, wasExplicitlyStopped: true)
        model.voice.onIncomplete?(completion)
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertEqual(model.captureText, completion.text)
        XCTAssertEqual(model.lastTypedText, completion.text)
        XCTAssertEqual(model.dictationDeliveryIssue, completion.recoveryMessage)
        XCTAssertNotNil(model.errorMessage)
        // Reviewing an incomplete transcript saves its exact text without a paste.
        model.saveCapture()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.items.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.items.first?.body, completion.text)
        XCTAssertTrue(delivery.delivered.isEmpty)
    }

    @MainActor
    func testHeldPastePreservesDraftEvenWithHistoryDisabled() async throws {
        let delivery = FakeDelivery()
        delivery.result = .held("Destination changed")
        let model = try await model(delivery: delivery)
        model.settings.saveDictationHistory = false
        model.performVoiceTyping("Keep the complete draft.")
        await model.voiceActionTask?.value
        XCTAssertEqual(delivery.delivered, ["Keep the complete draft."])
        XCTAssertEqual(model.captureText, "Keep the complete draft.")
        XCTAssertEqual(model.dictationStreamingStatus, "Destination changed")
        XCTAssertEqual(model.dictationDeliveryIssue, "Destination changed")
        XCTAssertEqual(model.dictationFeedback?.state, .failure)
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testCopyOnlyResultKeepsFullDraftAndExplainsWhyAutomaticPasteDidNotRun() async throws {
        let delivery = FakeDelivery()
        delivery.result = .copied("The destination app changed.")
        let model = try await model(delivery: delivery)
        model.settings.saveDictationHistory = false
        let text = (0..<800).map { "word\($0)" }.joined(separator: " ")
        model.performVoiceTyping(text)
        await model.voiceActionTask?.value
        XCTAssertEqual(model.captureText, text + ".")
        XCTAssertEqual(model.lastTypedText, text + ".")
        XCTAssertEqual(delivery.delivered, [text + "."])
        XCTAssertEqual(model.activeVoiceFeedback?.state, .needsInput)
        XCTAssertEqual(model.activeVoiceFeedback?.detail, "The destination app changed.")
        XCTAssertEqual(model.dictationStreamingStatus, "Copied · paste manually")
        XCTAssertTrue(model.canCopyLastDictation)
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testDuplicateFinalCannotPasteTwiceButExplicitRetryCan() async throws {
        let delivery = FakeDelivery()
        let model = try await model(delivery: delivery)
        model.performVoiceTyping("One final transcript.")
        await model.voiceActionTask?.value
        model.performVoiceTyping("One final transcript.")
        await model.voiceActionTask?.value
        XCTAssertEqual(delivery.delivered, ["One final transcript."])
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.activeVoiceFeedback?.state, .information)
        model.performVoiceTyping("One final transcript.", isRetry: true)
        await model.voiceActionTask?.value
        XCTAssertEqual(delivery.delivered, ["One final transcript.", "One final transcript."])
    }
    @MainActor
    func testFinalQuestionIsPunctuatedOnceBeforeDeliveryAndOriginalIsRecoverable() async throws {
        let delivery = FakeDelivery()
        let model = try await model(delivery: delivery)
        model.settings.speechLocale = "en-IN"
        let original = "The build is ready. Can you check it."
        model.receiveVoicePartial(original)
        XCTAssertTrue(delivery.delivered.isEmpty)
        model.performVoiceTyping(original)
        await model.voiceActionTask?.value
        XCTAssertEqual(delivery.delivered, ["The build is ready. Can you check it?"])
        XCTAssertEqual(model.items.first?.body, "The build is ready. Can you check it?")
        XCTAssertEqual(model.items.first?.rawText, original)
        XCTAssertEqual(model.lastTypedText, "The build is ready. Can you check it?")
    }

    @MainActor
    func testNonEnglishDictationDoesNotUseEnglishPunctuation() async throws {
        let otherDelivery = FakeDelivery()
        let other = try await model(delivery: otherDelivery)
        other.settings.speechLocale = "hi-IN"
        other.performVoiceTyping("can you check it")
        await other.voiceActionTask?.value
        XCTAssertEqual(otherDelivery.delivered, ["can you check it"])
    }

    @MainActor
    func testManuallySavedDictationPunctuatesAndClearsOriginalDraft() async throws {
        let delivery = FakeDelivery()
        let model = try await model(delivery: delivery)
        model.captureMode = .dictation
        model.captureText = "when is the meeting"
        model.saveCapture(source: .dictationCompletion)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while delivery.delivered.isEmpty && clock.now < deadline { await Task.yield() }
        XCTAssertEqual(delivery.delivered, ["when is the meeting?"])
        XCTAssertEqual(model.items.first?.body, "when is the meeting?")
        XCTAssertEqual(model.items.first?.rawText, "when is the meeting")
        XCTAssertEqual(model.captureText, "")
    }

    @MainActor
    func testCleanupFinishesBeforeOnePasteAndKeepsRecognizerOriginal() async throws {
        let delivery = FakeDelivery()
        let cleanup = SuspendedCleanup()
        let model = try await model(delivery: delivery, cleanup: cleanup)
        let original = "okay can you check it"
        model.performVoiceTyping(original)
        let work = try XCTUnwrap(model.voiceActionTask)
        while cleanup.continuation == nil { await Task.yield() }
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertTrue(model.hasCancellableVoiceInput)
        cleanup.complete("Okay, can you check it?")
        await work.value
        XCTAssertEqual(delivery.delivered, ["Okay, can you check it?"])
        XCTAssertEqual(model.items.first?.rawText, original)
        XCTAssertEqual(model.items.first?.body, "Okay, can you check it?")
        XCTAssertFalse(model.hasCancellableVoiceInput)
    }

    @MainActor
    func testEscapeStopsUIAndBlocksLateCleanupPasteImmediately() async throws {
        let delivery = FakeDelivery()
        let cleanup = SuspendedCleanup()
        let model = try await model(delivery: delivery, cleanup: cleanup)
        model.performVoiceTyping("keep every word from this recording")
        let work = try XCTUnwrap(model.voiceActionTask)
        while cleanup.continuation == nil { await Task.yield() }
        model.cancelVoiceInputFromEscape()
        // These are synchronous assertions: the fake model is still suspended.
        XCTAssertFalse(model.hasCancellableVoiceInput)
        XCTAssertFalse(model.voiceIsRecording)
        XCTAssertTrue(cleanup.wasCancelled)
        XCTAssertTrue(delivery.delivered.isEmpty)
        cleanup.complete("Keep every word from this recording.")
        await work.value
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.lastTypedText, "keep every word from this recording.")
    }

    @MainActor
    func testManualDictationRetainsEscapeCancellationUntilCleanupAndPasteFinish() async throws {
        let delivery = FakeDelivery()
        let cleanup = SuspendedCleanup()
        let model = try await model(delivery: delivery, cleanup: cleanup)
        model.captureMode = .dictation
        model.captureText = "can you check the build"
        model.saveCapture(source: .dictationCompletion)
        let work = try XCTUnwrap(model.manualDeliveryTask)
        while cleanup.continuation == nil { await Task.yield() }
        XCTAssertTrue(model.hasCancellableVoiceInput)
        model.cancelVoiceInputFromEscape()
        XCTAssertFalse(model.hasCancellableVoiceInput)
        cleanup.complete("Can you check the build?")
        await work.value
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.captureText, "can you check the build")
    }

    @MainActor
    func testNewManualStartCannotStrandPendingCleanupState() async throws {
        let delivery = FakeDelivery()
        let cleanup = SuspendedCleanup()
        let model = try await model(delivery: delivery, cleanup: cleanup)
        model.captureMode = .dictation
        model.captureText = "keep the pending words"
        model.saveCapture(source: .dictationCompletion)
        let work = try XCTUnwrap(model.manualDeliveryTask)
        while cleanup.continuation == nil { await Task.yield() }
        model.toggleRecording()
        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.manualCleanupInProgress)
        cleanup.complete("Keep the pending words.")
        await work.value
        XCTAssertEqual(delivery.delivered, ["Keep the pending words."])
        XCTAssertFalse(model.manualCleanupInProgress)
        XCTAssertFalse(model.hasCancellableVoiceInput)
    }

    @MainActor
    func testEscapeDuringManualDeliveryCannotReopenComposerOrReplaceCancelledReceipt() async throws {
        let delivery = FakeDelivery(); delivery.suspend = true
        let model = try await model(delivery: delivery)
        model.captureMode = .dictation
        model.captureText = "keep the pending words"
        model.saveCapture(source: .dictationCompletion)
        let work = try XCTUnwrap(model.manualDeliveryTask)
        while delivery.pending == nil { await Task.yield() }
        model.cancelVoiceInputFromEscape()
        delivery.pending?.resume(returning: .held("cancelled at delivery")); delivery.pending = nil
        await work.value
        XCTAssertFalse(model.showComposer)
        XCTAssertEqual(model.statusMessage, "Cancelled · microphone off")
        XCTAssertFalse(model.hasCancellableVoiceInput)
    }

    @MainActor
    func testIncompleteRecognitionStopsPrefixInferenceAndRetainsFullDraft() async throws {
        let delivery = FakeDelivery()
        let cleanup = SuspendedCleanup()
        let model = try await model(delivery: delivery, cleanup: cleanup)
        let draft = "the complete earlier draft must remain recoverable"
        model.voice.onIncomplete?(SpeechCompletion(text: draft, reason: .unreconciledFinal, wasExplicitlyStopped: true))
        XCTAssertTrue(cleanup.wasCancelled)
        XCTAssertEqual(model.captureText, draft)
        XCTAssertTrue(delivery.delivered.isEmpty)
    }

}

@MainActor
private final class FakeDelivery: TextDelivering {
    var result: DeliveryResult = .pasteSent
    var delivered: [String] = []
    var onDeliver: (() -> Void)?
    var suspend = false
    var pending: CheckedContinuation<DeliveryResult, Never>?
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        onDeliver?()
        delivered.append(text)
        if suspend { return await withCheckedContinuation { pending = $0 } }
        return result
    }
    func cancel() {}
}


@MainActor
private final class SuspendedCleanup: DictationCleaning {
    var continuation: CheckedContinuation<String, Error>?
    var wasCancelled = false
    func prepare() {}
    func begin(_ id: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func cancel() { wasCancelled = true }
    func release() { cancel() }
    func complete(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}
