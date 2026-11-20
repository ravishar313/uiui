import SwiftUI
import UIUICore

/// The notebook: what you said, searchable, with a quiet rail beside it.
struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool
    /// An item opened from a "Fix a word" action starts in fix mode.
    @State private var fixItemID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            main.frame(maxWidth: .infinity)
            NotebookRail(model: model)
        }
        .background(UIUIStyle.paper(scheme))
        .frame(minWidth: 940, minHeight: 520)
        .tint(UIUIStyle.tint(scheme))
        .onChange(of: model.selectedItemID) { _, id in if id == nil { fixItemID = nil } }
        .background {
            Button("Find") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
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

    private var main: some View {
        VStack(spacing: 0) {
            topRow
            if let item = model.selectedItem {
                HomeNotices(model: model).padding(.horizontal, 28).padding(.bottom, 8)
                SavedTextView(model: model, item: item, startsInFixMode: fixItemID == item.id).id(item.id)
            } else {
                HistoryListView(model: model, top: AnyView(listTop), onFixWord: openFix)
            }
            statusLine
        }
    }

    private var topRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                UIUIMark(size: 24)
                Text("uiui").font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(-0.6)
            }
            searchField
            QuietIconButton(symbol: "slider.horizontal.3", label: "Settings") { model.openSettings() }
        }.padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 18)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Find something you said", text: $model.searchText).textFieldStyle(.plain)
                .font(.system(size: 13)).focused($searchFocused)
                .accessibilityLabel("Search history")
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("Clear search").help("Clear search")
            } else {
                Text("\u{2318}F").font(.system(size: 11)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }.padding(.horizontal, 14).padding(.vertical, 9)
            .uiuiCard(radius: 12).frame(maxWidth: .infinity)
            .onChange(of: model.searchText) { _, text in
                if !text.isEmpty, model.selectedItemID != nil { model.selectedItemID = nil }
            }
    }

    /// Scrolls with the history: the last dictation, then any notices.
    private var listTop: some View {
        VStack(spacing: 0) {
            if model.searchText.isEmpty {
                VoiceHomeView(model: model, onFix: openFix)
            }
            HomeNotices(model: model).padding(.top, 14)
        }.padding(.horizontal, 28).padding(.bottom, 8)
    }

    @ViewBuilder private var statusLine: some View {
        if let error = model.errorMessage, !error.isEmpty, error != model.voiceError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 9)
        } else if model.statusMessage == "Copied to clipboard." {
            Text(model.statusMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 9)
        }
    }

    private func openFix(_ item: CaptureItem) {
        fixItemID = item.id
        model.selectedItemID = item.id
    }
}
