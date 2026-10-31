import SwiftUI
import UIUICore

/// A small notice when unfinished recordings exist. Review opens the full list.
/// Recovery actions stay explicit: opening or copying keeps the journal entry.
struct RecordingRecoveryView: View {
    @Bindable var model: AppModel
    @State private var showReview = false

    private var count: Int { model.recordingRecoveryDrafts.count }

    var body: some View {
        if count > 0 || model.recordingRecoveryIssue != nil {
            VStack(alignment: .leading, spacing: 6) {
                if count > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                        Text(count == 1 ? "1 unfinished recording was kept" : "\(count) unfinished recordings were kept")
                            .font(.system(size: 12))
                        Spacer(minLength: 8)
                        Button("Review") { showReview = true }
                            .buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
                            .help("Review the recognized text from unfinished recordings")
                            .accessibilityLabel("Review unfinished recordings")
                    }.padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .contain)
                }
                if let issue = model.recordingRecoveryIssue, !issue.isEmpty {
                    Label(issue, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.padding(.horizontal, 22).padding(.bottom, 10)
                .sheet(isPresented: $showReview) {
                    RecordingRecoveryReview(model: model) { showReview = false }
                }
                .onChange(of: count) { _, newValue in if newValue == 0 { showReview = false } }
        }
    }
}

/// The existing review list: open, copy or discard each recovered draft.
struct RecordingRecoveryReview: View {
    @Bindable var model: AppModel
    let onDone: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var showAllDrafts = false
    @State private var pendingDiscardID: UUID?

    private var drafts: [RecordingRecoveryDraft] {
        model.recordingRecoveryDrafts.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var visibleDrafts: [RecordingRecoveryDraft] {
        showAllDrafts ? drafts : Array(drafts.prefix(3))
    }
    private var actionsUnavailable: Bool { model.hasCancellableVoiceInput }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Unfinished recordings").font(.headline)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 22).padding(.vertical, 16)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Recognized text from unfinished recordings. The last unrecognized words may be missing.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if drafts.isEmpty {
                    Text("No unfinished recordings.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleDrafts) { draft in
                            recoveryRow(draft)
                            if draft.id != visibleDrafts.last?.id { Divider().opacity(0.35) }
                        }
                    }
                }
                if drafts.count > 3 {
                    Button(showAllDrafts ? "Show latest 3" : "Show all \(drafts.count) drafts") {
                        showAllDrafts.toggle()
                    }.font(.system(size: 11)).buttonStyle(.borderless)
                }
            }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(width: 540, height: 440).background(UIUIStyle.paper(scheme))
            .alert("Discard this recovery draft?", isPresented: Binding(
                get: { pendingDiscardID != nil },
                set: { if !$0 { pendingDiscardID = nil } }
            ), presenting: pendingDiscardID) { draftID in
                Button("Cancel", role: .cancel) { pendingDiscardID = nil }
                Button("Discard", role: .destructive) {
                    guard !actionsUnavailable else { return }
                    model.discardRecordingRecoveryDraft(draftID)
                    pendingDiscardID = nil
                }.disabled(actionsUnavailable)
            } message: { _ in
                Text("This removes the unfinished recording from Recovery. This cannot be undone.")
            }
    }

    private func recoveryRow(_ draft: RecordingRecoveryDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Unfinished recording")
                Text("·")
                Text(draft.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                Text("\(TextProcessing.wordCount(draft.text)) words")
                if !draft.project.isEmpty && draft.project != "Personal" {
                    Text("·")
                    Text(draft.project).lineLimit(1)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text(draft.text).font(.system(size: 12)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button("Open") { onDone(); model.openRecordingRecoveryDraft(draft.id) }
                    .help("Open recognized text for review; the recovery draft is kept")
                    .accessibilityLabel("Open unfinished recording from \(draft.startedAt.formatted(date: .abbreviated, time: .shortened))")
                Button("Copy") { model.copyRecordingRecoveryDraft(draft.id) }
                    .help("Copy recognized text to the clipboard; the recovery draft is kept")
                    .accessibilityLabel("Copy unfinished recording text")
                Spacer()
                Button("Discard", role: .destructive) { pendingDiscardID = draft.id }
                    .accessibilityLabel("Discard unfinished recording")
            }.font(.system(size: 11)).buttonStyle(.borderless).disabled(actionsUnavailable)
        }.padding(.vertical, 8)
    }
}
