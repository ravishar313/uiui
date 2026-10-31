import AppKit
import Observation

@MainActor
protocol TriggeredVoiceCapture: AnyObject {
    var engineDescription: String { get }
    var engineWarning: String? { get }
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onCompletion: ((SpeechCompletion) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onRecovery: ((String) -> Void)? { get set }
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onFinalization: ((Double) -> Void)? { get set }
    func requestAuthorization() async -> Bool
    func start(locale: String, contextualStrings: [String]) async throws
    func stop()
    func cancel()
}

extension TriggeredVoiceCapture {
    var engineDescription: String { "On-device speech" }
    var engineWarning: String? { nil }
}

extension SpeechCapture: TriggeredVoiceCapture {}

/// A single, explicitly triggered recording. Nothing in this owner starts or
/// restarts a microphone except start(), which is called from a user key action.
@MainActor @Observable
final class TriggeredVoice: NSObject {
    private(set) var isEnabled = false
    /// Includes asynchronous authorization/startup so a quick key release cancels it.
    private(set) var isRecording = false
    private(set) var state = "off"
    private(set) var partialCommand = ""
    private(set) var audioLevel: Float = 0
    private(set) var lastError: String?
    var engineDescription: String { capture.engineDescription }
    var engineWarning: String? { capture.engineWarning }
    var onCommand: ((String) -> Void)?
    /// The caller may accept an explicitly stopped partial or retain a recovery draft.
    var onIncomplete: ((SpeechCompletion) -> Void)?
    var onPartial: ((String) -> Void)?
    /// Milliseconds spent waiting for final recognition after finish().
    var onFinalization: ((Double) -> Void)?
    var onTrigger: (() -> Void)?
    /// Emitted after all related state properties agree, for native panel coordination.
    var onStateChanged: (() -> Void)?
    var onRecordingSound: ((RecordingSound) -> Void)?

    var stateLabel: String {
        switch state {
        case "starting": return "Preparing microphone"
        case "capturing": return "Recording"
        case "finishing": return "Finishing · microphone off"
        case "working": return "Working · microphone off"
        case "error": return "Voice needs attention · microphone off"
        case "incomplete": return "Recognition incomplete · microphone off"
        case "idle": return "Ready · microphone off"
        default: return "Voice off"
        }
    }

    @ObservationIgnored private let capture: any TriggeredVoiceCapture
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activeCapture: UInt64?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var finishWasUserInitiated = false
    @ObservationIgnored private var working = false
    @ObservationIgnored private var finishRequestedAt: UInt64?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    override convenience init() {
        self.init(capture: SpeechCapture())
    }

    /// Capture is injected so lifecycle checks can use a silent local driver.
    init(capture: any TriggeredVoiceCapture) {
        self.capture = capture
        super.init()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        // SpeechCapture releases its engine and tap in its own deinit as well.
    }

    func requestPermissions() async -> Bool { await capture.requestAuthorization() }

    func start(locale: String, contextualStrings: [String]) async throws {
        generation &+= 1
        let token = generation
        cancelResources()
        // Capture the destination before publishing any state that may show panels.
        onTrigger?()
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        isEnabled = true
        isRecording = true
        starting = true
        finishing = false
        working = false
        activeCapture = token
        finishRequestedAt = nil
        partialCommand = ""
        lastError = nil
        state = "starting"
        onStateChanged?()
        guard isCurrentCapture(token), !Task.isCancelled else {
            if isCurrentCapture(token) { stop() }
            throw CancellationError()
        }
        capture.onPartial = { [weak self] text in
            guard let self, self.isCurrentCapture(token) else { return }
            self.partialCommand = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.onPartial?(text)
        }
        capture.onFinal = { [weak self] text in self?.receivedFinal(text, token: token) }
        capture.onCompletion = { [weak self] completion in self?.receivedCompletion(completion, token: token) }
        capture.onError = { [weak self] message in self?.failed(message, token: token) }
        // Recognition failures never turn a partial into an executable command.
        capture.onRecovery = nil
        capture.onAudioLevel = { [weak self] level in
            guard let self, self.isCurrentCapture(token), self.isRecording, level.isFinite else { return }
            self.audioLevel = min(max(level, 0), 1)
        }
        // Measure finalization here before onCommand, avoiding a stale callback when
        // onCommand synchronously starts another capture.
        capture.onFinalization = nil
        do {
            try await capture.start(locale: locale, contextualStrings: contextualStrings)
            guard isCurrentCapture(token), !Task.isCancelled else {
                if isCurrentCapture(token) { stop() }
                throw CancellationError()
            }
            starting = false
            state = "capturing"
            onRecordingSound?(.ready)
            onStateChanged?()
        } catch {
            guard generation == token else { throw CancellationError() }
            if error is CancellationError {
                stop()
            } else {
                failed(error.localizedDescription, token: token)
            }
            throw error
        }
    }

    /// Release/second press closes audio acceptance synchronously; the audio owner
    /// releases hardware off the main actor. Repeated finishes are ignored.
    func finish(userInitiated: Bool = true) {
        guard let token = activeCapture, isCurrentCapture(token), !finishing else { return }
        if starting {
            // Permission requests cannot be dismissed programmatically. Invalidate
            // startup so accepting one after release can never turn on the microphone.
            generation &+= 1
            activeCapture = nil
            capture.cancel()
            starting = false
            finishing = false
            isRecording = false
            finishRequestedAt = nil
            state = "idle"
            onRecordingSound?(.cancelled)
            onStateChanged?()
            return
        }
        finishing = true
        finishWasUserInitiated = userInitiated
        isRecording = false
        audioLevel = 0
        finishRequestedAt = DispatchTime.now().uptimeNanoseconds
        state = "finishing"
        capture.stop()
        onRecordingSound?(.finished)
        onStateChanged?()
    }

    /// Cancels capture without delivering text or scheduling more work.
    func stop() {
        let cancelledCapture = isRecording || finishing
        generation &+= 1
        cancelResources()
        isEnabled = false
        isRecording = false
        working = false
        partialCommand = ""
        // A stopped session no longer owns an actionable capture error. Keeping
        // it here would override a later cancellation or manual delivery receipt.
        lastError = nil
        state = "off"
        if cancelledCapture { onRecordingSound?(.cancelled) }
        onStateChanged?()
    }

    func setWorking(_ value: Bool) {
        working = value
        guard isEnabled, !isRecording, !finishing, state != "error" else { return }
        state = value ? "working" : "idle"
        onStateChanged?()
    }

    /// Called only after the Dictation caller accepts an explicitly stopped partial.
    /// It does not dispatch text or restart recording.
    func acknowledgeIncompleteDictation() {
        guard state == "incomplete", !isRecording, !finishing else { return }
        lastError = nil
        state = working ? "working" : "idle"
        onStateChanged?()
    }

    private func receivedFinal(_ text: String, token: UInt64) {
        receivedCompletion(SpeechCompletion(text: text, reason: .final, wasExplicitlyStopped: finishing), token: token)
    }

    private func receivedCompletion(_ completion: SpeechCompletion, token: UInt64) {
        guard isCurrentCapture(token) else { return }
        let endedWhileRecording = isRecording
        let completion = SpeechCompletion(text: completion.text, reason: completion.reason,
                                          wasExplicitlyStopped: completion.wasExplicitlyStopped && finishWasUserInitiated)
        activeCapture = nil
        starting = false
        finishing = false
        finishWasUserInitiated = false
        isRecording = false
        audioLevel = 0
        let elapsed = finishRequestedAt.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000 }
        finishRequestedAt = nil
        let command = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        partialCommand = command
        if completion.reason != .final {
            lastError = completion.recoveryMessage
            state = command.isEmpty ? "error" : "incomplete"
        } else {
            state = command.isEmpty ? "idle" : "working"
        }
        if endedWhileRecording { onRecordingSound?(completion.reason == .final ? .finished : .cancelled) }
        onStateChanged?()
        guard generation == token, isEnabled else { return }
        if let elapsed { onFinalization?(elapsed) }
        guard generation == token, isEnabled, !command.isEmpty else { return }
        if completion.reason == .final { onCommand?(completion.text) }
        else { onIncomplete?(completion) }
    }

    private func failed(_ message: String, token: UInt64) {
        guard isCurrentCapture(token) else { return }
        let interruptedCapture = isRecording || finishing
        cancelResources()
        isRecording = false
        lastError = message
        state = "error"
        if interruptedCapture { onRecordingSound?(.cancelled) }
        onStateChanged?()
    }

    private func isCurrentCapture(_ token: UInt64) -> Bool {
        generation == token && activeCapture == token && isEnabled
    }

    private func cancelResources() {
        audioLevel = 0
        activeCapture = nil
        starting = false
        finishing = false
        finishWasUserInitiated = false
        finishRequestedAt = nil
        capture.cancel()
    }

}
