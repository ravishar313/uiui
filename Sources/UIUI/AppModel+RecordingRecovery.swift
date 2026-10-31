import Foundation
import UIUICore

@MainActor
extension AppModel {
    var recordingRecoveryDrafts: [RecordingRecoveryDraft] { recordingRecovery.drafts }
    var recordingRecoveryIssue: String? { recordingRecovery.issue }

    func checkpointTriggeredRecordingRecovery(_ text: String) {
        guard let id = voiceRecoveryCaptureID, id == dictationCaptureGeneration else { return }
        recordingRecovery.update(id: id, text: text)
    }

    func preserveTriggeredRecordingRecovery() {
        finishTriggeredRecordingRecovery(preserving: true)
    }

    func finishTriggeredRecordingRecovery(id explicitID: UUID? = nil, preserving: Bool) {
        guard let id = explicitID ?? voiceRecoveryCaptureID else { return }
        recordingRecovery.finish(id: id, preserving: preserving)
        if voiceRecoveryCaptureID == id { voiceRecoveryCaptureID = nil }
    }

    func preserveManualRecordingRecovery() {
        finishManualRecordingRecovery(id: manualRecoveryCaptureID, preserving: true)
    }

    func finishManualRecordingRecovery(id: UUID?, preserving: Bool) {
        guard let id else { return }
        recordingRecovery.finish(id: id, preserving: preserving)
        if manualRecoveryCaptureID == id { manualRecoveryCaptureID = nil }
    }

    func openRecordingRecoveryDraft(_ id: UUID) {
        guard !hasCancellableVoiceInput else { return }
        guard let draft = recordingRecovery.drafts.first(where: { $0.id == id }) else { return }
        guard captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || captureText == draft.text else {
            statusMessage = "Save or clear the current draft before opening recovered text."
            showComposer = true
            onOpenCapture?()
            return
        }
        // Recovery is reviewable text. It never replays a command, reminder,
        // microphone request, or paste into the previously focused application.
        captureMode = .dictation
        captureText = draft.text
        composerRecoveryDraftID = id
        explicitlyOpenedRecoveryDraftID = id
        showComposer = true
        statusMessage = "Recovered text opened for review. Save it to history or copy it."
        onOpenCapture?()
    }

    func copyRecordingRecoveryDraft(_ id: UUID) {
        guard !hasCancellableVoiceInput,
              let draft = recordingRecovery.drafts.first(where: { $0.id == id }) else { return }
        copy(draft.text)
    }

    func discardRecordingRecoveryDraft(_ id: UUID) {
        guard !hasCancellableVoiceInput else { return }
        recordingRecovery.discard(id: id)
        if composerRecoveryDraftID == id { composerRecoveryDraftID = nil }
        if explicitlyOpenedRecoveryDraftID == id { explicitlyOpenedRecoveryDraftID = nil }
    }
}
