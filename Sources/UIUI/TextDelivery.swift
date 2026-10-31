import AppKit
import ApplicationServices
import Carbon

struct DeliveryTarget {
    fileprivate let application: NSRunningApplication
    var appName: String? { application.localizedName }
    var appPID: pid_t { application.processIdentifier }
}

enum DeliveryResult {
    /// A paste event was dispatched to the validated target. This does not prove insertion.
    case pasteSent
    case copied(String)
    case held(String)
}

@MainActor
protocol TextDelivering: AnyObject {
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult
    func cancel()
}

/// Owns a single normal paste after dictation stops. Accessibility is read-only:
/// it checks the current control in the anchored app and never edits external text or selection.
@MainActor
final class TextDelivery: TextDelivering {
    private(set) static var targetFailure = "No text field is focused."
    private var generation: UInt64 = 0
    private let payloadGate: PastePayloadGate
    private var leaseTask: Task<Void, Never>?
    private let dependencies: TextDeliveryDependencies

    init(dependencies: TextDeliveryDependencies? = nil, payloadGate: PastePayloadGate? = nil) {
        self.dependencies = dependencies ?? Self.nativeDependencies()
        self.payloadGate = payloadGate ?? PastePayloadGate()
    }

    /// Call before showing an activating UI. Reading the target never prompts for access.
    static func captureTarget() -> DeliveryTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { targetFailure = "No destination app is active."; return nil }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            targetFailure = "uiui still has keyboard focus. Click your destination text field first."
            return nil
        }
        // Keep the foreground app even when AX is unavailable. The current field
        // is resolved only when the completed dictation is ready to paste.
        targetFailure = AXIsProcessTrusted() ? "" : "Dictation will be copied. Allow Accessibility access for uiui to paste automatically."
        return DeliveryTarget(application: app)
    }

    /// Unsupported or unreadable attributes are unknown, not proof that an editor
    /// cannot accept normal Cmd-V. Preserve any positive protection signals.
    private static func readAttributes(in element: AXUIElement, keys: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &values)
        guard result == .success, let values = values as? [AnyObject], values.count == keys.count else { return [:] }
        var attributes: [String: CFTypeRef] = [:]
        for (key, value) in zip(keys, values) {
            if CFGetTypeID(value) != AXValueGetTypeID(), !(value is NSNull) {
                attributes[key] = value
            }
        }
        return attributes
    }

    private static func allowsPaste(_ attributes: [String: CFTypeRef]) -> Bool {
        TextDestinationPolicy.allowsPaste(
            role: attributes[kAXRoleAttribute] as? String,
            subrole: attributes[kAXSubroleAttribute] as? String,
            enabled: attributes[kAXEnabledAttribute] as? Bool,
            containsProtectedContent: attributes[NSAccessibility.Attribute.containsProtectedContent.rawValue] as? Bool
        )
    }

    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
        guard !text.isEmpty else { return .held("There is no text to paste.") }
        let token = generation
        guard !Task.isCancelled else { return .held("Paste cancelled. Your text is available to copy.") }
        // A queued dictation must not replace a payload that an earlier posted
        // paste may still be consuming. It owns no clipboard state before its turn.
        let lease = await payloadGate.acquire()
        var cleanupOwnsLease = false
        defer { if !cleanupOwnsLease { payloadGate.release(lease) } }
        guard token == generation, !Task.isCancelled else {
            return .held("Paste cancelled. Your text is available to copy.")
        }
        let preparation = dependencies.preparePaste(target)
        guard token == generation, !Task.isCancelled else {
            return .held("Paste cancelled. Your text is available to copy.")
        }
        guard dependencies.writeClipboard(text) else {
            return .held("The clipboard could not accept the text. Your text is available to copy.")
        }
        let ownChangeCount = dependencies.clipboardChangeCount()
        func copiedResult(_ reason: String) -> DeliveryResult {
            // AX validation can spend time in another process. Even copy-only
            // exits must not claim our payload survived a newer user's copy.
            guard dependencies.clipboardChangeCount() == ownChangeCount,
                  dependencies.clipboardMatches(text) else {
                return .held("The clipboard changed. Your text is available to copy.")
            }
            return .copied(reason)
        }
        let prepared: TextDeliveryDependencies.PreparedPaste
        switch preparation {
        case .unavailable(let reason):
            return copiedResult(reason)
        case .ready(let paste): prepared = paste
        }
        // Physical shortcut modifiers must be released before one normal Cmd-V.
        // This is the only bounded polling period; no idle observation is installed.
        let modifiersReleased = await dependencies.waitForModifiersReleased()
        guard token == generation, !Task.isCancelled else {
            return .held("Paste cancelled. Your text is available to copy.")
        }
        guard dependencies.clipboardChangeCount() == ownChangeCount,
              dependencies.clipboardMatches(text) else {
            return .held("The clipboard changed. Your text is available to copy.")
        }
        guard modifiersReleased else {
            return copiedResult("Shortcut keys are still held. Your dictation is copied; release them and paste when ready.")
        }
        // Validation resolves the current field and ends with a foreground-app
        // check. There is no suspension between this check and event dispatch.
        guard prepared.validate() else {
            return copiedResult("The destination changed or cannot accept paste. Your dictation is copied to the clipboard.")
        }
        guard token == generation, !Task.isCancelled,
              dependencies.clipboardChangeCount() == ownChangeCount,
              dependencies.clipboardMatches(text) else {
            return .held("Paste cancelled or the clipboard changed. Your text is available to copy.")
        }
        guard prepared.canDispatch() else {
            return copiedResult("The destination or shortcut keys changed. Your dictation is copied to the clipboard.")
        }
        // Clipboard state and another process's key handling are not atomic.
        // The guard prevents known newer copies before dispatch; the 400ms lease
        // protects against our own next delivery, never against a user's copy.
        prepared.post()

        // Return immediately after dispatch. The lease alone survives for 400ms;
        // it never restores old clipboard data or overwrites a newer user copy.
        cleanupOwnsLease = true
        leaseTask = Task { [self] in
            await dependencies.waitForPasteConsumption()
            leaseTask = nil
            payloadGate.release(lease)
        }
        return .pasteSent
    }

    private static func nativeDependencies() -> TextDeliveryDependencies {
        TextDeliveryDependencies(
            writeClipboard: { text in
                ClipboardWriteTransaction.write(text, using: .native(NSPasteboard.general))
            },
            clipboardChangeCount: { NSPasteboard.general.changeCount },
            preparePaste: { target in
                guard AXIsProcessTrusted() else {
                    return .unavailable("Dictation copied. Enable uiui in System Settings → Privacy & Security → Accessibility to paste automatically.")
                }
                // A fresh Accessibility grant often reaches event posting only
                // after relaunch; without it the posted Command-V is dropped silently.
                guard CGPreflightPostEventAccess() else {
                    return .unavailable("Dictation copied. Quit and reopen uiui so macOS applies its Accessibility access, then paste works automatically.")
                }
                guard let target else {
                    return .unavailable(Self.targetFailure.isEmpty ? "Dictation copied. Focus your destination text field to paste automatically." : Self.targetFailure)
                }
                if let reason = Self.secureInputBlockReason(for: target) { return .unavailable(reason) }
                guard Self.currentDestinationAllowsPaste(target) else {
                    return .unavailable("The destination changed or isn’t a text field. Your dictation is copied to the clipboard.")
                }
                let vKey = Self.pasteKeyCode()
                guard let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
                    return .unavailable("macOS could not prepare a paste event. Your dictation is copied to the clipboard.")
                }
                down.flags = .maskCommand
                // End our synthetic shortcut with no modifiers. Leaving Command
                // on key-up can contaminate the state seen by the next paste.
                up.flags = []
                return .ready(.init(
                    validate: { Self.currentDestinationAllowsPaste(target) },
                    // Use the normal hardware event stream so AppKit and browser
                    // key-equivalent routing perform standard Command-V handling.
                    // The foreground app is rechecked immediately before this.
                    post: { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) },
                    canDispatch: { Self.physicalModifiersAreReleased && Self.secureInputBlockReason(for: target) == nil && Self.matchesForegroundApp(target) }
                ))
            },
            waitForPasteConsumption: {
                // Cancellation must not shorten an already posted key's grace.
                await Task.detached { try? await Task.sleep(for: .milliseconds(400)) }.value
            },
            waitForModifiersReleased: {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .milliseconds(700))
                while !Task.isCancelled {
                    if Self.physicalModifiersAreReleased { return true }
                    guard clock.now < deadline else { return false }
                    do { try await Task.sleep(for: .milliseconds(15)) }
                    catch { return false }
                }
                return false
            },
            clipboardMatches: { NSPasteboard.general.string(forType: .string) == $0 }
        )
    }

    /// Invalidates pending dispatches; a previously sent paste retains its consumption lease.
    func cancel() { generation &+= 1 }

    @discardableResult
    static func copy(_ text: String) -> Bool {
        ClipboardWriteTransaction.write(text, using: .native(NSPasteboard.general))
    }

    private static var physicalModifiersAreReleased: Bool {
        // Query actual modifier keys, not the aggregate flags that a synthetic
        // Command-V can leave set until the next real keyboard event.
        let keys: [CGKeyCode] = [54, 55, 56, 60, 58, 61, 59, 62, 63]
        return !keys.contains { CGEventSource.keyState(.hidSystemState, key: $0) }
    }

    /// Secure input is system-wide. The destination holding it (a password field,
    /// including from one of its helper processes) blocks paste. Another app's
    /// Secure Keyboard Entry does not, but then the focused field must positively
    /// read as a non-secure editor (see currentDestinationAllowsPaste).
    static func secureInputBlockReason(for target: DeliveryTarget) -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else {
            return "Secure keyboard entry is on, so macOS blocks automatic paste. Your dictation is copied."
        }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let ownerPath = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        let targetBundle = target.application.bundleURL?.standardizedFileURL.path
        let ownedByTarget = pid == target.appPID || ownerPath == nil
            || targetBundle.map { ownerPath!.hasPrefix($0 + "/") } == true
        guard ownedByTarget else { return nil }
        return "\(target.appName ?? "This app") is using secure keyboard entry (for example a password field or Terminal’s Secure Keyboard Entry). Your dictation is copied."
    }

    /// The key that types "v" with Command held in the current layout, so Dvorak,
    /// AZERTY and "Dvorak – QWERTY ⌘" layouts receive a real Command-V.
    static func pasteKeyCode() -> CGKeyCode {
        let ansiV: CGKeyCode = 9
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for case let source? in sources.map({ $0?.takeRetainedValue() }) {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            let found: CGKeyCode? = data.withUnsafeBytes { buffer in
                guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                func types(_ code: CGKeyCode) -> String? {
                    var deadKeys: UInt32 = 0, length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), UInt32((cmdKey >> 8) & 0xFF),
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                                &deadKeys, characters.count, &length, &characters)
                    return status == noErr && length > 0 ? String(utf16CodeUnits: characters, count: length).lowercased() : nil
                }
                if types(ansiV) == "v" { return ansiV }
                return (0..<128).map(CGKeyCode.init).first { types($0) == "v" }
            }
            if let found { return found }
        }
        return ansiV
    }

    private static func currentDestinationAllowsPaste(_ target: DeliveryTarget) -> Bool {
        guard AXIsProcessTrusted(), secureInputBlockReason(for: target) == nil, matchesForegroundApp(target) else { return false }
        // With secure input on somewhere, unknown is not good enough: a password
        // field elsewhere in the system must not receive the paste by accident.
        let needsEvidence = IsSecureEventInputEnabled()
        if let current = focusedElement(in: target.application) {
            var pid: pid_t = 0
            // A successful read identifying another app is a veto. Failed AX reads
            // remain unknown and leave ordinary paste routing to the anchored app.
            if AXUIElementGetPid(current, &pid) == .success, pid != target.appPID { return false }
            let attributes = readAttributes(in: current, keys: [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute, NSAccessibility.Attribute.containsProtectedContent.rawValue])
            if needsEvidence, attributes[kAXRoleAttribute] as? String == nil { return false }
            guard allowsPaste(attributes) else { return false }
        } else if needsEvidence {
            return false
        }
        return secureInputBlockReason(for: target) == nil && matchesForegroundApp(target)
    }

    private static func matchesForegroundApp(_ target: DeliveryTarget) -> Bool {
        !target.application.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.appPID
    }

    private static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        var value: CFTypeRef?
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.05)
        if AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.05)
            return element
        }
        // Some Electron builds expose the focused editor only through the system element.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        value = nil
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }
}

/// Clipboard-independent FIFO ownership. A posted paste keeps its lease until its
/// payload has had a chance to be consumed; stale releases cannot free another paste.
@MainActor
final class PastePayloadGate {
    private var active: UUID?
    private var waiters: [CheckedContinuation<UUID, Never>] = []
    var waitingCount: Int { waiters.count }

    func acquire() async -> UUID {
        if active == nil {
            let lease = UUID()
            active = lease
            return lease
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ lease: UUID) {
        guard active == lease else { return }
        guard !waiters.isEmpty else { active = nil; return }
        let next = UUID()
        active = next
        waiters.removeFirst().resume(returning: next)
    }
}

enum TextDestinationPolicy {
    static func allowsPaste(role: String?, subrole: String?, enabled: Bool?, containsProtectedContent: Bool?) -> Bool {
        guard subrole != kAXSecureTextFieldSubrole, enabled != false, containsProtectedContent != true else { return false }
        // Groups, web areas and custom/unknown roles can host browser editors.
        // Reject only roles that positively identify a non-editing control.
        let nonTextRoles = [kAXButtonRole, kAXStaticTextRole, kAXCheckBoxRole, kAXRadioButtonRole,
                            kAXSliderRole, kAXImageRole, kAXMenuItemRole, kAXMenuBarRole,
                            kAXScrollBarRole, kAXToolbarRole]
        if let role, nonTextRoles.contains(role) { return false }
        return true
    }
}

/// Narrow local seam for clipboard and keyboard effects. Tests supply in-memory
/// clipboard state and an explicit lease boundary, never the user's pasteboard.
struct TextDeliveryDependencies {
    struct PreparedPaste {
        let validate: @MainActor () -> Bool
        let post: @MainActor () -> Void
        let canDispatch: @MainActor () -> Bool

        init(validate: @escaping @MainActor () -> Bool,
             post: @escaping @MainActor () -> Void,
             canDispatch: @escaping @MainActor () -> Bool = { true }) {
            self.validate = validate
            self.post = post
            self.canDispatch = canDispatch
        }
    }
    enum Preparation {
        case unavailable(String)
        case ready(PreparedPaste)
    }
    let writeClipboard: @MainActor (String) -> Bool
    let clipboardChangeCount: @MainActor () -> Int
    let preparePaste: @MainActor (DeliveryTarget?) -> Preparation
    let waitForPasteConsumption: @MainActor () async -> Void
    let waitForModifiersReleased: @MainActor () async -> Bool
    let clipboardMatches: @MainActor (String) -> Bool

    init(writeClipboard: @escaping @MainActor (String) -> Bool,
         clipboardChangeCount: @escaping @MainActor () -> Int,
         preparePaste: @escaping @MainActor (DeliveryTarget?) -> Preparation,
         waitForPasteConsumption: @escaping @MainActor () async -> Void,
         waitForModifiersReleased: @escaping @MainActor () async -> Bool = { true },
         clipboardMatches: @escaping @MainActor (String) -> Bool = { _ in true }) {
        self.writeClipboard = writeClipboard
        self.clipboardChangeCount = clipboardChangeCount
        self.preparePaste = preparePaste
        self.waitForPasteConsumption = waitForPasteConsumption
        self.waitForModifiersReleased = waitForModifiersReleased
        self.clipboardMatches = clipboardMatches
    }
}

/// A failed string write may follow a successful clear. A materialized snapshot
/// enables best-effort failure recovery; unavailable old formats do not block a
/// deliberate completed-text copy. Successful copies never restore old data.
@MainActor
enum ClipboardWriteTransaction {
    static func write(_ text: String, using operations: ClipboardWriteOperations) -> Bool {
        let originalCount = operations.changeCount()
        let originalItems = operations.readItems()
        guard operations.changeCount() == originalCount else { return false }
        let clearCount = operations.clearContents()
        guard operations.changeCount() == clearCount else { return false }
        guard operations.writeString(text) else {
            // Another process's newer copy owns the board. Never restore over it.
            guard operations.changeCount() == clearCount, let originalItems else { return false }
            let restoreCount = operations.clearContents()
            guard operations.changeCount() == restoreCount else { return false }
            if !originalItems.isEmpty { _ = operations.writeItems(originalItems) }
            return false
        }
        return true
    }
}

/// The same primitive sequence is used by native delivery and in-memory tests.
/// Snapshot preparation is best effort and never permits overwriting a newer copy.
struct ClipboardWriteOperations {
    let changeCount: @MainActor () -> Int
    let readItems: @MainActor () -> [NSPasteboardItem]?
    let clearContents: @MainActor () -> Int
    let writeString: @MainActor (String) -> Bool
    let writeItems: @MainActor ([NSPasteboardItem]) -> Bool

    @MainActor
    static func native(_ pasteboard: NSPasteboard) -> ClipboardWriteOperations {
        ClipboardWriteOperations(
            changeCount: { pasteboard.changeCount },
            // Reading promised formats can invoke another app's data provider
            // synchronously. A deliberate completed-text copy must never depend
            // on materializing arbitrary old image/custom payloads.
            readItems: { nil },
            clearContents: { pasteboard.clearContents() },
            writeString: { pasteboard.setString($0, forType: .string) },
            writeItems: { pasteboard.writeObjects($0) }
        )
    }
}
