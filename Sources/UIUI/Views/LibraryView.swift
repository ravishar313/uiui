import SwiftUI
import UIUICore

/// A single workspace for dictation, saved text, and recovery.
struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                UIUIMark(size: 24)
                Text("uiui").font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(-0.6)
                Spacer()
                QuietIconButton(symbol: "slider.horizontal.3", label: "Settings") { model.openSettings() }
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 13)
            VoiceHomeView(model: model).padding(.horizontal, 20).padding(.bottom, 14)
            RecordingRecoveryView(model: model)
            Divider().opacity(0.5)
            if let item = model.selectedItem {
                SavedTextView(model: model, item: item).id(item.id)
            } else {
                HistoryListView(model: model)
            }
            if let error = model.errorMessage, !error.isEmpty, error != model.voiceError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 9)
            } else if model.statusMessage == "Copied to clipboard." {
                Text(model.statusMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 9)
            }
        }
        .background(UIUIStyle.paper(scheme))
        .frame(minWidth: 680, minHeight: 460)
        .tint(scheme == .dark ? UIUIStyle.lime : Color(red: 0.30, green: 0.42, blue: 0.12))
        .sheet(item: $model.workspaceSheet) { _ in
            VStack(spacing: 0) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button("Done") { model.workspaceSheet = nil }.keyboardShortcut(.defaultAction)
                }.padding(.horizontal, 22).padding(.vertical, 16)
                Divider()
                SettingsView(model: model)
            }.frame(width: 600, height: 540).background(UIUIStyle.paper(scheme))
        }
    }
}
