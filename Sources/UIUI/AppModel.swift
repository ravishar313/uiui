import AppKit
import Foundation
import Observation
import ServiceManagement
import UIUICore

@MainActor @Observable
final class AppModel {
    private(set) var items: [CaptureItem] = []
    private(set) var events: [UsageEvent] = []
    var selection: LibrarySection = .dictations
    var workspaceSheet: WorkspaceSheet?
    var selectedItemID: UUID?
    var searchText = "" { didSet { scheduleSearch() } }
    var captureText = ""
    /// Formatting decision on the raw recognised text of the completion being saved.
    private var completionRawFormatted: Bool?
    var captureMode: CaptureMode = .dictation { didSet { if oldValue != captureMode && speech.isRecording { cancelRecording() } } }
    /// The active dictionary profile persists independently of recovery metadata.
    var captureProject: String {
        get { settings.vocabularyScope }
        set { settings.vocabularyScope = newValue }
    }
    var statusMessage = "Ready to dictate."
    var errorMessage: String?
    var showComposer = false
    var notchExpanded = false
    var notchMounted = false
    var notchHasCamera = false
    var notchCameraWidth: CGFloat = 180
    var notchCameraHeight: CGFloat = 36
    var settings: UIUISettings {
        didSet {
            if oldValue.voiceTriggerEnabled != settings.voiceTriggerEnabled || oldValue.voiceTriggerKey != settings.voiceTriggerKey || oldValue.voiceTriggerMode != settings.voiceTriggerMode {
                stopVoiceSession()
            }
            recordingRecovery.enabled = settings.keepRecordingRecovery
            saveSettings(); onSettingsChanged?()
            if oldValue.voiceTriggerEnabled != settings.voiceTriggerEnabled || oldValue.speechLocale != settings.speechLocale {
                onSpeechPreferencesChanged?()
            }
        }
    }
    let recordingRecovery = RecordingRecovery()
    @ObservationIgnored var voiceRecoveryCaptureID: UUID?
    @ObservationIgnored var manualRecoveryCaptureID: UUID?
    @ObservationIgnored var composerRecoveryDraftID: UUID?
    @ObservationIgnored var explicitlyOpenedRecoveryDraftID: UUID?
    let speech = SpeechCapture()
    let voice: TriggeredVoice
    var voiceTriggerStatus = "Shortcut ready · microphone off"
    var voiceInputKind: VoiceGestureCaptureKind = .dictation
    var dictationStreamingStatus = "Live preview · microphone off"
    var dictationDeliveryIssue: String?
    var manualVoiceIssue: String?
    var dictationFeedback: VoiceActionFeedback?
    var activeVoiceFeedback: VoiceActionFeedback? {
        dictationFeedback
    }
    private var expiredNotchFeedbackIDs: Set<UUID> = []
    var notchVoiceFeedback: VoiceActionFeedback? {
        guard let feedback = activeVoiceFeedback, !expiredNotchFeedbackIDs.contains(feedback.id) else { return nil }
        return feedback
    }
    /// Cancellation is a transient receipt, never a retained Home status string.
    var notchCancellationVisible: Bool { notchVoiceFeedback?.presentation == .cancellation }
    /// One projection owns the visual state for both the stable drawing layer
    /// and the compact/collapsed content. Text never determines receipt meaning.
    var notchActionableError: String? {
        guard !voiceIsRecording, !isRecording, !manualVoiceIsPreparing else { return nil }
        if let issue = manualVoiceIssue, !issue.isEmpty { return issue }
        if let issue = voiceError, !issue.isEmpty { return issue }
        if let issue = dictationDeliveryIssue, !issue.isEmpty { return issue }
        return nil
    }
    var notchFeedbackPhase: NotchFeedbackPhase {
        if showsNotchStylePreview { return .recording }
        if showsSpeechDownload { return .processing }
        let captureIssue = !(manualVoiceIssue ?? "").isEmpty || !(voiceError ?? "").isEmpty
        // An expired copied notice must not come back as an orange error.
        let deliveryFailure = dictationDeliveryIssue != nil && dictationFeedback?.presentation != .copiedOnly
        return .resolve(captureRequested: voiceCaptureRequested, captureState: voice.state,
            manualRecording: isRecording, manualPreparing: manualVoiceIsPreparing,
            manualFinishing: manualVoiceIsFinishing || manualCleanupInProgress,
            feedback: notchVoiceFeedback, hasError: captureIssue || deliveryFailure,
            cancelled: notchCancellationVisible, triggerPressed: voiceTriggerIsPressed,
            queued: queuedVoiceCaptureKind != nil)
    }
    var manualVoiceLevel: Float = 0
    var notchAudioLevel: Double {
        if showsNotchStylePreview { return notchPreviewLevel }
        guard isRecording || voice.state == "capturing" else { return 0 }
        let rms = Double(isRecording ? manualVoiceLevel : voiceLevel)
        return rms.isFinite ? min(1, sqrt(max(0, rms) / 0.12)) : 0
    }
    /// Expire only the transient notch receipt. Home retains the full result.
    func dismissNotchFeedback(_ id: UUID) {
        guard let feedback = activeVoiceFeedback, feedback.id == id,
              feedback.state == .information || feedback.state == .success || feedback.presentation == .copiedOnly else { return }
        let retainedIDs = [dictationFeedback?.id].compactMap { $0 }
        expiredNotchFeedbackIDs.formIntersection(retainedIDs)
        expiredNotchFeedbackIDs.insert(id)
    }
    var voiceCaptureRequested = false
    var voiceTriggerIsPressed = false
    var queuedVoiceCaptureKind: VoiceGestureCaptureKind?
    @ObservationIgnored var queuedVoiceTriggerAt: UInt64?
    @ObservationIgnored var voiceResultIsBeingHandled = false
    @ObservationIgnored var voiceStartTask: Task<Void, Never>?
    @ObservationIgnored var voiceGesture = VoiceGestureState()
    @ObservationIgnored var voiceGestureTimer: Task<Void, Never>?
    @ObservationIgnored var voiceGestureTimerID = UUID()
    @ObservationIgnored var dictationCaptureGeneration = UUID()
    @ObservationIgnored var dictationDeliveryStartedFor: UUID?
    @ObservationIgnored var voiceKeyPressedAt: UInt64?
    @ObservationIgnored var voiceRequestedAt: UInt64?
    @ObservationIgnored var voiceFinishedAt: UInt64?
    @ObservationIgnored var voiceFirstPartialSeen = false
    @ObservationIgnored var voiceDestination: DeliveryTarget?
    var lastTypedText = ""
    var canCopyLastDictation: Bool {
        !lastTypedText.isEmpty && !voiceIsRecording && voice.state != "finishing" && dictationFeedback?.state != .working
    }
    @ObservationIgnored var voiceActionGeneration = UUID()
    @ObservationIgnored var voiceActionTask: Task<Void, Never>?
    @ObservationIgnored var voiceTypingOperationID: UUID?
    /// Enabled only by production lifecycle or a test with injected silent capture.
    @ObservationIgnored var captureEnabled = false
    @ObservationIgnored var onOpenHome: (() -> Void)?
    @ObservationIgnored var onOpenLibrary: (() -> Void)?
    @ObservationIgnored var onOpenCapture: (() -> Void)?
    @ObservationIgnored var onSettingsChanged: (() -> Void)?
    @ObservationIgnored var onSpeechPreferencesChanged: (() -> Void)?
    @ObservationIgnored var onActivityChanged: (() -> Void)?
    @ObservationIgnored var onVoiceTriggerAccess: (() -> Void)?
    @ObservationIgnored var repository: LibraryRepository?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var captureGeneration = UUID()
    @ObservationIgnored private var target: DeliveryTarget?
    @ObservationIgnored let cleanup: any DictationCleaning
    @ObservationIgnored let delivery: any TextDelivering
    @ObservationIgnored private let legacyReminderCleanup: (@MainActor (UUID) async -> Void)?
    var typingCheckStatus = ""
    var speechPreparationStatus = ""
    /// Download progress for a model fetch in progress; nil when not measurable.
    var speechPreparationFraction: Double?
    /// A model download is under way; the notch shows its progress until setup ends.
    var speechDownloadActive = false {
        didSet { if oldValue != speechDownloadActive { onNotchPreviewChanged?(speechDownloadActive || notchStylePreviewActive) } }
    }
    var showsSpeechDownload: Bool {
        speechDownloadActive && !notchStylePreviewActive && !hasCancellableVoiceInput && !isRecording
    }
    var isPreparingSpeech = false
    /// The shortcut recorder owns keyboard input; the global trigger is paused.
    var isRecordingShortcut = false { didSet { if oldValue != isRecordingShortcut { onSettingsChanged?() } } }
    /// The setup guide's style step plays the chosen style in the real notch.
    /// No microphone: the level is synthetic and real capture always wins.
    var notchStylePreviewActive = false {
        didSet { if oldValue != notchStylePreviewActive { onNotchPreviewChanged?(notchStylePreviewActive || speechDownloadActive) } }
    }
    var notchPreviewLevel: Double = 0
    @ObservationIgnored var onNotchPreviewChanged: ((Bool) -> Void)?
    var showsNotchStylePreview: Bool { notchStylePreviewActive && !hasCancellableVoiceInput && !isRecording }
    var pasteTestStatus = ""
    var pasteTestRunning = false
    @ObservationIgnored var pasteTestTask: Task<Void, Never>?
    @ObservationIgnored var updater: AppUpdater?
    @ObservationIgnored var onOpenOnboarding: (() -> Void)?
    /// Owns the entire manual dictation result, including final delivery.
    var manualCleanupInProgress = false
    @ObservationIgnored var speechPreparationTask: Task<Void, Never>?
    @ObservationIgnored var typingCheckTask: Task<Void, Never>?
    @ObservationIgnored var typingCheckID = UUID()
    @ObservationIgnored private var recordingStartedAt: Date?
    @ObservationIgnored private var recordingStartTask: Task<Void, Never>?
    @ObservationIgnored var manualDeliveryTask: Task<Void, Never>?
    @ObservationIgnored private let recordingSounds = RecordingSoundFeedback()
    @ObservationIgnored private var systemServicesEnabled = false
    private var searchResults: [CaptureItem]?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let dataDirectory: URL
    @ObservationIgnored private let persistSettingsEnabled: Bool

    var voiceEnabled: Bool { voice.isEnabled }
    var voiceIsRecording: Bool { voiceCaptureRequested || voice.isRecording }
    var voiceState: String { voice.stateLabel }
    var voiceTranscript: String {
        DictationEditing.applyingCommands(to: voice.partialCommand)
    }
    var voiceCorrectionApplied: Bool { voiceInputKind == .dictation && voiceTranscript != voice.partialCommand }
    var voiceLevel: Float { voice.audioLevel }
    func punctuateDictation(_ text: String) -> String {
        guard settings.speechLocale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased() == "en" else { return text }
        return DictationPunctuation.finalize(text)
    }
    var voiceError: String? { voice.lastError }
    var isRecording: Bool { speech.isRecording }
    var manualVoiceIsPreparing: Bool { speech.isPreparing }
    var manualVoiceIsFinishing: Bool { speech.isFinalizing }
    var hasCancellableVoiceInput: Bool {
        voiceIsRecording || queuedVoiceCaptureKind != nil || voice.state == "finishing" || voice.state == "working"
            || speech.hasActiveSession || recordingStartTask != nil
            || manualCleanupInProgress || dictationFeedback?.state == .working
    }
    /// A capture, cleanup or paste is under way: anything an update relaunch would lose.
    var isDictationWorkInFlight: Bool {
        hasCancellableVoiceInput || voiceTypingOperationID != nil || voiceResultIsBeingHandled
    }
    var liveTranscript: String { speech.transcript }
    var speechStatus: String { speech.stateDescription }
    var speechEngineDescription: String { voiceEnabled ? voice.engineDescription : speech.engineDescription }
    var speechEngineWarning: String? { voiceEnabled ? voice.engineWarning : speech.engineWarning }
    var speechAccessStatus: String { SpeechAuthorization.shared.summary }
    /// The user's dictionary first, so their spelling of a phrase wins, then built-ins.
    var effectiveVocabulary: [VocabularyEntry] { settings.vocabulary + VocabularyEntry.builtIn }
    /// Spellings that bias recognition for the active profile, without duplicates.
    var contextualVocabulary: [String] {
        var seen = Set<String>()
        return effectiveVocabulary.filter { $0.project == "All projects" || $0.project == captureProject }
            .map(\.replacement).filter { seen.insert($0.lowercased()).inserted }
    }
    /// Existing dictionary scopes remain available without project management.
    var projects: [String] {
        Array(Set(settings.customProjects + [settings.vocabularyScope] + items.map(\.project) + settings.vocabulary.map(\.project)))
            .filter { !$0.isEmpty && $0 != "All projects" }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    var selectedItem: CaptureItem? { items.first { $0.id == selectedItemID } }
    var visibleItems: [CaptureItem] {
        let base = searchResults ?? items
        return base.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    init(dataDirectory: URL? = nil, defaults: UserDefaults = .standard, persistSettings: Bool = true, delivery deliveryOverride: (any TextDelivering)? = nil, cleanup cleanupOverride: (any DictationCleaning)? = nil, voice voiceOverride: TriggeredVoice? = nil, legacyReminderCleanup: (@MainActor (UUID) async -> Void)? = nil) {
        self.delivery = deliveryOverride ?? TextDelivery()
        self.cleanup = cleanupOverride ?? DictationCleanup()
        self.voice = voiceOverride ?? TriggeredVoice()
        self.legacyReminderCleanup = legacyReminderCleanup
        self.persistSettingsEnabled = persistSettings
        self.defaults = defaults
        self.dataDirectory = dataDirectory ?? Self.defaultDataDirectory
        if let data = defaults.data(forKey: "uiui.settings"), let stored = try? JSONDecoder().decode(UIUISettings.self, from: data) { settings = stored }
        else { settings = UIUISettings() }
        recordingRecovery.enabled = settings.keepRecordingRecovery
        speech.onFinalization = { [weak self] milliseconds in Task { await self?.record(UsageEvent(action: "speech_finalize", durationMS: milliseconds)) } }
        voice.onFinalization = { [weak self] milliseconds in Task { await self?.record(UsageEvent(action: "speech_finalize", durationMS: milliseconds)) } }
        speech.onCompletion = { [weak self] completion in self?.receiveManualSpeechCompletion(completion) }
        speech.onSessionEnded = { [weak self] in
            self?.manualVoiceLevel = 0
            self?.resumeQueuedVoiceCaptureIfReady()
            self?.onActivityChanged?()
        }
        speech.onPartial = { [weak self] text in
            guard let self else { return }
            if let id = manualRecoveryCaptureID { recordingRecovery.update(id: id, text: text) }
            guard captureMode == .dictation, LocalSpeechModel.supports(locale: settings.speechLocale) else { return }
            let words = TextProcessing.applyingVocabulary(to: text, entries: effectiveVocabulary, project: captureProject)
            cleanup.update(words, captureID: captureGeneration, formatted: DictationCleanupText.isFormatted(text))
        }
        speech.onRecordingSound = { [weak self] cue in self?.playRecordingSound(cue) }
        speech.onAudioLevel = { [weak self] level in self?.manualVoiceLevel = level }
        voice.onRecordingSound = { [weak self] cue in self?.playRecordingSound(cue) }
        voice.onTrigger = { [weak self] in
            guard let self else { return }
            voiceDestination = TextDelivery.captureTarget()
            if voiceInputKind == .dictation {
                dictationStreamingStatus = voiceDestination == nil ? TextDelivery.targetFailure : "Live preview · inserts when you finish"
            }
        }
        voice.onPartial = { [weak self] text in self?.receiveVoicePartial(text) }
        voice.onStateChanged = { [weak self] in
            guard let self else { return }
            if !voice.isRecording { voiceCaptureRequested = false }
            if voice.state == "error" {
                preserveTriggeredRecordingRecovery()
                cleanup.cancel()
                delivery.cancel()
                dictationStreamingStatus = voice.lastError ?? "Speech stopped. Your words are kept here."
                if voiceInputKind == .dictation, !voice.partialCommand.isEmpty { captureText = voice.partialCommand }
            }
            if voice.state == "idle", voice.partialCommand.isEmpty, voiceInputKind == .dictation {
                preserveTriggeredRecordingRecovery()
                delivery.cancel()
                dictationStreamingStatus = "Microphone off"
                if voiceFinishedAt != nil, dictationFeedback == nil {
                    dictationFeedback = VoiceActionFeedback(state: .information, title: "No speech detected", detail: "Microphone off. Nothing was pasted.")
                    voiceFinishedAt = nil
                }
            }
            resumeQueuedVoiceCaptureIfReady()
            onActivityChanged?()
        }
        voice.onCommand = { [weak self] text in
            guard let self else { return }
            voiceResultIsBeingHandled = true
            defer {
                voiceResultIsBeingHandled = false
                resumeQueuedVoiceCaptureIfReady(afterCommand: true)
            }
            checkpointTriggeredRecordingRecovery(text)
            performVoiceTyping(text)
        }
        voice.onIncomplete = { [weak self] completion in
            guard let self else { return }
            voiceResultIsBeingHandled = true
            defer {
                voiceResultIsBeingHandled = false
                resumeQueuedVoiceCaptureIfReady(afterCommand: true)
            }
            checkpointTriggeredRecordingRecovery(completion.text)
            if voiceInputKind == .dictation, completion.wasExplicitlyStopped, completion.reason != .unreconciledFinal {
                // The user explicitly ended dictation: insert the best recognized
                // words, without executing assistant commands.
                voice.acknowledgeIncompleteDictation()
                performVoiceTyping(completion.text)
            } else {
                cleanup.cancel()
                delivery.cancel()
                captureText = completion.text
                finishTriggeredRecordingRecovery(preserving: true)
                errorMessage = completion.recoveryMessage
                lastTypedText = completion.text
                dictationDeliveryIssue = completion.recoveryMessage
                statusMessage = "Full draft kept. Open Recovery to review or copy it."
                onActivityChanged?()
            }
        }
    }

    static var defaultDataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["UIUI_DATA_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("uiui", isDirectory: true)
    }

    func start(installSystemServices: Bool = true) async {
        systemServicesEnabled = installSystemServices
        captureEnabled = installSystemServices
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            repository = try LibraryRepository(url: dataDirectory.appendingPathComponent("library.sqlite"))
            if let repository { await recordingRecovery.connect(repository) }
            await reload()
        } catch { errorMessage = "uiui couldn't open its local library. \(error.localizedDescription)" }
    }

    private func playRecordingSound(_ cue: RecordingSound) {
        guard systemServicesEnabled, settings.soundFeedbackEnabled else { return }
        recordingSounds.play(cue)
    }

    func openHome() { onOpenHome?() }
    func openLibrary() { onOpenLibrary?() }
    func openSettings() { workspaceSheet = .settings; onOpenLibrary?() }
    func openOnboarding() { onOpenOnboarding?() }
    func completeOnboarding() { if !settings.onboardingCompleted { settings.onboardingCompleted = true } }
    /// Exercises the real paste path without the microphone: after a countdown
    /// in which the user clicks a text field in another app, paste one line there.
    func runPasteTest() {
        pasteTestTask?.cancel()
        pasteTestRunning = true
        pasteTestTask = Task { [weak self] in
            guard let self else { return }
            defer { pasteTestRunning = false }
            for remaining in stride(from: 5, to: 0, by: -1) {
                pasteTestStatus = "Click into a text field in another app… \(remaining)"
                do { try await Task.sleep(for: .seconds(1)) } catch { pasteTestStatus = ""; return }
            }
            guard let target = TextDelivery.captureTarget() else { pasteTestStatus = TextDelivery.targetFailure; return }
            switch await delivery.deliver("Hello from uiui. ", to: target) {
            case .pasteSent: pasteTestStatus = "Pasted into \(target.appName ?? "the app"). If no text appeared, the app ignored the paste."
            case .copied(let reason), .held(let reason): pasteTestStatus = reason
            }
        }
    }
    func prepareDictation() {
        if isRecording { speech.stop(); return }
        guard captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { statusMessage = "An unfinished draft is waiting. Save or clear it before a new dictation."; onOpenCapture?(); return }
        target = TextDelivery.captureTarget()
        captureMode = .dictation
        captureText = ""
        startRecording()
    }
    func toggleRecording() { if isRecording { speech.stop(); statusMessage = "Finishing your words…" } else { startRecording() } }
    private func startRecording() {
        guard captureEnabled else { return }
        guard !manualCleanupInProgress else { statusMessage = "Finishing your words… Press Escape to cancel."; return }
        stopVoiceSession()
        preserveManualRecordingRecovery()
        captureGeneration = UUID()
        manualRecoveryCaptureID = captureGeneration
        recordingRecovery.begin(id: captureGeneration, project: captureProject, kind: captureMode.kind)
        if captureMode == .dictation, LocalSpeechModel.supports(locale: settings.speechLocale) {
            cleanup.begin(captureGeneration)
            if systemServicesEnabled { cleanup.prepare() }
        }
        delivery.cancel()
        recordingStartedAt = Date()
        errorMessage = nil
        manualVoiceIssue = nil
        let generation = captureGeneration
        recordingStartTask = Task { [weak self] in
            guard let self, generation == captureGeneration, !Task.isCancelled else { return }
            defer {
                if generation == captureGeneration { recordingStartTask = nil; onActivityChanged?() }
            }
            do {
                try await speech.start(locale: settings.speechLocale, contextualStrings: contextualVocabulary)
                guard generation == captureGeneration, !Task.isCancelled else { return }
                statusMessage = "Listening. Press the shortcut again to finish."
                onActivityChanged?()
            } catch is CancellationError {} catch {
                guard generation == captureGeneration else { return }
                errorMessage = error.localizedDescription
                manualVoiceIssue = error.localizedDescription
                onActivityChanged?()
            }
        }
        onActivityChanged?()
    }
    func cancelRecording() { preserveManualRecordingRecovery(); manualDeliveryTask?.cancel(); manualCleanupInProgress = false; cleanup.cancel(); captureGeneration = UUID(); recordingStartTask?.cancel(); recordingStartTask = nil; speech.cancel(); delivery.cancel(); statusMessage = "Recording cancelled."; recordingStartedAt = nil; onActivityChanged?() }
    func cancelVoiceInputFromEscape() {
        preserveManualRecordingRecovery()
        manualDeliveryTask?.cancel()
        manualCleanupInProgress = false
        captureGeneration = UUID()
        recordingStartTask?.cancel(); recordingStartTask = nil
        recordingStartedAt = nil
        speech.cancel()
        stopVoiceSession()
        manualVoiceIssue = nil
        dictationDeliveryIssue = nil
        publishVoiceCancellation()
        statusMessage = "Cancelled · microphone off"
        onActivityChanged?()
    }
    func receiveManualSpeechCompletion(_ completion: SpeechCompletion) {
        if let id = manualRecoveryCaptureID { recordingRecovery.update(id: id, text: completion.text) }
        // Every terminal result publishes activity, even an empty failed result,
        // so global Escape monitoring cannot stay installed after capture ends.
        voiceResultIsBeingHandled = true
        defer {
            voiceResultIsBeingHandled = false
            resumeQueuedVoiceCaptureIfReady()
            onActivityChanged?()
        }
        if completion.reason == .final { receiveTranscript(completion.text); return }
        manualVoiceIssue = completion.recoveryMessage
        composerRecoveryDraftID = manualRecoveryCaptureID
        preserveManualRecordingRecovery()
        cleanup.cancel()
        if !completion.text.isEmpty {
            captureText += (captureText.isEmpty ? "" : "\n") + completion.text
            onOpenCapture?()
        }
        errorMessage = completion.recoveryMessage
        statusMessage = completion.text.isEmpty ? "No speech detected · microphone off" : "Your partial words are kept here."
    }
    private func receiveTranscript(_ text: String) {
        let normalized = TextProcessing.applyingVocabulary(to: text, entries: effectiveVocabulary, project: captureProject)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { preserveManualRecordingRecovery(); statusMessage = "No speech detected. Your draft is unchanged."; onActivityChanged?(); return }
        captureText = captureText.isEmpty ? normalized : captureText + "\n" + normalized
        completionRawFormatted = DictationCleanupText.isFormatted(text)
        statusMessage = "Captured."
        onActivityChanged?()
        saveCapture(source: .dictationCompletion)
    }

    func saveCapture(source: CaptureSaveSource = .composer) {
        let isRecoveryReview = source == .composer
        let original = isRecoveryReview ? captureText : captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !manualCleanupInProgress else { return }
        let mode = captureMode
        let destination = target
        let generation = captureGeneration
        let recoveryID = manualRecoveryCaptureID
        let openedRecoveryID = source == .composer ? composerRecoveryDraftID : nil
        let explicitRecoveryID = source == .composer ? explicitlyOpenedRecoveryDraftID : nil
        let reviewedDraftID = explicitRecoveryID ?? openedRecoveryID ?? (isRecoveryReview ? recoveryID : nil)
        let project = recordingRecovery.drafts.first(where: { $0.id == reviewedDraftID })?.project ?? captureProject
        let rawFormatted = source == .dictationCompletion ? completionRawFormatted : nil
        completionRawFormatted = nil
        let useCleanup = !isRecoveryReview && LocalSpeechModel.supports(locale: settings.speechLocale)
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) * 1000 }
        recordingStartedAt = nil
        manualCleanupInProgress = true
        onActivityChanged?()
        manualDeliveryTask = Task { [weak self] in
            guard let self, captureGeneration == generation else { return }
            defer {
                if captureGeneration == generation { manualCleanupInProgress = false; onActivityChanged?() }
            }
            let cleanedText: String
            do { cleanedText = useCleanup ? try await cleanup.finish(original, captureID: generation, formatted: rawFormatted) : original }
            catch { return }
            guard captureGeneration == generation, !Task.isCancelled else { return }
            let text = isRecoveryReview ? original
                : TextProcessing.preservingVocabularySpelling(in: cleanedText, entries: effectiveVocabulary, project: project)
            var item = CaptureItem(title: TextProcessing.title(for: text), body: text, kind: mode.kind, project: project, sourceApp: destination?.appName)
            if text != original { item.rawText = original }
            let needsHistory = isRecoveryReview || settings.saveDictationHistory
            if needsHistory {
                guard await persist(item, select: true) else {
                    finishManualRecordingRecovery(id: recoveryID, preserving: true)
                    return
                }
                finishManualRecordingRecovery(id: recoveryID, preserving: false)
                for id in Set([openedRecoveryID, explicitRecoveryID].compactMap { $0 }) { recordingRecovery.discard(id: id) }
                if composerRecoveryDraftID == openedRecoveryID { composerRecoveryDraftID = nil }
                if explicitlyOpenedRecoveryDraftID == explicitRecoveryID { explicitlyOpenedRecoveryDraftID = nil }
            }
            guard captureGeneration == generation, !Task.isCancelled else { return }
            if (isRecoveryReview ? captureText : captureText.trimmingCharacters(in: .whitespacesAndNewlines)) == original {
                captureText = ""
                if isRecoveryReview { showComposer = false; onOpenLibrary?() }
            }
            await record(UsageEvent(action: mode.rawValue, durationMS: duration, wordCount: TextProcessing.wordCount(text)))
            statusMessage = "Saved to your history."
            if !isRecoveryReview {
                guard captureGeneration == generation, !Task.isCancelled else { return }
                let result = await delivery.deliver(text, to: destination)
                guard captureGeneration == generation, !Task.isCancelled else { return }
                lastTypedText = text
                if !needsHistory {
                    if case .held = result { finishManualRecordingRecovery(id: recoveryID, preserving: true) }
                    else { finishManualRecordingRecovery(id: recoveryID, preserving: false) }
                }
                switch result {
                case .pasteSent:
                    statusMessage = needsHistory ? "Paste sent. Your words are saved." : "Paste sent. History is off."
                    dictationDeliveryIssue = nil
                    dictationFeedback = VoiceActionFeedback(state: .information, title: "Paste sent · copied",
                        detail: "The complete dictation stays on your clipboard.", presentation: .pasteDispatch)
                case .copied(let reason):
                    captureText = text; statusMessage = "Copied. " + reason; dictationDeliveryIssue = reason
                    dictationFeedback = VoiceActionFeedback(state: .needsInput, title: "Copied · paste manually",
                        detail: reason, presentation: .copiedOnly)
                case .held(let reason):
                    captureText = text; composerRecoveryDraftID = recoveryID; statusMessage = reason; dictationDeliveryIssue = reason
                    dictationFeedback = VoiceActionFeedback(state: .failure, title: "Couldn’t paste · words kept", detail: reason)
                    showComposer = true; onOpenCapture?()
                }
            }
            onActivityChanged?()
        }
    }

    func copy(_ text: String) {
        statusMessage = TextDelivery.copy(text) ? "Copied to clipboard." : "Couldn’t copy. Your text is kept here."
    }
    func copyLastDictation() {
        guard canCopyLastDictation else { return }
        let copied = TextDelivery.copy(lastTypedText)
        let feedback = VoiceActionFeedback(state: copied ? .information : .failure,
            title: copied ? "Copied" : "Couldn’t copy",
            detail: copied ? "The complete dictation is on your clipboard." : "The complete dictation is kept here. Try Copy again.")
        dictationFeedback = feedback
        statusMessage = feedback.compactText
        onActivityChanged?()
    }
    func updateItem(_ item: CaptureItem) {
        var updated = item; updated.updatedAt = Date()
        Task { guard await persist(updated) else { return }; statusMessage = "Changes saved." }
    }
    func togglePin(_ item: CaptureItem) { var updated = item; updated.isPinned.toggle(); updateItem(updated) }
    func delete(_ item: CaptureItem) {
        Task {
            do {
                guard let repository else { throw AppError.libraryUnavailable }
                try await repository.delete(id: item.id)
                if item.kind == .reminder || item.reminderDate != nil {
                    if let legacyReminderCleanup { await legacyReminderCleanup(item.id) }
                    else if systemServicesEnabled { await LegacyReminderCleanup.remove(id: item.id) }
                }
                if selectedItemID == item.id { selectedItemID = nil }
                await reload()
                statusMessage = "Moved out of your library."
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func requestPermissions() {
        Task { _ = await speech.requestAuthorization(); statusMessage = "Permissions checked. Voice starts only from your trigger." }
    }
    func prepareSpeechModel() {
        guard !isPreparingSpeech, !voiceIsRecording, !isRecording else { return }
        let locale = settings.speechLocale
        isPreparingSpeech = true
        speechPreparationStatus = "Preparing the local speech model…"
        speechPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { isPreparingSpeech = false; speechPreparationTask = nil; speechPreparationFraction = nil; speechDownloadActive = false }
            do {
                try await SpeechAssets.prepare(localeIdentifier: locale, progress: { [weak self] progress in
                    Task { @MainActor [weak self] in self?.speechPreparationStatus = progress }
                }, fraction: { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.speechPreparationFraction = value
                        if value != nil { self?.speechDownloadActive = true }
                    }
                })
                if LocalSpeechModel.supports(locale: locale) {
                    await LocalSpeechModel.warmIfInstalled()
                    cleanup.prepare()
                }
                try Task.checkCancellation()
                speechPreparationStatus = "Ready · local transcription. Press your voice key to start."
            } catch is CancellationError {
                speechPreparationStatus = "Speech setup cancelled."
            } catch {
                speechPreparationStatus = error.localizedDescription
            }
        }
    }
    @discardableResult
    func addVocabulary(heard: String, replacement: String, project: String) -> Bool {
        guard Self.isValidVocabularyTerm(heard), Self.isValidVocabularyTerm(replacement) else { return false }
        let heard = heard.trimmingCharacters(in: .whitespaces), replacement = replacement.trimmingCharacters(in: .whitespaces)
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { return false }
        var vocabulary = settings.vocabulary
        let matches = vocabulary.indices.filter {
            vocabulary[$0].heard.caseInsensitiveCompare(heard) == .orderedSame &&
            vocabulary[$0].project.caseInsensitiveCompare(project) == .orderedSame
        }
        if let first = matches.first {
            vocabulary[first].heard = heard
            vocabulary[first].replacement = replacement
            if project.caseInsensitiveCompare("All projects") == .orderedSame { vocabulary[first].project = "All projects" }
            for index in matches.dropFirst().reversed() { vocabulary.remove(at: index) }
        } else { vocabulary.append(VocabularyEntry(heard: heard, replacement: replacement, project: project)) }
        settings.vocabulary = vocabulary
        return true
    }
    private static func isValidVocabularyTerm(_ term: String) -> Bool { VocabularyEntry.isValidTerm(term) }
    func exportNotes() {
        let panel = NSSavePanel(); panel.title = "Export your uiui library"; panel.nameFieldStringValue = "uiui-library.md"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = items.map { "# \($0.title)\n\nProject: \($0.project) · \($0.kind.title)\nCreated: \($0.createdAt.ISO8601Format())\n\n\($0.body)\n" }.joined(separator: "\n---\n\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8); statusMessage = "Library exported." } catch { errorMessage = error.localizedDescription }
    }
    func shutdown() { captureEnabled = false; systemServicesEnabled = false; preserveManualRecordingRecovery(); manualDeliveryTask?.cancel(); cleanup.release(); recordingStartTask?.cancel(); typingCheckTask?.cancel(); speechPreparationTask?.cancel(); stopVoiceSession(); speech.cancel(); delivery.cancel(); searchTask?.cancel(); pasteTestTask?.cancel() }

    @discardableResult func persist(_ item: CaptureItem, select: Bool = false) async -> Bool {
        do { guard let repository else { throw AppError.libraryUnavailable }; try await repository.upsert(item); await reload(); if select { selectedItemID = item.id }; return true }
        catch { errorMessage = error.localizedDescription; statusMessage = "Couldn’t save yet. Your draft is kept here."; return false }
    }
    func reload() async {
        do { guard let repository else { return }; items = try await repository.loadItems(); events = try await repository.loadEvents(since: Date().addingTimeInterval(-30*86400)); if !searchText.isEmpty { searchResults = try await repository.search(searchText) } }
        catch { errorMessage = error.localizedDescription }
    }
    func record(_ event: UsageEvent) async { do { try await repository?.appendEvent(event); events.append(event); if events.count > 10000 { events.removeFirst(events.count - 10000) } } catch { errorMessage = "Your note is safe, but its usage metric couldn't be saved." } }
    private func scheduleSearch() {
        searchTask?.cancel()
        guard !searchText.isEmpty else { searchResults = nil; return }
        let query = searchText
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)); guard let self, let repository else { return }; let results = try await repository.search(query); guard !Task.isCancelled, query == searchText else { return }; searchResults = results }
            catch is CancellationError {} catch { self?.errorMessage = "Search couldn't finish. Your notes are safe." }
        }
    }
    private func saveSettings() {
        guard persistSettingsEnabled else { return }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "uiui.settings") }
        if settings.launchAtLogin != (SMAppService.mainApp.status == .enabled) {
            do { if settings.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { errorMessage = "Login item couldn't be changed. You can set it in System Settings → Login Items." }
        }
    }
    enum AppError: LocalizedError {
        case libraryUnavailable
        var errorDescription: String? { switch self { case .libraryUnavailable: "Your library is still opening. Try again in a moment." } }
    }
}
