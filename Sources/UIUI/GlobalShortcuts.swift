import AppKit
import ApplicationServices
import Carbon
import IOKit.hidsystem
import UIUICore

/// Reads the chosen modifier's transitions. A key-combination trigger is a
/// registered system hot key: macOS delivers only that combination's press and
/// release, which works without Accessibility. For key or mouse chords, reads only
/// their event type and scroll phases to cancel a chord. During active
/// capture only, a separate active event tap consumes Escape and its matching release. No characters or key
/// history are read or retained. All other events retain their normal behavior.
@MainActor
final class GlobalShortcuts {
    var onVoicePressed: (() -> Void)?
    var onVoiceReleased: (() -> Void)?
    var onVoiceCancelled: (() -> Void)?
    var onEscape: (() -> Void)?
    var onStatusChanged: ((String) -> Void)?
    private(set) var registered = false
    private(set) var status = "Voice key is off."

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var escapeLocalMonitor: Any?
    private var escapeEventTap: CFMachPort?
    private var escapeEventSource: CFRunLoopSource?
    private var suppressEscapeUntilKeyUp = false
    private var escapeCancellationDelivered = false
    private var escapeMonitorIssue: String?
    private var baseStatus = "Voice key is off."
    private let globalAccessCheck: () -> Bool
    private let createEscapeTap: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?
    private(set) var escapeCancellationEnabled = false
    private let observesSystemEvents: Bool
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var filter = VoiceTriggerFilter()
    private var enabled = false
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeyIssue: String?
    private static let hotKeySignature: OSType = 0x75697569 // "uiui"

    init(observesSystemEvents: Bool = true,
         globalAccessCheck: @escaping () -> Bool = AXIsProcessTrusted,
         createEscapeTap: ((CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?)? = nil) {
        self.observesSystemEvents = observesSystemEvents
        self.globalAccessCheck = globalAccessCheck
        self.createEscapeTap = createEscapeTap ?? { mask, callback, userInfo in
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                              options: .defaultTap, eventsOfInterest: mask,
                              callback: callback, userInfo: userInfo)
        }
    }

    deinit {
        // The callback holds an unretained owner, so invalidate before it disappears.
        if let escapeLocalMonitor { NSEvent.removeMonitor(escapeLocalMonitor) }
        if let escapeEventTap { CFMachPortInvalidate(escapeEventTap) }
        if let escapeEventSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), escapeEventSource, .commonModes)
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    func install(key: VoiceTriggerKey, enabled: Bool) {
        // Other settings can change without interrupting a held trigger.
        guard self.enabled != enabled || filter.key != key else { return }
        remove()
        self.enabled = enabled
        _ = filter.configure(key: key)
        guard enabled, observesSystemEvents else { return }
        if !key.isModifierOnly { registerHotKey(key) }

        // Apple documents that both event-monitor handlers run on the main thread.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGlobalAccess() }
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Without global access a release outside the app cannot arrive.
                guard let self, !self.registered else { return }
                self.deliver(self.filter.reset())
            }
        }
        refreshGlobalAccess()
    }

    func remove() {
        setEscapeCancellationEnabled(false)
        enabled = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        localMonitor = nil
        globalMonitor = nil
        unregisterHotKey()
        activationObserver = nil
        deactivationObserver = nil
        registered = false
        deliver(filter.reset())
        updateStatus("Voice key is off.")
    }

    func refreshGlobalAccess() {
        refreshEscapeMonitor()
        guard enabled else { return }
        if !filter.key.isModifierOnly {
            // The hot key needs no Accessibility; the global monitor only adds
            // hold-mode chord cancellation in other apps when access exists.
            if globalAccessCheck(), globalMonitor == nil {
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                    self?.handle(event, canConsumeEscape: false)
                }
            }
            registered = hotKey != nil
            updateStatus(registered ? "\(filter.key.title) is ready in uiui and other apps."
                : hotKeyIssue ?? "\(filter.key.title) couldn’t be registered. Choose another shortcut.")
            return
        }
        guard globalAccessCheck() else {
            let lostGlobalAccess = globalMonitor != nil || registered
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            globalMonitor = nil
            registered = false
            // Activation can arrive between Fn down and up. Local-only access
            // stays local-only across that refresh; preserve its clean gesture.
            // Actual access loss still cancels a key whose release may be lost.
            if lostGlobalAccess { deliver(filter.reset()) }
            updateStatus(localMonitor == nil
                ? "Voice key unavailable. Turn it off and on to try again."
                : "\(filter.key.title) works while uiui is active. Allow Accessibility access for use in other apps.")
            return
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                self?.handle(event, canConsumeEscape: false)
            }
        }
        registered = globalMonitor != nil && localMonitor != nil
        updateStatus(registered
            ? "\(filter.key.title) is ready in uiui and other apps."
            : "Global voice key unavailable. \(filter.key.title) works only while uiui is active.")
    }

    /// The only global key filter: installed for startup, recording and finalization.
    /// After cancellation it stays just long enough to swallow the held Escape's
    /// repeats and keyup, even when onEscape synchronously disables cancellation.
    func setEscapeCancellationEnabled(_ value: Bool) {
        if value && !escapeCancellationEnabled { escapeCancellationDelivered = false }
        escapeCancellationEnabled = value
        refreshEscapeMonitor()
    }

    private var needsEscapeEvents: Bool { escapeCancellationEnabled || suppressEscapeUntilKeyUp }

    private func refreshEscapeMonitor() {
        guard observesSystemEvents else { return }
        guard needsEscapeEvents else {
            if let escapeLocalMonitor { NSEvent.removeMonitor(escapeLocalMonitor) }
            escapeLocalMonitor = nil
            removeEscapeTap()
            setEscapeMonitorIssue(nil)
            return
        }
        // A local filter also supports in-app cancellation without global access.
        if escapeLocalMonitor == nil {
            escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handleEscape(event) == true ? nil : event
            }
        }
        guard globalAccessCheck() else {
            removeEscapeTap()
            setEscapeMonitorIssue("Escape cancels only while uiui is active. Allow Accessibility access for cancellation in other apps.")
            return
        }
        if let tap = escapeEventTap, !CFMachPortIsValid(tap) { removeEscapeTap() }
        if escapeEventTap == nil {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            let callback: CGEventTapCallBack = { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                // This source is attached only to the main run loop.
                return MainActor.assumeIsolated {
                    Unmanaged<GlobalShortcuts>.fromOpaque(userInfo).takeUnretainedValue()
                        .filterEscapeEvent(type: type, event: event)
                }
            }
            guard let tap = createEscapeTap(mask, callback, Unmanaged.passUnretained(self).toOpaque()) else {
                setEscapeMonitorIssue("Global Escape cancellation unavailable. Escape cancels only while uiui is active.")
                return
            }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                setEscapeMonitorIssue("Global Escape cancellation unavailable. Escape cancels only while uiui is active.")
                return
            }
            escapeEventTap = tap
            escapeEventSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = escapeEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            setEscapeMonitorIssue(CGEvent.tapIsEnabled(tap: tap) ? nil
                : "Global Escape cancellation unavailable. Escape cancels only while uiui is active.")
        }
    }

    private func removeEscapeTap() {
        if let escapeEventTap { CFMachPortInvalidate(escapeEventTap) }
        if let escapeEventSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), escapeEventSource, .commonModes)
        }
        escapeEventTap = nil
        escapeEventSource = nil
    }

    /// Internal seam runs the same callback used by Quartz, including nil to consume.
    func filterEscapeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A disabled tap receives no ordinary events until explicitly re-enabled.
            refreshEscapeMonitor()
            return Unmanaged.passUnretained(event)
        }
        // Check the session/drain gate before reading any key identity.
        guard needsEscapeEvents, type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }
        return consumeEscape(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                             isKeyDown: type == .keyDown) ? nil : Unmanaged.passUnretained(event)
    }

    @discardableResult
    func handleEscape(_ event: NSEvent) -> Bool {
        guard needsEscapeEvents, event.type == .keyDown || event.type == .keyUp else { return false }
        return consumeEscape(keyCode: Int64(event.keyCode), isKeyDown: event.type == .keyDown)
    }

    private func consumeEscape(keyCode: Int64, isKeyDown: Bool) -> Bool {
        guard keyCode == 53 else { return false }
        if suppressEscapeUntilKeyUp {
            if !isKeyDown {
                suppressEscapeUntilKeyUp = false
                refreshEscapeMonitor()
            }
            return true
        }
        guard escapeCancellationEnabled, !escapeCancellationDelivered, isKeyDown else { return false }
        suppressEscapeUntilKeyUp = true
        escapeCancellationDelivered = true
        _ = filter.reset() // A later Fn release must never finish or paste this capture.
        onEscape?() // Synchronous cancellation; no timer or main-queue hop.
        return true
    }

    @discardableResult
    func handle(_ event: NSEvent, canConsumeEscape: Bool = true) -> Bool {
        // Only a consuming path may cancel Escape. NSEvent's global monitor cannot
        // stop delivery to another app; the active Quartz tap owns that path.
        if canConsumeEscape && handleEscape(event) { return true }
        guard enabled else { return false }
        // Privacy boundary: ordinary events contribute only their type and scroll
        // phases while the configured modifier is down. No ordinary key
        // identity or characters are read, copied, stored, or logged.
        if event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown || event.type == .scrollWheel {
            guard filter.isPressed else { return false }
            // A combination trigger's own key repeat is not a new chord. Only
            // equality with the configured key code is checked.
            if !filter.key.isModifierOnly, event.type == .keyDown, event.keyCode == filter.key.keyCode { return false }
            // Trackpad inertia continues after the fingers leave the surface.
            // It belongs to the earlier scroll, not a new Fn/key combination.
            if event.type == .scrollWheel, !event.momentumPhase.isEmpty { return false }
            // The previous gesture can also end after Fn goes down, before any
            // momentum begins. Its completion is not a new scroll chord.
            if event.type == .scrollWheel,
               !event.phase.intersection([.ended, .cancelled]).isEmpty,
               event.phase.intersection([.began, .changed]).isEmpty { return false }
            deliver(filter.cancelChord())
            return false
        }
        // Combination triggers arrive as hot-key events; modifier changes while
        // one is held never finish or cancel it.
        guard event.type == .flagsChanged, filter.key.isModifierOnly,
              let modifier = Self.modifierMasks[filter.key.keyCode] else { return false }
        let flags = event.modifierFlags
        // Device-specific flags distinguish left and right keys when the other stays down.
        let isDown = flags.rawValue & modifier.device != 0
        let chordFlags: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
        let hasOtherModifiers = !flags.intersection(chordFlags).subtracting(modifier.flag).isEmpty
            || flags.rawValue & modifier.oppositeDevice != 0
        guard event.keyCode == filter.key.keyCode else {
            // Adding another modifier also turns a clean tap into a chord.
            if filter.isPressed && hasOtherModifiers { deliver(filter.cancelChord()) }
            return false
        }
        deliver(filter.handle(keyCode: event.keyCode, isDown: isDown, hasOtherModifiers: hasOtherModifiers))
        return false
    }

    /// Device mask, generic flag and the opposite-side device mask for each
    /// modifier that can be a trigger on its own.
    private static let modifierMasks: [UInt16: (device: UInt, flag: NSEvent.ModifierFlags, oppositeDevice: UInt)] = [
        63: (NSEvent.ModifierFlags.function.rawValue, .function, 0),
        59: (UInt(NX_DEVICELCTLKEYMASK), .control, UInt(NX_DEVICERCTLKEYMASK)),
        62: (UInt(NX_DEVICERCTLKEYMASK), .control, UInt(NX_DEVICELCTLKEYMASK)),
        58: (UInt(NX_DEVICELALTKEYMASK), .option, UInt(NX_DEVICERALTKEYMASK)),
        61: (UInt(NX_DEVICERALTKEYMASK), .option, UInt(NX_DEVICELALTKEYMASK)),
        55: (UInt(NX_DEVICELCMDKEYMASK), .command, UInt(NX_DEVICERCMDKEYMASK)),
        54: (UInt(NX_DEVICERCMDKEYMASK), .command, UInt(NX_DEVICELCMDKEYMASK)),
        56: (UInt(NX_DEVICELSHIFTKEYMASK), .shift, UInt(NX_DEVICERSHIFTKEYMASK)),
        60: (UInt(NX_DEVICERSHIFTKEYMASK), .shift, UInt(NX_DEVICELSHIFTKEYMASK))
    ]

    /// Internal seam for the hot-key callback and tests.
    func handleHotKey(isDown: Bool) {
        guard enabled, !filter.key.isModifierOnly else { return }
        deliver(filter.handle(keyCode: filter.key.keyCode, isDown: isDown, hasOtherModifiers: false))
    }

    private func registerHotKey(_ key: VoiceTriggerKey) {
        unregisterHotKey()
        if hotKeyHandler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let callback: EventHandlerUPP = { _, event, userInfo in
                guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == GlobalShortcuts.hotKeySignature else { return OSStatus(eventNotHandledErr) }
                let isDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                // The application event target dispatches on the main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<GlobalShortcuts>.fromOpaque(userInfo).takeUnretainedValue().handleHotKey(isDown: isDown)
                }
                return noErr
            }
            let status = InstallEventHandler(GetApplicationEventTarget(), callback, types.count, &types,
                                             Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
            guard status == noErr else {
                hotKeyHandler = nil
                hotKeyIssue = "\(key.title) couldn’t be registered. Choose another shortcut."
                return
            }
        }
        var carbonModifiers: UInt32 = 0
        if key.modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if key.modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if key.modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if key.modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key.keyCode), carbonModifiers,
                                         EventHotKeyID(signature: Self.hotKeySignature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKey = ref
            hotKeyIssue = nil
        } else {
            hotKeyIssue = status == OSStatus(eventHotKeyExistsErr)
                ? "\(key.title) is already used by macOS or another app. Choose another shortcut."
                : "\(key.title) couldn’t be registered. Choose another shortcut."
        }
    }

    private func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        hotKeyIssue = nil
    }

    private func deliver(_ transition: VoiceTriggerTransition?) {
        switch transition {
        case .pressed: onVoicePressed?()
        case .released: onVoiceReleased?()
        case .cancelled: onVoiceCancelled?()
        case nil: break
        }
    }

    private func setEscapeMonitorIssue(_ value: String?) {
        escapeMonitorIssue = value
        updateStatus(baseStatus)
    }

    private func updateStatus(_ value: String) {
        baseStatus = value
        let value = escapeMonitorIssue.map { "\(value) \($0)" } ?? value
        guard status != value else { return }
        status = value
        onStatusChanged?(value)
    }
}
