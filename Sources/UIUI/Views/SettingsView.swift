import SwiftUI
import UIUICore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var heard = ""
    @State private var replacement = ""
    @State private var vocabularyProject = "All projects"
    @State private var editingVocabularyID: UUID?
    @State private var dictionaryIssue: String?
    @State private var showDisableRecordingRecovery = false
    private var dictionaryScopes: [String] {
        Array(Set(model.projects + model.settings.vocabulary.map(\.project))).filter { $0 != "All projects" }.sorted()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SetupStatusCard(model: model)
                SettingsCard(title: "Voice shortcut", symbol: "keyboard", compact: true) {
                    settingToggle("Enable voice shortcut", detail: "Monitors the chosen key. Microphone stays off until triggered.", value: $model.settings.voiceTriggerEnabled)
                    Divider().opacity(0.4)
                    ShortcutRecorder(model: model)
                    Picker("Activation", selection: $model.settings.voiceTriggerMode) {
                        Text(VoiceTriggerMode.toggle.title).tag(VoiceTriggerMode.toggle)
                        Text(VoiceTriggerMode.hold.title).tag(VoiceTriggerMode.hold)
                    }.font(.system(size: 12)).disabled(model.voiceIsRecording)
                    Text(model.settings.voiceTriggerMode == .toggle
                         ? "Tap \(model.settings.voiceTriggerKey.title) to dictate. Tap again to finish."
                         : "Hold \(model.settings.voiceTriggerKey.title) to dictate; release to finish.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.settings.voiceTriggerKey == .fn, SystemSetup.shared.fnKeyAction != .nothing {
                        HStack {
                            Text("macOS also uses Fn to \(SystemSetup.shared.fnKeyAction?.title.lowercased() ?? "show emoji or switch input"). Set “Press 🌐 key to” Do Nothing.")
                                .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Keyboard Settings…") { SystemSetup.shared.open(.keyboard) }.font(.system(size: 11))
                        }
                    }
                    Divider().opacity(0.4)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Shortcut access").font(.system(size: 12, weight: .medium))
                            Text(model.voiceTriggerStatus).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if !SystemSetup.shared.accessibilityTrusted {
                            Button("Allow Accessibility…") { model.requestVoiceTriggerAccess() }.font(.system(size: 11))
                        }
                    }
                    if let error = model.voiceError {
                        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                SettingsCard(title: "Appearance", symbol: "macbook", compact: true) {
                    settingToggle("Show uiui at the notch", detail: "Capture and status at the screen edge.", value: $model.settings.notchEnabled)
                    Divider().opacity(0.4)
                    NotchStylePicker(selection: $model.settings.notchVisualStyle)
                    Divider().opacity(0.4)
                    NotchSizePicker(selection: $model.settings.notchSize)
                    Divider().opacity(0.4)
                    settingToggle("Open on hover", detail: "Expand the notch when you hover.", value: $model.settings.openOnHover)
                    Divider().opacity(0.4)
                    settingToggle("Quiet mode", detail: "Keep the interface understated.", value: $model.settings.quietMode)
                    Divider().opacity(0.4)
                    settingToggle("Sound feedback", detail: "Subtle sounds when recording starts, finishes or is cancelled.", value: $model.settings.soundFeedbackEnabled)
                    Divider().opacity(0.4)
                    settingToggle("Launch at login", detail: "Start uiui with macOS.", value: $model.settings.launchAtLogin)
                }
                SettingsCard(title: "Speech & typing", symbol: "waveform", compact: true) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Local speech model").font(.system(size: 12, weight: .medium))
                            Text(model.speechPreparationStatus.isEmpty
                                 ? (LocalSpeechModel.supports(locale: model.settings.speechLocale)
                                    ? LocalCleanupModel.speechSummary
                                    : "Apple on-device speech · system-managed language assets.")
                                 : model.speechPreparationStatus)
                                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if model.isPreparingSpeech {
                            if let fraction = model.speechPreparationFraction {
                                ProgressView(value: fraction).progressViewStyle(.linear).tint(UIUIStyle.lime).frame(width: 120)
                            } else { ProgressView().controlSize(.small) }
                        }
                        else { Button("Prepare Speech") { model.prepareSpeechModel() }.font(.system(size: 11)) }
                    }
                    Divider().opacity(0.4)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dictation language").font(.system(size: 12, weight: .medium))
                            Text("English uses \(LocalSpeechModel.name); Hindi uses Apple Speech.").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Dictation language", selection: $model.settings.speechLocale) {
                            Text("English · India").tag("en-IN")
                            Text("English · US").tag("en-US")
                            Text("English · UK").tag("en-GB")
                            Text("Hindi · India").tag("hi-IN")
                        }.labelsHidden().frame(width: 155)
                    }
                    Divider().opacity(0.4)
                    settingToggle("Keep dictation history", detail: "Save completed dictations locally.", value: $model.settings.saveDictationHistory)
                    Divider().opacity(0.4)
                    settingToggle("Keep unfinished recording drafts", detail: "Keep the last 20 drafts’ recognized text on this Mac, without raw audio. Turning this off deletes recovery drafts.", value: Binding(
                        get: { model.settings.keepRecordingRecovery },
                        set: { enabled in
                            if enabled { model.settings.keepRecordingRecovery = true }
                            else { showDisableRecordingRecovery = true }
                        }
                    ))
                    Divider().opacity(0.4)
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Microphone & speech").font(.system(size: 12, weight: .medium))
                            Text(model.speechAccessStatus)
                                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(model.speechEngineDescription)
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            if let warning = model.speechEngineWarning {
                                Text(warning).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Speech: \(model.speechStatus)")
                                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Enable permissions") { model.requestPermissions() }.font(.system(size: 11))
                    }
                }
                SettingsCard(title: "Dictionary", symbol: "text.badge.checkmark", compact: true) {
                    Text("Names, spellings and shorthand, remembered on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("Dictionary profile", selection: $model.captureProject) {
                        ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                    }.font(.system(size: 12)).disabled(model.hasCancellableVoiceInput)
                    Text("Choose the profile for scoped word replacements. Entries in All projects always apply.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.4)
                    Text("Add names, spellings, and shorthand below. Existing project scopes stay attached to their dictionary entries.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    if model.settings.vocabulary.isEmpty {
                        Text("No custom words yet.").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 7)
                    } else {
                        ForEach(model.settings.vocabulary) { entry in
                            HStack(spacing: 10) {
                                Text(entry.heard).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                Text(entry.replacement).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                                Text(entry.project).font(.system(size: 9)).foregroundStyle(.tertiary)
                                QuietIconButton(symbol: "pencil", label: "Edit \(entry.replacement)") {
                                    editingVocabularyID = entry.id
                                    heard = entry.heard; replacement = entry.replacement; vocabularyProject = entry.project
                                }
                                QuietIconButton(symbol: "minus.circle", label: "Remove \(entry.replacement)") {
                                    model.settings.vocabulary.removeAll { $0.id == entry.id }
                                    if editingVocabularyID == entry.id { resetDictionaryForm() }
                                }
                            }
                        }
                    }
                    Divider().opacity(0.4)
                    HStack(spacing: 10) {
                        TextField("When I say…", text: $heard).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        TextField("Write this", text: $replacement).textFieldStyle(.roundedBorder)
                    }.font(.system(size: 11))
                    HStack {
                        Picker("Dictionary scope", selection: $vocabularyProject) {
                            Text("All projects").tag("All projects")
                            ForEach(dictionaryScopes, id: \.self) { Text($0).tag($0) }
                        }.frame(maxWidth: 240).disabled(editingVocabularyID != nil)
                        Spacer()
                        if editingVocabularyID != nil { Button("Cancel edit") { resetDictionaryForm() } }
                        Button(editingVocabularyID == nil ? "Add word" : "Save word") {
                            let original = model.settings.vocabulary.first { $0.id == editingVocabularyID }
                            guard model.addVocabulary(heard: heard, replacement: replacement, project: vocabularyProject) else {
                                dictionaryIssue = "Use 1–120 characters for each term, without line breaks or control characters."
                                return
                            }
                            if let original, original.heard.caseInsensitiveCompare(heard.trimmingCharacters(in: .whitespaces)) != .orderedSame {
                                model.settings.vocabulary.removeAll { $0.id == original.id }
                            }
                            resetDictionaryForm()
                        }.disabled(heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.font(.system(size: 11))
                    if let dictionaryIssue {
                        Text(dictionaryIssue).font(.system(size: 10)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let updater = model.updater { UpdatesCard(updater: updater) }
                ModelStatusView(model: model)
            }.padding(18).frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
        }
        .alert("Delete unfinished recording drafts?", isPresented: $showDisableRecordingRecovery) {
            Button("Cancel", role: .cancel) { }
            Button("Delete drafts and turn off", role: .destructive) { model.settings.keepRecordingRecovery = false }
        } message: {
            Text("This deletes all recovery drafts on this Mac and stops keeping unfinished recordings. Completed dictation history is controlled separately.")
        }
    }
    private func resetDictionaryForm() {
        editingVocabularyID = nil; dictionaryIssue = nil; heard = ""; replacement = ""; vocabularyProject = "All projects"
    }
    private func settingToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(title, isOn: value).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    var compact = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 17) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            content
        }.padding(compact ? 14 : 21).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: compact ? 10 : 15))
            .overlay { RoundedRectangle(cornerRadius: compact ? 10 : 15).strokeBorder(.primary.opacity(0.055)) }
    }
}

/// Everything uiui needs from macOS at a glance, with a way back into setup.
private struct SetupStatusCard: View {
    let model: AppModel
    private var setup: SystemSetup { SystemSetup.shared }
    private var permissions: SpeechAuthorization { SpeechAuthorization.shared }

    var body: some View {
        SettingsCard(title: "Setup & permissions", symbol: "checkmark.shield", compact: true) {
            row("Microphone", ok: permissions.microphoneStatus == .authorized, detail: permissions.microphoneStatus.title)
            row("Accessibility", ok: setup.pasteReady,
                detail: setup.pasteReady ? (setup.needsRelaunchForAccessibility ? "Allowed · reopen uiui to apply" : "Allowed")
                    : setup.accessibilityTrusted ? "Reopen uiui to apply" : "Needed for the shortcut in other apps and paste")
            if setup.shouldMoveToApplications {
                row("Location", ok: false, detail: "Move uiui to Applications so permissions and updates stick")
            }
            HStack {
                Spacer()
                if setup.needsRelaunchForAccessibility { Button("Reopen uiui") { setup.relaunch() }.font(.system(size: 11)) }
                Button("Open Setup Guide…") { model.openOnboarding() }.font(.system(size: 11))
            }
        }
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? Color.green : Color.orange)
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

private struct UpdatesCard: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        SettingsCard(title: "Updates", symbol: "arrow.down.circle", compact: true) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("uiui \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 12, weight: .medium))
                    Text(updater.status).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if updater.isBusy { ProgressView().controlSize(.small) }
                else if let release = updater.available {
                    Button("Install \(release.version.description)") { updater.installAvailableUpdate() }.font(.system(size: 11))
                } else { Button("Check for Updates") { updater.checkNow() }.font(.system(size: 11)) }
            }
            Divider().opacity(0.4)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check automatically").font(.system(size: 12, weight: .medium))
                    Text("Once a day at most, when uiui opens or the Mac wakes. App updates never re-download speech models.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Check automatically", isOn: $updater.automaticChecks).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
        }
    }
}
