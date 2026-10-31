import SwiftUI
import UIUICore

/// Saved dictations grouped by day, with search, an app filter and keyboard navigation.
struct HistoryListView: View {
    @Bindable var model: AppModel
    @State private var appFilter: String?
    init(model: AppModel, initialAppFilter: String? = nil) {
        self.model = model
        _appFilter = State(initialValue: initialAppFilter)
    }
    @State private var focusedID: UUID?
    @State private var pendingDelete: CaptureItem?
    /// The keyboard highlight appears only after an arrow key, never on its own.
    @State private var keyboardActive = false
    @FocusState private var listFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var apps: [String] { HistoryOrganizer.apps(in: model.items) }
    private var activeFilter: String? { appFilter.flatMap { filter in apps.contains(filter) ? filter : nil } }
    private var items: [CaptureItem] { HistoryOrganizer.filter(model.visibleItems, app: activeFilter) }
    private var sections: [HistorySection] { HistoryOrganizer.sections(for: items) }
    private var orderedIDs: [UUID] { sections.flatMap(\.items).map(\.id) }
    private var isFiltering: Bool { !model.searchText.isEmpty || activeFilter != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            if items.isEmpty { emptyState } else { list }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert("Delete this saved text?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { item in
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) { model.delete(item); pendingDelete = nil }
            } message: { _ in Text("This removes it from your local history.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("History").font(.system(size: 14, weight: .semibold))
                Text("\(items.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .accessibilityLabel("\(items.count) saved")
                Spacer(minLength: 8)
                if !apps.isEmpty { appMenu }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search history", text: $model.searchText).textFieldStyle(.plain)
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("Clear search").help("Clear search")
                    }
                }.font(.system(size: 11)).padding(7)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7)).frame(width: 200)
            }
            StatsLine(model: model)
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

    private var appMenu: some View {
        Menu {
            Button { appFilter = nil } label: {
                if activeFilter == nil { Label("All apps", systemImage: "checkmark") } else { Text("All apps") }
            }
            Divider()
            ForEach(apps, id: \.self) { app in
                Button { appFilter = app } label: {
                    if activeFilter == app { Label(app, systemImage: "checkmark") } else { Text(app) }
                }
            }
        } label: {
            Label(activeFilter ?? "All apps", systemImage: "line.3.horizontal.decrease")
                .font(.system(size: 11)).lineLimit(1)
        }.menuStyle(.borderlessButton).fixedSize()
            .help("Show dictations from one app").accessibilityLabel("Filter by app")
            .accessibilityValue(activeFilter ?? "All apps")
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            if isFiltering {
                Image(systemName: "magnifyingglass").font(.system(size: 23)).foregroundStyle(.tertiary)
                Text("No matching text").font(.system(size: 14, weight: .medium))
            }
            Text(emptyDetail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if activeFilter != nil {
                Button("Show all apps") { appFilter = nil }.buttonStyle(.borderless).font(.system(size: 12))
            } else if !model.settings.saveDictationHistory && !isFiltering {
                Button("Open Settings") { model.openSettings() }.buttonStyle(.borderless).font(.system(size: 12))
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDetail: String {
        if isFiltering { return "Try another search or app." }
        if !model.settings.saveDictationHistory { return "History is off, so new dictations are not kept here." }
        return "Saved dictations appear here."
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                HistoryRow(model: model, item: item, showsDate: section.id == HistoryOrganizer.pinnedID,
                                           isFocused: listFocused && keyboardActive && focusedID == item.id,
                                           onOpen: { focusedID = item.id; keyboardActive = false; model.selectedItemID = item.id },
                                           onDelete: { pendingDelete = item })
                                    .id(item.id)
                                Divider().opacity(0.35).padding(.horizontal, 22)
                            }
                        } header: {
                            Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22).padding(.vertical, 6)
                                .background(UIUIStyle.paper(scheme))
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
            }
            .focusable().focusEffectDisabled().focused($listFocused)
            .onKeyPress(phases: [.down, .repeat]) { press in handle(press, proxy: proxy) }
            .onChange(of: listFocused) { _, focused in
                if !focused { keyboardActive = false }
                else if focusedID == nil || !orderedIDs.contains(focusedID!) { focusedID = orderedIDs.first }
            }
        }
    }

    private func handle(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = orderedIDs
        guard !ids.isEmpty else { return .ignored }
        let current = focusedID.flatMap { ids.firstIndex(of: $0) }
        func move(to index: Int) {
            keyboardActive = true
            let id = ids[max(0, min(ids.count - 1, index))]
            focusedID = id
            proxy.scrollTo(id)
        }
        switch press.key {
        case .downArrow: move(to: (current ?? -1) + 1); return .handled
        case .upArrow: move(to: (current ?? 1) - 1); return .handled
        case .home: move(to: 0); return .handled
        case .end: move(to: ids.count - 1); return .handled
        case .return, .space:
            guard let id = focusedID else { return .ignored }
            model.selectedItemID = id; return .handled
        case .delete, .deleteForward:
            guard let id = focusedID, let item = items.first(where: { $0.id == id }) else { return .ignored }
            pendingDelete = item; return .handled
        default:
            if press.characters.lowercased() == "c", press.modifiers.contains(.command),
               let id = focusedID, let item = items.first(where: { $0.id == id }) {
                model.copy(item.body); return .handled
            }
            if press.characters.lowercased() == "p", press.modifiers.contains(.command),
               let id = focusedID, let item = items.first(where: { $0.id == id }) {
                model.togglePin(item); return .handled
            }
            return .ignored
        }
    }
}

/// One saved item: when, where it went, and its text, with quick actions.
private struct HistoryRow: View {
    let model: AppModel
    let item: CaptureItem
    let showsDate: Bool
    let isFocused: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var showsActions: Bool { hovering || isFocused }
    private var accessibilitySummary: String {
        let time = item.createdAt.formatted(date: showsDate ? .abbreviated : .omitted, time: .shortened)
        let destination = item.sourceApp.flatMap { $0.isEmpty ? nil : " to \($0)" } ?? ""
        return "\(item.kind.title) at \(time)\(destination). \(item.body.isEmpty ? item.title : item.body)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) { content }
                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(accessibilitySummary).accessibilityHint("Opens the full text")
            HStack(spacing: 0) {
                QuietIconButton(symbol: item.isPinned ? "pin.fill" : "pin", label: item.isPinned ? "Unpin" : "Pin") { model.togglePin(item) }
                    .opacity(showsActions || item.isPinned ? 1 : 0)
                QuietIconButton(symbol: "trash", label: "Delete saved text", action: onDelete)
                    .opacity(showsActions ? 1 : 0)
                QuietIconButton(symbol: "doc.on.doc", label: "Copy saved text") { model.copy(item.body) }
            }
        }.padding(.horizontal, 22)
            .background((isFocused ? UIUIStyle.lime.opacity(0.16) : hovering ? Color.primary.opacity(0.03) : .clear))
            .overlay(alignment: .leading) {
                if isFocused { Rectangle().fill(UIUIStyle.lime).frame(width: 3) }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                Button(item.isPinned ? "Unpin" : "Pin") { model.togglePin(item) }
                Button("Copy") { model.copy(item.body) }
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Delete") { onDelete() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.createdAt.formatted(date: showsDate ? .abbreviated : .omitted, time: .shortened))
                if let source = item.sourceApp, !source.isEmpty {
                    Text("·")
                    Label(source, systemImage: "arrow.turn.down.right").labelStyle(.titleAndIcon).lineLimit(1)
                } else {
                    Text("·"); Text("No app").foregroundStyle(.tertiary)
                }
                if item.kind != .dictation { Text("·"); Text(item.kind.title) }
                if !item.project.isEmpty && item.project != "Personal" { Text("·"); Text(item.project).lineLimit(1) }
                Spacer(minLength: 0)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text(item.body.isEmpty ? item.title : item.body)
                .font(.system(size: 13)).foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 12).contentShape(Rectangle())
    }
}

/// Words dictated and an honest estimate of typing time saved. Silent when history is off.
private struct StatsLine: View {
    let model: AppModel
    var body: some View {
        if let stats = model.dictationStats() {
            Text("Last 7 days · \(stats.summary)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .help("Estimated at \(DictationStats.assumedTypingWordsPerMinute) words per minute of typing, from your saved history")
        }
    }
}

// MARK: Saved text

struct SavedTextView: View {
    let model: AppModel
    let item: CaptureItem
    @State private var showDelete = false
    @State private var fixMode = false
    @State private var lastFix: HistoryWordFix?
    @State private var notice: String?

    init(model: AppModel, item: CaptureItem, startsInFixMode: Bool = false, previousFix: HistoryWordFix? = nil) {
        self.model = model
        self.item = item
        _fixMode = State(initialValue: startsInFixMode)
        _lastFix = State(initialValue: previousFix)
        _notice = State(initialValue: previousFix.map(Self.message(for:)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { model.selectedItemID = nil } label: { Label("History", systemImage: "chevron.left") }
                    .buttonStyle(.plain).help("Back to history").keyboardShortcut(.cancelAction)
                Spacer()
                Button { fixMode.toggle() } label: {
                    Label(fixMode ? "Done fixing" : "Fix a word", systemImage: fixMode ? "checkmark" : "character.cursor.ibeam")
                }.buttonStyle(.borderless).help("Click a misheard word to correct it and teach your dictionary")
                QuietIconButton(symbol: item.isPinned ? "pin.fill" : "pin", label: item.isPinned ? "Unpin" : "Pin") { model.togglePin(item) }
                Button { model.copy(item.body) } label: { Label("Copy saved text", systemImage: "doc.on.doc") }.buttonStyle(.borderless)
                QuietIconButton(symbol: "trash", label: "Delete saved text") { showDelete = true }
            }.font(.system(size: 12)).padding(.horizontal, 22).padding(.vertical, 12)
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.kind == .dictation ? "Dictation" : item.title).font(.system(size: 18, weight: .medium))
                    Text(metadata).font(.system(size: 10)).foregroundStyle(.secondary)
                    if let notice { noticeBanner(notice) }
                    if fixMode {
                        Text("Click the word that was misheard.").font(.system(size: 11)).foregroundStyle(.secondary)
                        WordFixBody(text: item.body) { heard, correction in
                            await submit(heard: heard, correction: correction)
                        }
                    } else {
                        Text(item.body).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

    private var metadata: String {
        var parts = [item.createdAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append(item.sourceApp.flatMap { $0.isEmpty ? nil : "Sent to \($0)" } ?? "No app")
        parts.append("\(TextProcessing.wordCount(item.body)) words")
        if !item.project.isEmpty && item.project != "Personal" { parts.append(item.project) }
        return parts.joined(separator: " · ")
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(UIUIStyle.lime).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if lastFix != nil {
                Button("Undo") { undo() }.buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
            }
            Button { notice = nil; lastFix = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss").help("Dismiss")
        }.padding(.horizontal, 12).padding(.vertical, 9)
            .background(UIUIStyle.lime.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
    }

    /// Returns an error message for the popover, or nil when the fix was applied.
    private func submit(heard: String, correction: String) async -> String? {
        switch await model.fixWord(in: item, heard: heard, correction: correction) {
        case .rejected(let reason): return reason
        case .fixed(let fix):
            lastFix = fix
            notice = Self.message(for: fix)
            return nil
        }
    }

    private func undo() {
        guard let fix = lastFix else { return }
        Task {
            if await model.undoWordFix(fix) {
                lastFix = nil
                notice = "Undone. The text and dictionary are back as they were."
            } else {
                notice = "Couldn’t undo because the text has changed since."
                lastFix = nil
            }
        }
    }

    static func message(for fix: HistoryWordFix) -> String {
        var base = "Changed “\(fix.heardAsWritten)” to “\(fix.correction)”"
        if fix.replacedCount > 1 { base += " in \(fix.replacedCount) places" }
        switch fix.outcome {
        case .added: return base + " and added it to your dictionary."
        case .updated(let previous): return base + ". Dictionary entry updated (was “\(previous.replacement)”)."
        case .alreadyPresent: return base + ". Your dictionary already had this."
        }
    }
}

// MARK: Click-a-word correction

/// The saved text as clickable words. Clicking one opens a small field for the correction.
private struct WordFixBody: View {
    let text: String
    let onSubmit: (_ heard: String, _ correction: String) async -> String?
    @State private var editingID: String?

    private var lines: [[String]] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { lineIndex, words in
                if words.isEmpty { Color.clear.frame(height: 8) }
                else {
                    FlowLayout(spacing: 2, lineSpacing: 7) {
                        ForEach(Array(words.enumerated()), id: \.offset) { wordIndex, chunk in
                            let id = "\(lineIndex)-\(wordIndex)"
                            WordChip(chunk: chunk, isEditing: Binding(
                                get: { editingID == id },
                                set: { if $0 { editingID = id } else if editingID == id { editingID = nil } }
                            ), onSubmit: onSubmit)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WordChip: View {
    let chunk: String
    @Binding var isEditing: Bool
    let onSubmit: (_ heard: String, _ correction: String) async -> String?
    @State private var hovering = false

    private var word: String { HistoryCorrection.coreWord(of: chunk) }

    var body: some View {
        Button { if !word.isEmpty { isEditing = true } } label: {
            Text(chunk).font(.system(size: 14))
                .padding(.horizontal, 2).padding(.vertical, 1)
                .background((hovering || isEditing) && !word.isEmpty ? UIUIStyle.lime.opacity(0.28) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .disabled(word.isEmpty)
            .accessibilityLabel("Fix \(chunk)")
            .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                FixWordForm(word: word, onCancel: { isEditing = false }) { correction in
                    let failure = await onSubmit(word, correction)
                    if failure == nil { isEditing = false }
                    return failure
                }
            }
    }
}

struct FixWordForm: View {
    let word: String
    let onCancel: () -> Void
    let onSubmit: (_ correction: String) async -> String?
    @State private var correction = ""
    @State private var problem: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fix “\(word)”").font(.system(size: 13, weight: .semibold))
            TextField("Write it as", text: $correction).textFieldStyle(.roundedBorder).focused($focused)
                .frame(width: 240).onSubmit(apply).accessibilityLabel("Correct spelling")
            Text("This text changes, and “\(word.lowercased())” becomes the written form in your dictionary for all projects.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Fix word", action: apply).keyboardShortcut(.defaultAction)
                    .disabled(working || correction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(14).frame(width: 268)
            .onAppear { correction = word; focused = true }
    }

    private func apply() {
        guard !working else { return }
        working = true
        Task {
            problem = await onSubmit(correction)
            working = false
        }
    }
}

/// Wraps children onto lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineHeight), origins)
    }
}
