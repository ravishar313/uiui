import SwiftUI

/// Immediate Canvas drawing for the Eyes, Voice bars and Words first styles.
/// Scheduling, level smoothing, receipt identity and the final opaque camera black
/// all belong to NotchVisualFeedback; nothing here owns a clock or an OS effect.
enum NotchNativeDrawing {
    struct Input {
        var phase: NotchFeedbackPhase
        var time: Double
        var progress: Double
        var audio: Double
        /// Per-bar delayed levels for Voice bars, nearest the camera first.
        var bars: [Double]
        var reduceMotion: Bool
        var tint: Color
        var paused: Bool
        /// Hover controls sit over the wings; the picture steps back.
        var dimmed: Bool
        /// 0 to 1: the eyes glance toward the transcript line.
        var glance: Double
        var intensity: Double
    }

    static let barCount = 9
    /// Shape of a calm voice across the bars when only a single level is known.
    static let barProfile: [Double] = [1, 0.92, 0.97, 0.74, 0.82, 0.58, 0.64, 0.44, 0.5]

    /// Header band that carries the style on both sides of the camera.
    static func headerHeight(_ geometry: NotchMosaicGeometry) -> CGFloat {
        geometry.cameraRect?.height ?? min(32, geometry.bounds.height)
    }

    /// The x of the nearest pixel a wing mark may use on each side of the camera.
    static func wingEdges(_ geometry: NotchMosaicGeometry) -> (left: CGFloat, right: CGFloat) {
        if let camera = geometry.cameraRect { return (camera.minX, camera.maxX) }
        return (geometry.bounds.midX - 7, geometry.bounds.midX + 7)
    }

    static func screenPath(geometry: NotchMosaicGeometry) -> Path {
        var path = Path(geometry.bounds)
        if let camera = geometry.cameraRect {
            path.addRect(camera.insetBy(dx: -0.75, dy: -0.75).intersection(geometry.bounds))
        }
        return path
    }

    static func draw(in context: inout GraphicsContext, geometry: NotchMosaicGeometry,
                     style: NotchVisualStyle, input: Input) {
        guard input.intensity > 0.0001, !geometry.bounds.isEmpty else { return }
        var safe = context
        safe.clip(to: screenPath(geometry: geometry), style: FillStyle(eoFill: true))
        safe.opacity *= input.intensity * (input.dimmed ? 0.07 : 1)
        switch style {
        case .eyes: drawEyes(in: &safe, geometry: geometry, input: input)
        case .bars: drawBars(in: &safe, geometry: geometry, input: input)
        case .words: drawWordsLine(in: &safe, geometry: geometry, input: input)
        case .mosaic: break
        }
    }

    // MARK: Eyes

    struct EyePose: Equatable {
        /// Height as a fraction of the resting pill.
        var open: Double
        /// Radians; positive tilts the outer end of each eye downward.
        var droop: Double
        /// Points down.
        var drop: Double
        /// Horizontal drift in points, mirrored between the eyes.
        var drift: Double
    }

    static func eyePose(phase: NotchFeedbackPhase, time: Double, progress: Double, audio: Double,
                        paused: Bool, glance: Double, reduceMotion: Bool) -> EyePose {
        let p = NotchMosaicMetrics.smooth(progress)
        var pose = EyePose(open: 1, droop: 0, drop: 0, drift: 0)
        switch phase {
        case .preparing:
            pose.open = 0.1 + 0.9 * p
        case .recording:
            if paused {
                pose.open = 0.26; pose.drop = 0.8
            } else {
                // A calm resting size that swells with the real voice level.
                pose.open = (0.82 + 0.78 * min(1, max(0, audio)))
                if !reduceMotion { pose.open *= 0.08 + 0.92 * NotchEyeMotion.openness(time: time) }
                pose.drop = 1.9 * glance
            }
        case .processing:
            pose.open = 0.3 + (reduceMotion ? 0 : 0.03 * sin(time * 3.1))
            pose.drift = reduceMotion ? 0 : 1.1 * sin(time * 1.5)
        case .queued:
            pose.open = 0.5; pose.drift = 1.2
        case .dispatched:
            let close = NotchMosaicMetrics.smooth(min(1, progress / 0.55))
            pose.open = 1 - 0.93 * close
            pose.drop = 0.6 * close
        case .cancelled:
            pose.open = 1 - 0.4 * p
            pose.droop = 0.62 * p
            pose.drop = 2.4 * p
        case .copied, .needsInput:
            pose.open = 0.92; pose.droop = -0.3
        case .success, .message:
            pose.open = 0.4
        case .idle:
            pose.open = 0.0
        }
        return pose
    }

    private static func drawEyes(in context: inout GraphicsContext, geometry: NotchMosaicGeometry, input: Input) {
        let header = headerHeight(geometry)
        let edges = wingEdges(geometry)
        let wing = geometry.cameraRect.map { $0.minX } ?? 24
        let offset = max(10, wing * 0.5) // The middle of the wing, at every notch size.
        let centers = [edges.left - offset, edges.right + offset]
        let pose = eyePose(phase: input.phase, time: input.time, progress: input.progress, audio: input.audio,
                           paused: input.paused, glance: input.glance, reduceMotion: input.reduceMotion)
        let width: CGFloat = 7.2
        let rest: CGFloat = min(15, max(8, header * 0.4))
        let height = max(2.4, rest * CGFloat(pose.open))
        let cy = header / 2 + CGFloat(pose.drop)
        for (index, cx) in centers.enumerated() {
            let side: CGFloat = index == 0 ? -1 : 1
            var eye = context
            eye.translateBy(x: cx + side * CGFloat(pose.drift), y: cy)
            // Outer end lower when drooping, inner end lower when the amber worry tilt is negative.
            eye.rotate(by: .radians(Double(side) * pose.droop))
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            let radius = min(width, height) / 2
            eye.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(input.tint))
            // The logo's small catchlight keeps the pills looking like eyes, not bars.
            if height > 7 {
                let dot = CGRect(x: width * 0.06, y: -height / 2 + height * 0.1, width: 1.7, height: 1.7)
                eye.fill(Path(ellipseIn: dot), with: .color(.black.opacity(0.85)))
            }
        }
    }

    // MARK: Voice bars

    static func barHeights(phase: NotchFeedbackPhase, time: Double, progress: Double, bars: [Double],
                           paused: Bool, header: CGFloat) -> (heights: [CGFloat], alphas: [Double]) {
        let minHeight: CGFloat = 2.6
        let maxHeight = max(minHeight + 2, header - 11)
        let p = NotchMosaicMetrics.smooth(progress)
        var heights = Array(repeating: minHeight, count: barCount)
        var alphas = Array(repeating: 1.0, count: barCount)
        for j in 0..<barCount {
            let falloff = 1 - 0.45 * Double(j) / Double(barCount - 1)
            let level = j < bars.count ? min(1, max(0, bars[j])) : 0
            switch phase {
            case .recording:
                if paused { alphas[j] = 0.38 }
                else { heights[j] = minHeight + (maxHeight - minHeight) * CGFloat(pow(level, 0.85) * falloff) }
                alphas[j] = paused ? 0.38 : 0.45 + 0.55 * falloff
            case .processing:
                // A soft highlight travels outward from the camera and loops.
                let centre = (time * 0.85).truncatingRemainder(dividingBy: 1) * Double(barCount + 4) - 2
                let bump = max(0, 1 - abs(Double(j) - centre) / 2.4)
                heights[j] = minHeight + 5.2 * CGFloat(bump)
                alphas[j] = 0.3 + 0.7 * bump
            case .preparing:
                heights[j] = minHeight * CGFloat(p)
                alphas[j] = 0.5
            case .dispatched:
                let start = minHeight + (maxHeight - minHeight) * 0.3 * CGFloat(falloff)
                heights[j] = start + (minHeight - start) * CGFloat(p)
                alphas[j] = 0.9
            case .cancelled:
                heights[j] = minHeight * CGFloat(1 - p) + 1
                alphas[j] = 0.6
            case .copied, .needsInput:
                heights[j] = minHeight + (j % 2 == 0 ? 3.5 : 0.5)
                alphas[j] = 0.5 + 0.4 * falloff
            case .queued:
                heights[j] = minHeight
                alphas[j] = j < 3 ? 0.7 : 0.18
            case .success, .message:
                alphas[j] = 0.4
            case .idle:
                alphas[j] = 0
            }
        }
        return (heights, alphas)
    }

    private static func drawBars(in context: inout GraphicsContext, geometry: NotchMosaicGeometry, input: Input) {
        let header = headerHeight(geometry)
        let edges = wingEdges(geometry)
        let bounds = geometry.bounds
        let barWidth: CGFloat = 2.2
        let pitch: CGFloat = 5.4
        // The group of bars sits in the middle of the wing, at every notch size.
        let groupWidth = CGFloat(barCount - 1) * pitch + barWidth
        let wing = geometry.cameraRect.map { $0.minX } ?? 0
        let inset: CGFloat = geometry.cameraRect == nil ? 12 : max(9, (wing - groupWidth) / 2)
        let spec = barHeights(phase: input.phase, time: input.time, progress: input.progress,
                              bars: input.bars, paused: input.paused, header: header)
        for j in 0..<barCount {
            let height = spec.heights[j]
            let alpha = spec.alphas[j]
            guard alpha > 0.01 else { continue }
            for side in [-1.0, 1.0] {
                let x = side < 0 ? edges.left - inset - CGFloat(j) * pitch - barWidth
                                 : edges.right + inset + CGFloat(j) * pitch
                guard x >= 5, x + barWidth <= bounds.maxX - 5 else { continue }
                let rect = CGRect(x: x, y: header / 2 - height / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(input.tint.opacity(alpha)))
            }
        }
    }

    // MARK: Words first

    /// The words are drawn by the transcript line. The Canvas adds only a thin line
    /// along the lower edge: breathing with the voice, sweeping while working, flashing on send.
    private static func drawWordsLine(in context: inout GraphicsContext, geometry: NotchMosaicGeometry, input: Input) {
        let bounds = geometry.bounds
        let margin: CGFloat = 28
        let left = margin, right = bounds.maxX - margin
        guard right - left > 20 else { return }
        let y = bounds.maxY - 2.4
        let full = right - left
        let p = NotchMosaicMetrics.smooth(input.progress)
        func line(_ from: CGFloat, _ to: CGFloat, alpha: Double, width: CGFloat = 1.3) {
            guard to - from > 0.5 else { return }
            let rect = CGRect(x: from, y: y - width / 2, width: to - from, height: width)
            context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(input.tint.opacity(alpha)))
        }
        switch input.phase {
        case .preparing:
            let half = full / 2 * CGFloat(p)
            line(bounds.midX - half, bounds.midX + half, alpha: 0.35)
        case .recording:
            if input.paused { line(left, right, alpha: 0.12) }
            else {
                let spread = full * CGFloat(0.35 + 0.65 * input.audio) / 2
                line(bounds.midX - spread, bounds.midX + spread, alpha: 0.14 + 0.5 * input.audio)
            }
        case .processing:
            line(left, right, alpha: 0.1)
            let segment = full * 0.24
            let travel = input.reduceMotion ? 0.5 : (input.time * 0.8).truncatingRemainder(dividingBy: 1)
            let start = left + (full - segment) * CGFloat(travel)
            line(start, start + segment, alpha: 0.85)
        case .dispatched:
            // One quick confirming sweep left to right, then it fades with the receipt.
            let head = left + full * CGFloat(min(1, input.progress / 0.7))
            line(left, head, alpha: 0.9, width: 1.6)
        case .cancelled:
            let half = full / 2 * CGFloat(1 - p)
            line(bounds.midX - half, bounds.midX + half, alpha: 0.4)
        case .copied, .needsInput:
            line(left, right, alpha: 0.7)
        case .queued:
            line(left, left + full * 0.18, alpha: 0.5)
            line(left + full * 0.24, left + full * 0.42, alpha: 0.25)
        case .success, .message:
            line(left, right, alpha: 0.22)
        case .idle: break
        }
    }
}
