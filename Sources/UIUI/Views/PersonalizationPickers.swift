import AppKit
import SwiftUI
import UIUICore

/// Accent colour: presets plus a custom colour. Very dark picks are lightened so
/// they stay readable on the notch.
struct AccentPicker: View {
    @Binding var choice: UIUIAccent
    @Binding var customHex: String

    private var customColor: Binding<Color> {
        Binding(get: { UIUIStyle.color(AccentRGB(hex: customHex) ?? UIUIAccent.lime.resolved(customHex: "")) },
                set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    customHex = AccentRGB(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent).hex
                    choice = .custom
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Colour").font(.system(size: 12, weight: .medium))
            HStack(spacing: 10) {
                ForEach(UIUIAccent.allCases.filter { $0 != .custom }) { option in
                    Button { choice = option } label: {
                        Circle().fill(UIUIStyle.color(option.resolved(customHex: ""))).frame(width: 22, height: 22)
                            .overlay { if choice == option { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(UIUIStyle.ink) } }
                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.15)) }
                    }
                    .buttonStyle(.plain).help(option.title)
                    .accessibilityLabel(option.title).accessibilityAddTraits(choice == option ? .isSelected : [])
                }
                ColorPicker("Custom colour", selection: customColor, supportsOpacity: false).labelsHidden()
                    .help("Custom colour")
                if choice == .custom { Text("Custom").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Which recording sounds play, how loud, and a way to hear them.
struct SoundChoice: View {
    @Binding var pack: SoundPack
    @Binding var volume: Double
    let preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Sound", selection: $pack) {
                    ForEach(SoundPack.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 220)
                Button("Play") { preview() }.accessibilityLabel("Play sound")
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Volume").font(.system(size: 12))
                Slider(value: $volume, in: 0.1...1, onEditingChanged: { editing in if !editing { preview() } })
                    .frame(maxWidth: 220).accessibilityLabel("Sound volume")
                Spacer()
            }
        }
        .onChange(of: pack) { _, _ in preview() }
    }
}
