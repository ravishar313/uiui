import Foundation

public enum VoiceGestureCaptureKind: Equatable, Sendable { case dictation, agentAnswer }
public enum VoiceGestureEvent: Equatable, Sendable { case pressed, released, holdThreshold, cancelled, reset }
public enum VoiceGestureAction: Equatable, Sendable {
    case startDictation, finish, cancelCapture, scheduleHold, cancelHold
}

/// A reducer only: the application owns the 160 ms timer and all capture side effects.
public struct VoiceGestureState: Sendable {
    private var isPressed = false
    private var pressedAt: TimeInterval?
    private var pressedMode: VoiceTriggerMode?
    private var holdScheduled = false
    private var startedHoldCapture = false

    public init() {}

    public mutating func handle(_ event: VoiceGestureEvent, mode: VoiceTriggerMode, activeCapture: VoiceGestureCaptureKind?, now: TimeInterval) -> [VoiceGestureAction] {
        if event == .cancelled || event == .reset || !now.isFinite {
            return clear(activeCapture: activeCapture)
        }
        // Reconfiguration cannot turn an old key-down into a new mode's release action.
        if let pressedMode, pressedMode != mode { return clear(activeCapture: activeCapture) }

        switch event {
        case .pressed:
            guard !isPressed else { return [] }
            isPressed = true
            pressedAt = now
            pressedMode = mode
            startedHoldCapture = false
            if mode == .hold, activeCapture == nil {
                holdScheduled = true
                return [.scheduleHold]
            }
            return []

        case .holdThreshold:
            guard isPressed, pressedMode == .hold, holdScheduled,
                  let pressedAt, now >= pressedAt + 0.160 else { return [] }
            holdScheduled = false
            guard activeCapture == nil else { return [.cancelHold] }
            startedHoldCapture = true
            return [.startDictation]

        case .released:
            guard isPressed else { return [] }
            isPressed = false
            pressedAt = nil
            pressedMode = nil
            var actions: [VoiceGestureAction] = holdScheduled ? [.cancelHold] : []
            holdScheduled = false
            startedHoldCapture = false
            if activeCapture != nil {
                actions.append(.finish)
            } else if mode == .toggle {
                actions.append(.startDictation)
            }
            // A quick hold-mode tap never opens the microphone.
            return actions

        case .cancelled, .reset:
            return [] // Handled before interpreting any gesture state.
        }
    }

    private mutating func clear(activeCapture: VoiceGestureCaptureKind?) -> [VoiceGestureAction] {
        var actions: [VoiceGestureAction] = [.cancelHold]
        if startedHoldCapture && activeCapture == .dictation { actions.append(.cancelCapture) }
        isPressed = false
        pressedAt = nil
        pressedMode = nil
        holdScheduled = false
        startedHoldCapture = false
        return actions
    }
}
