import SwiftUI
import UIUICore

/// Home leads with the last dictation and the shortcut that makes the next one.
struct VoiceHomeView: View {
    let model: AppModel
    var showsUsage = true
    private var microphoneActive: Bool { model.microphoneIsActive }
    private var modeAccent: Color { UIUIStyle.accent }
    private var showingLiveTranscript: Bool {
        !model.voiceTranscript.isEmpty && (model.voiceIsRecording || microphoneActive || model.voice.state == "finishing")
    }
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
              normalized != "shortcut ready · microphone off",
              normalized != "voice key is off.",
              !normalized.hasSuffix(" is ready in uiui and other apps.") else { return nil }
        return status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                mainCard.frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                shortcutCard.frame(width: 268, alignment: .topLeading)
            }.fixedSize(horizontal: false, vertical: true)
            if showsUsage { UsageOverview(model: model) }
            if let updater = model.updater, let release = updater.pendingNotice {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").accessibilityHidden(true)
                    Text("uiui \(release.version) is available").lineLimit(1)
                    Button("Review") { updater.presentPendingUpdate() }.buttonStyle(.borderless)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let warning = model.speechEngineWarning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
                    Text(guidance).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Settings") { model.openSettings() }.buttonStyle(.borderless).font(.system(size: 10))
                }
            }
            if let error = model.voiceError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 12) }

    @ViewBuilder private var mainCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showingLiveTranscript || model.voiceIsRecording || microphoneActive {
                HStack(spacing: 6) {
                    if model.isVoicePaused {
                        Image(systemName: "pause.circle.fill").font(.system(size: 11)).foregroundStyle(modeAccent).accessibilityHidden(true)
                    } else {
                        Circle().fill(modeAccent).frame(width: 6, height: 6)
                    }
                    Text(model.isVoicePaused ? "Paused" : "Listening").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                if showingLiveTranscript {
                    ScrollView {
                        Text(model.voiceTranscript).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 96)
                } else {
                    Text(model.isVoicePaused ? "Paused. Nothing is being transcribed. Press Control-Option-P to continue."
                         : "Start speaking. Your words appear here.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            } else if let latest = model.latestDictation {
                HStack(spacing: 6) {
                    Text("Last dictation").font(.system(size: 11, weight: .semibold))
                    if let meta = latestMeta(latest) { Text("·").foregroundStyle(.tertiary); Text(meta).lineLimit(1) }
                    Spacer(minLength: 8)
                    Button { model.copyLatestDictation() } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(!model.canCopyLatestDictation)
                        .help("Copy the last dictation").accessibilityLabel("Copy last dictation")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                Text(latest.text).font(.system(size: 15)).lineSpacing(4).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            } else {
                emptyState
            }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.primary.opacity(0.03), in: cardShape)
            .overlay { cardShape.strokeBorder(.primary.opacity(0.07)) }
    }

    private func latestMeta(_ latest: LatestDictation) -> String? {
        var parts: [String] = []
        if let date = latest.date { parts.append(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))) }
        if let app = latest.app, !app.isEmpty { parts.append(app) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 20, weight: .light)).foregroundStyle(UIUIStyle.muted)
            Text("Nothing dictated yet").font(.system(size: 15, weight: .semibold))
            Text(model.settings.voiceTriggerEnabled
                 ? "Click into any text field, \(shortcutVerb), and speak. Your words are typed there\(model.settings.saveDictationHistory ? " and kept in history" : "")."
                 : "Press Dictate, then speak. Turn on the keyboard shortcut in Settings to dictate in any app.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutVerb: String {
        let key = model.settings.voiceTriggerKey
        let name = key == .fn ? "fn" : key.title
        return model.settings.voiceTriggerMode == .hold ? "hold \(name)" : "tap \(name)"
    }

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.settings.voiceTriggerEnabled {
                HStack(spacing: 10) {
                    LargeKeycap(key: model.settings.voiceTriggerKey)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.settings.voiceTriggerMode == .hold ? "Hold to dictate" : "Tap to dictate")
                            .font(.system(size: 14, weight: .semibold))
                        Text(model.settings.voiceTriggerMode == .hold ? "Release to finish" : "Tap again to finish")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .ignore).accessibilityLabel(triggerInstruction)
                Text("Works in any app").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Shortcut is off").font(.system(size: 14, weight: .semibold))
                Button("Turn on in Settings") { model.openSettings() }.buttonStyle(.link).font(.system(size: 11))
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if model.isVoicePaused {
                    Image(systemName: "pause.circle.fill").font(.system(size: 10)).foregroundStyle(modeAccent).accessibilityHidden(true)
                } else {
                    Circle().fill(microphoneActive ? modeAccent : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                }
                Text(model.voiceStatusSummary).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(microphoneActive ? .primary : .secondary)
                Spacer(minLength: 4)
                if model.voiceIsRecording {
                    Button("Cancel") { model.cancelTriggeredVoice() }.buttonStyle(.borderless).controlSize(.small)
                }
                Button {
                    if model.voiceIsRecording { model.finishVoiceCapture() } else { model.toggleVoiceCapture() }
                } label: {
                    Label(model.voiceIsRecording ? "Stop" : "Dictate", systemImage: model.voiceIsRecording ? "stop.fill" : "mic")
                }.buttonStyle(PrimaryButtonStyle(accent: modeAccent, compact: true))
            }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(modeAccent.opacity(0.10), in: cardShape)
            .overlay { cardShape.strokeBorder(modeAccent.opacity(0.28)) }
    }

    private var triggerInstruction: String {
        guard model.settings.voiceTriggerEnabled else { return "Keyboard trigger is off. Enable it in Settings." }
        let key = model.settings.voiceTriggerKey.title
        return model.settings.voiceTriggerMode == .hold
            ? "Hold \(key) to dictate; release to finish."
            : "Tap \(key) to dictate. Tap again to finish."
    }
}

/// The user's real trigger key, drawn large enough to find on the keyboard.
struct LargeKeycap: View {
    let key: VoiceTriggerKey
    var body: some View {
        HStack(spacing: 5) {
            if key == .fn {
                Text("fn").font(.system(size: 19, weight: .semibold, design: .rounded))
                Image(systemName: "globe").font(.system(size: 14, weight: .medium))
            } else if key.isModifierOnly {
                Text(key.title.hasPrefix("Left") ? "L" : "R")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Image(systemName: key.symbol).font(.system(size: 18, weight: .medium))
            } else {
                Text(key.title).font(.system(size: 19, weight: .semibold, design: .rounded))
            }
        }.foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 12).frame(minWidth: 52, minHeight: 44)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.16)) }
            .shadow(color: .primary.opacity(0.10), radius: 0, x: 0, y: 2)
            .fixedSize()
            .help(key.title).accessibilityLabel(key.title)
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
