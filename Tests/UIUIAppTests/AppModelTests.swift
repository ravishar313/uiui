import Foundation
import XCTest
import UIUICore
import Observation
@testable import UIUI

final class AppModelTests: XCTestCase {
    @MainActor
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("data", isDirectory: true)
    }

    @MainActor
    private func makeModel(directory: URL, legacyReminderCleanup: (@MainActor (UUID) async -> Void)? = nil) throws -> AppModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "uiui-tests-\(UUID().uuidString)"))
        let model = AppModel(dataDirectory: directory, defaults: defaults, persistSettings: false,
                             delivery: AppModelHeldDelivery(), cleanup: AppModelCleanup(), legacyReminderCleanup: legacyReminderCleanup)
        addTeardownBlock { await MainActor.run { model.shutdown() } }
        return model
    }

    private enum WaitError: Error { case deadlineExceeded }

    @MainActor
    private func eventually(_ description: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw WaitError.deadlineExceeded
            }
            await Task.yield()
        }
    }

    @MainActor
    func testRecoveredTextPreservesTextAndProjectAcrossModelReload() async throws {
        let directory = try temporaryDirectory()
        let model = try makeModel(directory: directory)
        await model.start(installSystemServices: false)
        XCTAssertNil(model.errorMessage)
        let text = "Build review\n\nKeep  two spaces\tand किताब 🪷\nSecond paragraph."
        model.captureText = text
        model.captureProject = "Research"
        model.explicitlyOpenedRecoveryDraftID = UUID()
        model.saveCapture()
        try await eventually("saved draft and recorded event") { model.items.count == 1 && model.captureText.isEmpty && model.events.count == 1 }
        let saved = try XCTUnwrap(model.items.first)
        XCTAssertEqual(saved.body, text)
        XCTAssertEqual(saved.project, "Research")
        XCTAssertEqual(saved.kind, .dictation)
        XCTAssertEqual(model.selectedItemID, saved.id)

        let reloaded = try makeModel(directory: directory)
        await reloaded.start(installSystemServices: false)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertEqual(reloaded.items, [saved])
        let repository = try LibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
        let stored = try await repository.loadItems()
        XCTAssertEqual(stored, [saved])
    }

    @MainActor
    func testReviewSaveKeepsEditorOpenWhenNewerEditsArriveDuringSave() async throws {
        let model = try makeModel(directory: temporaryDirectory())
        await model.start(installSystemServices: false)
        model.captureText = "Words included in the save"
        model.showComposer = true
        var openedLibrary = false
        model.onOpenLibrary = { openedLibrary = true }
        model.saveCapture()
        // The save captures its input synchronously; these newer edits belong to
        // the still-open editor while the repository operation awaits its turn.
        model.captureText = "New edits typed after Save"
        await model.manualDeliveryTask?.value
        XCTAssertEqual(model.items.first?.body, "Words included in the save")
        XCTAssertEqual(model.captureText, "New edits typed after Save")
        XCTAssertTrue(model.showComposer)
        XCTAssertFalse(openedLibrary)
    }

    @MainActor
    func testRecoverySaveFailureKeepsDraftWithoutReportingSuccess() async throws {
        let directory = try temporaryDirectory()
        try Data("occupied path".utf8).write(to: URL(fileURLWithPath: directory.path))
        let model = try makeModel(directory: directory)
        await model.start(installSystemServices: false)
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        let draft = "This draft must survive a failed save."
        model.captureText = draft
        model.explicitlyOpenedRecoveryDraftID = UUID()
        model.saveCapture()
        try await eventually("save failure") { model.errorMessage != nil }
        XCTAssertEqual(model.captureText, draft)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertNil(model.selectedItemID)
        XCTAssertEqual(model.statusMessage, "Couldn’t save yet. Your draft is kept here.")
    }

    @MainActor
    func testPrepareDictationPreservesUnfinishedDraftAndDoesNotStartMicrophone() async throws {
        let model = try makeModel(directory: temporaryDirectory())
        await model.start(installSystemServices: false)
        let draft = "Unfinished note\nwith another line"
        model.captureText = draft
        model.captureMode = .dictation
        let initialSpeechStatus = model.speechStatus
        var openedDraft = false
        model.onOpenCapture = { openedDraft = true }
        model.prepareDictation()
        XCTAssertEqual(model.captureText, draft)
        XCTAssertEqual(model.captureMode, .dictation)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(model.speechStatus, initialSpeechStatus)
        XCTAssertTrue(openedDraft)
        XCTAssertEqual(model.statusMessage, "An unfinished draft is waiting. Save or clear it before a new dictation.")
    }

    @MainActor
    func testReminderWordingRemainsDictationAndDoesNotCreateHistoryWhenDisabled() async throws {
        let model = try makeModel(directory: temporaryDirectory())
        await model.start(installSystemServices: false)
        model.settings.saveDictationHistory = false
        let text = "remind me to check build in 10 minutes"
        model.captureText = text
        model.saveCapture(source: .dictationCompletion)
        await model.manualDeliveryTask?.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.captureText, text)
        XCTAssertEqual(model.events.map(\.action), ["dictation"])
        XCTAssertFalse(model.captureEnabled)
        XCTAssertFalse(model.isRecording)
    }

    @MainActor
    func testLegacyKindsRemainVisibleAndSearchableWithoutMutatingMetadata() async throws {
        let directory = try temporaryDirectory()
        let repository = try LibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
        let kinds: [CaptureKind] = [.note, .thought, .reminder, .dictation]
        let legacy = kinds.map { CaptureItem(title: "Legacy \($0.rawValue)", body: $0 == .reminder ? "Unique searchable wording" : "Archived wording", kind: $0, project: "Old project", reminderDate: $0 == .reminder ? Date().addingTimeInterval(600) : nil, rawText: "Original wording") }
        for item in legacy { try await repository.upsert(item) }
        let model = try makeModel(directory: directory)
        await model.start(installSystemServices: false)
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set(legacy.map(\.id)))
        model.searchText = "Unique"
        try await eventually("legacy search results") { model.visibleItems.count == 1 }
        XCTAssertEqual(model.visibleItems.map(\.kind), [.reminder])
        let stored = try await repository.loadItems()
        XCTAssertEqual(Set(stored), Set(legacy))
    }

    @MainActor
    func testDeletingLegacyReminderCancelsOnlyAfterDurableHistoryDeletion() async throws {
        let directory = try temporaryDirectory()
        let repository = try LibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
        let item = CaptureItem(title: "Old reminder", body: "Legacy record", kind: .reminder)
        let remaining = CaptureItem(title: "Other reminder", body: "Keep scheduled", kind: .reminder)
        try await repository.upsert(item)
        try await repository.upsert(remaining)
        var removedIDs: [UUID] = []
        var recordsAtCleanup: [CaptureItem] = []
        let model = try makeModel(directory: directory, legacyReminderCleanup: { id in
            recordsAtCleanup = (try? await repository.loadItems()) ?? []
            removedIDs.append(id)
        })
        await model.start(installSystemServices: false)
        XCTAssertTrue(removedIDs.isEmpty) // Startup preserves previously scheduled requests.
        model.delete(item)
        try await eventually("legacy reminder deletion") { model.statusMessage == "Moved out of your library." }
        XCTAssertEqual(removedIDs, [item.id])
        XCTAssertEqual(recordsAtCleanup, [remaining])
        XCTAssertEqual(model.items, [remaining])
    }

    @MainActor
    func testDeletingLegacyReminderDateAlsoUsesCompatibilityCleanup() async throws {
        let directory = try temporaryDirectory()
        let item = CaptureItem(title: "Old dated note", body: "Legacy record", kind: .note, reminderDate: Date().addingTimeInterval(600))
        let repository = try LibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
        try await repository.upsert(item)
        var removedIDs: [UUID] = []
        let model = try makeModel(directory: directory, legacyReminderCleanup: { removedIDs.append($0) })
        await model.start(installSystemServices: false)
        model.delete(item)
        try await eventually("dated record deletion") { model.statusMessage == "Moved out of your library." }
        XCTAssertEqual(removedIDs, [item.id])
    }

    @MainActor
    func testDeletingOrdinaryHistoryDoesNotUseNotificationCleanup() async throws {
        let directory = try temporaryDirectory()
        let item = CaptureItem(title: "Dictation", body: "Ordinary words", kind: .dictation)
        let repository = try LibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
        try await repository.upsert(item)
        var removedIDs: [UUID] = []
        let model = try makeModel(directory: directory, legacyReminderCleanup: { removedIDs.append($0) })
        await model.start(installSystemServices: false)
        model.delete(item)
        try await eventually("ordinary record deletion") { model.statusMessage == "Moved out of your library." }
        XCTAssertTrue(removedIDs.isEmpty)
    }

    @MainActor
    func testFailedHistoryDeleteNeverUsesNotificationCleanup() async throws {
        var removedIDs: [UUID] = []
        let model = try makeModel(directory: temporaryDirectory(), legacyReminderCleanup: { removedIDs.append($0) })
        let item = CaptureItem(title: "Old reminder", body: "Legacy record", kind: .reminder)
        // No repository is connected: durable deletion must fail first.
        model.delete(item)
        try await eventually("deletion failure") { model.errorMessage != nil }
        XCTAssertTrue(removedIDs.isEmpty)
    }

    @MainActor
    func testUpdatingPreviouslySelectedItemDoesNotStealCurrentSelection() async throws {
        let directory = try temporaryDirectory()
        let repository = try LibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
        let first = CaptureItem(title: "First", body: "Original first item")
        let second = CaptureItem(title: "Second", body: "Keep this selection")
        try await repository.upsert(first)
        try await repository.upsert(second)
        let model = try makeModel(directory: directory)
        await model.start(installSystemServices: false)
        model.selectedItemID = first.id
        var edited = first
        edited.body = "Updated first item"
        model.selectedItemID = second.id
        model.updateItem(edited)
        try await eventually("saved edit") { model.items.first(where: { $0.id == first.id })?.body == edited.body && model.statusMessage == "Changes saved." }
        XCTAssertEqual(model.selectedItemID, second.id)
        XCTAssertEqual(model.selectedItem?.body, second.body)
        let stored = try await repository.loadItems()
        XCTAssertEqual(stored.first(where: { $0.id == first.id })?.body, edited.body)
    }

    @MainActor
    func testNotchStylePreviewShowsListeningWithoutMicrophoneAndEndsCleanly() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "uiui-preview-\(UUID().uuidString)"))
        let model = AppModel(dataDirectory: try temporaryDirectory(), defaults: defaults, persistSettings: false)
        defer { model.shutdown() }
        await model.start(installSystemServices: false)
        var changes: [Bool] = []
        model.onNotchPreviewChanged = { changes.append($0) }
        XCTAssertEqual(model.notchFeedbackPhase, .idle)
        model.notchStylePreviewActive = true
        model.notchPreviewLevel = 0.6
        XCTAssertEqual(model.notchFeedbackPhase, .recording)
        XCTAssertEqual(model.notchAudioLevel, 0.6)
        XCTAssertFalse(model.voiceIsRecording, "The preview never opens the microphone")
        model.notchStylePreviewActive = true
        model.notchStylePreviewActive = false
        XCTAssertEqual(model.notchFeedbackPhase, .idle)
        XCTAssertEqual(model.notchAudioLevel, 0)
        XCTAssertEqual(changes, [true, false], "Only real transitions reach the notch owner")
    }

    @MainActor
    func testLegacyListeningPreferenceMigratesWithoutStartingMicrophone() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "uiui-migration-\(UUID().uuidString)"))
        let legacy = Data(#"{"handsFreeEnabled":true,"speechLocale":"en-GB","quietMode":true,"customProjects":["Work"],"notchEnabled":false}"#.utf8)
        defaults.set(legacy, forKey: "uiui.settings")
        let model = AppModel(dataDirectory: try temporaryDirectory(), defaults: defaults, persistSettings: false)
        defer { model.shutdown() }
        await model.start(installSystemServices: false)
        XCTAssertEqual(model.settings.voiceTriggerMode, .toggle)
        XCTAssertEqual(model.settings.voiceTriggerKey, .fn)
        XCTAssertEqual(model.settings.speechLocale, "en-GB")
        XCTAssertTrue(model.settings.quietMode)
        XCTAssertFalse(model.settings.notchEnabled)
        XCTAssertEqual(model.settings.customProjects, ["Work"])
        XCTAssertFalse(model.voiceIsRecording)
        XCTAssertFalse(model.voice.isEnabled)
        XCTAssertFalse(model.isRecording)
        let encoded = try JSONEncoder().encode(model.settings)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("handsFreeEnabled"))
    }

    @MainActor
    func testPendingCapturePublishesRecordingStateInBothDirections() async throws {
        let model = try makeModel(directory: temporaryDirectory())
        let began = expectation(description: "Recording indicator updates on trigger")
        withObservationTracking {
            XCTAssertFalse(model.voiceIsRecording)
        } onChange: { began.fulfill() }
        model.voiceCaptureRequested = true
        await fulfillment(of: [began], timeout: 1)
        let ended = expectation(description: "Recording indicator clears after finish")
        withObservationTracking {
            XCTAssertTrue(model.voiceIsRecording)
        } onChange: { ended.fulfill() }
        model.voiceCaptureRequested = false
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertFalse(model.voiceIsRecording)
    }

    @MainActor
    func testStartWithoutSystemServicesBlocksManualAndTriggeredCapture() async throws {
        let model = try makeModel(directory: temporaryDirectory())
        await model.start(installSystemServices: false)
        model.toggleRecording()
        model.beginVoiceCapture()
        XCTAssertFalse(model.captureEnabled)
        XCTAssertFalse(model.hasCancellableVoiceInput)
        model.cancelVoiceInputFromEscape()
        XCTAssertFalse(model.hasCancellableVoiceInput)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.speech.hasActiveSession)
        XCTAssertEqual(model.statusMessage, "Cancelled · microphone off")
    }

    @MainActor
    func testEmptyManualRecognitionFailureStillPublishesEndOfCapture() throws {
        let model = try makeModel(directory: temporaryDirectory())
        var activityUpdates = 0
        model.onActivityChanged = { activityUpdates += 1 }
        model.receiveManualSpeechCompletion(SpeechCompletion(text: "", reason: .recognitionError, wasExplicitlyStopped: false))
        XCTAssertEqual(activityUpdates, 1)
        XCTAssertFalse(model.hasCancellableVoiceInput)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "No speech detected · microphone off")
    }

    @MainActor
    func testSpokenCorrectionPersistsEditedWordsWithRecoverableOriginal() async throws {
        let model = try makeModel(directory: temporaryDirectory())
        await model.start(installSystemServices: false)
        let raw = "Wrong sentence no actually scratch that Keep this exact wording."
        model.performVoiceTyping(raw)
        try await eventually("corrected dictation and held delivery") {
            model.items.count == 1 && model.events.contains(where: { $0.action == "paste_held" })
        }
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.body, "Keep this exact wording.")
        XCTAssertEqual(item.rawText, raw)
        XCTAssertEqual(model.captureText, item.body)
        XCTAssertFalse(model.voiceIsRecording)
    }

    @MainActor
    func testScratchThatWithoutReplacementCreatesNoEmptyCapture() async throws {
        let model = try makeModel(directory: temporaryDirectory())
        await model.start(installSystemServices: false)
        model.performVoiceTyping("unwanted wording scratch that")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertEqual(model.statusMessage, "Current dictation cleared.")
        XCTAssertFalse(model.voiceIsRecording)
    }
}

/// Persistence/correction tests choose their delivery outcome explicitly. They
/// must not depend on sandbox/Accessibility state or write the user's clipboard.
@MainActor
private final class AppModelHeldDelivery: TextDelivering {
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        .held("Synthetic held delivery")
    }
    func cancel() {}
}

@MainActor
private final class AppModelCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ captureID: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}
