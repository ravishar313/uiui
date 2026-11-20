import SwiftUI
import UIUICore

/// The first thing in the notebook: the last dictation, or the live words while talking.
/// Notices and warnings sit right under it (see `HomeNotices`).
struct VoiceHomeView: View {
    let model: AppModel
    /// Opens a saved item in fix-a-word mode.
    var onFix: (CaptureItem) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    private var microphoneActive: Bool { model.microphoneIsActive }
    private var isLive: Bool { model.voiceIsRecording || microphoneActive || model.voice.state == "finishing" }
    private var showingLiveTranscript: Bool { !model.voiceTranscript.isEmpty && isLive }
    /// The saved item behind the last dictation, when it has been kept.
    private var latestItem: CaptureItem? {
        guard let latest = model.latestDictation else { return nil }
        return model.items.filter { $0.kind == .dictation && $0.body == latest.text }.max { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        card
            .frame(maxWidth: .infinity, alignment: .leading)
            .uiuiCard()
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLive {
                liveContent
            } else if let latest = model.latestDictation {
                latestContent(latest)
            } else {
                emptyContent
            }
        }.padding(.horizontal, 26).padding(.vertical, 22)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }

    // MARK: Live

    @ViewBuilder private var liveContent: some View {
        HStack(spacing: 7) {
            if model.isVoicePaused {
                Image(systemName: "pause.circle.fill").font(.system(size: 11)).foregroundStyle(UIUIStyle.tint(scheme)).accessibilityHidden(true)
            } else {
                Circle().fill(UIUIStyle.accent).frame(width: 6, height: 6)
            }
            Text(model.isVoicePaused ? "Paused" : "Listening").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
        if showingLiveTranscript {
            ScrollView {
                liveText(model.voiceTranscript).font(UIUIStyle.words(24)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 190)
        } else {
            Text(model.isVoicePaused ? "Paused. Nothing is being transcribed. Press Control-Option-P to continue."
                 : "Start speaking. Your words appear here.")
                .font(UIUIStyle.words(20)).foregroundStyle(.secondary).lineSpacing(5)
        }
    }

    /// The newest few words are lime; what came before is ink.
    private func liveText(_ transcript: String) -> Text {
        let words = transcript.split(separator: " ", omittingEmptySubsequences: false)
        let tailCount = min(3, words.count)
        let head = words.dropLast(tailCount).joined(separator: " ")
        let tail = words.suffix(tailCount).joined(separator: " ")
        let separator = head.isEmpty ? "" : " "
        return Text(head + separator) + Text(tail).foregroundStyle(UIUIStyle.tint(scheme))
    }

    // MARK: Last dictation

    @ViewBuilder private func latestContent(_ latest: LatestDictation) -> some View {
        Text(meta(latest)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        Text(latest.text).font(UIUIStyle.words(24)).lineSpacing(6).lineLimit(6)
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        HStack(spacing: 8) {
            Button { model.copyLatestDictation() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(ChipButtonStyle()).disabled(!model.canCopyLatestDictation)
                .help("Copy the last dictation").accessibilityLabel("Copy last dictation")
            Button { if let item = latestItem { onFix(item) } } label: { Label("Fix a word", systemImage: "character.cursor.ibeam") }
                .buttonStyle(ChipButtonStyle()).disabled(latestItem == nil)
                .help(latestItem == nil ? "This dictation is not saved in history" : "Click a misheard word to correct it and teach uiui")
            Button { if let item = latestItem { model.togglePin(item) } } label: {
                Label(latestItem?.isPinned == true ? "Pinned" : "Pin", systemImage: latestItem?.isPinned == true ? "pin.fill" : "pin")
            }.buttonStyle(ChipButtonStyle()).disabled(latestItem == nil)
                .help(latestItem?.isPinned == true ? "Unpin this dictation" : "Keep this dictation at the top of the notebook")
        }
    }

    private func meta(_ latest: LatestDictation) -> String {
        var parts = ["Last dictation"]
        if let app = latest.app, !app.isEmpty { parts.append("pasted in \(app)") }
        if let date = latest.date { parts.append(date.formatted(.relative(presentation: .named, unitsStyle: .wide))) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: New user

    @ViewBuilder private var emptyContent: some View {
        Text("Your first dictation will show up here.").font(UIUIStyle.words(24)).lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        if model.settings.voiceTriggerEnabled {
            HStack(spacing: 12) {
                VoiceKeycap(key: model.settings.voiceTriggerKey)
                Text("Click into any text field, \(shortcutVerb), and speak. Your words are typed there\(model.settings.saveDictationHistory ? " and kept in this notebook" : "").")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }.accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 8) {
                Text("The voice shortcut is off.").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Turn on in Settings") { model.openSettings() }.buttonStyle(.link).font(.system(size: 12))
            }
        }
    }

    private var shortcutVerb: String {
        let key = model.settings.voiceTriggerKey
        let name = key == .fn ? "fn" : key.title
        return model.settings.voiceTriggerMode == .hold ? "hold \(name)" : "tap \(name)"
    }
}

/// Warnings and receipts that belong right under the last dictation.
struct HomeNotices: View {
    let model: AppModel
    private var modeAccent: Color { UIUIStyle.accent }
    private var deliveryStatus: String? {
        guard model.activeVoiceFeedback == nil else { return nil }
        if let issue = model.dictationDeliveryIssue, !issue.isEmpty { return issue }
        guard model.voiceIsRecording || model.voice.state == "finishing", !model.dictationStreamingStatus.isEmpty else { return nil }
        return model.dictationStreamingStatus
    }
    private var shortcutAccessGuidance: String? {
        let status = model.voiceTriggerStatus
        let normalized = status.lowercased()
        guard !status.isEmpty,
              normalized != "shortcut ready \u{00B7} microphone off",
              normalized != "voice key is off.",
              !normalized.hasSuffix(" is ready in uiui and other apps.") else { return nil }
        return status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let updater = model.updater, let release = updater.pendingNotice {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").accessibilityHidden(true)
                    Text("uiui \(release.version) is available").lineLimit(1)
                    Button("Review") { updater.presentPendingUpdate() }.buttonStyle(.borderless)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let warning = model.speechEngineWarning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let status = deliveryStatus {
                Label(status, systemImage: model.dictationDeliveryIssue == nil ? "text.cursor" : "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(model.dictationDeliveryIssue == nil ? Color.secondary : Color.orange)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let feedback = model.activeVoiceFeedback {
                ScrollView { VoiceActionReceipt(feedback: feedback, modeAccent: modeAccent) }.frame(maxHeight: 100)
            }
            if let guidance = shortcutAccessGuidance {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(guidance).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Settings") { model.openSettings() }.buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            if let error = model.voiceError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A durable receipt of the action result, separate from the microphone's current state.
private struct VoiceActionReceipt: View {
    let feedback: VoiceActionFeedback
    let modeAccent: Color
    private var accent: Color {
        switch feedback.state {
        case .success: return .green
        case .failure, .needsInput: return .orange
        case .working, .information: return modeAccent
        }
    }
    private var symbol: String {
        switch feedback.state {
        case .success: return "checkmark.circle.fill"
        case .needsInput: return "questionmark.circle"
        case .failure: return "exclamationmark.circle"
        case .working, .information: return feedback.symbol
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if feedback.state == .working {
                    ProgressView().controlSize(.small).tint(modeAccent)
                } else {
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(accent)
                }
            }.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(feedback.title).font(.system(size: 12, weight: .semibold))
                if !feedback.detail.isEmpty {
                    Text(feedback.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(accent.opacity(0.10)) }
            .accessibilityElement(children: .combine)
    }
}
