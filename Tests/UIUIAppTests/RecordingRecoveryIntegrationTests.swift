import Foundation
import XCTest
import UIUICore
@testable import UIUI

@MainActor
final class RecordingRecoveryIntegrationTests: XCTestCase {
    private func fixture(cleanup: (any DictationCleaning)? = nil, delivery overrideDelivery: RecoveryDelivery? = nil) async throws -> (AppModel, RecoveryCapture, RecoveryDelivery, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-recovery-integration-\(UUID())")
        let suite = "uiui-recovery-integration-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let capture = RecoveryCapture()
        let delivery = overrideDelivery ?? RecoveryDelivery()
        let model = AppModel(dataDirectory: root, defaults: defaults, persistSettings: false, delivery: delivery, cleanup: cleanup ?? RecoveryCleanup(),
                             voice: TriggeredVoice(capture: capture))
        model.voice.onTrigger = {}
        await model.start(installSystemServices: false)
        model.captureEnabled = true // Only the injected silent capture can start.
        model.settings.saveDictationHistory = false
        addTeardownBlock {
            await MainActor.run { model.captureEnabled = false; model.shutdown() }
            await model.recordingRecovery.flush()
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (model, capture, delivery, root)
    }

    private func started(_ model: AppModel, _ capture: RecoveryCapture) async throws {
        model.beginVoiceCapture()
        for _ in 0..<2_000 {
            if capture.startCount > 0 && model.voice.state == "capturing" { return }
            await Task.yield()
        }
        XCTFail("Injected capture did not start")
        throw RecoveryIntegrationError.notStarted
    }

    func testEscapeKeepsExactLongTranscriptAcrossRestartWithoutPasteOrHistory() async throws {
        let (model, capture, delivery, root) = try await fixture()
        try await started(model, capture)
        let text = String(repeating: "Do not send 12.50. किताब 🪷\n", count: 700) + "Keep this last sentence."
        capture.onPartial?(text)
        model.cancelVoiceInputFromEscape()
        XCTAssertFalse(model.voiceIsRecording)
        XCTAssertFalse(model.hasCancellableVoiceInput)
        XCTAssertGreaterThan(capture.cancelCount, 0)
        XCTAssertTrue(delivery.payloads.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.recordingRecoveryDrafts.first?.text, text)
        await model.recordingRecovery.flush()
        let repository = try LibraryRepository(url: root.appendingPathComponent("library.sqlite"))
        let stored = try await repository.loadRecordingDrafts()
        XCTAssertEqual(stored.map(\.text), [text])
        let restart = AppModel(dataDirectory: root, persistSettings: false,
                               delivery: RecoveryDelivery(), cleanup: RecoveryCleanup())
        await restart.start(installSystemServices: false)
        XCTAssertEqual(restart.recordingRecoveryDrafts.map(\.text), [text])
        XCTAssertFalse(restart.voiceIsRecording)
        restart.shutdown()
        await restart.recordingRecovery.flush()
    }

    func testEscapeDuringCleanupRejectsLatePasteAndKeepsFinalRecognizedWords() async throws {
        let cleanup = RecoverySuspendedCleanup()
        let (model, capture, delivery, _) = try await fixture(cleanup: cleanup)
        try await started(model, capture)
        capture.onPartial?("partial words")
        model.finishVoiceCapture()
        capture.onCompletion?(SpeechCompletion(text: "do not send the final words", reason: .final, wasExplicitlyStopped: true))
        for _ in 0..<2_000 {
            if cleanup.waiting { break }
            await Task.yield()
        }
        XCTAssertTrue(cleanup.waiting)
        model.cancelVoiceInputFromEscape()
        cleanup.resume()
        await model.voiceActionTask?.value
        await model.recordingRecovery.flush()
        XCTAssertTrue(delivery.payloads.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.recordingRecoveryDrafts.first?.text, "do not send the final words")
    }

    func testSuccessfulDeliveryWithHistoryOffRemovesTemporaryCheckpoint() async throws {
        let (model, capture, delivery, _) = try await fixture()
        try await started(model, capture)
        capture.onPartial?("recognized words")
        model.finishVoiceCapture()
        capture.onCompletion?(SpeechCompletion(text: "recognized words", reason: .final, wasExplicitlyStopped: true))
        await model.voiceActionTask?.value
        await model.recordingRecovery.flush()
        XCTAssertEqual(delivery.payloads.count, 1)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.recordingRecoveryDrafts.isEmpty)
        let stored = try await model.repository?.loadRecordingDrafts()
        XCTAssertEqual(stored?.count, 0)
    }

    func testOpenPreservesExistingDraftAndSavesExactRecoveredTextWithoutCommandsOrPaste() async throws {
        let (model, capture, delivery, _) = try await fixture()
        try await started(model, capture)
        let text = "\n  remind me to send the private note tomorrow at 9 AM\nKeep  two spaces and किताब 🪷.  \n"
        capture.onPartial?(text)
        model.cancelVoiceInputFromEscape()
        await model.recordingRecovery.flush()
        let id = try XCTUnwrap(model.recordingRecoveryDrafts.first?.id)
        model.captureText = "Unrelated unfinished draft"
        model.openRecordingRecoveryDraft(id)
        XCTAssertEqual(model.captureText, "Unrelated unfinished draft")
        model.captureText = ""
        model.openRecordingRecoveryDraft(id)
        XCTAssertEqual(model.captureText, text)
        XCTAssertEqual(model.captureMode, .dictation)
        XCTAssertEqual(model.recordingRecoveryDrafts.count, 1)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(delivery.payloads.isEmpty)
        model.captureEnabled = false
        var openedLibrary = false
        model.onOpenLibrary = { openedLibrary = true }
        model.saveCapture()
        await model.manualDeliveryTask?.value
        await model.recordingRecovery.flush()
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.kind, .dictation)
        XCTAssertNil(model.items.first?.reminderDate)
        XCTAssertEqual(model.items.first?.body, text)
        XCTAssertTrue(model.recordingRecoveryDrafts.isEmpty)
        XCTAssertTrue(delivery.payloads.isEmpty)
        XCTAssertFalse(model.showComposer)
        XCTAssertTrue(openedLibrary)
    }

    func testRecoveryReviewPreservesOriginalProjectWithoutChangingDictionaryProfile() async throws {
        let (model, capture, delivery, _) = try await fixture()
        model.captureProject = "Legacy project"
        try await started(model, capture)
        let text = "legacy recognized words"
        capture.onPartial?(text)
        model.cancelVoiceInputFromEscape()
        await model.recordingRecovery.flush()
        let id = try XCTUnwrap(model.recordingRecoveryDrafts.first?.id)
        XCTAssertEqual(model.recordingRecoveryDrafts.first?.project, "Legacy project")
        model.captureProject = "Active profile"
        model.openRecordingRecoveryDraft(id)
        XCTAssertEqual(model.captureProject, "Active profile")
        XCTAssertEqual(model.captureText, text)
        model.saveCapture()
        await model.manualDeliveryTask?.value
        await model.recordingRecovery.flush()
        XCTAssertEqual(model.captureProject, "Active profile")
        XCTAssertEqual(model.settings.vocabularyScope, "Active profile")
        XCTAssertEqual(model.items.first?.project, "Legacy project")
        XCTAssertEqual(model.items.first?.body, text)
        XCTAssertTrue(model.recordingRecoveryDrafts.isEmpty)
        XCTAssertTrue(delivery.payloads.isEmpty)
    }

    func testReviewSavingHeldFallbackPreservesFullTextWithoutAnotherCleanupOrPaste() async throws {
        let cleanup = RecoveryCountingCleanup()
        let delivery = RecoveryHeldDelivery()
        let (model, capture, _, _) = try await fixture(cleanup: cleanup, delivery: delivery)
        try await started(model, capture)
        capture.onPartial?("recognized fallback words")
        model.finishVoiceCapture()
        capture.onCompletion?(.init(text: "recognized fallback words", reason: .final, wasExplicitlyStopped: true))
        await model.voiceActionTask?.value
        XCTAssertEqual(cleanup.finishCount, 1)
        XCTAssertEqual(delivery.payloads.count, 1)
        XCTAssertFalse(model.captureText.isEmpty)
        XCTAssertNil(model.explicitlyOpenedRecoveryDraftID)
        let reviewed = "\n  remind me tomorrow. Keep  two spaces.  \n"
        model.captureText = reviewed
        model.saveCapture()
        await model.manualDeliveryTask?.value
        XCTAssertEqual(cleanup.finishCount, 1)
        XCTAssertEqual(delivery.payloads.count, 1)
        await model.recordingRecovery.flush()
        XCTAssertEqual(model.items.first?.body, reviewed)
        XCTAssertTrue(model.recordingRecoveryDrafts.isEmpty)
        XCTAssertEqual(model.items.first?.kind, .dictation)
        XCTAssertNil(model.items.first?.reminderDate)
    }

    func testFailedRecoverySaveKeepsCheckpointAndFullEditorText() async throws {
        let (model, capture, delivery, _) = try await fixture()
        try await started(model, capture)
        let text = "\n  full cancelled words.  \n"
        capture.onPartial?(text)
        model.cancelVoiceInputFromEscape()
        await model.recordingRecovery.flush()
        let id = try XCTUnwrap(model.recordingRecoveryDrafts.first?.id)
        model.openRecordingRecoveryDraft(id)
        model.repository = nil // Simulate an unavailable history store after opening.
        var openedLibrary = false
        model.onOpenLibrary = { openedLibrary = true }
        model.saveCapture()
        await model.manualDeliveryTask?.value
        await model.recordingRecovery.flush()
        XCTAssertEqual(model.captureText, text)
        XCTAssertEqual(model.recordingRecoveryDrafts.map(\.text), [text])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(delivery.payloads.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.showComposer)
        XCTAssertFalse(openedLibrary)
    }

    func testDictationCancellationWhileDeliveryWaitsPreservesWords() async throws {
        let delivery = RecoverySuspendedDelivery()
        let (model, capture, _, _) = try await fixture(delivery: delivery)
        try await started(model, capture)
        capture.onPartial?("please keep the full words")
        model.finishVoiceCapture()
        capture.onCompletion?(.init(text: "please keep the full words", reason: .final, wasExplicitlyStopped: true))
        for _ in 0..<2_000 {
            if delivery.waiting { break }
            await Task.yield()
        }
        XCTAssertTrue(delivery.waiting)
        model.cancelVoiceInputFromEscape()
        delivery.resume()
        await model.voiceActionTask?.value
        await model.recordingRecovery.flush()
        XCTAssertTrue(delivery.payloads.isEmpty)
        XCTAssertEqual(model.recordingRecoveryDrafts.first?.text, "please keep the full words")
    }

    func testManualPartialSurvivesEscapeAndShutdown() async throws {
        let (model, _, _, _) = try await fixture()
        let id = UUID()
        model.manualRecoveryCaptureID = id
        model.recordingRecovery.begin(id: id, project: "Work", kind: .dictation)
        model.speech.onPartial?("manual partial must remain")
        model.cancelRecording()
        model.shutdown()
        await model.recordingRecovery.flush()
        XCTAssertEqual(model.recordingRecoveryDrafts.map(\.text), ["manual partial must remain"])
        XCTAssertEqual(model.recordingRecoveryDrafts.first?.project, "Work")
    }

    func testDisablingRecoveryRejectsSubsequentPartialsAndOldSettingsDecodeToEnabled() async throws {
        let old = try JSONDecoder().decode(UIUISettings.self, from: Data("{\"saveDictationHistory\":false}".utf8))
        XCTAssertTrue(old.keepRecordingRecovery)
        let (model, capture, _, _) = try await fixture()
        try await started(model, capture)
        capture.onPartial?("before opting out")
        model.settings.keepRecordingRecovery = false
        capture.onPartial?("after opting out")
        model.cancelVoiceInputFromEscape()
        await model.recordingRecovery.flush()
        XCTAssertTrue(model.recordingRecoveryDrafts.isEmpty)
        let saved = try await model.repository?.loadRecordingDrafts()
        XCTAssertEqual(saved?.count, 0)
    }
}

private enum RecoveryIntegrationError: Error { case notStarted }

@MainActor
private final class RecoveryCapture: TriggeredVoiceCapture {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onCompletion: ((SpeechCompletion) -> Void)?
    var onError: ((String) -> Void)?
    var onRecovery: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onFinalization: ((Double) -> Void)?
    var startCount = 0
    var cancelCount = 0
    func requestAuthorization() async -> Bool { true }
    func start(locale: String, contextualStrings: [String]) async throws { startCount += 1 }
    func stop() {}
    func cancel() { cancelCount += 1 }
}

@MainActor
private class RecoveryDelivery: TextDelivering {
    var payloads: [String] = []
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult { payloads.append(text); return .pasteSent }
    func cancel() {}
}

@MainActor
private class RecoveryCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ captureID: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}

@MainActor
private final class RecoverySuspendedCleanup: RecoveryCleanup {
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    override func finish(_ text: String, captureID: UUID) async throws -> String {
        await withCheckedContinuation { continuation = $0 }
        return text
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class RecoverySuspendedDelivery: RecoveryDelivery {
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelled = false
    var waiting: Bool { continuation != nil }
    override func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        cancelled = false
        await withCheckedContinuation { continuation = $0 }
        if cancelled { return .held("Cancelled") }
        payloads.append(text)
        return .pasteSent
    }
    override func cancel() { cancelled = true }
    func resume() { continuation?.resume(); continuation = nil }
}


@MainActor
private final class RecoveryCountingCleanup: RecoveryCleanup {
    var finishCount = 0
    override func finish(_ text: String, captureID: UUID) async throws -> String {
        finishCount += 1
        return text
    }
}

@MainActor
private final class RecoveryHeldDelivery: RecoveryDelivery {
    override func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        payloads.append(text)
        return .held("Synthetic held delivery")
    }
}
