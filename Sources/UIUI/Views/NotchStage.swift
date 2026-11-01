import AppKit
import SwiftUI

enum NotchLayout {
    static func expandedWidth(cameraWidth: CGFloat, hasCamera: Bool, size: NotchSize = .standard) -> CGFloat {
        max(size.minimumExpandedWidth, hasCamera ? cameraWidth + size.expandedWings : size.minimumExpandedWidth)
    }
    static let revealDuration = 0.16
    /// Extra height while the pointer rests on a recording: the transcript so far.
    static let hoverTranscriptExtra: CGFloat = 84
    static func expandedHeight(cameraHeight: CGFloat, size: NotchSize = .standard, transcriptOpen: Bool = false) -> CGFloat {
        max(33 + size.bodyHeight, cameraHeight + size.bodyHeight) + (transcriptOpen ? hoverTranscriptExtra : 0)
    }
    static func closedSize(cameraWidth: CGFloat, cameraHeight: CGFloat, hasCamera: Bool, size: NotchSize = .standard) -> CGSize {
        CGSize(width: hasCamera ? cameraWidth + size.closedWings : size.closedWidthWithoutCamera,
               height: hasCamera ? max(36, cameraHeight + 3) : 38)
    }
    static func surfaceSize(phase: NotchFeedbackPhase, cameraWidth: CGFloat, cameraHeight: CGFloat,
                            hasCamera: Bool, expanded: Bool, size: NotchSize = .standard,
                            transcriptOpen: Bool = false) -> CGSize {
        guard expanded else { return closedSize(cameraWidth: cameraWidth, cameraHeight: cameraHeight, hasCamera: hasCamera, size: size) }
        let header = hasCamera ? max(32, cameraHeight) : 32
        let fullWidth = expandedWidth(cameraWidth: cameraWidth, hasCamera: hasCamera, size: size)
        switch phase {
        case .preparing, .recording, .processing, .queued, .dispatched, .cancelled, .copied, .needsInput:
            // One compact footprint for the entire voice cycle. A fast cleanup
            // result cannot shrink, expand, then shrink the body within a blink.
            let hover = transcriptOpen && (phase == .recording) ? hoverTranscriptExtra : 0
            return CGSize(width: fullWidth, height: header + size.bodyHeight + hover)
        default:
            return CGSize(width: hasCamera ? max(fullWidth - 20, cameraWidth + size.expandedWings - 16) : fullWidth - 40, height: header + 11)
        }
    }

    /// Floating pill (no camera) corners are fully rounded; the camera notch keeps its contour.
    static func pillRadius(expanded: Bool) -> CGFloat { expanded ? 20 : 17 }
}

/// The notch body's outline: hardware-matched with a camera, a pill without one.
struct NotchOutline: Shape {
    var hasCamera: Bool
    var top: CGFloat
    var bottom: CGFloat
    init(hasCamera: Bool, expanded: Bool) {
        self.hasCamera = hasCamera
        top = hasCamera ? (expanded ? 14 : 9) : NotchLayout.pillRadius(expanded: expanded)
        bottom = hasCamera ? (expanded ? 24 : 14) : NotchLayout.pillRadius(expanded: expanded)
    }
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        if hasCamera { return NotchContour(topRadius: top, bottomRadius: bottom).path(in: rect) }
        let radius = min(bottom, rect.height / 2, rect.width / 2)
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }
}

/// Spoken state changes. Short phrases only, never transcript text.
@MainActor
enum NotchAnnouncer {
    static func post(_ announcement: NotchAnnouncement) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: announcement.text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// One persistent hosting view. Only its mask and content opacity animate; the controls
/// keep their final layout throughout the reveal. Window resizing never animates.
struct NotchStage: View {
    let model: AppModel
    let onExpand: () -> Void
    let onCollapse: () -> Void
    var onPointerEnter: () -> Void = {}
    var onPointerExit: () -> Void = {}
    /// Called when the panel's size must change (hover transcript opened or closed).
    var onLayoutChange: () -> Void = {}
    var feedbackPreviewIsVisible: Bool? = nil
    @Environment(\.notchReduceMotion) private var reduceMotion
    private var revealAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 0.8, 0.25, 1, duration: NotchLayout.revealDuration)
    }
    private var phase: NotchFeedbackPhase { model.notchFeedbackPhase }
    private var paused: Bool { phase == .recording && model.notchVoiceIsPaused }
    private var announcement: NotchAnnouncement? {
        NotchAnnouncement.resolve(phase: phase, paused: paused, cannotHear: model.notchExtras.cannotHear)
    }
    private func surface(expanded: Bool) -> CGSize {
        if expanded, let ask = model.askPresentation {
            return NotchLayout.askSize(ask, cameraWidth: model.notchCameraWidth, cameraHeight: model.notchCameraHeight,
                                       hasCamera: model.notchHasCamera, size: model.settings.notchSize)
        }
        return speechSurface(expanded: expanded)
    }
    private func speechSurface(expanded: Bool) -> CGSize {
        NotchLayout.surfaceSize(phase: phase, cameraWidth: model.notchCameraWidth,
            cameraHeight: model.notchCameraHeight, hasCamera: model.notchHasCamera, expanded: expanded,
            size: model.settings.notchSize, transcriptOpen: model.notchExtras.transcriptOpen)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // One persistent animation owner: hidden content branches never
                // run a second timeline or restart a receipt on hover/collapse.
                NotchVisualFeedback(phase: phase, level: model.notchAudioLevel,
                    hasCamera: model.notchHasCamera, cameraWidth: model.notchCameraWidth,
                    cameraHeight: model.notchCameraHeight, style: model.settings.notchVisualStyle, feedbackID: model.notchVoiceFeedback?.id,
                    isVisible: feedbackPreviewIsVisible ?? model.settings.notchEnabled,
                    paused: paused, dimmed: model.notchExtras.pointerOver && model.hasCancellableVoiceInput,
                    textActive: !model.notchTranscript.isEmpty)
                    .opacity(model.askPresentation.map { $0.mode == .answering } ?? true ? 1 : 0)
                    .background(Color.black)
                    .frame(width: surface(expanded: model.notchExpanded).width,
                           height: surface(expanded: model.notchExpanded).height)
                    .animation(revealAnimation, value: model.notchExpanded)
                    .animation(revealAnimation, value: phase)
                    .animation(revealAnimation, value: model.notchExtras.transcriptOpen)
                if let ask = model.askPresentation {
                    NotchAskView(ask: ask, cameraWidth: model.notchHasCamera ? model.notchCameraWidth : 0,
                                 header: model.notchHasCamera ? max(32, model.notchCameraHeight) : 32,
                                 onCopy: { model.copyAskReceiptWords() }, onDismiss: { model.dismissAskReceipt() },
                                 onHover: { model.setAskPointerOver($0) })
                        .id(ask.mode)
                        .frame(width: surface(expanded: true).width, height: surface(expanded: true).height)
                } else if model.notchMounted {
                    NotchView(model: model, expanded: true, onExpand: onExpand, onCollapse: onCollapse, rendersMosaic: false,
                              onPointerEnter: onPointerEnter, onPointerExit: onPointerExit)
                        .transaction { $0.animation = nil }
                        .frame(width: surface(expanded: true).width, height: surface(expanded: true).height)
                        .opacity(model.notchExpanded ? 1 : 0)
                        .animation(revealAnimation, value: model.notchExpanded)
                        .allowsHitTesting(model.notchExpanded)
                }
                if model.askPresentation == nil {
                NotchView(model: model, expanded: false, onExpand: onExpand, onCollapse: onCollapse, rendersMosaic: false,
                          onPointerEnter: onPointerEnter, onPointerExit: onPointerExit)
                    .transaction { $0.animation = nil }
                    .frame(width: surface(expanded: false).width, height: surface(expanded: false).height)
                    .opacity(model.notchExpanded ? 0 : 1)
                    .animation(revealAnimation, value: model.notchExpanded)
                    .allowsHitTesting(!model.notchExpanded)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .mask(alignment: .top) {
                NotchOutline(hasCamera: model.notchHasCamera, expanded: model.notchExpanded)
                    .frame(width: surface(expanded: model.notchExpanded).width, height: surface(expanded: model.notchExpanded).height)
                    .animation(revealAnimation, value: model.notchExpanded)
                    .animation(revealAnimation, value: phase)
                    .animation(revealAnimation, value: model.notchExtras.transcriptOpen)
            }
        }
        .onChange(of: model.notchExtras.transcriptOpen) { _, _ in onLayoutChange() }
        .onChange(of: surface(expanded: true)) { _, _ in if model.askPresentation != nil { onLayoutChange() } }
        .onChange(of: announcement) { _, new in
            if let new { NotchAnnouncer.post(new) }
        }
    }
}
