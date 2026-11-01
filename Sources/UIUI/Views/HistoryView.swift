import SwiftUI
import UIUICore

/// Saved dictations grouped by day, with search, an app filter and keyboard navigation.
struct HistoryListView: View {
    @Bindable var model: AppModel
    @State private var appFilter: String?
    /// Scrolls with the history, so the whole page moves as one at any window size.
    private let top: AnyView
    init(model: AppModel, initialAppFilter: String? = nil, top: AnyView = AnyView(EmptyView())) {
        self.model = model
        self.top = top
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
        list.frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }.padding(24).frame(maxWidth: .infinity, minHeight: 180)
    }

    private var emptyDetail: String {
        if isFiltering { return "Try another search or app." }
        if !model.settings.saveDictationHistory { return "History is off, so new dictations are not kept here." }
        return "Saved dictations appear here."
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                top
                header
                if items.isEmpty { emptyState }
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
            .background((isFocused ? UIUIStyle.accent.opacity(0.16) : hovering ? Color.primary.opacity(0.03) : .clear))
            .overlay(alignment: .leading) {
                if isFocused { Rectangle().fill(UIUIStyle.accent).frame(width: 3) }
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
    @State private var notice: String?

    init(model: AppModel, item: CaptureItem, startsInFixMode: Bool = false, previousFix: HistoryWordFix? = nil) {
        self.model = model
        self.item = item
        _fixMode = State(initialValue: startsInFixMode)
        _notice = State(initialValue: previousFix.map(Self.message(for:)))
    }

    /// Survives the banner being dismissed and the view being left: it lives in the model.
    private var undoableFix: HistoryWordFix? { model.undoableFix(for: item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { model.selectedItemID = nil } label: { Label("History", systemImage: "chevron.left") }
                    .buttonStyle(.plain).help("Back to history").keyboardShortcut(.cancelAction)
                Spacer()
                if undoableFix != nil {
                    Button { undo() } label: { Label("Undo last fix", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).help("Put back the text and dictionary entry from the last fix")
                }
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
                        Text("Click the word that was misheard, or use the arrow keys and Return.").font(.system(size: 11)).foregroundStyle(.secondary)
                        WordFixBody(text: item.body) { range, heard, correction, others, dictionary in
                            await submit(range: range, heard: heard, correction: correction, others: others, dictionary: dictionary)
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
            Image(systemName: "checkmark.circle.fill").foregroundStyle(UIUIStyle.accent).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if undoableFix != nil {
                Button("Undo") { undo() }.buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
            }
            Button { notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss").help("Dismiss")
        }.padding(.horizontal, 12).padding(.vertical, 9)
            .background(UIUIStyle.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
    }

    /// Returns an error message for the popover, or nil when the fix was applied.
    private func submit(range: NSRange, heard: String, correction: String, others: Bool, dictionary: Bool) async -> String? {
        switch await model.fixWord(in: item, wordRange: range, heard: heard, correction: correction,
                                   alsoFixOtherMatches: others, addToDictionary: dictionary) {
        case .rejected(let reason): return reason
        case .fixed(let fix):
            notice = Self.message(for: fix)
            return nil
        }
    }

    private func undo() {
        guard let fix = undoableFix else { return }
        Task {
            notice = await model.undoWordFix(fix)
                ? "Undone. The text and dictionary are back as they were."
                : "Couldn’t undo because the text has changed since."
        }
    }

    static func message(for fix: HistoryWordFix) -> String {
        var base = "Changed “\(fix.heardAsWritten)” to “\(fix.correction)”"
        if fix.replacedCount > 1 { base += " in \(fix.replacedCount) places" }
        switch fix.outcome {
        case .added: return base + " and added it to your dictionary."
        case .updated(let previous): return base + ". Dictionary entry updated (was “\(previous.replacement)”)."
        case .alreadyPresent: return base + ". Your dictionary already had this."
        case .notRequested: return base + ". Your dictionary was not changed."
        }
    }
}

// MARK: Click-a-word correction

private struct PickedWord: Identifiable, Equatable {
    let id = UUID()
    let range: NSRange
    let word: String
    let rect: CGRect
}

/// The saved text as one text view. A click is hit-tested to a word and opens a
/// small form beside it, so cost does not grow with the number of words.
private struct WordFixBody: View {
    let text: String
    let onSubmit: (_ range: NSRange, _ heard: String, _ correction: String, _ alsoFixOthers: Bool, _ addToDictionary: Bool) async -> String?
    @State private var picked: PickedWord?

    var body: some View {
        FixableText(text: text, highlighted: picked?.range) { range, rect in
            let word = (text as NSString).substring(with: range)
            picked = PickedWord(range: range, word: word, rect: rect)
        }
        .popover(item: $picked, attachmentAnchor: .rect(.rect(picked?.rect ?? .zero)), arrowEdge: .bottom) { pick in
            FixWordForm(word: pick.word,
                        otherMatches: max(0, HistoryCorrection.exactMatches(of: pick.word, in: text).count - 1),
                        onCancel: { picked = nil }) { correction, others, dictionary in
                let failure = await onSubmit(pick.range, pick.word, correction, others, dictionary)
                if failure == nil { picked = nil }
                return failure
            }
        }
    }
}

/// Text view with word hit-testing. Layout is TextKit's; the view count stays at one.
final class FixTextView: NSTextView {
    var onPick: ((NSRange, CGRect) -> Void)?
    private(set) var plainText = ""
    private var marked: [NSRange] = []
    private var hover: NSRange?
    var highlight: NSRange? { didSet { restyle() } }
    private var keyboardWord: NSRange?
    private var lastWidth: CGFloat = -1
    private var lastHeight: CGFloat = 0
    private var tracking: NSTrackingArea?

    static let fontSize: CGFloat = 14
    static let lineSpacing: CGFloat = 7

    func configure(text: String) {
        guard text != plainText || textStorage?.length == 0 else { return }
        plainText = text
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Self.lineSpacing
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Self.fontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
        ]))
        marked = []; hover = nil; keyboardWord = nil; lastWidth = -1
    }

    /// Height for a width; laid out once per width and text.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0, let layoutManager, let textContainer else { return 0 }
        if abs(width - lastWidth) < 0.5 { return lastHeight }
        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        lastWidth = width
        lastHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        return lastHeight
    }

    /// The word under a point in this view's coordinates, nil on gaps between lines or past line ends.
    func word(at point: CGPoint) -> NSRange? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.insetBy(dx: -1, dy: -Self.lineSpacing / 2).contains(local) else { return nil }
        return HistoryCorrection.wordRange(in: plainText, atUTF16Offset: layoutManager.characterIndexForGlyph(at: glyph))
    }

    func rect(of range: NSRange) -> CGRect {
        guard let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return box.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func restyle() {
        guard let layoutManager else { return }
        for range in marked { layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range) }
        marked = [highlight, hover, keyboardWord].compactMap { $0 }
        let color = NSColor(UIUIStyle.accent).withAlphaComponent(0.28)
        for range in marked { layoutManager.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: range) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let found = word(at: convert(event.locationInWindow, from: nil))
        if found != hover { hover = found; restyle() }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; restyle() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let range = word(at: convert(event.locationInWindow, from: nil)) {
            keyboardWord = range
            onPick?(range, rect(of: range))
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124: moveKeyboardWord(forward: event.keyCode == 124)
        case 36, 76, 49:
            if let range = keyboardWord { onPick?(range, rect(of: range)) } else { moveKeyboardWord(forward: true) }
        default: super.keyDown(with: event)
        }
    }

    private func moveKeyboardWord(forward: Bool) {
        let length = (plainText as NSString).length
        var offset = forward ? (keyboardWord.map(NSMaxRange) ?? 0) : ((keyboardWord?.location ?? length) - 1)
        while offset >= 0, offset < length {
            if let range = HistoryCorrection.wordRange(in: plainText, atUTF16Offset: offset) {
                keyboardWord = range; restyle(); scrollToVisible(rect(of: range).insetBy(dx: -8, dy: -12)); return
            }
            offset += forward ? 1 : -1
        }
    }
}

private struct FixableText: NSViewRepresentable {
    let text: String
    let highlighted: NSRange?
    let onPick: (NSRange, CGRect) -> Void

    func makeNSView(context: Context) -> FixTextView {
        let view = FixTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.setAccessibilityLabel("Saved text")
        view.setAccessibilityHelp("Choose a word with the arrow keys and press Return to fix it.")
        return view
    }

    func updateNSView(_ view: FixTextView, context: Context) {
        view.onPick = onPick
        view.configure(text: text)
        view.highlight = highlighted
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: FixTextView, context: Context) -> CGSize? {
        view.configure(text: text)
        let width = proposal.width ?? 600
        return CGSize(width: width, height: view.height(forWidth: width))
    }
}

struct FixWordForm: View {
    let word: String
    let otherMatches: Int
    let onCancel: () -> Void
    let onSubmit: (_ correction: String, _ alsoFixOthers: Bool, _ addToDictionary: Bool) async -> String?
    @State private var correction = ""
    @State private var alsoFixOthers = false
    @State private var addToDictionary: Bool
    @State private var problem: String?
    @State private var working = false
    @FocusState private var focused: Bool

    init(word: String, otherMatches: Int = 0, onCancel: @escaping () -> Void,
         onSubmit: @escaping (_ correction: String, _ alsoFixOthers: Bool, _ addToDictionary: Bool) async -> String?) {
        self.word = word
        self.otherMatches = otherMatches
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _addToDictionary = State(initialValue: HistoryCorrection.suggestsDictionaryEntry(for: word))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fix “\(word)”").font(.system(size: 13, weight: .semibold))
            TextField("Write it as", text: $correction).textFieldStyle(.roundedBorder).focused($focused)
                .frame(width: 240).onSubmit(apply).accessibilityLabel("Correct spelling")
            if otherMatches > 0 {
                Toggle(isOn: $alsoFixOthers) {
                    Text("Also fix other matches here (\(otherMatches))").font(.system(size: 12))
                }.toggleStyle(.checkbox)
                Text("Whole words with the same spelling and capitals, in this text only.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $addToDictionary) {
                Text("Use this spelling in future dictation").font(.system(size: 12))
            }.toggleStyle(.checkbox)
            Text(addToDictionary
                 ? "“\(word.lowercased())” will be written the way you type above, for all projects."
                 : "Only this saved text changes. Your dictionary stays as it is.")
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
            problem = await onSubmit(correction, alsoFixOthers && otherMatches > 0, addToDictionary)
            working = false
        }
    }
}
