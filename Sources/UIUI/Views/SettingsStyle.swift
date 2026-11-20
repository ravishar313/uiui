import SwiftUI

/// Quiet Paper pieces for Settings. Purely visual; the controls and wording live in the views.

/// Hairline between rows inside a card.
struct SettingsHairline: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(UIUIStyle.hair(scheme)).frame(height: 1).accessibilityHidden(true)
    }
}

/// Small capsule status: "Ready", "Connected".
struct StatusPill: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(UIUIStyle.tint(scheme))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(UIUIStyle.tint(scheme).opacity(scheme == .dark ? 0.16 : 0.15), in: Capsule())
    }
}

/// Round check (or amber alert) badge for permission rows.
struct PermissionBadge: View {
    let ok: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colour = ok ? UIUIStyle.tint(scheme) : Color.orange
        Image(systemName: ok ? "checkmark" : "exclamationmark")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(colour)
            .frame(width: 22, height: 22)
            .background(colour.opacity(scheme == .dark ? 0.18 : 0.16), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The five section tabs as a capsule track. Selected is ink in light mode, accent in dark.
struct SettingsTabBar: View {
    @Binding var selection: SettingsPane
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsPane.allCases) { item in
                let selected = item == selection
                Button { selection = item } label: {
                    Text(item.title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? selectedText : Color.secondary)
                        .padding(.horizontal, 15).padding(.vertical, 6)
                        .background { if selected { Capsule().fill(selectedFill) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(UIUIStyle.chip(scheme), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings section")
    }

    private var selectedFill: Color { scheme == .dark ? UIUIStyle.accent : UIUIStyle.ink }
    private var selectedText: Color { scheme == .dark ? UIUIStyle.ink : Color(red: 0.97, green: 0.97, blue: 0.95) }
}

/// Title and secondary line on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var alignment: VerticalAlignment = .center
    /// Toggles name themselves for VoiceOver, so the visible text is skipped there.
    var hidesText = false
    @ViewBuilder let control: Control
    var body: some View {
        HStack(alignment: alignment, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.accessibilityHidden(hidesText)
            Spacer(minLength: 12)
            control
        }
    }
}

extension View {
    /// Paper-toned field for text inputs and the shortcut cap.
    func settingsField(radius: CGFloat = 8) -> some View { modifier(SettingsFieldModifier(radius: radius)) }
}

private struct SettingsFieldModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.padding(.horizontal, 10).padding(.vertical, 6)
            .background(UIUIStyle.chip(scheme), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
