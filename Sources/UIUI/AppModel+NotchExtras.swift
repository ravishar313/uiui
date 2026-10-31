import AppKit
import Foundation
import Observation

/// What the notch needs beyond the capture phase: signal warnings, input hint,
/// long-recording timer, hover transcript and the short undo offer. Event-driven:
/// it reacts to level samples and user actions and owns no recurring timer.
@MainActor @Observable
final class NotchCaptureExtras {
    struct UndoOffer {
        let captureID: UUID
        let target: DeliveryTarget
        let appName: String?
        let deadline: TimeInterval
    }

    private(set) var cannotHear = false
    private(set) var micHint: String?
    private(set) var showsTimer = false
    private(set) var timerReference = Date()
    private(set) var timerPausedAt: Date?
    private(set) var undoOffer: UndoOffer?
    /// Pointer is over the capture notch: show the full transcript, scrollable.
    private(set) var transcriptOpen = false
    /// Pointer rests on the notch (any state); the wings then show controls.
    private(set) var pointerOver = false

    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var inputDevice: () -> InputDeviceInfo.Device? = { InputDeviceInfo.current() }
    @ObservationIgnored private var monitor = NotchSignalMonitor()
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    func captureStarted() {
        endCapture()
        monitor.begin(at: clock())
        timerReference = Date()
        let device = inputDevice()
        if let text = NotchMicHintPolicy.text(deviceName: device?.name, isBuiltIn: device?.isBuiltIn ?? true) {
            micHint = text
            hintTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(NotchMicHintPolicy.displaySeconds)) } catch { return }
                self?.micHint = nil
            }
        }
        // The 3 s grace is a single deadline, not a poll: it evaluates once even
        // if no level sample ever arrives.
        graceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(NotchSignalPolicy.startGrace)) } catch { return }
            self?.evaluate()
        }
    }

    func levelSample(_ level: Float) {
        guard monitor.isActive else { return }
        monitor.record(level: level, at: clock())
        evaluate()
    }

    func transcriptChanged(hasText: Bool) {
        guard monitor.isActive, monitor.hasTranscript != hasText else { return }
        monitor.hasTranscript = hasText
        evaluate()
    }

    func pauseChanged(_ paused: Bool) {
        guard monitor.isActive else { return }
        monitor.setPaused(paused, at: clock())
        if paused { timerPausedAt = Date() }
        else if let at = timerPausedAt {
            timerReference = timerReference.addingTimeInterval(Date().timeIntervalSince(at))
            timerPausedAt = nil
        }
        evaluate()
    }

    func endCapture() {
        graceTask?.cancel(); graceTask = nil
        hintTask?.cancel(); hintTask = nil
        monitor.reset()
        if cannotHear { cannotHear = false }
        if micHint != nil { micHint = nil }
        if showsTimer { showsTimer = false }
        timerPausedAt = nil
        hoverTask?.cancel(); hoverTask = nil
        if transcriptOpen { transcriptOpen = false }
    }

    private func evaluate() {
        let snapshot = monitor.snapshot(at: clock())
        let warn = NotchSignalPolicy.cannotHear(snapshot)
        if warn != cannotHear { cannotHear = warn }
        if warn, micHint != nil { micHint = nil }
        let timer = NotchTimerPolicy.isVisible(elapsed: snapshot.elapsed)
        if timer != showsTimer {
            showsTimer = timer
            if timer { timerReference = Date().addingTimeInterval(-snapshot.elapsed) }
        }
    }

    func setPointerOver(_ over: Bool, capturing: Bool) {
        hoverTask?.cancel(); hoverTask = nil
        if pointerOver != over { pointerOver = over }
        if over {
            if capturing, !transcriptOpen { transcriptOpen = true }
        } else if transcriptOpen {
            // A short grace so a wobble past the edge does not snap the panel shut.
            hoverTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
                self?.transcriptOpen = false
            }
        }
    }

    func offerUndo(captureID: UUID, target: DeliveryTarget?) {
        guard let target else { undoOffer = nil; return }
        undoOffer = UndoOffer(captureID: captureID, target: target, appName: target.appName,
                              deadline: clock() + NotchUndoPolicy.window + 0.5)
    }
    func clearUndo() { undoOffer = nil }
}

@MainActor
extension AppModel {
    var notchVoiceIsPaused: Bool { voice.isPaused }
    /// Words shown by the notch: the live recognition while a session is active.
    var notchTranscript: String { speech.hasActiveSession ? liveTranscript : voiceTranscript }
    var canPauseVoiceCapture: Bool { voice.isRecording && voice.state == "capturing" }

    func pauseVoiceCapture() {
        guard canPauseVoiceCapture, voice.setPaused(true) else { return }
        notchExtras.pauseChanged(true)
        statusMessage = "Paused · transcript kept"
        onActivityChanged?()
    }
    func resumeVoiceCapture() {
        guard voice.isPaused, voice.setPaused(false) else { return }
        notchExtras.pauseChanged(false)
        statusMessage = "Listening."
        onActivityChanged?()
    }
    func toggleVoicePause() {
        if voice.isPaused { resumeVoiceCapture() } else { pauseVoiceCapture() }
    }

    /// The window in which Undo is still meaningful for the paste just sent.
    var notchUndoAvailable: Bool {
        guard let offer = notchExtras.undoOffer else { return false }
        return NotchUndoPolicy.isAvailable(
            sentCaptureID: offer.captureID, currentCaptureID: dictationCaptureGeneration,
            captureActive: voiceIsRecording || isRecording || queuedVoiceCaptureKind != nil,
            targetPID: offer.target.appPID, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            now: notchExtras.clock(), deadline: offer.deadline)
    }

    /// Sends one Command-Z to the app that received the paste. Never presses Enter.
    func undoLastPaste() {
        guard notchUndoAvailable, let offer = notchExtras.undoOffer else {
            notchExtras.clearUndo()
            dictationFeedback = VoiceActionFeedback(state: .information, title: "Undo unavailable",
                detail: "The destination changed or a newer recording started.")
            onActivityChanged?()
            return
        }
        notchExtras.clearUndo()
        let sent = delivery.undoPaste(to: offer.target)
        dictationFeedback = VoiceActionFeedback(state: sent ? .information : .failure,
            title: sent ? "Undo sent" : "Couldn’t undo",
            detail: sent ? "Command-Z was sent to \(offer.appName ?? "your app")." : "Use Command-Z in \(offer.appName ?? "your app") yourself.")
        onActivityChanged?()
    }
}
