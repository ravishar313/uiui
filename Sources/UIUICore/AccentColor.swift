import Foundation

/// An sRGB colour with components from 0 to 1.
public struct AccentRGB: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red)); self.green = min(1, max(0, green)); self.blue = min(1, max(0, blue))
    }

    /// Parses `RRGGBB` with or without a leading `#`.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }

    public var hex: String {
        let byte = { (value: Double) in Int((value * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        let linear = { (value: Double) in value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrast(with other: AccentRGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    private func mixed(with other: AccentRGB, _ amount: Double) -> AccentRGB {
        AccentRGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                  blue: blue + (other.blue - blue) * amount)
    }

    private func moved(towards other: AccentRGB, until done: (AccentRGB) -> Bool) -> AccentRGB {
        for step in 0...50 {
            let candidate = mixed(with: other, Double(step) / 50)
            if done(candidate) { return candidate }
        }
        return other
    }

    /// Bright enough to read on the black notch and to carry dark ink on a button.
    public var legibleAccent: AccentRGB {
        moved(towards: AccentRGB(red: 1, green: 1, blue: 1)) { $0.luminance >= 0.35 }
    }

    /// Dark enough for links and controls on the light window background.
    public var legibleInk: AccentRGB {
        let paper = AccentRGB(red: 0.975, green: 0.974, blue: 0.96)
        return moved(towards: AccentRGB(red: 0, green: 0, blue: 0)) { $0.contrast(with: paper) >= 4.5 }
    }
}

/// The colour choices offered in Settings. `custom` uses a colour the person picked.
public enum UIUIAccent: String, Codable, CaseIterable, Identifiable, Sendable {
    case lime, mint, sky, lavender, rose, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lime: "Lime"
        case .mint: "Mint"
        case .sky: "Sky"
        case .lavender: "Lavender"
        case .rose: "Rose"
        case .custom: "Custom"
        }
    }
    public var preset: AccentRGB? {
        switch self {
        case .lime: AccentRGB(red: 0.79, green: 0.94, blue: 0.40)
        case .mint: AccentRGB(red: 0.45, green: 0.92, blue: 0.72)
        case .sky: AccentRGB(red: 0.47, green: 0.78, blue: 1.00)
        case .lavender: AccentRGB(red: 0.74, green: 0.68, blue: 1.00)
        case .rose: AccentRGB(red: 1.00, green: 0.62, blue: 0.72)
        case .custom: nil
        }
    }
    /// The colour to draw with. An invalid custom value falls back to lime.
    public func resolved(customHex: String) -> AccentRGB {
        let lime = AccentRGB(red: 0.79, green: 0.94, blue: 0.40)
        return (preset ?? AccentRGB(hex: customHex) ?? lime).legibleAccent
    }
    /// The darker form for light backgrounds.
    public func resolvedInk(customHex: String) -> AccentRGB {
        if self == .lime { return AccentRGB(red: 0.30, green: 0.42, blue: 0.12) }
        return resolved(customHex: customHex).legibleInk
    }
}
