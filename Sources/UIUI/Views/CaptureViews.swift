import SwiftUI
import UIUICore

/// A review destination for recovered text; saving never starts dictation.
struct QuickCaptureView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    private var isEmpty: Bool { model.captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                UIUIMark(size: 27)
                Text("Review recognized text").font(.system(size: 14, weight: .medium))
                Spacer()
            }
            Text("Review the recognized words before saving. Opening and copying keep the recovery draft.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $model.captureText).font(.system(size: 14)).lineSpacing(5)
                .scrollContentBackground(.hidden).focused($focused)
                .accessibilityLabel("Recovered recording text").frame(minHeight: 180)
            HStack {
                Text("\(TextProcessing.wordCount(model.captureText)) words").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.showComposer = false; model.openLibrary() }.keyboardShortcut(.cancelAction)
                Button("Copy") { model.copy(model.captureText) }.disabled(isEmpty)
                Button("Save") { model.saveCapture() }.buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command).disabled(isEmpty || model.hasCancellableVoiceInput)
            }
            ModelStatusView(model: model)
        }.padding(22).frame(minWidth: 470, minHeight: 310)
            .background(UIUIStyle.paper(scheme))
            .tint(scheme == .dark ? UIUIStyle.lime : Color(red: 0.3, green: 0.42, blue: 0.12))
            .onAppear { focused = true }
    }
}
