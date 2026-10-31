import SwiftUI

// System accessibility remains authoritative in normal use. Explicit native
// previews can exercise the same reduced-motion path without changing macOS.
private struct NotchMotionPreviewOverride: EnvironmentKey {
    static let defaultValue: Bool? = nil
}
extension EnvironmentValues {
    var notchMotionPreviewOverride: Bool? {
        get { self[NotchMotionPreviewOverride.self] }
        set { self[NotchMotionPreviewOverride.self] = newValue }
    }
    var notchReduceMotion: Bool { notchMotionPreviewOverride ?? accessibilityReduceMotion }
}

enum NotchFeedbackTiming {
    static let pasteAnimationSeconds = 0.46
    static let pasteDwell: Duration = .milliseconds(650)
    /// A paste receipt that offers Undo and Copy. The illumination still ends at
    /// `pasteAnimationSeconds`; only the quiet sent state stays reachable.
    static let undoDwell: Duration = .seconds(3)
    static let cancellationDwell: Duration = .milliseconds(280)
    static let informationDwell: Duration = .milliseconds(1_400)
    static let successDwell: Duration = .seconds(2)
    /// Long enough to read "Copied · press ⌘V"; Home keeps the full reason.
    static let copiedDwell: Duration = .seconds(4)
}

/// Owns a single receipt deadline, independently of whether the notch is expanded.
/// Activity updates never extend that deadline. Busy work suspends only the sleep,
/// so its receipt expires immediately if the original deadline has passed on return.
@MainActor
final class NotchFeedbackLifetime {
    private struct Receipt {
        let id: UUID
        let deadline: TimeInterval?
        let hideOnExpiry: Bool
        var expired = false
    }

    private let now: () -> TimeInterval
    private let sleep: (Duration) async throws -> Void
    private let onExpiry: (UUID, Bool) -> Bool
    private var receipt: Receipt?
    private var expiryTask: Task<Void, Never>?
    private var taskGeneration = UUID()

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         onExpiry: @escaping (UUID, Bool) -> Bool) {
        self.now = now
        self.sleep = sleep
        self.onExpiry = onExpiry
    }

    deinit { expiryTask?.cancel() }

    func update(feedback: VoiceActionFeedback?, busy: Bool) {
        guard let feedback else { cancel(); return }
        if receipt?.id != feedback.id {
            cancelSleep()
            let dwell: Duration?
            let hideOnExpiry: Bool
            switch feedback.state {
            case _ where feedback.presentation == .copiedOnly:
                // The text is safely on the clipboard: a short notice, not an
                // alarm that holds the notch open until the next dictation.
                dwell = NotchFeedbackTiming.copiedDwell
                hideOnExpiry = true
            case .working:
                dwell = nil
                hideOnExpiry = false
            case .failure, .needsInput:
                dwell = nil
                hideOnExpiry = false
            case .information, .success:
                switch feedback.presentation {
                case .pasteDispatch: dwell = feedback.offersUndo ? NotchFeedbackTiming.undoDwell : NotchFeedbackTiming.pasteDwell
                case .cancellation: dwell = NotchFeedbackTiming.cancellationDwell
                case .message:
                    dwell = feedback.state == .success ? NotchFeedbackTiming.successDwell : NotchFeedbackTiming.informationDwell
                case .copiedOnly: dwell = nil
                }
                hideOnExpiry = dwell != nil
            }
            let deadline = dwell.map { duration in
                let parts = duration.components
                return now() + Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            }
            receipt = Receipt(id: feedback.id, deadline: deadline, hideOnExpiry: hideOnExpiry)
        }
        guard let receipt, !receipt.expired, let deadline = receipt.deadline else { return }
        if busy {
            cancelSleep()
            return
        }
        let remaining = deadline - now()
        if remaining <= 0 {
            expire(id: receipt.id)
            return
        }
        guard expiryTask == nil else { return }
        let generation = taskGeneration
        let sleep = sleep
        expiryTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do { try await sleep(.seconds(remaining)) } catch { return }
            guard !Task.isCancelled, let self, self.taskGeneration == generation,
                  self.receipt?.id == receipt.id else { return }
            self.expire(id: receipt.id)
        }
    }

    func cancel() {
        cancelSleep()
        receipt = nil
    }

    private func cancelSleep() {
        taskGeneration = UUID()
        expiryTask?.cancel()
        expiryTask = nil
    }

    private func expire(id: UUID) {
        guard var current = receipt, current.id == id, !current.expired else { return }
        current.expired = true
        receipt = current
        cancelSleep()
        // Mark expired before calling out: a synchronous activity update cannot
        // schedule the same receipt again or extend its life by collapsing it.
        let expiryGeneration = taskGeneration
        let accepted = onExpiry(id, current.hideOnExpiry)
        if !accepted, receipt?.id == id, taskGeneration == expiryGeneration {
            // Live activity can change before its observation reaches this owner.
            // Preserve the overdue deadline for the next event-driven idle update.
            receipt?.expired = false
        }
    }
}

/// Visible meaning is independent of animation progress. Preparing never implies an open mic.
enum NotchFeedbackPhase: String, Equatable {
    case idle, preparing, recording, processing, queued, dispatched, copied, success, needsInput, cancelled, message

    static func resolve(captureRequested: Bool, captureState: String, manualRecording: Bool,
                        manualPreparing: Bool = false, manualFinishing: Bool = false,
                        feedback: VoiceActionFeedback?, hasError: Bool,
                        cancelled: Bool = false, triggerPressed: Bool = false,
                        queued: Bool = false) -> Self {
        if captureState == "capturing" || manualRecording { return .recording }
        if captureState == "starting" || manualPreparing { return .preparing }
        if captureState == "finishing" || manualFinishing { return .processing }
        if queued { return .queued }
        if captureRequested { return .preparing }
        if feedback?.state == .working { return .processing }
        if hasError || feedback?.state == .failure { return .needsInput }
        if feedback?.state == .needsInput {
            return feedback?.presentation == .copiedOnly ? .copied : .needsInput
        }
        if triggerPressed { return .preparing }
        if cancelled || feedback?.presentation == .cancellation { return .cancelled }
        if feedback?.presentation == .pasteDispatch { return .dispatched }
        if feedback?.state == .success { return .success }
        if feedback != nil { return .message }
        return .idle
    }

    var label: String {
        switch self {
        case .idle: "Mic off"
        case .preparing: "Starting"
        case .recording: "Listening"
        case .processing: "Working"
        case .queued: "Queued · mic off"
        case .dispatched: "Paste sent"
        case .copied: "Copied · paste manually"
        case .success: "Done"
        case .needsInput: "Action needed"
        case .cancelled: "Cancelled"
        case .message: "Mic off"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "plus"
        case .preparing: "mic.badge.plus"
        case .recording: "waveform"
        case .processing: "ellipsis"
        case .queued: "clock"
        case .dispatched: "arrow.right.to.line"
        case .copied: "doc.on.clipboard"
        case .success: "checkmark"
        case .needsInput: "exclamationmark.circle"
        case .cancelled: "xmark"
        case .message: "sparkles"
        }
    }
}

/// Only receipts belonging to the visible phase can restart its gesture. A retained
/// receipt changing during capture must not replay the microphone arrival animation.
struct NotchFeedbackEvent: Equatable {
    let phase: NotchFeedbackPhase
    let feedbackID: UUID?

    init(phase: NotchFeedbackPhase, feedbackID: UUID?) {
        self.phase = phase
        switch phase {
        case .idle, .preparing, .recording, .queued: self.feedbackID = nil
        default: self.feedbackID = feedbackID
        }
    }
}

