import SwiftUI

/// Drawing limits are independent of the notch's current expanded/collapsed size.
enum NotchMosaicMetrics {
    static let preferredPitch: CGFloat = 4.75
    static let tileSize: CGFloat = 3
    static let maximumTiles = 2_200
    static let opacitySteps = 12
    static let maximumTranslation: CGFloat = 0.42
    static let frameInterval = 1.0 / 30.0
    static func preferredFrameInterval(phase: NotchFeedbackPhase, blending: Bool, settled: Bool) -> Double {
        // Spend smoother display cadence only on short handoffs/terminal
        // gestures. Steady listening and processing keep the original budget.
        let shortGesture = !settled && (phase == .dispatched || phase == .cancelled)
        return phase != .idle && (blending || shortGesture) ? 1.0 / 60.0 : frameInterval
    }

    static func duration(for phase: NotchFeedbackPhase) -> TimeInterval {
        switch phase {
        case .idle: 0
        case .dispatched: NotchFeedbackTiming.pasteAnimationSeconds
        case .cancelled: 0.26
        case .preparing: 0.38
        default: 0.34
        }
    }

    static func requestsFrames(phase: NotchFeedbackPhase, elapsed: TimeInterval,
                               reduceMotion: Bool) -> Bool {
        guard !reduceMotion, phase != .idle else { return false }
        if phase == .recording || phase == .processing { return true }
        return max(0, elapsed) < duration(for: phase)
    }

    static func progress(phase: NotchFeedbackPhase, elapsed: TimeInterval) -> Double {
        let duration = duration(for: phase)
        guard duration > 0 else { return 1 }
        return min(1, max(0, elapsed / duration))
    }

    /// Every light layer, including the edge, shares the terminal zero.
    static func intensity(phase: NotchFeedbackPhase, progress: Double) -> Double {
        let p = min(1, max(0, progress))
        switch phase {
        case .idle: return 0
        case .dispatched: return p >= 1 ? 0 : pow(1 - p, 0.65)
        case .cancelled: return 1 - smooth(p)
        case .preparing: return 0.32 * (0.2 + 0.8 * smooth(p))
        case .queued: return 0.43
        case .copied, .needsInput: return 0.72
        case .message: return 0.22
        case .success: return 0.36
        case .recording, .processing: return 1
        }
    }

    static func smooth(_ value: Double) -> Double {
        let p = min(1, max(0, value))
        return p * p * (3 - 2 * p)
    }
}

/// Pure layout also enforces camera exclusion after all tile movement. The camera
/// rectangle never depends on phase, volume, reveal progress, or panel expansion.
struct NotchMosaicGeometry {
    let bounds: CGRect
    let cameraRect: CGRect?
    let pitch: CGFloat
    let columns: Int
    let rows: Int

    init(size: CGSize, hasCamera: Bool, cameraWidth: CGFloat, cameraHeight: CGFloat) {
        // Invalid/transient layout produces no tiles. The upper bound protects
        // integer conversion even if a malformed preview supplies extreme sizes.
        func dimension(_ value: CGFloat) -> CGFloat {
            value.isFinite ? min(16_384, max(0, value)) : 0
        }
        let width = dimension(size.width)
        let height = dimension(size.height)
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let cameraW = min(width, dimension(cameraWidth))
        let cameraH = min(height, dimension(cameraHeight))
        if hasCamera {
            // A transient unknown camera measurement must fail dark, rather than
            // interpreting the screen as a model without a physical cutout.
            cameraRect = cameraW > 0 && cameraH > 0
                ? CGRect(x: (width - cameraW) / 2, y: 0, width: cameraW, height: cameraH) : bounds
        } else {
            cameraRect = nil
        }
        // Coarsen only for unusually large panels; ordinary notches keep 3 pt tiles.
        pitch = max(NotchMosaicMetrics.preferredPitch,
                    sqrt(width * height / CGFloat(NotchMosaicMetrics.maximumTiles)))
        columns = Int(floor(width / pitch))
        rows = Int(floor(height / pitch))
    }

    var tileCount: Int { columns * rows }

    func tileRect(column: Int, row: Int, offset: CGSize = .zero) -> CGRect? {
        guard column >= 0, column < columns, row >= 0, row < rows,
              offset.width.isFinite, offset.height.isFinite else { return nil }
        let inset = (pitch - NotchMosaicMetrics.tileSize) / 2
        let rect = CGRect(x: CGFloat(column) * pitch + inset + offset.width,
                          y: CGFloat(row) * pitch + inset + offset.height,
                          width: NotchMosaicMetrics.tileSize, height: NotchMosaicMetrics.tileSize)
        return allows(rect) ? rect : nil
    }

    func allows(_ rect: CGRect) -> Bool {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              !rect.isEmpty, bounds.contains(rect) else { return false }
        // Leave a subpoint safety gutter so antialiasing cannot illuminate the seam.
        return cameraRect.map { !$0.insetBy(dx: -0.75, dy: -0.75).intersects(rect) } ?? true
    }

    /// The compact expanded HUD adds one 27 pt transcript row below its camera
    /// header. Preserve the top wings and last bottom cells, quieting that row.
    func readingOpacity(at point: CGPoint) -> Double {
        let headerHeight = cameraRect?.height ?? 32
        guard bounds.height >= headerHeight + 25 else { return 1 }
        let start = headerHeight + 3
        let end = min(bounds.maxY - 3, headerHeight + 23)
        guard point.y > start, point.y < end else { return 1 }
        let vertical = min(1, max(0, min(point.y - start, end - point.y) / 3))
        let interior = min(1, max(0, min(point.x - 10, bounds.maxX - 10 - point.x) / 8))
        return 1 - 0.82 * Double(vertical * interior)
    }
}

/// One timing and drawing owner for the selectable native notch treatments.
/// Mosaic retains its bounded cell grid; continuous styles use a few paths and
/// gradients in the same Canvas. None owns an OS side effect or an idle clock.
struct NotchVisualFeedback: View {
    let phase: NotchFeedbackPhase
    let level: Double
    let hasCamera: Bool
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat
    var style: NotchVisualStyle = .mosaic
    var feedbackID: UUID? = nil
    var previewProgress: Double? = nil
    var isVisible: Bool = true
    /// Capture is held: still, dim and free of frame requests.
    var paused: Bool = false
    /// Hover controls are shown over the wings.
    var dimmed: Bool = false
    /// Words are on screen; the Eyes glance toward them.
    var textActive: Bool = false

    @Environment(\.notchReduceMotion) private var reduceMotion
    @State private var eventStart = Date()
    @State private var fieldStart = Date()
    @State private var fieldStoppedAt: TimeInterval?
    @State private var activeEvent: NotchFeedbackEvent?
    @State private var blend = NotchPhaseBlend()
    @State private var blending = false
    @State private var settled = false
    @State private var levelFrom = 0.0
    @State private var levelTo = 0.0
    @State private var levelStart = Date()
    @State private var history = NotchLevelHistory()
    @State private var glanceFrom = 0.0
    @State private var glanceTo = 0.0
    @State private var glanceStart = Date()

    private var event: NotchFeedbackEvent { NotchFeedbackEvent(phase: phase, feedbackID: feedbackID) }
    private struct Transition: Equatable {
        let event: NotchFeedbackEvent
        let style: NotchVisualStyle
        let reduceMotion: Bool
    }
    private var ticking: Bool {
        isVisible && previewProgress == nil && !reduceMotion && !paused && (blending || NotchMosaicMetrics.requestsFrames(
            phase: phase,
            elapsed: settled ? NotchMosaicMetrics.duration(for: phase) : 0,
            reduceMotion: reduceMotion))
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: NotchMosaicMetrics.preferredFrameInterval(
                phase: phase, blending: blending, settled: settled), paused: !ticking)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(eventStart))
                let progress = previewProgress.map { min(1, max(0, $0)) }
                    ?? (reduceMotion ? 1 : activeEvent != event ? 0 : settled ? 1 : NotchMosaicMetrics.progress(phase: phase, elapsed: elapsed))
                let time = reduceMotion ? 0 : previewProgress.map { $0 * 1.4 } ?? fieldTime(at: timeline.date)
                let audio = paused ? 0 : (reduceMotion || previewProgress != nil) ? safeLevel : interpolatedLevel(at: timeline.date)
                let bars = barLevels(at: timeline.date, audio: audio)
                let glance = glanceValue(at: timeline.date)
                let layers = previewProgress != nil || reduceMotion || blend.isEmpty
                    ? [NotchPhaseBlend.Layer(drawing: .init(phase: phase, style: style,
                        progress: progress, audio: audio, time: time), weight: 1)]
                    : blend.layers(at: timeline.date.timeIntervalSinceReferenceDate, audio: audio, fieldTime: time)
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    draw(context: &context, size: size, layers: layers, progress: progress, bars: bars, glance: glance)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .task(id: Transition(event: event, style: style, reduceMotion: reduceMotion)) {
            let now = Date()
            let oldFieldTime = fieldTime(at: now)
            if activeEvent != event {
                eventStart = now
                settled = reduceMotion || phase == .idle
                activeEvent = event
            }
            if reduceMotion { settled = true }
            else if phase == .recording || phase == .processing { settled = false }
            blend.transition(phase: phase, style: style,
                eventStartedAt: eventStart.timeIntervalSinceReferenceDate,
                at: now.timeIntervalSinceReferenceDate, audio: interpolatedLevel(at: now),
                fieldTime: oldFieldTime, immediate: reduceMotion || phase == .idle || previewProgress != nil)
            blending = !reduceMotion && previewProgress == nil && blend.isBlending(at: now.timeIntervalSinceReferenceDate)
            guard previewProgress == nil, !reduceMotion, phase != .idle else {
                blending = false
                fieldStoppedAt = oldFieldTime
                return
            }
            if !settled { fieldStoppedAt = nil }
            do {
                if blending {
                    var wait = NotchPhaseBlend.duration
                    if phase == .dispatched || phase == .cancelled {
                        wait = min(wait, max(0, NotchMosaicMetrics.duration(for: phase) - now.timeIntervalSince(eventStart)))
                    }
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                    guard !Task.isCancelled else { return }
                    blending = false
                }
                guard phase != .recording, phase != .processing else { return }
                let remaining = NotchMosaicMetrics.duration(for: phase) - Date().timeIntervalSince(eventStart)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                guard !Task.isCancelled else { return }
                // Freeze at the event's existing entrance deadline, independent
                // of scheduler delay or a later hover/layout/style update.
                fieldStoppedAt = max(0, eventStart.timeIntervalSince(fieldStart) + NotchMosaicMetrics.duration(for: phase))
                settled = true
            } catch { return }
        }
        .onAppear { levelTo = safeLevel; levelFrom = safeLevel; glanceTo = textActive ? 1 : 0; glanceFrom = glanceTo }
        .onChange(of: safeLevel) { _, newLevel in
            let now = Date()
            levelFrom = interpolatedLevel(at: now)
            levelTo = newLevel
            levelStart = now
            if style == .bars { history.append(newLevel, at: now.timeIntervalSinceReferenceDate) }
        }
        .onChange(of: textActive) { _, active in
            let now = Date()
            glanceFrom = glanceValue(at: now)
            glanceTo = active ? 1 : 0
            glanceStart = now
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase != .recording { history.clear() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var safeLevel: Double { level.isFinite ? min(1, max(0, level)) : 0 }

    private func glanceValue(at date: Date) -> Double {
        if reduceMotion { return glanceTo }
        let fraction = NotchMosaicMetrics.smooth(max(0, date.timeIntervalSince(glanceStart)) / 0.3)
        return glanceFrom + (glanceTo - glanceFrom) * fraction
    }

    /// Real, smoothed level per bar; each bar reads slightly older audio than the
    /// one nearer the camera. Without samples (previews, Reduced Motion) a fixed
    /// profile of the single level is used.
    private func barLevels(at date: Date, audio: Double) -> [Double] {
        let count = NotchNativeDrawing.barCount
        guard style == .bars else { return [] }
        if reduceMotion || previewProgress != nil || history.samples.isEmpty {
            return (0..<count).map { audio * NotchNativeDrawing.barProfile[$0] }
        }
        let now = date.timeIntervalSinceReferenceDate
        return (0..<count).map { history.value(at: now, delay: Double($0) * 0.045) }
    }

    private func fieldTime(at date: Date) -> TimeInterval {
        if let fieldStoppedAt { return fieldStoppedAt }
        let advancing = max(0, date.timeIntervalSince(fieldStart))
        if let activePhase = activeEvent?.phase, activePhase != .recording, activePhase != .processing {
            return min(advancing, max(0, eventStart.timeIntervalSince(fieldStart) + NotchMosaicMetrics.duration(for: activePhase)))
        }
        return advancing
    }

    private func interpolatedLevel(at date: Date) -> Double {
        let fraction = NotchMosaicMetrics.smooth(max(0, date.timeIntervalSince(levelStart)) / 0.12)
        return levelFrom + (levelTo - levelFrom) * fraction
    }

    private func draw(context: inout GraphicsContext, size: CGSize,
                      layers: [NotchPhaseBlend.Layer], progress: Double, bars: [Double], glance: Double) {
        let geometry = NotchMosaicGeometry(size: size, hasCamera: hasCamera,
                                           cameraWidth: cameraWidth, cameraHeight: cameraHeight)
        guard !geometry.bounds.isEmpty else { return }
        let envelope = NotchPhaseBlend.terminalEnvelope(phase: phase, progress: progress)
        for layer in layers where layer.weight > 0.0001 && envelope > 0 {
            var light = context
            light.opacity *= layer.weight
            drawLayer(context: &light, geometry: geometry, drawing: layer.drawing, envelope: envelope, bars: bars, glance: glance)
        }
        // Last, opaque and independent of animation: no field, transform, or
        // expanded-panel light can ever draw over the physical camera cutout.
        if let camera = geometry.cameraRect { context.fill(Path(camera), with: .color(.black)) }
    }

    private func drawLayer(context: inout GraphicsContext, geometry: NotchMosaicGeometry,
                           drawing: NotchPhaseBlend.Drawing, envelope: Double, bars: [Double], glance: Double) {
        let phase = drawing.phase
        let style = drawing.style
        let progress = drawing.progress
        let audio = drawing.audio
        let time = drawing.time
        let size = geometry.bounds.size
        let intensity = min(envelope, NotchMosaicMetrics.intensity(phase: phase, progress: progress))
        let tint = phase == .copied || phase == .needsInput
            ? Color(red: 0.97, green: 0.67, blue: 0.26) : UIUIStyle.lime
        if intensity > 0.0001 && style == .mosaic {
            var paths = Array(repeating: Path(), count: NotchMosaicMetrics.opacitySteps)
            for row in 0..<geometry.rows {
                for column in 0..<geometry.columns {
                    guard let original = geometry.tileRect(column: column, row: row) else { continue }
                    let point = CGPoint(x: original.midX, y: original.midY)
                    let wave = field(at: point, time: time, phase: phase)
                    var offset = CGSize.zero
                    if !reduceMotion {
                        let drift = NotchMosaicMetrics.maximumTranslation
                        offset = CGSize(width: sin(time * 0.9 + point.y * 0.035) * drift,
                                        height: cos(time * 0.7 + point.x * 0.023) * drift)
                        if phase == .preparing {
                            let arrival = 1 - NotchMosaicMetrics.smooth(progress)
                            offset.width += (point.x < size.width / 2 ? -1 : 1) * arrival * 7
                        } else if phase == .dispatched {
                            let gather = NotchMosaicMetrics.smooth(min(1, progress / 0.72))
                            let release = NotchMosaicMetrics.smooth((progress - 0.65) / 0.35)
                            offset.width += (size.width / 2 - point.x) * gather * 0.62
                            offset.height += (size.height - 4 - point.y) * gather + release * 3
                        } else if phase == .cancelled {
                            offset.height -= NotchMosaicMetrics.smooth(progress) * 7
                        }
                    }
                    guard let rect = geometry.tileRect(column: column, row: row, offset: offset) else { continue }
                    let alpha = tileOpacity(point: point, geometry: geometry, phase: phase, wave: wave,
                                            audio: audio, progress: progress) * intensity
                    guard alpha > 0.018 else { continue }
                    let bucket = min(paths.count - 1, max(0, Int(alpha * Double(paths.count - 1))))
                    paths[bucket].addRoundedRect(in: rect, cornerSize: CGSize(width: 0.65, height: 0.65))
                }
            }
            for index in paths.indices where !paths[index].isEmpty {
                context.fill(paths[index], with: .color(tint.opacity(Double(index + 1) / Double(paths.count))))
            }
        } else if intensity > 0.0001 {
            NotchNativeDrawing.draw(in: &context, geometry: geometry, style: style,
                input: .init(phase: phase, time: reduceMotion ? 0 : time, progress: progress, audio: audio,
                             bars: bars, reduceMotion: reduceMotion, tint: tint, paused: paused,
                             dimmed: dimmed, glance: glance, intensity: intensity))
        }
    }

    private func field(at point: CGPoint, time: Double, phase: NotchFeedbackPhase) -> Double {
        // A fixed phase velocity stays continuous even after long recordings.
        // Audio changes brightness, never total elapsed time multiplied by speed.
        let speed = phase == .processing ? 1.45 : 0.7
        let first = sin(point.x * 0.036 + point.y * 0.068 - time * speed)
        let second = cos(point.x * 0.019 - point.y * 0.054 + time * speed * 0.71)
        return min(1, max(0, 0.5 + first * 0.31 + second * 0.19))
    }

    private func tileOpacity(point: CGPoint, geometry: NotchMosaicGeometry, phase: NotchFeedbackPhase, wave: Double,
                             audio: Double, progress: Double) -> Double {
        let bounds = geometry.bounds
        let center = bounds.midX
        let cameraHalf = geometry.cameraRect?.width ?? min(120, bounds.width * 0.4)
        let wingCenter = (cameraHalf / 2 + bounds.width / 2) / 2
        let wingDistance = abs(abs(point.x - center) - wingCenter)
        let edge = max(exp(-Double(min(point.x, bounds.maxX - point.x)) / 17),
                       exp(-Double(bounds.maxY - point.y) / 10))
        // The real expanded HUD can be only cameraHeight + 27 pt tall.
        let readingArea = geometry.readingOpacity(at: point)
        switch phase {
        case .preparing:
            return (0.07 + 0.38 * wave * wave) * readingArea
        case .recording:
            return (0.07 + (0.22 + audio * 0.4) * wave * wave) * readingArea
        case .processing:
            let compressed = 0.32 + edge * 0.68
            return (0.05 + 0.44 * wave * wave) * compressed * readingArea
        case .dispatched:
            return (0.2 + 0.48 * wave) * (0.75 + 0.25 * sin(.pi * progress)) * readingArea
        case .copied:
            // Three calm amber ledges, distinct from the interrupted error field.
            let ledge = Int(point.y / geometry.pitch) % 3 != 2
            return (wingDistance < 18 && ledge ? 0.5 + 0.3 * wave : 0.025) * readingArea
        case .needsInput:
            let breakInRightWing = point.x > center && wingDistance < 8
            return breakInRightWing ? 0 : (0.12 + 0.45 * wave * wave) * readingArea
        case .queued:
            let queueCenter = center + wingCenter
            return abs(point.x - queueCenter) < 12 && point.y < min(18, bounds.height * 0.65)
                ? 0.38 + 0.18 * wave : 0
        case .cancelled: return (0.09 + 0.29 * wave) * readingArea
        case .success, .message: return (0.06 + 0.25 * wave * wave) * readingArea
        case .idle: return 0
        }
    }
}
