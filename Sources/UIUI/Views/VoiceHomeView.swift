import SwiftUI
import UIUICore

/// Compact capture controls shared by the single workspace.
struct VoiceHomeView: View {
    let model: AppModel
    private var microphoneActive: Bool { model.voice.state == "capturing" || model.isRecording }
    private var modeAccent: Color { UIUIStyle.lime }
    private var primaryVoiceStatus: String {
        if microphoneActive { return "Recording" }
        if model.voiceIsRecording { return "Preparing microphone" }
        if model.voice.state == "finishing" { return "Finishing · microphone off" }
        if model.voice.state == "working" { return "Working · microphone off" }
        return "Microphone off"
    }
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
            HStack(spacing: 8) {
                Circle().fill(microphoneActive ? modeAccent : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                Text(primaryVoiceStatus)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Button {
                    if model.voiceIsRecording { model.finishVoiceCapture() } else { model.toggleVoiceCapture() }
                } label: {
                    Label(model.voiceIsRecording ? "Stop" : "Dictate", systemImage: model.voiceIsRecording ? "stop.fill" : "mic")
                }.buttonStyle(PrimaryButtonStyle(accent: model.voiceIsRecording ? modeAccent : UIUIStyle.lime, compact: true))
                if model.voiceIsRecording {
                    Button("Cancel") { model.cancelTriggeredVoice() }.buttonStyle(.borderless).controlSize(.small)
                }
            }
            shortcutGuidance
            if let warning = model.speechEngineWarning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if showingLiveTranscript {
                ScrollView {
                    Text(model.voiceTranscript).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 78)
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
            if model.canCopyLastDictation {
                Button { model.copyLastDictation() } label: {
                    Label("Copy last dictation", systemImage: "doc.on.doc")
                }.buttonStyle(.borderless).controlSize(.small)
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
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.055)) }
    }

    private var triggerInstruction: String {
        guard model.settings.voiceTriggerEnabled else { return "Keyboard trigger is off. Enable it in Settings." }
        let key = model.settings.voiceTriggerKey.title
        return model.settings.voiceTriggerMode == .hold
            ? "Hold \(key) to dictate; release to finish."
            : "Tap \(key) to dictate. Tap again to finish."
    }
    private var shortcutGuidance: some View {
        Group {
            if model.settings.voiceTriggerEnabled {
                HStack(spacing: 5) {
                    VoiceTriggerKeycap(key: model.settings.voiceTriggerKey)
                    Text(model.settings.voiceTriggerMode == .hold ? "Hold to dictate" : "Tap to dictate")
                    Text("·").foregroundStyle(.tertiary)
                    Text(model.settings.voiceTriggerMode == .hold ? "Release to finish" : "Tap again to finish")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Button("Keyboard trigger is off · Open Settings") { model.openSettings() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(triggerInstruction)
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
