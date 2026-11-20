import SwiftUI
import UIUICore

/// The quiet side column: how to talk, what uiui learned, and whether it is listening.
struct NotebookRail: View {
    let model: AppModel
    static let width: CGFloat = 320
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    talkAnywhere
                    learnedWords
                    RecordingRecoveryView(model: model)
                    UsageOverview(model: model)
                }.padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            micStatus
        }.frame(width: Self.width).frame(maxHeight: .infinity)
            .background(UIUIStyle.rail(scheme).ignoresSafeArea())
    }

    // MARK: Talk anywhere

    private var talkAnywhere: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Talk anywhere").uiuiSectionLabel()
            if model.settings.voiceTriggerEnabled {
                keyRow(VoiceKeycap(key: model.settings.voiceTriggerKey), model.settings.voiceTriggerMode == .hold
                       ? "hold to dictate, release to finish" : "tap to dictate, tap to finish")
            } else {
                HStack(spacing: 8) {
                    Text("The voice shortcut is off.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Turn on") { model.openSettings() }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            keyRow(NotebookKeycap(label: "\u{232B}"), "while talking, drops the last word")
            if model.settings.agentAskEnabled {
                let key = model.agentAnswerKey
                keyRow(VoiceKeycap(key: key),
                       "\(key.title) answers an agent\u{2019}s question")
            }
        }
    }

    private func keyRow<Cap: View>(_ cap: Cap, _ text: String) -> some View {
        HStack(spacing: 12) {
            cap
            Text(text).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.75)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }

    // MARK: Learned words

    private var learnedWords: some View {
        let entries = model.settings.vocabulary
        return VStack(alignment: .leading, spacing: 12) {
            Text("Words uiui learned").uiuiSectionLabel()
            if entries.isEmpty {
                Text("Fix a word in a dictation to teach uiui.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entries.suffix(6).reversed())) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.replacement).font(UIUIStyle.words(15)).lineLimit(1)
                                .underline(true, color: UIUIStyle.accent)
                            Text("heard \u{201C}\(entry.heard)\u{201D}").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }.accessibilityElement(children: .combine)
                    }
                }
                Button(entries.count > 6 ? "All \(entries.count) words" : "All words") { model.openSettings() }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UIUIStyle.tint(scheme))
                    .help("Open Settings to see and edit the dictionary")
            }
        }
    }

    // MARK: Microphone

    private var micStatus: some View {
        let active = model.microphoneIsActive
        let idle = !active && !model.voiceIsRecording && !model.isVoicePaused && model.voice.state != "finishing" && model.voice.state != "working"
        return HStack(spacing: 10) {
            MicEyes(open: active || model.voiceIsRecording)
            Text(idle ? "Microphone off \u{00B7} nothing is listening" : model.voiceStatusSummary)
                .font(.system(size: 11, weight: .medium)).lineLimit(2)
                .foregroundStyle(idle ? .secondary : .primary)
            Spacer(minLength: 4)
            if model.voiceIsRecording {
                Button("Cancel") { model.cancelTriggeredVoice() }.buttonStyle(.borderless).font(.system(size: 11))
                Button("Stop") { model.finishVoiceCapture() }.buttonStyle(ChipButtonStyle())
            } else if idle {
                Button("Dictate") { model.toggleVoiceCapture() }.buttonStyle(ChipButtonStyle())
                    .help("Start dictating here; uiui listens until you finish")
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(UIUIStyle.hair(scheme)).frame(height: 1) }
            .accessibilityElement(children: .contain)
    }
}
