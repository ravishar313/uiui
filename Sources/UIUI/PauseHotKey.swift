import AppKit
import Carbon

/// Control-Option-P, registered with the system only while a capture is active.
/// It is a single registered hot key, not a key monitor: no other key is observed
/// and no characters are read. Unregistered the moment capture ends.
@MainActor
final class PauseHotKey {
    static let keyCode = UInt32(kVK_ANSI_P)
    static let modifiers = UInt32(controlKey | optionKey)
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var isRegistered = false

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard !isRegistered else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let owner = Unmanaged<PauseHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.onPress?() } }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                                  Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return }
        let id = EventHotKeyID(signature: OSType(0x55495550), id: 1)
        guard RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return
        }
        isRegistered = true
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; isRegistered = false
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
