import AppKit
import SwiftUI

final class CompanionPanel: NSPanel {
    var acceptsKeyboardFocus = true
    override var canBecomeKey: Bool { acceptsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

enum NotchLayout {
    static func expandedWidth(cameraWidth: CGFloat, hasCamera: Bool, size: NotchSize = .standard) -> CGFloat {
        max(size.minimumExpandedWidth, hasCamera ? cameraWidth + size.expandedWings : size.minimumExpandedWidth)
    }
    static let revealDuration = 0.16
    static func expandedHeight(cameraHeight: CGFloat, size: NotchSize = .standard) -> CGFloat {
        max(33 + size.bodyHeight, cameraHeight + size.bodyHeight)
    }
    static func closedSize(cameraWidth: CGFloat, cameraHeight: CGFloat, hasCamera: Bool, size: NotchSize = .standard) -> CGSize {
        CGSize(width: hasCamera ? cameraWidth + size.closedWings : size.closedWidthWithoutCamera,
               height: hasCamera ? max(36, cameraHeight + 3) : 38)
    }
    static func surfaceSize(phase: NotchFeedbackPhase, cameraWidth: CGFloat, cameraHeight: CGFloat,
                            hasCamera: Bool, expanded: Bool, size: NotchSize = .standard) -> CGSize {
        guard expanded else { return closedSize(cameraWidth: cameraWidth, cameraHeight: cameraHeight, hasCamera: hasCamera, size: size) }
        let header = hasCamera ? max(32, cameraHeight) : 32
        let fullWidth = expandedWidth(cameraWidth: cameraWidth, hasCamera: hasCamera, size: size)
        switch phase {
        case .preparing, .recording, .processing, .queued, .dispatched, .cancelled, .copied, .needsInput:
            // One compact footprint for the entire voice cycle. A fast cleanup
            // result cannot shrink, expand, then shrink the body within a blink.
            return CGSize(width: fullWidth, height: header + size.bodyHeight)
        default:
            return CGSize(width: hasCamera ? max(fullWidth - 20, cameraWidth + size.expandedWings - 16) : fullWidth - 40, height: header + 11)
        }
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
    var feedbackPreviewIsVisible: Bool? = nil
    @Environment(\.notchReduceMotion) private var reduceMotion
    private var revealAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 0.8, 0.25, 1, duration: NotchLayout.revealDuration)
    }
    private var phase: NotchFeedbackPhase { model.notchFeedbackPhase }
    private func surface(expanded: Bool) -> CGSize {
        NotchLayout.surfaceSize(phase: phase, cameraWidth: model.notchCameraWidth,
            cameraHeight: model.notchCameraHeight, hasCamera: model.notchHasCamera, expanded: expanded,
            size: model.settings.notchSize)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // One persistent animation owner: hidden content branches never
                // run a second timeline or restart a receipt on hover/collapse.
                NotchVisualFeedback(phase: phase, level: model.notchAudioLevel,
                    hasCamera: model.notchHasCamera, cameraWidth: model.notchCameraWidth,
                    cameraHeight: model.notchCameraHeight, style: model.settings.notchVisualStyle, feedbackID: model.notchVoiceFeedback?.id,
                    isVisible: feedbackPreviewIsVisible ?? model.settings.notchEnabled)
                    .background(Color.black)
                    .frame(width: surface(expanded: model.notchExpanded).width,
                           height: surface(expanded: model.notchExpanded).height)
                    .animation(revealAnimation, value: model.notchExpanded)
                    .animation(revealAnimation, value: phase)
                if model.notchMounted {
                    NotchView(model: model, expanded: true, onExpand: onExpand, onCollapse: onCollapse, rendersMosaic: false,
                              onPointerEnter: onPointerEnter, onPointerExit: onPointerExit)
                        .transaction { $0.animation = nil }
                        .frame(width: surface(expanded: true).width, height: surface(expanded: true).height)
                        .opacity(model.notchExpanded ? 1 : 0)
                        .animation(revealAnimation, value: model.notchExpanded)
                        .allowsHitTesting(model.notchExpanded)
                }
                NotchView(model: model, expanded: false, onExpand: onExpand, onCollapse: onCollapse, rendersMosaic: false,
                          onPointerEnter: onPointerEnter, onPointerExit: onPointerExit)
                    .transaction { $0.animation = nil }
                    .frame(width: surface(expanded: false).width, height: surface(expanded: false).height)
                    .opacity(model.notchExpanded ? 0 : 1)
                    .animation(revealAnimation, value: model.notchExpanded)
                    .allowsHitTesting(!model.notchExpanded)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .mask(alignment: .top) {
                NotchContour(topRadius: model.notchExpanded ? 14 : 9, bottomRadius: model.notchExpanded ? 24 : 14)
                    .frame(width: surface(expanded: model.notchExpanded).width, height: surface(expanded: model.notchExpanded).height)
                    .animation(revealAnimation, value: model.notchExpanded)
                    .animation(revealAnimation, value: phase)
            }
        }
    }
}

/// Closed history can release its AppKit/SwiftUI tree without cooling the voice
/// HUD or models. Editors and sheets retain their local, recoverable drafts.
@MainActor
final class WorkspaceWindowLifetime: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let makeWindow: () -> NSWindow
    private(set) var window: NSWindow?
    private var savedFrame: NSRect?
    private var closeGeneration = UUID()
    private(set) var pendingClose: Task<Void, Never>?

    init(model: AppModel, makeWindow: @escaping () -> NSWindow) {
        self.model = model; self.makeWindow = makeWindow
        super.init()
    }

    func windowForOpening() -> NSWindow {
        // A close notification may still be awaiting its main-actor turn when
        // the user reopens Home. Never dispose that reopened window.
        closeGeneration = UUID(); pendingClose?.cancel(); pendingClose = nil
        if let window { return window }
        let created = makeWindow()
        if let savedFrame { created.setFrame(savedFrame, display: false) }
        created.delegate = self
        window = created
        return created
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        savedFrame = closed.frame
        let generation = UUID(); closeGeneration = generation
        pendingClose?.cancel()
        guard canEvict else { return }
        // Release after AppKit's synchronous close finishes. Recheck eligibility
        // because capture or another UI request can start before this runs.
        pendingClose = Task { @MainActor [weak self, weak closed] in
            guard let self else { return }
            defer { if self.closeGeneration == generation { self.pendingClose = nil } }
            guard let closed, !Task.isCancelled,
                  self.closeGeneration == generation, self.window === closed,
                  !closed.isVisible, self.canEvict else { return }
            closed.contentView = nil
            closed.delegate = nil
            self.window = nil
        }
    }

    private var canEvict: Bool {
        model.selectedItemID == nil && model.workspaceSheet == nil && !model.showComposer
            && !model.hasCancellableVoiceInput
    }
}

@MainActor
final class PanelCoordinator {
    private let model: AppModel
    private var notch: CompanionPanel?
    private var capture: CompanionPanel?
    private var onboarding: NSWindow?
    private var onboardingCloseObserver: NSObjectProtocol?
    private let workspace: WorkspaceWindowLifetime
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var collapseTask: Task<Void, Never>?
    private var hoverCollapseTask: Task<Void, Never>?
    private var transitionID = UUID()
    private var feedbackID: UUID?
    private lazy var feedbackLifetime = NotchFeedbackLifetime { [weak self] id, clearReceipt in
        guard let self, model.activeVoiceFeedback?.id == id,
              !keepsVoiceHUDVisible else { return false }
        if clearReceipt { model.dismissNotchFeedback(id) }
        collapse()
        return true
    }

    init(model: AppModel, installSystemObservers: Bool = true) {
        self.model = model
        workspace = WorkspaceWindowLifetime(model: model) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "uiui"; window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
            window.tabbingMode = .disallowed
            window.minSize = NSSize(width: 680, height: 460); window.isReleasedWhenClosed = false; window.isRestorable = false
            window.contentView = NSHostingView(rootView: LibraryView(model: model)); window.center()
            return window
        }
        guard installSystemObservers else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.updateNotch() } }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.cancelRecording(); self?.model.cancelTriggeredVoice(); self?.collapse() } }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.keepsVoiceHUDVisible else { return }
                self.collapse(); self.capture?.orderOut(nil)
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Active input is cancelled by GlobalShortcuts in both local and
            // foreground apps. This fallback only dismisses an idle local panel.
            if let self, !self.model.hasCancellableVoiceInput, event.keyCode == 53,
               self.model.notchExpanded || self.capture?.isVisible == true {
                self.dismissCaptureUI(); return nil
            }
            return event
        }
    }
    func openHome() {
        model.workspaceSheet = nil
        openWorkspace()
    }
    func openLibrary() {
        // Migrate callers that still use the old navigation destinations.
        if model.selection == .settings {
            model.workspaceSheet = .settings
            model.selection = .dictations
        }
        openWorkspace()
    }
    private func openWorkspace() {
        capture?.orderOut(nil); collapse()
        workspace.windowForOpening().makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func openOnboarding() {
        capture?.orderOut(nil); collapse()
        if onboarding == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Set up uiui"; window.titlebarAppearsTransparent = true
            window.tabbingMode = .disallowed; window.isReleasedWhenClosed = false; window.isRestorable = false
            window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak window] in window?.close() })
            window.center()
            onboarding = window
            // Closing the guide on the style step must never leave the preview running.
            onboardingCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.model.notchStylePreviewActive = false } }
        }
        onboarding?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func closeFrontWindow() {
        guard let front = NSApplication.shared.keyWindow else { return }
        if front === workspace.window { front.close() }
        else { front.orderOut(nil) }
    }
    func openCapture() {
        collapse()
        if capture == nil {
            let panel = makePanel(); panel.level = .floating; panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: QuickCaptureView(model: model)); panel.setContentSize(NSSize(width: 560, height: 480)); capture = panel
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        if let screen { capture?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 280, y: screen.visibleFrame.midY - 210)) }
        capture?.makeKeyAndOrderFront(nil)
    }
    func updateNotch() {
        guard model.settings.notchEnabled else { collapseTask?.cancel(); model.notchExpanded = false; model.notchMounted = false; notch?.orderOut(nil); return }
        guard let screen = preferredScreen else { return }
        model.notchHasCamera = screen.safeAreaInsets.top > 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { model.notchCameraWidth = max(160, right.minX - left.maxX) }
        else { model.notchCameraWidth = 180 }
        model.notchCameraHeight = model.notchHasCamera ? max(32, screen.safeAreaInsets.top) : 0
        if notch == nil {
            let panel = makePanel(acceptsKeyboardFocus: false); panel.level = .statusBar; panel.hasShadow = false
            panel.contentView = NSHostingView(rootView: NotchStage(model: model, onExpand: { [weak self] in self?.expand() }, onCollapse: { [weak self] in self?.collapse() },
                                                                onPointerEnter: { [weak self] in self?.pointerEnteredNotch() },
                                                                onPointerExit: { [weak self] in self?.pointerLeftNotch() }))
            notch = panel
        }
        setNotchFrame(expanded: model.notchExpanded || model.notchMounted)
        if notch?.isVisible == false { notch?.orderFrontRegardless() }
    }
    func expand() {
        guard model.settings.notchEnabled else { return }
        guard !model.notchExpanded else { return }
        transitionID = UUID(); collapseTask?.cancel(); collapseTask = nil
        updateNotch()
        // Resize the transparent host first while the mask remains collapsed. The visible
        // shape stays at the same global top-center; no window-frame interpolation occurs.
        setNotchFrame(expanded: true)
        notch?.contentView?.layoutSubtreeIfNeeded()
        model.notchMounted = true
        model.notchExpanded = true
    }
    /// Moving the pointer away closes the opened notch after a short grace, so a
    /// brief wobble past the edge doesn't snap it shut. Active dictation, setup's
    /// preview and model downloads keep it open.
    func pointerLeftNotch() {
        hoverCollapseTask?.cancel()
        hoverCollapseTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, model.notchExpanded, !keepsVoiceHUDVisible else { return }
            collapse()
        }
    }
    func pointerEnteredNotch() {
        hoverCollapseTask?.cancel()
        hoverCollapseTask = nil
    }
    func collapse() {
        guard model.notchExpanded || model.notchMounted else { return }
        let token = UUID(); transitionID = token; collapseTask?.cancel()
        model.notchExpanded = false
        let delay: Duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .zero : .milliseconds(170)
        collapseTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, transitionID == token, !model.notchExpanded else { return }
            model.notchMounted = false
            setNotchFrame(expanded: false)
        }
    }
    func activityChanged() {
        if model.isRecording { capture?.orderOut(nil) }
        if model.voiceIsRecording || model.isRecording {
            // Keep receipts in Home without letting an older action interrupt
            // the recording HUD, or reopen it after this new dictation finishes.
            if let receipt = model.activeVoiceFeedback { model.dismissNotchFeedback(receipt.id) }
            feedbackID = model.notchVoiceFeedback?.id
        }
        if keepsVoiceHUDVisible {
            if !model.isRecording { expandForVoice() }
        }
        if let feedback = model.notchVoiceFeedback, feedback.id != feedbackID,
           !model.voiceIsRecording, !model.isRecording, model.voice.state != "finishing" {
            feedbackID = feedback.id
            expand()
        } else if model.notchVoiceFeedback == nil {
            feedbackID = nil
        }
        feedbackLifetime.update(feedback: model.notchVoiceFeedback, busy: keepsVoiceHUDVisible)
        updateNotch()
    }
    /// Shows or ends a notch overlay: the setup guide's style preview or a model download.
    func setNotchStylePreview(_ active: Bool) {
        if active { expandForVoice() } else if !keepsVoiceHUDVisible { collapse() }
        updateNotch()
    }
    private var keepsVoiceHUDVisible: Bool {
        model.notchStylePreviewActive || model.speechDownloadActive || model.voiceIsRecording || model.isRecording || model.manualVoiceIsPreparing
            || model.manualVoiceIsFinishing || model.manualCleanupInProgress
            || model.queuedVoiceCaptureKind != nil || model.voice.state == "finishing"
            || model.voice.state == "working" || model.activeVoiceFeedback?.state == .working
    }
    func dismissCaptureUI() {
        collapse()
        capture?.orderOut(nil)
        model.showComposer = false
    }
    private func expandForVoice() {
        guard model.settings.notchEnabled, !model.notchExpanded else { return }
        // Keep the previously focused app/field active for later delivery.
        expand()
    }
    func shutdown() {
        feedbackLifetime.cancel()
        collapseTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        notch?.close(); capture?.close(); workspace.window?.close()
    }
    private var preferredScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first }
    private func setNotchFrame(expanded: Bool) {
        guard let screen = preferredScreen else { return }
        let size = model.settings.notchSize
        let closed = NotchLayout.closedSize(cameraWidth: model.notchCameraWidth, cameraHeight: model.notchCameraHeight, hasCamera: model.notchHasCamera, size: size)
        let width: CGFloat = expanded ? NotchLayout.expandedWidth(cameraWidth: model.notchCameraWidth, hasCamera: model.notchHasCamera, size: size) : closed.width
        let height: CGFloat = expanded ? NotchLayout.expandedHeight(cameraHeight: model.notchCameraHeight, size: size) : closed.height
        let top = model.notchHasCamera ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let frame = NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        if notch?.frame != frame { notch?.setFrame(frame, display: true) }
    }
    private func makePanel(acceptsKeyboardFocus: Bool = true) -> CompanionPanel {
        let panel = CompanionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.acceptsKeyboardFocus = acceptsKeyboardFocus
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]; panel.isMovable = false
        return panel
    }
}
