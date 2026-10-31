import CoreGraphics
import Foundation

// Pure decisions behind the notch's extra behaviour. Nothing here touches the OS,
// a clock or a microphone, so every rule is unit-testable and event-driven.

/// Too-quiet warning. Levels are raw RMS from the existing ~10 Hz capture meter
/// (speech is typically 0.02 to 0.2; a live microphone in a silent room still
/// reports a noise floor above `deadFloor`, a muted or disconnected one reports ~0).
enum NotchSignalPolicy {
    /// RMS above which the microphone is clearly hearing something.
    static let signalThreshold: Float = 0.01
    /// RMS below which the input is electrically dead rather than merely quiet.
    static let deadFloor: Float = 0.0004
    /// Grace from the start of capture before "Can't hear you" can appear.
    static let startGrace: TimeInterval = 3
    /// How long a dead input must persist after speech before the hint appears.
    static let deadAfterSpeech: TimeInterval = 4

    struct Snapshot: Equatable {
        /// Seconds since capture started, excluding paused time.
        var elapsed: TimeInterval
        /// The largest level seen in this capture.
        var peakLevel: Float
        /// Seconds since the level last exceeded the signal threshold; nil if never.
        var secondsSinceSignal: TimeInterval?
        /// Seconds the level has stayed below the dead floor.
        var deadFor: TimeInterval
        var hasTranscript: Bool
        var isPaused: Bool
    }

    /// True when "Can't hear you" should be visible. Clears itself as soon as the
    /// conditions stop holding, so a returning signal removes the hint.
    static func cannotHear(_ s: Snapshot) -> Bool {
        guard !s.isPaused else { return false }
        // Nothing but near-silence and no words since the start.
        if s.peakLevel < signalThreshold, !s.hasTranscript, s.elapsed >= startGrace { return true }
        // Speech was heard, then the input went dead (not merely a quiet pause).
        if s.peakLevel >= signalThreshold, s.deadFor >= deadAfterSpeech { return true }
        return false
    }
}

/// Accumulates level samples into the snapshot the policy needs. Value type, so a
/// test can replay a whole capture with explicit timestamps.
struct NotchSignalMonitor: Equatable {
    private(set) var startedAt: TimeInterval?
    private(set) var peakLevel: Float = 0
    private var lastSignalAt: TimeInterval?
    private var deadSince: TimeInterval?
    private var pausedAt: TimeInterval?
    private var pausedTotal: TimeInterval = 0
    var hasTranscript = false

    mutating func begin(at time: TimeInterval) { self = NotchSignalMonitor(); startedAt = time }
    mutating func reset() { self = NotchSignalMonitor() }
    var isActive: Bool { startedAt != nil }

    mutating func setPaused(_ paused: Bool, at time: TimeInterval) {
        guard startedAt != nil else { return }
        if paused, pausedAt == nil { pausedAt = time }
        else if !paused, let at = pausedAt {
            pausedTotal += max(0, time - at); pausedAt = nil
            deadSince = nil // Paused time never counts as a dead input.
            if lastSignalAt != nil { lastSignalAt = time }
        }
    }

    mutating func record(level: Float, at time: TimeInterval) {
        guard startedAt != nil, pausedAt == nil, level.isFinite else { return }
        peakLevel = max(peakLevel, level)
        if level >= NotchSignalPolicy.signalThreshold { lastSignalAt = time }
        if level < NotchSignalPolicy.deadFloor { if deadSince == nil { deadSince = time } } else { deadSince = nil }
    }

    func snapshot(at time: TimeInterval) -> NotchSignalPolicy.Snapshot {
        let paused = pausedAt != nil
        let reference = pausedAt ?? time
        let elapsed = max(0, reference - (startedAt ?? reference) - pausedTotal)
        return .init(elapsed: elapsed, peakLevel: peakLevel,
                     secondsSinceSignal: lastSignalAt.map { max(0, reference - $0) },
                     deadFor: deadSince.map { max(0, reference - $0) } ?? 0,
                     hasTranscript: hasTranscript, isPaused: paused)
    }
}

/// A small timer appears only on long recordings.
enum NotchTimerPolicy {
    static let threshold: TimeInterval = 30
    static func isVisible(elapsed: TimeInterval) -> Bool { elapsed >= threshold }
    static func text(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

enum NotchMicHintPolicy {
    /// Names the input only when it is not the built-in microphone.
    static func text(deviceName: String?, isBuiltIn: Bool) -> String? {
        guard !isBuiltIn, let name = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return "Mic: " + name
    }
    static let displaySeconds: TimeInterval = 2.5
}

/// Undo is a single Command-Z for the paste just sent. It is available only while
/// the same app is still frontmost and nothing newer has started.
enum NotchUndoPolicy {
    static let window: TimeInterval = 3
    static func isAvailable(sentCaptureID: UUID?, currentCaptureID: UUID, captureActive: Bool,
                            targetPID: pid_t?, frontmostPID: pid_t?, now: TimeInterval, deadline: TimeInterval?) -> Bool {
        guard let sentCaptureID, sentCaptureID == currentCaptureID, !captureActive,
              let targetPID, targetPID == frontmostPID else { return false }
        if let deadline, now > deadline { return false }
        return true
    }
}

/// "Copied, press ⌘V in Slack" when the destination is known.
enum NotchPasteFailureText {
    static func copied(appName: String?) -> String {
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Copied, press ⌘V" : "Copied, press ⌘V in \(name)"
    }
}

/// Which display carries the notch and what shape it takes. A display with a camera
/// housing gets the hardware-matched notch; anything else gets a floating pill
/// below the menu bar. The pill never invents a camera.
struct NotchPlacement: Equatable {
    enum Shape: Equatable { case cameraNotch, floatingPill }
    struct Screen: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
        var safeAreaTop: CGFloat
        var isMain = false
        var hasCamera: Bool { safeAreaTop > 0 }
    }

    let screenIndex: Int
    let shape: Shape
    /// Top edge of the panel in global coordinates.
    let topEdge: CGFloat
    let centerX: CGFloat

    static let pillGapBelowMenuBar: CGFloat = 6

    static func decide(screens: [Screen]) -> NotchPlacement? {
        guard !screens.isEmpty else { return nil }
        let index = screens.firstIndex { $0.hasCamera } ?? screens.firstIndex { $0.isMain } ?? 0
        let screen = screens[index]
        if screen.hasCamera {
            return NotchPlacement(screenIndex: index, shape: .cameraNotch, topEdge: screen.frame.maxY, centerX: screen.frame.midX)
        }
        return NotchPlacement(screenIndex: index, shape: .floatingPill,
                              topEdge: screen.visibleFrame.maxY - pillGapBelowMenuBar, centerX: screen.frame.midX)
    }

    func frame(size: CGSize) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: topEdge - size.height, width: size.width, height: size.height)
    }
}

/// Short phrases spoken through accessibility announcements. Never transcript text.
enum NotchAnnouncement: Equatable {
    case listening, paused, resumed, processing, sent, copied, cancelled, cannotHear

    var text: String {
        switch self {
        case .listening: "Listening"
        case .paused: "Paused"
        case .resumed: "Listening"
        case .processing: "Processing"
        case .sent: "Sent"
        case .copied: "Copied. Press Command V to paste."
        case .cancelled: "Cancelled"
        case .cannotHear: "Can't hear you"
        }
    }

    static func resolve(phase: NotchFeedbackPhase, paused: Bool, cannotHear: Bool) -> NotchAnnouncement? {
        if cannotHear, phase == .recording { return .cannotHear }
        if paused, phase == .recording { return .paused }
        switch phase {
        case .recording: return .listening
        case .processing: return .processing
        case .dispatched: return .sent
        case .copied: return .copied
        case .cancelled: return .cancelled
        default: return nil
        }
    }
}

/// Per-bar delayed levels for the Voice bars style. Fed by real level samples; the
/// bars read progressively older values, so a syllable travels outward.
struct NotchLevelHistory: Equatable {
    static let retention: TimeInterval = 0.8
    private(set) var samples: [(time: TimeInterval, value: Double)] = []

    static func == (a: Self, b: Self) -> Bool {
        a.samples.count == b.samples.count && zip(a.samples, b.samples).allSatisfy { $0.time == $1.time && $0.value == $1.value }
    }

    mutating func append(_ value: Double, at time: TimeInterval) {
        samples.append((time, value))
        samples.removeAll { time - $0.time > Self.retention }
    }
    mutating func clear() { samples = [] }

    /// Smoothly interpolated level `delay` seconds before `time`.
    func value(at time: TimeInterval, delay: TimeInterval, rise: TimeInterval = 0.12) -> Double {
        let t = time - delay
        var level = 0.0
        var previous = 0.0
        for sample in samples {
            if sample.time > t { break }
            let x = min(1, max(0, (t - sample.time) / rise))
            level = previous + (sample.value - previous) * (x * x * (3 - 2 * x))
            previous = sample.value
        }
        return min(1, max(0, level))
    }
}

/// Deterministic blink schedule: no timers. A blink starts at a pseudo-random time
/// inside each period and closes then reopens over `duration`.
enum NotchEyeMotion {
    static let period: TimeInterval = 3.4
    static let duration: TimeInterval = 0.2

    static func openness(time: TimeInterval) -> Double {
        guard time.isFinite, time >= 0 else { return 1 }
        let index = floor(time / period)
        // A stable hash of the period index places the blink between 0.8 s and period - 0.4 s.
        let hash = abs(sin(index * 12.9898 + 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let start = index * period + 0.8 + hash * (period - 1.2)
        let local = time - start
        guard local >= 0, local < duration else { return 1 }
        let phase = local / duration
        return 1 - sin(phase * .pi)
    }
}
