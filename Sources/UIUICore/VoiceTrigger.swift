import Foundation

/// The physical key that starts dictation. Either a single modifier key tapped or
/// held on its own (Fn, either Control/Option/Command/Shift), or any key with
/// optional modifiers (for example F5 or ⌃⌥Space). Stored as hardware key codes,
/// independent of keyboard layout and text input.
public struct VoiceTriggerKey: Codable, Hashable, Identifiable, Sendable {
    /// Device-independent modifier bits for key combinations.
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers
    /// The key's printed character when recorded, used only for display.
    public let label: String?

    public init(keyCode: UInt16, modifiers: Modifiers = [], label: String? = nil) {
        self.keyCode = keyCode
        // A lone modifier trigger never carries extra modifier bits.
        self.modifiers = Self.modifierKeyNames[keyCode] == nil ? modifiers : []
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = Self.namedKeys[keyCode] == nil && Self.modifierKeyNames[keyCode] == nil
            && trimmed?.isEmpty == false ? String(trimmed!.prefix(4)) : nil
    }

    public static let fn = VoiceTriggerKey(keyCode: 63)
    public static let leftControl = VoiceTriggerKey(keyCode: 59)
    public static let rightControl = VoiceTriggerKey(keyCode: 62)
    public static let leftOption = VoiceTriggerKey(keyCode: 58)
    public static let rightOption = VoiceTriggerKey(keyCode: 61)
    public static let leftCommand = VoiceTriggerKey(keyCode: 55)
    public static let rightCommand = VoiceTriggerKey(keyCode: 54)
    public static let leftShift = VoiceTriggerKey(keyCode: 56)
    public static let rightShift = VoiceTriggerKey(keyCode: 60)
    /// Single-modifier choices offered without recording.
    public static let presets: [VoiceTriggerKey] = [.fn, .rightOption, .rightCommand, .rightControl, .leftControl,
                                                    .leftOption, .rightShift]
    public static var allCases: [VoiceTriggerKey] { presets + [.leftCommand, .leftShift] }

    /// True when the trigger is one modifier key on its own.
    public var isModifierOnly: Bool { Self.modifierKeyNames[keyCode] != nil }
    public var id: String { "\(keyCode):\(modifiers.rawValue)" }

    public var title: String {
        if let name = Self.modifierKeyNames[keyCode] { return name }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.namedKeys[keyCode] ?? label?.uppercased() ?? "Key \(keyCode)")
        return parts.joined()
    }
    public var symbol: String {
        switch keyCode {
        case 63: return "globe"
        case 59, 62: return "control"
        case 58, 61: return "option"
        case 55, 54: return "command"
        case 56, 60: return "shift"
        default: return "keyboard"
        }
    }

    /// Why a combination is unsuitable, or nil when it can be used. Bare
    /// character keys would stop that character from being typed anywhere, and
    /// uiui's own Command-V paste would retrigger dictation.
    public var unsuitableReason: String? {
        if isModifierOnly { return nil }
        if keyCode == 53 { return "Escape is reserved for cancelling dictation." }
        if modifiers.isEmpty, !Self.standaloneKeys.contains(keyCode) {
            return "Add ⌃ or ⌘ to this key so you can still type it normally."
        }
        if modifiers == [.shift], !Self.standaloneKeys.contains(keyCode) {
            return "Shift alone types capitals. Add ⌃ or ⌘."
        }
        // macOS 15 refuses system hot keys whose only modifiers are Option or
        // Option-Shift, so they could never work.
        if modifiers.contains(.option), modifiers.isSubset(of: [.option, .shift]) {
            return "macOS doesn’t allow ⌥-only shortcuts. Add ⌃ or ⌘."
        }
        // Matched by character too: on Dvorak or AZERTY, ⌘V is another key code.
        if modifiers == [.command], Self.reservedCommandKeys.contains(keyCode)
            || label.map({ Self.reservedCommandCharacters.contains($0.lowercased()) }) == true {
            return "\(title) is a standard editing shortcut. Choose another combination."
        }
        return nil
    }

    // MARK: Coding. Earlier versions stored a bare string such as "fn".

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, label }
    private static let legacyNames: [String: VoiceTriggerKey] = [
        "fn": .fn, "leftControl": .leftControl, "rightControl": .rightControl, "rightOption": .rightOption
    ]

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            guard let legacy = Self.legacyNames[name] else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unknown trigger key \(name)")
            }
            self = legacy
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try values.decode(UInt16.self, forKey: .keyCode),
                  modifiers: Modifiers(rawValue: try values.decodeIfPresent(UInt.self, forKey: .modifiers) ?? 0),
                  label: try values.decodeIfPresent(String.self, forKey: .label))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(keyCode, forKey: .keyCode)
        try values.encode(modifiers.rawValue, forKey: .modifiers)
        try values.encodeIfPresent(label, forKey: .label)
    }

    // MARK: Key names (macOS virtual key codes)

    static let modifierKeyNames: [UInt16: String] = [
        63: "Fn / Globe", 59: "Left Control", 62: "Right Control", 58: "Left Option", 61: "Right Option",
        55: "Left Command", 54: "Right Command", 56: "Left Shift", 60: "Right Shift"
    ]
    static let namedKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20", 49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete",
        117: "Forward Delete", 53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home",
        119: "End", 116: "Page Up", 121: "Page Down", 114: "Help", 71: "Clear",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5",
        88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 65: "Keypad .", 67: "Keypad *",
        69: "Keypad +", 75: "Keypad /", 78: "Keypad -", 81: "Keypad ="
    ]
    /// Keys that may be used without a modifier: function keys and navigation keys
    /// that don't type text.
    static let standaloneKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                              105, 107, 113, 106, 64, 79, 80, 90, 114, 71]
    /// ⌘A, ⌘C, ⌘Q, ⌘V, ⌘W, ⌘X, ⌘Z on an ANSI layout.
    static let reservedCommandKeys: Set<UInt16> = [0, 8, 12, 9, 13, 7, 6]
    static let reservedCommandCharacters: Set<String> = ["a", "c", "q", "v", "w", "x", "z"]
}

public enum VoiceTriggerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case toggle
    case hold
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .toggle: return "Press to start, press to finish"
        case .hold: return "Hold to talk"
        }
    }
}

public enum VoiceTriggerTransition: Equatable, Sendable {
    case pressed
    case released
    case cancelled
}

/// Deduplicates only the configured physical key's transitions.
/// No ordinary key, character, event, or event history is retained.
public struct VoiceTriggerFilter: Sendable {
    public private(set) var key: VoiceTriggerKey
    public private(set) var isPressed = false
    private var isPhysicallyDown = false

    public init(key: VoiceTriggerKey = .fn) { self.key = key }

    public mutating func handle(keyCode: UInt16, isDown: Bool, hasOtherModifiers: Bool) -> VoiceTriggerTransition? {
        guard keyCode == key.keyCode else { return nil }
        if isDown == isPhysicallyDown {
            // A second press without a release means macOS swallowed the release
            // (⌘Tab, Spotlight, screenshots). Treat it as a fresh press instead of
            // ignoring it, which made the first tap after such a shortcut do nothing.
            guard isDown, !isPressed else { return nil }
        }
        isPhysicallyDown = isDown
        if isDown {
            guard !hasOtherModifiers else { return nil }
            isPressed = true
            return .pressed
        }
        guard isPressed else { return nil }
        isPressed = false
        return hasOtherModifiers ? .cancelled : .released
    }

    /// An ordinary key went down while the trigger was held. Its identity and text
    /// are irrelevant: cancel this gesture and wait for the physical release.
    public mutating func cancelChord() -> VoiceTriggerTransition? {
        guard isPressed else { return nil }
        isPressed = false
        return .cancelled
    }

    /// Disabling or changing the trigger cancels a held gesture exactly once.
    /// Only a physical release may complete a clean tap.
    @discardableResult
    public mutating func reset() -> VoiceTriggerTransition? {
        let transition: VoiceTriggerTransition? = isPressed ? .cancelled : nil
        isPressed = false
        isPhysicallyDown = false
        return transition
    }

    @discardableResult
    public mutating func configure(key: VoiceTriggerKey) -> VoiceTriggerTransition? {
        let transition = reset()
        self.key = key
        return transition
    }
}
