import SwiftUI

/// Native, immediate preference selection. All three drawings are still previews:
/// no microphone, extra display clock, model work or temporary settings writes.
struct NotchStylePicker: View {
    @Binding var selection: NotchVisualStyle
    @Environment(\.colorScheme) private var scheme
    private var selectionTint: Color {
        UIUIStyle.tint(scheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notch style").font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                ForEach(NotchVisualStyle.allCases) { style in
                    Button { selection = style } label: {
                        VStack(spacing: 7) {
                            NotchStyleThumbnail(style: style)
                                .padding(.top, 3)
                            HStack(spacing: 5) {
                                Text(style.title).font(.system(size: 11, weight: .medium))
                                Image(systemName: selection == style ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(selection == style ? selectionTint : Color.secondary.opacity(0.45))
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(.primary.opacity(selection == style ? 0.055 : 0.02),
                            in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(selection == style ? selectionTint.opacity(0.65) : Color.primary.opacity(0.1),
                                              lineWidth: selection == style ? 1.25 : 0.75)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .help(style.detail)
                    .accessibilityLabel(style.title + " notch style")
                    .accessibilityValue(selection == style ? "Selected" : "Not selected")
                    .accessibilityHint(style.detail)
                    .accessibilityAddTraits(selection == style ? .isSelected : [])
                }
            }
            Text(selection.detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch style")
    }
}

private struct NotchStyleThumbnail: View {
    let style: NotchVisualStyle

    var body: some View {
        // Render at real notch proportions, then scale the whole drawing; the
        // Mosaic cells and camera stay proportional to the shipped HUD.
        NotchVisualFeedback(phase: .recording, level: 0.65, hasCamera: true,
            cameraWidth: 220, cameraHeight: 38, style: style,
            previewProgress: 0.65, isVisible: false)
            .background(Color.black)
            .frame(width: 368, height: 65)
            .overlay(alignment: .bottom) {
                if style == .words {
                    Text(NotchWordsText.attributed("once the review is complete"))
                        .font(.system(size: 15)).padding(.bottom, 9)
                }
            }
            .clipShape(NotchContour(topRadius: 14, bottomRadius: 24))
            .scaleEffect(0.27)
            .frame(width: 100, height: 20)
            .accessibilityHidden(true)
    }
}

/// Compact, Standard or Large. The open notch follows the choice immediately.
struct NotchSizePicker: View {
    @Binding var selection: NotchSize

    var body: some View {
        HStack {
            Text("Notch size").font(.system(size: 12, weight: .medium))
            Spacer()
            Picker("Notch size", selection: $selection) {
                ForEach(NotchSize.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}
