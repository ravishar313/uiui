import AppKit
import SwiftUI

final class CompanionPanel: NSPanel {
    var acceptsKeyboardFocus = true
    override var canBecomeKey: Bool { acceptsKeyboardFocus }
    override var canBecomeMain: Bool { false }
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
    private let pauseHotKey = PauseHotKey()
    private let ownsSystemHooks: Bool
    private var feedbackID: UUID?
    /// The display the notch stays on while in use, so it never moves mid-capture.
    private var heldDisplay: UInt32?
    private var askWasVisible = false
    private lazy var feedbackLifetime = NotchFeedbackLifetime { [weak self] id, clearReceipt in
        guard let self, model.activeVoiceFeedback?.id == id,
              !keepsVoiceHUDVisible else { return false }
        if clearReceipt { model.dismissNotchFeedback(id) }
        collapse()
        return true
    }

    init(model: AppModel, installSystemObservers: Bool = true) {
        self.model = model
        ownsSystemHooks = installSystemObservers
        workspace = WorkspaceWindowLifetime(model: model) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "uiui"; window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
            window.tabbingMode = .disallowed
            window.minSize = NSSize(width: 680, height: 460); window.isReleasedWhenClosed = false; window.isRestorable = false
            window.contentView = NSHostingView(rootView: LibraryView(model: model)); window.center()
            return window
        }
        guard installSystemObservers else { return }
        pauseHotKey.onPress = { [weak model] in model?.toggleVoicePause() }
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
    func updateNotch(opening: Bool = false) {
        guard model.settings.notchEnabled else { collapseTask?.cancel(); model.notchExpanded = false; model.notchMounted = false; heldDisplay = nil; notch?.orderOut(nil); return }
        let inUse = opening || model.notchExpanded || model.notchMounted || keepsVoiceHUDVisible
        if !inUse { heldDisplay = nil }
        guard let (screen, placement) = notchScreen(inUse: inUse) else { return }
        if inUse { heldDisplay = Self.displayID(screen) }
        model.notchHasCamera = placement.shape == .cameraNotch
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { model.notchCameraWidth = max(160, right.minX - left.maxX) }
        else { model.notchCameraWidth = 180 }
        model.notchCameraHeight = model.notchHasCamera ? max(32, screen.safeAreaInsets.top) : 0
        if notch == nil {
            let panel = makePanel(acceptsKeyboardFocus: false); panel.level = .statusBar; panel.hasShadow = false
            panel.contentView = NSHostingView(rootView: NotchStage(model: model, onExpand: { [weak self] in self?.expand(inPlace: true) }, onCollapse: { [weak self] in self?.collapse() },
                                                                onPointerEnter: { [weak self] in self?.pointerEnteredNotch() },
                                                                onPointerExit: { [weak self] in self?.pointerLeftNotch() },
                                                                onLayoutChange: { [weak self] in
                                                                    guard let self, model.notchMounted else { return }
                                                                    setNotchFrame(expanded: true)
                                                                }))
            notch = panel
        }
        setNotchFrame(expanded: model.notchExpanded || model.notchMounted)
        // At rest a pill would be a black shape with nothing to say. The camera
        // notch stays because it blends into the hardware and answers the pointer.
        if placement.shape == .floatingPill, !inUse { notch?.orderOut(nil) }
        else if notch?.isVisible == false { notch?.orderFrontRegardless() }
    }
    /// `inPlace` opens where the person pointed rather than where keyboard focus is.
    func expand(inPlace: Bool = false) {
        guard model.settings.notchEnabled else { return }
        guard !model.notchExpanded else { return }
        transitionID = UUID(); collapseTask?.cancel(); collapseTask = nil
        if inPlace, let screen = notch?.screen { heldDisplay = Self.displayID(screen) }
        updateNotch(opening: true)
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
            updateNotch()
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
        let askVisible = model.askPresentation != nil
        if askWasVisible, !askVisible, !keepsVoiceHUDVisible { collapse() }
        askWasVisible = askVisible
        feedbackLifetime.update(feedback: model.notchVoiceFeedback, busy: keepsVoiceHUDVisible)
        // Control-Option-P exists only while a capture can be paused.
        if ownsSystemHooks { pauseHotKey.setEnabled(model.canPauseVoiceCapture) }
        updateNotch()
    }
    /// Shows or ends a notch overlay: the setup guide's style preview or a model download.
    func setNotchStylePreview(_ active: Bool) {
        if active { expandForVoice() } else if !keepsVoiceHUDVisible { collapse() }
        updateNotch()
    }
    private var keepsVoiceHUDVisible: Bool {
        model.askPresentation != nil || model.notchStylePreviewActive || model.speechDownloadActive || model.voiceIsRecording || model.isRecording || model.manualVoiceIsPreparing
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
        pauseHotKey.setEnabled(false)
        feedbackLifetime.cancel()
        collapseTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        notch?.close(); capture?.close(); workspace.window?.close()
    }
    /// The geometry decision itself is pure (NotchPlacement).
    private func notchScreen(inUse: Bool) -> (NSScreen, NotchPlacement)? {
        let screens = NSScreen.screens
        let main = NSScreen.main
        let described = screens.map { screen in
            NotchPlacement.Screen(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                  safeAreaTop: screen.safeAreaInsets.top, isMain: screen == main,
                                  id: Self.displayID(screen) ?? 0)
        }
        guard let placement = NotchPlacement.decide(screens: described, inUse: inUse, heldDisplay: heldDisplay) else { return nil }
        return (screens[placement.screenIndex], placement)
    }
    private static func displayID(_ screen: NSScreen) -> UInt32? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
    private func setNotchFrame(expanded: Bool) {
        guard let (_, placement) = notchScreen(inUse: heldDisplay != nil) else { return }
        let size = model.settings.notchSize
        let closed = NotchLayout.closedSize(cameraWidth: model.notchCameraWidth, cameraHeight: model.notchCameraHeight, hasCamera: model.notchHasCamera, size: size)
        let width: CGFloat = expanded ? NotchLayout.expandedWidth(cameraWidth: model.notchCameraWidth, hasCamera: model.notchHasCamera, size: size) : closed.width
        let height: CGFloat = expanded
            ? NotchLayout.expandedHeight(cameraHeight: model.notchCameraHeight, size: size, transcriptOpen: model.notchExtras.transcriptOpen)
            : closed.height
        var frameSize = CGSize(width: width, height: height)
        if expanded, let ask = model.askPresentation {
            frameSize = NotchLayout.askSize(ask, cameraWidth: model.notchCameraWidth, cameraHeight: model.notchCameraHeight,
                                            hasCamera: model.notchHasCamera, size: size)
        }
        let frame = placement.frame(size: frameSize)
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
