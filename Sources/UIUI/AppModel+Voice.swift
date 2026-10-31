import Foundation
import UIUICore

@MainActor
extension AppModel {
    func voiceTriggerPressed() {
        guard settings.voiceTriggerEnabled else { return }
        voiceTriggerIsPressed = true
        voiceKeyPressedAt = DispatchTime.now().uptimeNanoseconds
        handleVoiceGesture(.pressed)
        onActivityChanged?()
    }
    func voiceTriggerReleased() {
        guard settings.voiceTriggerEnabled else { return }
        voiceTriggerIsPressed = false
        handleVoiceGesture(.released)
        onActivityChanged?()
    }
    func voiceTriggerCancelled() {
        voiceTriggerIsPressed = false
        handleVoiceGesture(.cancelled)
        onActivityChanged?()
    }
    func handleVoiceGesture(_ event: VoiceGestureEvent, at timestamp: TimeInterval? = nil) {
        let actions = voiceGesture.handle(event, mode: settings.voiceTriggerMode, activeCapture: voiceIsRecording ? voiceInputKind : queuedVoiceCaptureKind, now: timestamp ?? ProcessInfo.processInfo.systemUptime)
        for action in actions {
            switch action {
            case .startDictation: beginVoiceCapture(kind: .dictation, triggeredAt: voiceKeyPressedAt)
            case .finish: finishVoiceCapture()
            case .cancelCapture:
                if queuedVoiceCaptureKind != nil, !voiceIsRecording {
                    finishVoiceCapture() // Cancel only the next hold request.
                    continue
                }
                queuedVoiceCaptureKind = nil; queuedVoiceTriggerAt = nil
                voiceTriggerIsPressed = false
                voiceCaptureRequested = false; voiceStartTask?.cancel()
                preserveTriggeredRecordingRecovery()
                voice.stop(); cleanup.cancel(); delivery.cancel()
                dictationStreamingStatus = "Cancelled · microphone off"
                statusMessage = "Key combination · microphone off"
            case .scheduleHold:
                let identifier = UUID(); voiceGestureTimerID = identifier
                voiceGestureTimer?.cancel()
                voiceGestureTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                    guard let self, voiceGestureTimerID == identifier else { return }
                    handleVoiceGesture(.holdThreshold)
                }
            case .cancelHold:
                voiceGestureTimerID = UUID(); voiceGestureTimer?.cancel()
            }
        }
    }
    func toggleVoiceCapture() {
        if voiceIsRecording { finishVoiceCapture() }
        else { beginVoiceCapture() }
    }
    func beginVoiceCapture(kind: VoiceGestureCaptureKind = .dictation, triggeredAt: UInt64? = nil) {
        guard !voiceIsRecording else { return }
        guard captureEnabled else { return } // Tests must opt in with an injected silent capture.
        defer { onActivityChanged?() }
        if manualCleanupInProgress || speech.isFinalizing || voice.state == "finishing" || voiceTypingOperationID != nil || dictationFeedback?.state == .working {
            // One explicit request waits behind the current result. It never
            // restarts the old recognizer or preempts its only paste.
            queuedVoiceCaptureKind = kind
            queuedVoiceTriggerAt = triggeredAt
            statusMessage = "Finishing your words · next recording queued · microphone off"
            return
        }
        if typingCheckTask != nil { cancelTypingCheck() }
        preserveManualRecordingRecovery()
        speech.cancel()
        preserveTriggeredRecordingRecovery()
        delivery.cancel()
        voiceInputKind = kind
        manualVoiceIssue = nil
        dictationDeliveryIssue = nil
        dictationFeedback = nil
        notchExtras.clearUndo()
        dictationCaptureGeneration = UUID()
        voiceRecoveryCaptureID = dictationCaptureGeneration
        recordingRecovery.begin(id: dictationCaptureGeneration, project: captureProject, kind: .dictation)
        if kind == .dictation, LocalSpeechModel.supports(locale: settings.speechLocale) {
            cleanup.begin(dictationCaptureGeneration)
            cleanup.prepare()
        } else { cleanup.cancel() }
        voiceRequestedAt = triggeredAt ?? DispatchTime.now().uptimeNanoseconds
        voiceFinishedAt = nil
        voiceFirstPartialSeen = false
        if kind == .dictation {
            // Recognition streams only into the nonactivating HUD. External editors
            // receive one normal paste after stop, with no speculative AX mutations.
            dictationStreamingStatus = "Live preview · inserts when you finish"
        }
        voiceCaptureRequested = true
        errorMessage = nil
        voiceStartTask = Task { [weak self] in
            guard let self, voiceCaptureRequested, !Task.isCancelled else { return }
            do {
                try await voice.start(locale: settings.speechLocale, contextualStrings: contextualVocabulary)
                notchExtras.captureStarted()
                if let startedAt = voiceRequestedAt { recordVoiceTiming("voice_startup", since: startedAt) }
                statusMessage = settings.voiceTriggerMode == .toggle ? "Listening. Tap \(settings.voiceTriggerKey.title) again to finish." : "Listening. Release \(settings.voiceTriggerKey.title) to finish."
            } catch is CancellationError {} catch {
                voiceCaptureRequested = false
                errorMessage = error.localizedDescription
                statusMessage = "Voice needs a one-time setup. Microphone off."
            }
            onActivityChanged?()
        }
    }
    func finishVoiceCapture() {
        if queuedVoiceCaptureKind != nil, !voiceIsRecording {
            queuedVoiceCaptureKind = nil; queuedVoiceTriggerAt = nil
            voiceTriggerIsPressed = false
            statusMessage = "Next recording cancelled · finishing current words"
            onActivityChanged?()
            return
        }
        guard voiceIsRecording else { return }
        voiceFinishedAt = DispatchTime.now().uptimeNanoseconds
        voiceCaptureRequested = false
        voiceStartTask?.cancel()
        voice.finish()
        statusMessage = "Finishing your words · microphone off"
        onActivityChanged?()
    }
    func cancelTriggeredVoice() {
        stopVoiceSession()
        publishVoiceCancellation()
        statusMessage = "Cancelled · microphone off"
        onActivityChanged?()
    }
    func publishVoiceCancellation() {
        let detail = recordingRecovery.drafts.isEmpty ? "Microphone off. Your request was cancelled." : "Microphone off. Recognized text is kept in uiui → Recovery drafts."
        let receipt = VoiceActionFeedback(state: .information, title: "Cancelled", detail: detail, presentation: .cancellation)
        dictationFeedback = receipt
    }
    func requestVoiceTriggerAccess() { onVoiceTriggerAccess?() }
    func disableVoice() {
        settings.voiceTriggerEnabled = false
    }
    func stopVoiceSession() {
        preserveTriggeredRecordingRecovery()
        queuedVoiceCaptureKind = nil; queuedVoiceTriggerAt = nil
        voiceTriggerIsPressed = false
        cleanup.cancel()
        _ = voiceGesture.handle(.reset, mode: settings.voiceTriggerMode, activeCapture: nil, now: ProcessInfo.processInfo.systemUptime)
        voiceGestureTimerID = UUID(); voiceGestureTimer?.cancel()
        dictationCaptureGeneration = UUID()
        voiceCaptureRequested = false
        voiceFinishedAt = nil
        voiceStartTask?.cancel()
        voice.stop()
        cancelVoiceActions()
    }
    /// Event-driven handoff only. A final recognizer callback publishes "working"
    /// before dispatching onCommand; don't replace it during that narrow boundary.
    func resumeQueuedVoiceCaptureIfReady(afterCommand: Bool = false) {
        guard let kind = queuedVoiceCaptureKind, !voiceIsRecording,
              !voiceResultIsBeingHandled, voiceTypingOperationID == nil,
              !manualCleanupInProgress, !speech.hasActiveSession,
              voice.state != "finishing", (afterCommand || (voice.state != "working" && voice.state != "incomplete")),
              dictationFeedback?.state != .working else { return }
        let triggeredAt = queuedVoiceTriggerAt
        queuedVoiceCaptureKind = nil; queuedVoiceTriggerAt = nil
        beginVoiceCapture(kind: kind, triggeredAt: triggeredAt)
    }
    private func cancelVoiceActions() {
        if dictationFeedback?.state == .working {
            dictationFeedback = VoiceActionFeedback(state: .information, title: "Cancelled", detail: "Paste stopped. Your words are kept in uiui.", presentation: .cancellation)
        }
        voiceActionGeneration = UUID()
        voiceTypingOperationID = nil
        voiceActionTask?.cancel()
        delivery.cancel()
        dictationStreamingStatus = "Cancelled · microphone off"
    }
    func receiveVoicePartial(_ text: String) {
        notchExtras.transcriptChanged(hasText: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        checkpointTriggeredRecordingRecovery(text)
        if voiceInputKind == .dictation, LocalSpeechModel.supports(locale: settings.speechLocale) {
            cleanup.update(dictationWords(text), captureID: dictationCaptureGeneration,
                           formatted: DictationCleanupText.isFormatted(text))
        }
        if !text.isEmpty, !voiceFirstPartialSeen, let start = voiceRequestedAt {
            voiceFirstPartialSeen = true
            recordVoiceTiming("voice_first_partial", since: start)
        }
    }

    func recordVoiceTiming(_ action: String, since start: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return }
        let milliseconds = Double(now - start) / 1_000_000
        Task { [weak self] in await self?.record(UsageEvent(action: action, durationMS: milliseconds)) }
    }

    private func dictationWords(_ input: String) -> String {
        TextProcessing.applyingVocabulary(to: DictationEditing.applyingCommands(to: input), entries: effectiveVocabulary, project: captureProject)
    }

    func performVoiceTyping(_ input: String, isRetry: Bool = false) {
        let inputKind = voiceInputKind
        let captureID = dictationCaptureGeneration
        let recoveryID = voiceRecoveryCaptureID
        checkpointTriggeredRecordingRecovery(input)
        // Recognition may publish a late duplicate final. Dispatch each capture once.
        guard inputKind != .dictation || isRetry || dictationDeliveryStartedFor != captureID else { return }
        if inputKind == .dictation {
            dictationDeliveryStartedFor = captureID
        }
        let vocabularyText = inputKind == .dictation ? dictationWords(input)
            : TextProcessing.applyingVocabulary(to: input, entries: effectiveVocabulary, project: captureProject)
        let fallback = inputKind == .dictation ? punctuateDictation(vocabularyText) : vocabularyText
        lastTypedText = fallback
        let destination = isRetry
            ? (captureEnabled ? TextDelivery.captureTarget() : nil)
            : voiceDestination
        let generation = voiceActionGeneration
        if vocabularyText.isEmpty {
            finishTriggeredRecordingRecovery(id: recoveryID, preserving: false)
            statusMessage = "Current dictation cleared."; dictationStreamingStatus = "Current dictation cleared"
            if inputKind == .dictation {
                dictationFeedback = VoiceActionFeedback(state: .information, title: "Dictation cleared", detail: "Nothing was pasted.")
            }
            voice.setWorking(false)
            onActivityChanged?()
            return
        }
        // Keep Escape armed while a stopped partial waits for its one paste,
        // just as for a recognizer-confirmed final result.
        let typingOperationID = UUID()
        voiceTypingOperationID = typingOperationID
        voice.setWorking(true)
        if inputKind == .dictation {
            dictationFeedback = VoiceActionFeedback(state: .working, title: "Finishing dictation", detail: "On-device cleanup · microphone off.")
            onActivityChanged?()
        }
        voiceActionTask = Task {
            defer {
                if voiceTypingOperationID == typingOperationID {
                    voiceTypingOperationID = nil
                    if captureID == dictationCaptureGeneration { voice.setWorking(false) }
                    resumeQueuedVoiceCaptureIfReady()
                    onActivityChanged?()
                }
            }
            guard generation == voiceActionGeneration, !Task.isCancelled else { return }
            guard generation == voiceActionGeneration, captureID == dictationCaptureGeneration, !Task.isCancelled else { return }
            let cleanedText: String
            do {
                if inputKind == .dictation, !isRetry, LocalSpeechModel.supports(locale: settings.speechLocale) {
                    cleanedText = try await cleanup.finish(vocabularyText, captureID: captureID,
                                                           formatted: DictationCleanupText.isFormatted(input))
                } else { cleanedText = fallback }
            } catch {
                if captureID == dictationCaptureGeneration { finishTriggeredRecordingRecovery(id: recoveryID, preserving: true) }
                return
            }
            guard generation == voiceActionGeneration, captureID == dictationCaptureGeneration, !Task.isCancelled else { return }
            // Cleanup may capitalize a custom name. Match only the stored replacement forms
            // here, preserving exact case without running heard aliases a second time.
            let text = TextProcessing.preservingVocabularySpelling(in: cleanedText, entries: effectiveVocabulary, project: captureProject)
            lastTypedText = text
            if inputKind == .dictation {
                dictationFeedback = VoiceActionFeedback(state: .working, title: "Placing dictation", detail: "Microphone off.")
                onActivityChanged?()
            }
            let historyItem = settings.saveDictationHistory
                ? CaptureItem(title: TextProcessing.title(for: text), body: text, kind: .dictation, project: captureProject, sourceApp: destination?.appName, rawText: text == input ? nil : input)
                : nil
            let event: UsageEvent
            // One normal paste is the only external edit. Recognition partials
            // stay in the HUD; no failed speculative edit can suppress this path.
            let result = await delivery.deliver(text, to: destination)
            guard captureID == dictationCaptureGeneration else { return }
            switch result {
            case .pasteSent:
                dictationDeliveryIssue = nil
                dictationStreamingStatus = "Paste sent · copied"
                if inputKind == .dictation {
                    var receipt = VoiceActionFeedback(state: .information, title: "Paste sent · copied",
                        detail: "Sent to \(destination?.appName ?? "your app"). The complete dictation stays on your clipboard.", presentation: .pasteDispatch)
                    // Undo and Copy stay reachable briefly; Undo needs a known destination.
                    receipt.offersUndo = true
                    notchExtras.offerUndo(captureID: captureID, target: destination)
                    dictationFeedback = receipt
                }
                let sentAt = DispatchTime.now().uptimeNanoseconds
                let elapsed = voiceFinishedAt.flatMap { sentAt >= $0 ? Double(sentAt - $0) / 1_000_000 : nil }
                event = UsageEvent(action: "paste_dispatched", durationMS: elapsed, wordCount: TextProcessing.wordCount(text))
            case .copied(let reason):
                dictationDeliveryIssue = reason
                captureText = text
                dictationStreamingStatus = "Copied · paste manually"
                statusMessage = reason
                if inputKind == .dictation {
                    dictationFeedback = VoiceActionFeedback(state: .needsInput, title: "Copied · paste manually", detail: reason, presentation: .copiedOnly)
                }
                event = UsageEvent(action: "dictation_copied", wordCount: TextProcessing.wordCount(text))
            case .held(let reason):
                dictationDeliveryIssue = reason
                captureText = text; composerRecoveryDraftID = recoveryID
                statusMessage = reason; dictationStreamingStatus = reason
                if inputKind == .dictation {
                    dictationFeedback = VoiceActionFeedback(state: .failure, title: "Couldn’t paste · words kept", detail: reason)
                }
                event = UsageEvent(action: "paste_held", succeeded: false)
            }
            onActivityChanged?()
            let historySaved: Bool
            if let item = historyItem {
                historySaved = await persist(item)
                if !historySaved, captureID == dictationCaptureGeneration { captureText = text }
            } else { historySaved = false }
            if captureID == dictationCaptureGeneration {
                let preserve: Bool
                if historyItem != nil { preserve = !historySaved }
                else if case .held = result { preserve = true }
                else { preserve = false }
                finishTriggeredRecordingRecovery(id: recoveryID, preserving: preserve)
            }
            await record(event)
        }
    }

    /// An explicit, microphone-free check of the same final insertion path.
    /// The delay lets the user put the cursor in a disposable target field.
    func testTyping() {
        guard typingCheckTask == nil, !voiceIsRecording, !isRecording else { return }
        let checkID = UUID(); typingCheckID = checkID
        typingCheckStatus = "Click an empty text field. uiui will type a test in 8 seconds."
        typingCheckTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, typingCheckID == checkID, !Task.isCancelled else { return }
            defer { if typingCheckID == checkID { typingCheckTask = nil } }
            guard !voiceIsRecording, !isRecording else { typingCheckStatus = "Typing check cancelled while recording."; return }
            let destination = TextDelivery.captureTarget()
            let result = await delivery.deliver("uiui typing test", to: destination)
            guard typingCheckID == checkID else { return }
            switch result {
            case .pasteSent: typingCheckStatus = "Paste sent to \(destination?.appName ?? "the focused field"). Check that uiui typing test appeared."
            case .copied(let reason): typingCheckStatus = "Test copied. " + reason
            case .held(let reason): typingCheckStatus = reason
            }
        }
    }
    func cancelTypingCheck() {
        if typingCheckTask != nil { delivery.cancel() }
        typingCheckID = UUID()
        typingCheckTask?.cancel(); typingCheckTask = nil; typingCheckStatus = "Typing check cancelled."
    }
}
