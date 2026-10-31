import SwiftUI

/// Immediate Canvas drawing only. Scheduling, audio smoothing, receipt identity,
/// terminal darkness, and final camera black all belong to NotchVisualFeedback.
enum NotchContinuousDrawing {
    struct LightRegion {
        let rect: CGRect
        let opacity: Double
    }

    /// Three disjoint strips avoid a panel-sized compositing mask. The center
    /// transcript strip receives the same 18% light floor as the Mosaic grid.
    static func lightRegions(geometry: NotchMosaicGeometry) -> [LightRegion] {
        let bounds = geometry.bounds
        guard !bounds.isEmpty else { return [] }
        let header = geometry.cameraRect?.height ?? 32
        guard bounds.height >= header + 25 else { return [.init(rect: bounds, opacity: 1)] }
        let start = header + 3
        let end = min(bounds.maxY - 3, header + 23)
        return [
            .init(rect: CGRect(x: 0, y: 0, width: bounds.width, height: start), opacity: 1),
            .init(rect: CGRect(x: 0, y: start, width: bounds.width, height: end - start), opacity: 0.18),
            .init(rect: CGRect(x: 0, y: end, width: bounds.width, height: bounds.height - end), opacity: 1)
        ]
    }

    /// The camera gutter is clipped before drawing and never follows any moving
    /// light. The parent also paints the physical rectangle opaque black last.
    static func screenPath(geometry: NotchMosaicGeometry) -> Path {
        var path = Path(geometry.bounds)
        if let camera = geometry.cameraRect {
            path.addRect(camera.insetBy(dx: -0.75, dy: -0.75).intersection(geometry.bounds))
        }
        return path
    }

    static func draw(in context: inout GraphicsContext, geometry: NotchMosaicGeometry,
                     style: NotchVisualStyle, phase: NotchFeedbackPhase, time: Double,
                     progress: Double, audio: Double, reduceMotion: Bool,
                     tint: Color, intensity: Double) {
        guard intensity > 0.0001, !geometry.bounds.isEmpty else { return }
        var safe = context
        safe.clip(to: screenPath(geometry: geometry), style: FillStyle(eoFill: true))
        // The timing owner supplies one continuous field clock and freezes it
        // after finite entrances; phase-local progress only shapes the gesture.
        let t = reduceMotion ? 0 : time
        for region in lightRegions(geometry: geometry) {
            var light = safe
            light.clip(to: Path(region.rect))
            light.opacity *= intensity * region.opacity
            if phase == .queued {
                drawQueue(in: &light, geometry: geometry, style: style, tint: tint)
            } else if style == .liquid {
                drawLiquid(in: &light, geometry: geometry, phase: phase,
                           time: t, progress: progress, audio: audio, tint: tint)
            } else {
                drawRibbon(in: &light, geometry: geometry, phase: phase,
                           time: t, progress: progress, audio: audio, tint: tint)
            }
        }
    }

    private static func drawLiquid(in context: inout GraphicsContext, geometry: NotchMosaicGeometry,
                                   phase: NotchFeedbackPhase, time: Double, progress: Double,
                                   audio: Double, tint: Color) {
        let bounds = geometry.bounds
        let w = bounds.width
        let h = bounds.height
        let speed = phase == .processing ? 1.35 : 0.72
        let p = NotchMosaicMetrics.smooth(progress)
        let gather = phase == .dispatched ? NotchMosaicMetrics.smooth(progress / 0.72) : 0
        let preparing = phase == .preparing ? 1 - p : 0
        let retract = phase == .cancelled ? p : 0
        let power: Double
        switch phase {
        case .recording: power = 0.32 + audio * 0.24
        case .processing: power = 0.43
        case .copied, .needsInput: power = 0.32
        default: power = 0.36
        }
        let centers = [
            CGPoint(x: w * 0.16 + sin(time * speed) * 10 - preparing * 17 - retract * 10,
                    y: min(19, h * 0.4) + sin(time * speed * 0.83) * 3 - preparing * 5 - retract * 8),
            CGPoint(x: w * 0.84 + sin(time * speed + 2) * 10 + preparing * 17 + retract * 10,
                    y: min(23, h * 0.48) + cos(time * speed * 0.71) * 3 - preparing * 5 - retract * 8),
            CGPoint(x: w * 0.5 + sin(time * speed * 0.64) * 24, y: h + 9)
        ]
        for (index, source) in centers.enumerated() {
            let center = CGPoint(x: source.x + (w / 2 - source.x) * gather,
                                 y: source.y + (h - 3 - source.y) * gather)
            let radius = (index == 2 ? min(92, w * 0.3) : min(94, w * 0.31)) * (1 - gather * 0.62)
            let gradient = Gradient(stops: [
                .init(color: tint.opacity(power * (index == 0 ? 0.9 : 0.72)), location: 0),
                .init(color: tint.opacity(power * 0.32), location: 0.4),
                .init(color: tint.opacity(0), location: 1)
            ])
            context.fill(Path(bounds), with: .radialGradient(gradient, center: center,
                                                            startRadius: 0, endRadius: max(1, radius)))
        }
        let spread = 1 - gather * 0.67 - retract * 0.17
        for band in 0..<4 {
            let y = h - 4 - CGFloat(band) * 2.8 + sin(time * 0.67 + Double(band) * 0.7) * 1.6
            let left = w / 2 - (w / 2 - 12) * spread
            let right = w / 2 + (w / 2 - 12) * spread
            var silk = Path()
            silk.move(to: CGPoint(x: left, y: y - 2))
            silk.addCurve(to: CGPoint(x: right, y: y - 1),
                          control1: CGPoint(x: w * 0.29, y: y - 5 + sin(time + Double(band)) * 2),
                          control2: CGPoint(x: w * 0.71, y: y + 3 + cos(time * 0.8 + Double(band)) * 2))
            context.stroke(silk, with: .color(tint.opacity(0.08 + Double(band) * 0.025)),
                           style: StrokeStyle(lineWidth: band == 0 ? 2.4 : 0.8, lineCap: .round))
        }
        if phase == .copied { drawCopyLedges(in: &context, geometry: geometry, tint: tint) }
        if phase == .needsInput { drawAttentionBreak(in: &context, geometry: geometry, tint: tint) }
    }

    private static func drawRibbon(in context: inout GraphicsContext, geometry: NotchMosaicGeometry,
                                   phase: NotchFeedbackPhase, time: Double, progress: Double,
                                   audio: Double, tint: Color) {
        let bounds = geometry.bounds
        let w = bounds.width
        let h = bounds.height
        let p = NotchMosaicMetrics.smooth(progress)
        let gather = phase == .dispatched ? NotchMosaicMetrics.smooth(progress / 0.72) : 0
        // The starting rim arrives inward from just outside its settled rails.
        let assembly = phase == .preparing ? 1 + (1 - p) * 0.08 : 1
        let retract = phase == .cancelled ? 1 - p * 0.8 : 1
        let spread = assembly * retract * (1 - gather * 0.7)
        let left = w / 2 - (w / 2 - 15) * spread
        let right = w / 2 + (w / 2 - 15) * spread
        let voice = phase == .recording ? audio : 0
        let y = h - 2.5
        let gradient = Gradient(stops: [
            .init(color: tint.opacity(0.08), location: 0),
            .init(color: tint.opacity(0.38 + voice * 0.22), location: 0.48),
            .init(color: tint.opacity(0.08), location: 1)
        ])
        let ribbonRect = CGRect(x: left, y: h - 7, width: max(0, right - left), height: 7)
        context.fill(Path(ribbonRect), with: .linearGradient(gradient,
                     startPoint: CGPoint(x: left, y: y), endPoint: CGPoint(x: right, y: y)))
        var contour = Path()
        contour.move(to: CGPoint(x: left, y: min(13, h * 0.33)))
        contour.addLine(to: CGPoint(x: left, y: max(13, h - 12)))
        contour.addQuadCurve(to: CGPoint(x: min(left + 11, right), y: y),
                             control: CGPoint(x: left, y: y))
        contour.addLine(to: CGPoint(x: max(left, right - 11), y: y))
        contour.addQuadCurve(to: CGPoint(x: right, y: max(13, h - 12)),
                             control: CGPoint(x: right, y: y))
        contour.addLine(to: CGPoint(x: right, y: min(13, h * 0.33)))
        if phase == .needsInput {
            // Separate amber sections retain an unmistakable interruption.
            let broken = StrokeStyle(lineWidth: 1, lineCap: .round, dash: [54, 12, 86, 10])
            context.stroke(contour, with: .color(tint.opacity(0.68)), style: broken)
        } else {
            context.stroke(contour, with: .color(tint.opacity(0.09)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round))
            context.stroke(contour, with: .color(tint.opacity(0.24 + voice * 0.15)),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            context.stroke(contour, with: .color(tint.opacity(0.66 + voice * 0.24)),
                           style: StrokeStyle(lineWidth: 0.85, lineCap: .round))
        }
        if phase == .processing {
            context.stroke(contour, with: .color(tint.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                              dash: [28, 230], dashPhase: -time * 37))
        } else if phase == .recording {
            let sweep = 0.5 + 0.22 * sin(time * 0.8)
            let center = left + (right - left) * sweep
            let width = min(72, (right - left) * 0.3)
            let sheen = Gradient(colors: [tint.opacity(0), tint.opacity(0.38 + audio * 0.25), tint.opacity(0)])
            context.fill(Path(CGRect(x: center - width / 2, y: h - 6, width: width, height: 5)),
                         with: .linearGradient(sheen,
                             startPoint: CGPoint(x: center - width / 2, y: y),
                             endPoint: CGPoint(x: center + width / 2, y: y)))
        }
        if phase == .copied { drawCopyLedges(in: &context, geometry: geometry, tint: tint) }
    }

    private static func drawCopyLedges(in context: inout GraphicsContext,
                                       geometry: NotchMosaicGeometry, tint: Color) {
        let w = geometry.bounds.width
        let cameraW = geometry.cameraRect?.width ?? w * 0.4
        let wing = (w + cameraW) / 4
        for side in [-1.0, 1.0] {
            let x = w / 2 + side * wing
            for row in 0..<2 {
                let y = min(geometry.bounds.height - 5, 16 + CGFloat(row) * 5)
                let rect = CGRect(x: x - 9 + CGFloat(row) * 2, y: y, width: 16, height: 1.6)
                var ledge = Path()
                ledge.addRoundedRect(in: rect, cornerSize: CGSize(width: 0.8, height: 0.8))
                context.fill(ledge, with: .color(tint.opacity(0.58)))
            }
        }
    }

    private static func drawAttentionBreak(in context: inout GraphicsContext,
                                          geometry: NotchMosaicGeometry, tint: Color) {
        let w = geometry.bounds.width
        let h = geometry.bounds.height
        var line = Path()
        line.move(to: CGPoint(x: 13, y: h - 3))
        line.addLine(to: CGPoint(x: w * 0.68, y: h - 3))
        line.move(to: CGPoint(x: w * 0.73, y: h - 3))
        line.addLine(to: CGPoint(x: w - 13, y: h - 3))
        context.stroke(line, with: .color(tint.opacity(0.52)), style: StrokeStyle(lineWidth: 0.9))
    }

    private static func drawQueue(in context: inout GraphicsContext, geometry: NotchMosaicGeometry,
                                  style: NotchVisualStyle, tint: Color) {
        let w = geometry.bounds.width
        let cameraW = geometry.cameraRect?.width ?? w * 0.4
        let x = w / 2 + (w + cameraW) / 4
        let y = min(18, geometry.bounds.height / 2)
        if style == .liquid {
            let gradient = Gradient(colors: [tint.opacity(0.65), tint.opacity(0)])
            context.fill(Path(CGRect(x: x - 14, y: y - 9, width: 28, height: 18)),
                         with: .radialGradient(gradient, center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 14))
        } else {
            var line = Path()
            line.move(to: CGPoint(x: x - 9, y: y))
            line.addQuadCurve(to: CGPoint(x: x + 9, y: y), control: CGPoint(x: x, y: y + 4))
            context.stroke(line, with: .color(tint.opacity(0.7)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }
}
