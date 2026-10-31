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
                history
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

    private var history: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("History").font(.system(size: 14, weight: .semibold))
                Text("\(model.visibleItems.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search history", text: $model.searchText).textFieldStyle(.plain)
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.font(.system(size: 11)).padding(7)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7)).frame(width: 220)
            }.padding(.horizontal, 22).padding(.vertical, 14)
            if model.visibleItems.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: model.searchText.isEmpty ? "waveform" : "magnifyingglass")
                        .font(.system(size: 23)).foregroundStyle(.tertiary)
                    Text(model.searchText.isEmpty ? "No saved dictations yet" : "No matching text")
                        .font(.system(size: 14, weight: .medium))
                    Text(model.searchText.isEmpty ? "Start dictation above. Your saved words appear here." : "Try another search.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleItems) { item in
                            HStack(spacing: 14) {
                                Button { model.selectedItemID = item.id } label: { CaptureRow(item: item) }
                                    .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                                Button { model.copy(item.body) } label: {
                                    Image(systemName: "doc.on.doc").font(.system(size: 12)).frame(width: 28, height: 28)
                                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .help("Copy text").accessibilityLabel("Copy saved text")
                            }.padding(.horizontal, 22)
                                .contextMenu {
                                    Button(item.isPinned ? "Unpin" : "Pin") { model.togglePin(item) }
                                    Button("Copy") { model.copy(item.body) }
                                }
                            Divider().opacity(0.35).padding(.horizontal, 22)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CaptureRow: View {
    let item: CaptureItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                if item.kind != .dictation { Text("·"); Text(item.kind.title) }
                if let source = item.sourceApp, !source.isEmpty { Text("·"); Text(source).lineLimit(1) }
                if !item.project.isEmpty && item.project != "Personal" { Text("·"); Text(item.project).lineLimit(1) }
                Spacer(minLength: 0)
                if item.isPinned { Image(systemName: "pin.fill") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text(item.body.isEmpty ? item.title : item.body)
                .font(.system(size: 13)).foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 13).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

private struct SavedTextView: View {
    let model: AppModel
    let item: CaptureItem
    @State private var showDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { model.selectedItemID = nil } label: { Label("History", systemImage: "chevron.left") }
                    .buttonStyle(.plain).help("Back to history")
                Spacer()
                QuietIconButton(symbol: item.isPinned ? "pin.fill" : "pin", label: item.isPinned ? "Unpin" : "Pin") { model.togglePin(item) }
                Button { model.copy(item.body) } label: { Label("Copy saved text", systemImage: "doc.on.doc") }.buttonStyle(.borderless)
                QuietIconButton(symbol: "trash", label: "Delete saved text") { showDelete = true }
            }.font(.system(size: 12)).padding(.horizontal, 22).padding(.vertical, 12)
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.kind == .dictation ? "Dictation" : item.title).font(.system(size: 18, weight: .medium))
                    Text("\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(TextProcessing.wordCount(item.body)) words")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !item.project.isEmpty && item.project != "Personal" {
                        Text(item.project).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(item.body).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let original = item.rawText {
                        DisclosureGroup("Original wording") {
                            Text(original).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 9)
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert("Delete this saved text?", isPresented: $showDelete) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) { model.delete(item); model.selectedItemID = nil }
            } message: { Text("This removes it from your local history.") }
    }
}
