import Foundation

/// A bounded mixture of drawing parameters, never rendered images or view layers.
/// Interrupting a transition starts from its visible mixture instead of dropping
/// the previous phase. Receipt progress remains tied to each event's own start.
struct NotchPhaseBlend {
    static let duration: TimeInterval = 0.12
    static let maximumStates = 4

    struct Drawing {
        let phase: NotchFeedbackPhase
        let style: NotchVisualStyle
        var progress: Double
        var audio: Double
        var time: TimeInterval
    }

    struct Layer {
        var drawing: Drawing
        var weight: Double
    }

    private struct Target {
        let phase: NotchFeedbackPhase
        let style: NotchVisualStyle
        let eventStartedAt: TimeInterval
    }

    private var sources: [Layer] = []
    private var target: Target?
    private var startedAt: TimeInterval = 0

    var isEmpty: Bool { target == nil }

    func isBlending(at time: TimeInterval) -> Bool {
        !sources.isEmpty && time - startedAt < Self.duration
    }

    mutating func transition(phase: NotchFeedbackPhase, style: NotchVisualStyle,
                             eventStartedAt: TimeInterval, at time: TimeInterval,
                             audio: Double, fieldTime: TimeInterval, immediate: Bool) {
        if target == nil || immediate {
            sources = []
        } else {
            let visible = layers(at: time, audio: audio, fieldTime: fieldTime)
                .filter { $0.weight > 0.0001 }
            // Three retained descriptors plus one destination bound all drawing
            // work even under a burst of phase/style changes.
            sources = Array(visible.sorted { $0.weight > $1.weight }.prefix(Self.maximumStates - 1))
            let sum = sources.reduce(0) { $0 + $1.weight }
            if sum > 0 { sources = sources.map { Layer(drawing: $0.drawing, weight: $0.weight / sum) } }
        }
        target = Target(phase: phase, style: style, eventStartedAt: eventStartedAt)
        startedAt = time
    }

    func layers(at time: TimeInterval, audio: Double, fieldTime: TimeInterval) -> [Layer] {
        guard let target else { return [] }
        let fraction = sources.isEmpty ? 1 : NotchMosaicMetrics.smooth((time - startedAt) / Self.duration)
        var result: [Layer] = []
        if fraction < 1 {
            result = sources.map { source in
                var layer = source
                layer.weight *= 1 - fraction
                if layer.drawing.phase == .recording || layer.drawing.phase == .processing {
                    layer.drawing.time += max(0, time - startedAt)
                }
                return layer
            }
        }
        if fraction > 0 {
            result.append(Layer(drawing: Drawing(phase: target.phase, style: target.style,
                progress: NotchMosaicMetrics.progress(phase: target.phase, elapsed: time - target.eventStartedAt),
                audio: audio, time: fieldTime), weight: fraction))
        }
        return result
    }

    /// Incoming terminal states own every retained field's deadline. A source
    /// microphone field can never outlive send, cancellation, or return to idle.
    static func terminalEnvelope(phase: NotchFeedbackPhase, progress: Double) -> Double {
        switch phase {
        case .idle, .dispatched, .cancelled:
            NotchMosaicMetrics.intensity(phase: phase, progress: progress)
        default: 1
        }
    }
}
