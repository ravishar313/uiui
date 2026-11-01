import SwiftUI
import UIUICore

/// Explicit state for native previews and tests, so the extra notch states can be
/// drawn without a microphone, a clipboard or another app.
struct NotchPreviewState: Equatable {
    var paused = false
    var cannotHear = false
    var micHint: String?
    var timer: String?
    var transcriptOpen = false
    var undo = false
    var sentApp: String?
    var copiedApp: String?
    var hovering = false
}

/// Text and controls remain separate from the stable drawing layer.
struct NotchView: View {
    @Bindable var model: AppModel
    let expanded: Bool
    let onExpand: () -> Void
    let onCollapse: () -> Void
    var pastePreviewProgress: Double? = nil
    var feedbackPreviewPhase: NotchFeedbackPhase? = nil
    var feedbackPreviewProgress: Double? = nil
    var feedbackPreviewLevel: Double? = nil
    var feedbackPreviewTranscript: String? = nil
    var preview: NotchPreviewState? = nil
    var rendersMosaic = true
    var onPointerEnter: () -> Void = {}
    var onPointerExit: () -> Void = {}
    @State private var hovering = false
    @Environment(\.notchReduceMotion) private var reduceMotion

    private var extras: NotchCaptureExtras { model.notchExtras }
    private var phase: NotchFeedbackPhase { feedbackPreviewPhase ?? model.notchFeedbackPhase }
    private var style: NotchVisualStyle { model.settings.notchVisualStyle }
    private var level: Double {
        let value = feedbackPreviewLevel ?? model.notchAudioLevel
        return value.isFinite ? min(1, max(0, value)) : 0
    }
    private var cameraHeader: CGFloat { model.notchHasCamera ? max(34, model.notchCameraHeight) : 32 }
    private var cameraWidth: CGFloat { model.notchHasCamera ? model.notchCameraWidth : 0 }
    private var rowHeight: CGFloat { model.settings.notchSize.rowHeight }
    private var fontSize: CGFloat { model.settings.notchSize.transcriptFontSize }
    private var isHovering: Bool { hovering || preview?.hovering == true }

    // Extra capture state, from the model or from an explicit preview.
    private var paused: Bool { phase == .recording && (preview?.paused ?? model.notchVoiceIsPaused) }
    private var cannotHear: Bool { phase == .recording && (preview?.cannotHear ?? extras.cannotHear) }
    private var micHint: String? { phase == .recording ? (preview?.micHint ?? extras.micHint) : nil }
    private var transcriptOpen: Bool { phase == .recording && (preview?.transcriptOpen ?? extras.transcriptOpen) }
    private var offersUndo: Bool {
        phase == .dispatched && (preview?.undo ?? (model.notchVoiceFeedback?.offersUndo == true))
    }
    private var undoAvailable: Bool { preview?.undo ?? model.notchUndoAvailable }
    private var sentApp: String? { preview?.sentApp ?? extras.undoOffer?.appName ?? model.voiceDestination?.appName }
    private var copiedApp: String? { preview?.copiedApp ?? model.voiceDestination?.appName }
    private var canPause: Bool { phase == .recording && (preview?.hovering == true || model.canPauseVoiceCapture) }
    /// Eyes and Voice bars draw the whole header; the logo and glance marks step aside.
    private var stylePaintsHeader: Bool { (style == .eyes || style == .bars) && phase != .idle }

    private var statusLabel: String {
        if phase == .recording {
            if paused { return "Dictation paused. No audio is being transcribed" }
            if cannotHear { return "Dictation listening. Can't hear you" }
            return "Dictation listening. Microphone on"
        }
        if phase == .preparing { return "Starting dictation. Microphone not ready" }
        if model.queuedVoiceCaptureKind != nil || phase == .queued { return "Next recording queued. Microphone off" }
        if phase == .processing { return "Processing dictation. Microphone off" }
        if offersUndo { return undoAvailable ? "Paste sent. Undo and Copy available" : "Paste sent. Copy available" }
        if let feedback = model.notchVoiceFeedback { return "Microphone off. " + feedback.compactText }
        if let issue = model.notchActionableError { return "Microphone off. " + issue }
        return "Microphone off"
    }
    private var transcript: String {
        if let feedbackPreviewTranscript { return feedbackPreviewTranscript }
        if model.showsNotchStylePreview { return "This is how uiui looks while you talk." }
        return model.notchTranscript
    }
    private var reason: String { model.notchActionableError ?? model.notchVoiceFeedback?.detail ?? "" }

    /// What replaces or accompanies the transcript line while recording.
    private var statusBadge: (text: String, color: Color)? {
        if paused { return ("Paused", .white.opacity(0.78)) }
        if cannotHear { return ("Can't hear you", Color(red: 0.97, green: 0.67, blue: 0.26)) }
        if let hint = micHint { return (hint, .white.opacity(0.62)) }
        return nil
    }
    private var timerVisible: Bool {
        guard phase == .recording else { return false }
        return preview?.timer != nil || extras.showsTimer
    }

    var body: some View {
        Group {
            if expanded { compactHUD }
            else {
                Button(action: onExpand) {
                    HStack(spacing: 0) {
                        // Centred in the wing: the compact notch has no room for a side margin.
                        NotchPresenceMark(phase: phase, level: level).opacity(stylePaintsHeader ? 0 : 1)
                            .frame(maxWidth: .infinity)
                        Color.clear.frame(width: cameraWidth, height: 1)
                        NotchGlanceContext(phase: phase, level: level, queued: model.queuedVoiceCaptureKind != nil)
                            .opacity(stylePaintsHeader ? 0 : 1)
                            .frame(maxWidth: .infinity)
                    }.frame(maxWidth: .infinity).frame(height: cameraHeader).contentShape(Rectangle())
                }.buttonStyle(.plain).help(statusLabel)
                    .accessibilityLabel(statusLabel + ". Open uiui.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if rendersMosaic {
                ZStack {
                    Color.black
                    NotchVisualFeedback(phase: phase, level: paused ? 0 : level, hasCamera: model.notchHasCamera,
                        cameraWidth: model.notchCameraWidth, cameraHeight: model.notchCameraHeight,
                        style: style, feedbackID: model.notchVoiceFeedback?.id,
                        previewProgress: feedbackPreviewProgress ?? pastePreviewProgress,
                        paused: paused, dimmed: isHovering && (model.hasCancellableVoiceInput || preview?.hovering == true),
                        textActive: !transcript.isEmpty)
                }
            }
        }
        .clipShape(NotchOutline(hasCamera: model.notchHasCamera, expanded: expanded))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(statusLabel)
        .accessibilityAction(named: Text("Cancel recording")) {
            if model.hasCancellableVoiceInput { model.cancelVoiceInputFromEscape() }
        }
        .accessibilityAction(named: Text("Finish recording")) { finishCapture() }
        .accessibilityAction(named: Text(paused ? "Resume recording" : "Pause recording")) {
            if model.canPauseVoiceCapture { model.toggleVoicePause() }
        }
        .contextMenu {
            Button("History") { model.openLibrary() }
            Button("Settings") { model.openSettings() }
        }
        .onHover { over in
            hovering = over
            extras.setPointerOver(over, capturing: phase == .recording && model.hasCancellableVoiceInput)
            if over { onPointerEnter() } else if expanded { onPointerExit() }
            if over && !expanded && model.settings.openOnHover && !model.settings.quietMode { onExpand() }
        }
    }

    private var shortNotice: String {
        if phase == .copied { return NotchPasteFailureText.copied(appName: copiedApp) }
        let lowered = reason.lowercased()
        if lowered.contains("accessibility") { return "Allow Accessibility" }
        if lowered.contains("microphone") { return "Allow microphone" }
        if lowered.contains("speech") { return "Speech not ready" }
        return "Needs attention"
    }

    private var isIdle: Bool { phase == .idle && !model.hasCancellableVoiceInput }

    private var hasTranscriptSlot: Bool {
        switch phase {
        case .preparing, .recording, .processing, .queued, .dispatched, .copied, .needsInput: true
        default: false
        }
    }

    private var rowOpacity: Double {
        if model.showsSpeechDownload { return 0 }
        switch phase {
        case .recording: return paused ? 0.55 : 1
        case .processing: return 0.42
        default: return 0
        }
    }

    /// Width held back at the right of the line for the badge and timer.
    private var trailingReserve: CGFloat {
        var width: CGFloat = 0
        if let badge = statusBadge, !transcript.isEmpty { width += CGFloat(badge.text.count) * 5.4 + 12 }
        return width
    }

    private var compactHUD: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ZStack {
                    NotchPresenceMark(phase: phase, level: level)
                        .opacity(stylePaintsHeader || (canPause && isHovering) ? 0 : 1)
                    if canPause {
                        hudButton(paused ? "play.fill" : "pause.fill",
                                  label: paused ? "Resume recording" : "Pause recording") { model.toggleVoicePause() }
                            .opacity(isHovering ? 1 : 0).allowsHitTesting(isHovering)
                    }
                }
                .frame(maxWidth: .infinity) // Centred in the wing at every notch size.
                Color.clear.frame(width: cameraWidth, height: 1)
                if isIdle {
                    // The notch panel never takes focus, so the app you were typing
                    // in stays the paste destination, exactly like the shortcut.
                    HStack(spacing: 4) {
                        Button { model.beginVoiceCapture() } label: {
                            Image(systemName: "mic.fill").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(UIUIStyle.accent.opacity(isHovering ? 1 : 0.75))
                                .frame(width: 26, height: 26).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Start dictation").accessibilityLabel("Start dictation")
                        hudButton("chevron.up", label: "Collapse uiui", action: onCollapse)
                            .opacity(isHovering ? 1 : 0).allowsHitTesting(isHovering)
                    }.frame(maxWidth: .infinity)
                } else {
                ZStack {
                    // While recording the words show that you are speaking, so this
                    // wing keeps the time. Eyes and Voice bars paint this wing themselves.
                    if phase == .recording, !(model.queuedVoiceCaptureKind != nil) {
                        timerView.opacity(isHovering || stylePaintsHeader ? 0 : 1)
                    } else {
                        NotchGlanceContext(phase: phase, level: level, queued: model.queuedVoiceCaptureKind != nil)
                            .opacity(isHovering || stylePaintsHeader ? 0 : 1)
                    }
                    HStack(spacing: 2) {
                        if model.hasCancellableVoiceInput || preview?.hovering == true {
                            hudButton("xmark", label: "Cancel recording") { model.cancelVoiceInputFromEscape() }
                            if phase == .recording || phase == .preparing {
                                hudButton("stop.fill", label: "Finish recording", action: finishCapture)
                            }
                        } else {
                            hudButton("chevron.up", label: "Collapse uiui", action: onCollapse)
                        }
                    }
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                }.frame(minWidth: 26, minHeight: 26)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: cameraHeader)
            .help(statusLabel)
            if hasTranscriptSlot {
                lowerRow
                    .frame(height: rowHeight + (transcriptOpen ? NotchLayout.hoverTranscriptExtra : 0), alignment: .top)
                    .padding(.horizontal, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var lowerRow: some View {
        if offersUndo {
            sentRow
        } else if transcriptOpen {
            HoverTranscript(text: transcript, fontSize: fontSize,
                            badge: statusBadge, timer: timerView, staticLayout: preview != nil)
        } else {
            ZStack(alignment: .leading) {
                // Keep the viewport mounted through fast recognition/cleanup
                // changes, fading the words instead of removing a whole row.
                RollingTranscriptLine(text: transcript, isError: false, accent: .white,
                                      fontSize: fontSize + (style == .words ? 1 : 0), rowHeight: rowHeight)
                    .padding(.trailing, trailingReserve)
                    .opacity(rowOpacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: phase)
                    .accessibilityHidden(phase != .recording && phase != .processing)
                if phase == .recording, transcript.isEmpty, let badge = statusBadge {
                    Text(badge.text).font(.system(size: fontSize, weight: .medium)).foregroundStyle(badge.color)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel(badge.text)
                }
                if phase == .recording, !transcript.isEmpty, let badge = statusBadge {
                    Text(badge.text).font(.system(size: fontSize - 1, weight: .medium)).foregroundStyle(badge.color)
                        .lineLimit(1).accessibilityLabel(badge.text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if model.showsSpeechDownload { NotchDownloadBar(fraction: model.speechPreparationFraction) }
                if phase == .copied || phase == .needsInput {
                    // A couple of words, always visible; the full reason is a tooltip.
                    Text(shortNotice).font(.system(size: fontSize - 1, weight: .medium))
                        .foregroundStyle(Color.orange.opacity(0.9)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .help(reason).accessibilityLabel(reason.isEmpty ? shortNotice : reason)
                }
            }
        }
    }

    @ViewBuilder private var timerView: some View {
        if timerVisible {
            if let text = preview?.timer {
                Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7)).accessibilityLabel("Recording time " + text)
            } else {
                Text(timerInterval: extras.timerReference...extras.timerReference.addingTimeInterval(86_400),
                     pauseTime: extras.timerPausedAt, countsDown: false)
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7)).lineLimit(1).fixedSize()
                    .accessibilityLabel("Recording time")
            }
        }
    }

    /// Brief sent state: reachable by pointer, never focus.
    private var sentRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: fontSize - 2, weight: .semibold))
                .foregroundStyle(UIUIStyle.accent).accessibilityHidden(true)
            Text(sentApp.map { "Sent to \($0)" } ?? "Sent").font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.82)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if undoAvailable {
                sentButton("Undo", symbol: "arrow.uturn.backward", label: "Undo paste") { model.undoLastPaste() }
            }
            sentButton("Copy", symbol: "doc.on.doc", label: "Copy dictation") { model.copyLastDictation() }
        }
        .frame(height: rowHeight)
    }

    private func sentButton(_ title: String, symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: fontSize - 3, weight: .medium))
                Text(title).font(.system(size: fontSize - 1, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7).frame(height: rowHeight - 2)
            .background(.white.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private func finishCapture() {
        if model.queuedVoiceCaptureKind != nil || model.voiceIsRecording { model.finishVoiceCapture() }
        else if model.isRecording { model.toggleRecording() }
    }
    private func hudButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.66)).frame(width: 16, height: 18).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// The full transcript so far while the pointer rests on a recording. Scrolls by
/// pointer or trackpad; it never takes keyboard focus.
private struct HoverTranscript<Timer: View>: View {
    let text: String
    let fontSize: CGFloat
    let badge: (text: String, color: Color)?
    let timer: Timer
    /// ImageRenderer cannot draw a ScrollView, so previews lay the same text out bottom-aligned.
    var staticLayout = false
    @State private var follow = NotchTranscriptFollow()
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 2) {
            if staticLayout {
                Text(NotchWordsText.attributed(text))
                    .font(.system(size: fontSize)).lineSpacing(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).clipped()
            } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            if text.isEmpty {
                                Text(badge?.text ?? "Listening").foregroundStyle(badge?.color ?? .white.opacity(0.5))
                            } else {
                                Text(NotchWordsText.attributed(text))
                            }
                        }
                        .font(.system(size: fontSize)).lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.disabled)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: TranscriptContentKey.self,
                                                   value: .init(minY: geometry.frame(in: .named("hoverTranscript")).minY, height: geometry.size.height))
                        }
                    }
                }
                .coordinateSpace(name: "hoverTranscript")
                .background {
                    GeometryReader { geometry in Color.clear.preference(key: TranscriptViewportKey.self, value: geometry.size.height) }
                }
                .onPreferenceChange(TranscriptViewportKey.self) { viewportHeight = $0 }
                .onPreferenceChange(TranscriptContentKey.self) { content in
                    // New words keep the view at the end only while the person is at the end.
                    if follow.update(contentHeight: content.height, offset: -content.minY, viewportHeight: viewportHeight) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            }
            HStack(spacing: 6) {
                if !text.isEmpty, let badge {
                    Text(badge.text).font(.system(size: fontSize - 2, weight: .medium)).foregroundStyle(badge.color)
                }
                Spacer()
                timer
            }.frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.isEmpty ? "No transcript yet" : text)
        .help("Transcript so far")
    }
}

private struct TranscriptContent: Equatable {
    var minY: CGFloat = 0
    var height: CGFloat = 0
}
private struct TranscriptContentKey: PreferenceKey {
    static var defaultValue = TranscriptContent()
    static func reduce(value: inout TranscriptContent, nextValue: () -> TranscriptContent) { value = nextValue() }
}
private struct TranscriptViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Newest words in the accent colour, fading to white a few words back. Only the last
/// few words are styled one by one; everything older is one plain run, so the cost of an
/// update does not grow with the length of the transcript.
enum NotchWordsText {
    static let fadeWords = 5
    /// The one-line viewport shows the end of the text; this many trailing characters are plenty.
    static let rollingLineCharacters = 240

    /// 1 for the newest word, falling to 0 after `fadeWords` words.
    static func recency(index: Int, count: Int) -> Double {
        guard count > 0, index >= 0, index < count else { return 0 }
        return max(0, 1 - Double(count - 1 - index) / Double(fadeWords))
    }

    /// Where the last `fadeWords` words begin (just after the word before them),
    /// found by walking back from the end: cost depends on the tail, not the text.
    static func tailStart(in text: String) -> String.Index {
        var index = text.endIndex
        var words = 0
        var inWord = false
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous].isWhitespace { inWord = false }
            else if !inWord {
                inWord = true
                words += 1
                if words > fadeWords { return index }
            }
            index = previous
        }
        return text.startIndex
    }

    /// The last `rollingLineCharacters` of `text`, whitespace collapsed to single spaces.
    static func rollingTail(of text: String) -> String {
        String(text.suffix(rollingLineCharacters)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func attributed(_ text: String) -> AttributedString {
        let split = tailStart(in: text)
        var result = AttributedString()
        if split > text.startIndex {
            result = AttributedString(String(text[..<split]) + " ")
            result.foregroundColor = blend(0)
        }
        let words = text[split...].split(whereSeparator: { $0.isWhitespace })
        for (index, word) in words.enumerated() {
            var piece = AttributedString(String(word) + (index < words.count - 1 ? " " : ""))
            piece.foregroundColor = blend(recency(index: index, count: words.count))
            result += piece
        }
        return result
    }

    static func blend(_ recency: Double) -> Color {
        // Only ever called while a view draws, on the main thread.
        let accent = MainActor.assumeIsolated { UIUIStyle.accentStore.rgb }
        let t = min(1, max(0, recency))
        let base = 0.86 - 0.0 // older words are a quiet white
        return Color(red: base + (accent.red - base) * t, green: base + (accent.green - base) * t, blue: base + (accent.blue - base) * t)
    }
}

private struct NotchPresenceMark: View {
    let phase: NotchFeedbackPhase
    let level: Double
    @Environment(\.notchReduceMotion) private var reduceMotion
    private var heightScale: CGFloat {
        switch phase {
        case .preparing: 0.45
        case .processing: 0.55
        case .dispatched: 0.22
        case .cancelled: 0.12
        case .recording: reduceMotion ? 1 : 1 + 0.13 * CGFloat(min(1, max(0, level)))
        default: 1
        }
    }
    var body: some View {
        UIUIMark(size: 26, dark: true, accent: UIUIStyle.accent, highlight: false)
            .opacity(phase == .idle ? 0.52 : phase == .cancelled ? 0.24 : 1)
            .scaleEffect(x: 1, y: heightScale)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            .animation(reduceMotion ? nil : .timingCurve(0.22, 0.8, 0.25, 1, duration: 0.16), value: phase)
            .frame(width: 26, height: 26).accessibilityHidden(true)
    }
}

/// Compact semantic marks supplement the field without repeating status labels.
private struct NotchGlanceContext: View {
    let phase: NotchFeedbackPhase
    let level: Double
    var queued = false
    @Environment(\.notchReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            mark.id(phase.rawValue + (queued ? "-queued" : ""))
                .transition(.opacity)
        }
        .font(.system(size: 12, weight: .medium))
        .frame(width: 26, height: 26)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: phase)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: queued)
        .accessibilityHidden(true)
    }
    private var mark: some View {
        Group {
            if queued || phase == .queued { Image(systemName: "rectangle.stack").foregroundStyle(UIUIStyle.accent) }
            else if phase == .recording {
                HStack(spacing: 2) {
                    ForEach(0..<5) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(UIUIStyle.accent.opacity(0.8))
                            .frame(width: 1.5, height: CGFloat(3 + 13 * level * [0.4, 0.8, 1.0, 0.7, 0.5][index]))
                    }
                }.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            } else if phase == .copied { Image(systemName: "square.on.square").foregroundStyle(.orange) }
            else if phase == .needsInput { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            else if phase == .success { Image(systemName: "checkmark").foregroundStyle(UIUIStyle.accent) }
            else if phase == .processing { Image(systemName: "ellipsis").foregroundStyle(UIUIStyle.accent.opacity(0.7)) }
            else { Color.clear }
        }
    }
}

private struct TranscriptWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A fixed-height trailing viewport. Only the measured text offset changes as words arrive.
private struct RollingTranscriptLine: View {
    let text: String
    let isError: Bool
    let accent: Color
    var fontSize: CGFloat = 12
    var rowHeight: CGFloat = 18
    @Environment(\.notchReduceMotion) private var reduceMotion
    @State private var measuredWidth: CGFloat = 0
    private var singleLine: String { NotchWordsText.rollingTail(of: text) }

    var body: some View {
        GeometryReader { geometry in
            let overflow = max(0, measuredWidth - geometry.size.width)
            Group {
                if !isError { Text(NotchWordsText.attributed(singleLine)) } else { Text(singleLine) }
            }
                .font(.system(size: isError ? fontSize - 2 : fontSize))
                .foregroundStyle(isError ? Color.orange.opacity(0.9) : accent.opacity(0.9))
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { textGeometry in
                        Color.clear.preference(key: TranscriptWidthKey.self, value: textGeometry.size.width)
                    }
                }
                .offset(x: -overflow)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: overflow)
                .frame(width: geometry.size.width, height: rowHeight, alignment: .leading)
                .clipped()
                .mask {
                    if overflow > 0 {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.055),
                            .init(color: .white, location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                    } else { Color.white }
                }
                .onPreferenceChange(TranscriptWidthKey.self) { measuredWidth = $0 }
                .accessibilityLabel(singleLine.isEmpty ? "No transcript yet" : singleLine)
                .help(isError ? text : "Live transcript")
        }.frame(height: rowHeight)
    }
}

/// Model download progress spanning the notch's width. Between packs (unpacking,
/// verifying) the fraction is unknown and the bar shows a quiet full track.
private struct NotchDownloadBar: View {
    let fraction: Double?
    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(UIUIStyle.accent)
                        .frame(width: max(6, geometry.size.width * min(1, max(0, fraction ?? 0))))
                        .opacity(fraction == nil ? 0 : 1)
                        .animation(.easeOut(duration: 0.2), value: fraction)
                }
            }.frame(height: 6)
            Text(fraction.map { "\(Int($0 * 100))%" } ?? "Preparing")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.75)).fixedSize()
        }
        .frame(height: 16)
        .help("Downloading the speech model")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading the speech model")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "Preparing")
    }
}
