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

/// Text and controls remain separate from the stable Mosaic drawing layer.
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
    var rendersMosaic = true
    var onPointerEnter: () -> Void = {}
    var onPointerExit: () -> Void = {}
    @State private var hovering = false
    @Environment(\.notchReduceMotion) private var reduceMotion

    private var phase: NotchFeedbackPhase { feedbackPreviewPhase ?? model.notchFeedbackPhase }
    private var level: Double {
        let value = feedbackPreviewLevel ?? model.notchAudioLevel
        return value.isFinite ? min(1, max(0, value)) : 0
    }
    private var cameraHeader: CGFloat { model.notchHasCamera ? max(34, model.notchCameraHeight) : 32 }
    private var cameraWidth: CGFloat { model.notchHasCamera ? model.notchCameraWidth : 0 }
    private var rowHeight: CGFloat { model.settings.notchSize.rowHeight }
    private var statusLabel: String {
        if phase == .recording { return "Dictation listening. Microphone on" }
        if phase == .preparing { return "Starting dictation. Microphone not ready" }
        if model.queuedVoiceCaptureKind != nil || phase == .queued { return "Next recording queued. Microphone off" }
        if phase == .processing { return "Processing dictation. Microphone off" }
        if let feedback = model.notchVoiceFeedback { return "Microphone off. " + feedback.compactText }
        if let issue = model.notchActionableError { return "Microphone off. " + issue }
        return "Microphone off"
    }
    private var transcript: String {
        if let feedbackPreviewTranscript { return feedbackPreviewTranscript }
        if model.showsNotchStylePreview { return "This is how uiui looks while you talk." }
        return model.speech.hasActiveSession ? model.liveTranscript : model.voiceTranscript
    }
    private var reason: String { model.notchActionableError ?? model.notchVoiceFeedback?.detail ?? "" }

    var body: some View {
        Group {
            if expanded { compactHUD }
            else {
                Button(action: onExpand) {
                    HStack(spacing: 0) {
                        NotchPresenceMark(phase: phase, level: level).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 8)
                        Color.clear.frame(width: cameraWidth, height: 1)
                        NotchGlanceContext(phase: phase, level: level, queued: model.queuedVoiceCaptureKind != nil)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    }.padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: cameraHeader).contentShape(Rectangle())
                }.buttonStyle(.plain).help(statusLabel)
                    .accessibilityLabel(statusLabel + ". Open uiui.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if rendersMosaic {
                ZStack {
                    Color.black
                    NotchVisualFeedback(phase: phase, level: level, hasCamera: model.notchHasCamera,
                        cameraWidth: model.notchCameraWidth, cameraHeight: model.notchCameraHeight,
                        style: model.settings.notchVisualStyle, feedbackID: model.notchVoiceFeedback?.id,
                        previewProgress: feedbackPreviewProgress ?? pastePreviewProgress)
                }
            }
        }
        .clipShape(NotchContour(topRadius: expanded ? 14 : 9, bottomRadius: expanded ? 24 : 14))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(statusLabel)
        .accessibilityAction(named: Text("Cancel recording")) {
            if model.hasCancellableVoiceInput { model.cancelVoiceInputFromEscape() }
        }
        .accessibilityAction(named: Text("Finish recording")) { finishCapture() }
        .contextMenu {
            Button("History") { model.openLibrary() }
            Button("Settings") { model.openSettings() }
        }
        .onHover { over in
            hovering = over
            if over { onPointerEnter() } else if expanded { onPointerExit() }
            if over && !expanded && model.settings.openOnHover && !model.settings.quietMode { onExpand() }
        }
    }

    private var shortNotice: String {
        if phase == .copied { return "Copied · press ⌘V" }
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

    private var compactHUD: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                NotchPresenceMark(phase: phase, level: level).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 8)
                Color.clear.frame(width: cameraWidth, height: 1)
                if isIdle {
                    // The notch panel never takes focus, so the app you were typing
                    // in stays the paste destination, exactly like the shortcut.
                    HStack(spacing: 4) {
                        Button { model.beginVoiceCapture() } label: {
                            Image(systemName: "mic.fill").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(UIUIStyle.lime.opacity(hovering ? 1 : 0.75))
                                .frame(width: 26, height: 26).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Start dictation").accessibilityLabel("Start dictation")
                        hudButton("chevron.up", label: "Collapse uiui", action: onCollapse)
                            .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                } else {
                ZStack {
                    NotchGlanceContext(phase: phase, level: level, queued: model.queuedVoiceCaptureKind != nil)
                        .opacity(hovering ? 0 : 1)
                    HStack(spacing: 2) {
                        if model.hasCancellableVoiceInput {
                            hudButton("xmark", label: "Cancel recording") { model.cancelVoiceInputFromEscape() }
                            if phase == .recording || phase == .preparing {
                                hudButton("stop.fill", label: "Finish recording", action: finishCapture)
                            }
                        } else {
                            hudButton("chevron.up", label: "Collapse uiui", action: onCollapse)
                        }
                    }
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }.frame(width: 26, height: 26)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: cameraHeader)
            .help(statusLabel)
            if hasTranscriptSlot {
                ZStack(alignment: .leading) {
                    // Keep the viewport mounted through fast recognition/cleanup
                    // changes, fading the words instead of removing a whole row.
                    RollingTranscriptLine(text: transcript, isError: false, accent: .white,
                                          fontSize: model.settings.notchSize.transcriptFontSize, rowHeight: rowHeight)
                        .opacity(model.showsSpeechDownload ? 0 : phase == .recording ? 1 : phase == .processing ? 0.42 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: phase)
                        .accessibilityHidden(phase != .recording && phase != .processing)
                    if model.showsSpeechDownload { NotchDownloadBar(fraction: model.speechPreparationFraction) }
                    if phase == .copied || phase == .needsInput {
                        // A couple of words, always visible; the full reason is a tooltip.
                        Text(shortNotice).font(.system(size: model.settings.notchSize.transcriptFontSize - 1, weight: .medium))
                            .foregroundStyle(Color.orange.opacity(0.9)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .help(reason).accessibilityLabel(reason.isEmpty ? shortNotice : reason)
                    }
                }
                .frame(height: rowHeight).padding(.horizontal, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

/// Only actual audio changes animate the eyes; idle has no clock or blinking loop.
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
        UIUIMark(size: 26, dark: true, accent: UIUIStyle.lime)
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
            if queued || phase == .queued { Image(systemName: "rectangle.stack").foregroundStyle(UIUIStyle.lime) }
            else if phase == .recording {
                HStack(spacing: 2) {
                    ForEach(0..<5) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(UIUIStyle.lime.opacity(0.8))
                            .frame(width: 1.5, height: CGFloat(3 + 13 * level * [0.4, 0.8, 1.0, 0.7, 0.5][index]))
                    }
                }.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            } else if phase == .copied { Image(systemName: "square.on.square").foregroundStyle(.orange) }
            else if phase == .needsInput { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            else if phase == .success { Image(systemName: "checkmark").foregroundStyle(UIUIStyle.lime) }
            else if phase == .processing { Image(systemName: "ellipsis").foregroundStyle(UIUIStyle.lime.opacity(0.7)) }
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
    private var singleLine: String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    var body: some View {
        GeometryReader { geometry in
            let overflow = max(0, measuredWidth - geometry.size.width)
            Text(singleLine)
                .font(.system(size: isError ? fontSize - 2 : fontSize))
                .foregroundStyle(isError ? Color.orange.opacity(0.9) : accent.opacity(0.9))
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { textGeometry in
                        Color.clear.preference(key: TranscriptWidthKey.self, value: textGeometry.size.width)
                    }
                }
                .offset(x: -overflow)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: overflow)
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
                    Capsule().fill(UIUIStyle.lime)
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
