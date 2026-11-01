import Observation
import SwiftUI
import UIUICore

enum UIUIStyle {
    /// Observable, so every view that reads the accent redraws the moment it changes.
    @Observable final class AccentStore {
        var rgb = UIUIAccent.lime.resolved(customHex: "")
        var ink = UIUIAccent.lime.resolvedInk(customHex: "")
    }
    @MainActor static let accentStore = AccentStore()
    /// The chosen accent colour. AppModel updates it when the setting changes.
    @MainActor static var accent: Color { color(accentStore.rgb) }
    @MainActor static func apply(_ choice: UIUIAccent, customHex: String) {
        let rgb = choice.resolved(customHex: customHex)
        let ink = choice.resolvedInk(customHex: customHex)
        if accentStore.rgb != rgb { accentStore.rgb = rgb }
        if accentStore.ink != ink { accentStore.ink = ink }
    }
    /// Accent for controls and links: the darker form on light backgrounds.
    @MainActor static func tint(_ scheme: ColorScheme) -> Color { scheme == .dark ? accent : color(accentStore.ink) }
    static func color(_ rgb: AccentRGB) -> Color { Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
    static let ink = Color(red: 0.12, green: 0.14, blue: 0.12)
    static let muted = Color.secondary
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.105, green: 0.115, blue: 0.105) : Color(red: 0.975, green: 0.974, blue: 0.958)
    }
}

struct UIUIMark: View {
    var size: CGFloat = 30
    var dark = false
    var accent: Color = UIUIStyle.accent
    /// The eye glint. At notch size it reads as a chip out of the eye.
    var highlight = true
    var body: some View {
        HStack(spacing: size * 0.12) {
            ForEach(0..<2) { _ in
                RoundedRectangle(cornerRadius: size * 0.13)
                    .fill(dark ? accent : UIUIStyle.ink)
                    .frame(width: size * 0.22, height: size * 0.40)
                    .overlay(alignment: .topTrailing) {
                        if highlight {
                            Circle().fill(dark ? Color.black : accent)
                                .frame(width: size * 0.075, height: size * 0.075)
                                .offset(x: -size * 0.04, y: size * 0.055)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .background(dark ? Color.clear : accent, in: RoundedRectangle(cornerRadius: size * 0.32))
        .accessibilityHidden(true)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var accent: Color = UIUIStyle.accent
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(UIUIStyle.ink)
            .padding(.horizontal, compact ? 10 : 15).padding(.vertical, compact ? 5 : 9)
            .background(accent.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: compact ? 6 : 9))
            .contentShape(RoundedRectangle(cornerRadius: compact ? 6 : 9))
    }
}

struct QuietIconButton: View {
    let symbol: String
    let label: String
    var tint: Color = .secondary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint).frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct ModelStatusView: View {
    let model: AppModel
    var body: some View {
        if let error = model.errorMessage, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                .lineLimit(3).accessibilityLabel("Error: \(error)")
        } else if !model.statusMessage.isEmpty {
            Text(model.statusMessage).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// Flared, concave top shoulders join the screen edge; lower corners round inward.
/// Shared by the content clip and the native panel's animated reveal mask.
struct NotchContour: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite,
              rect.width > 0, rect.height > 0 else { return Path() }
        let width = rect.width
        let height = rect.height
        let requestedTop = topRadius.isFinite ? max(0, topRadius) : 0
        let requestedBottom = bottomRadius.isFinite ? max(0, bottomRadius) : 0
        let top = min(requestedTop, width / 2, height)
        let bottom = min(requestedBottom, max(0, (width - 2 * top) / 2), max(0, height - top))
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x, y: rect.minY + y)
        }
        var path = Path()
        path.move(to: point(0, 0))
        path.addQuadCurve(to: point(top, top), control: point(top, 0))
        path.addLine(to: point(top, height - bottom))
        path.addQuadCurve(to: point(top + bottom, height), control: point(top, height))
        path.addLine(to: point(width - top - bottom, height))
        path.addQuadCurve(to: point(width - top, height - bottom), control: point(width - top, height))
        path.addLine(to: point(width - top, top))
        path.addQuadCurve(to: point(width, 0), control: point(width - top, 0))
        path.closeSubpath()
        return path
    }
}
