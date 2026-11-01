import SwiftUI
import UIUICore

/// The four places settings live. Titles are what people see; nothing here is stored.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcut, dictionary, agents, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .shortcut: "Shortcut"
        case .dictionary: "Dictionary"
        case .agents: "Agents"
        case .privacy: "Privacy"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var pane: SettingsPane
    @State private var heard = ""
    @State private var replacement = ""
    @State private var usesShorthand = false
    @State private var vocabularyProject = "All projects"
    @State private var editingVocabularyID: UUID?
    @State private var dictionaryIssue: String?
    @State private var showDisableRecordingRecovery = false
    @State private var showDeleteEverything = false
    @State private var deleteResult: String?
    @State private var deleting = false

    init(model: AppModel, pane: SettingsPane = .general) {
        self.model = model
        _pane = State(initialValue: pane)
    }

    private var dictionaryScopes: [String] {
        Array(Set(model.projects + model.settings.vocabulary.map(\.project))).filter { $0 != "All projects" }.sorted()
    }
    /// Word groups are an older feature. Their controls show only when an entry already uses one.
    private var hasScopedEntries: Bool { model.settings.vocabulary.contains { $0.project != "All projects" } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $pane) {
                ForEach(SettingsPane.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .accessibilityLabel("Settings section")
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            .background {
                // Command-1 to Command-5 switch sections from the keyboard.
                HStack {
                    ForEach(Array(SettingsPane.allCases.enumerated()), id: \.element) { index, item in
                        Button(item.title) { pane = item }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }.opacity(0).accessibilityHidden(true).allowsHitTesting(false)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch pane {
                    case .general: general
                    case .shortcut: shortcut
                    case .dictionary: dictionary
                    case .agents: AgentSettingsPane(model: model)
                    case .privacy: privacy
                    }
                    if pane == .general { ModelStatusView(model: model) }
                }.padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 4)
                    .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .alert("Delete unfinished recording drafts?", isPresented: $showDisableRecordingRecovery) {
            Button("Cancel", role: .cancel) { }
            Button("Delete drafts and turn off", role: .destructive) { model.settings.keepRecordingRecovery = false }
        } message: {
            Text("This deletes all recovery drafts on this Mac and stops keeping unfinished recordings. Completed dictation history is controlled separately.")
        }
        .alert("Delete everything uiui has saved?", isPresented: $showDeleteEverything) {
            Button("Cancel", role: .cancel) { }
            Button("Delete everything", role: .destructive) {
                deleting = true
                Task {
                    deleteResult = await model.deleteEverythingStoredLocally()
                    deleting = false
                }
            }
        } message: {
            Text("This permanently deletes your dictation history, unfinished recording drafts and dictionary words from this Mac. It can’t be undone. Your settings and downloaded speech models stay.")
        }
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        SetupStatusCard(model: model)
        SettingsCard(title: "Speech", symbol: "waveform", compact: true) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Language").font(.system(size: 12, weight: .medium))
                    Text(SpeechLanguageOptions.detail(for: model.settings.speechLocale))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("Language", selection: $model.settings.speechLocale) {
                    Text(SpeechLanguageOptions.primary.title).tag(SpeechLanguageOptions.primary.locale)
                    Divider()
                    Section("Other languages") {
                        ForEach(SpeechLanguageOptions.others(including: model.settings.speechLocale)) { Text($0.title).tag($0.locale) }
                    }
                }.labelsHidden().frame(width: 200)
            }
            Divider().opacity(0.4)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech model").font(.system(size: 12, weight: .medium))
                    Text(model.speechPreparationStatus.isEmpty
                         ? (LocalSpeechModel.supports(locale: model.settings.speechLocale)
                            ? LocalCleanupModel.speechSummary
                            : "Apple’s on-device speech. macOS manages the language data.")
                         : model.speechPreparationStatus)
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.isPreparingSpeech {
                    if let fraction = model.speechPreparationFraction {
                        ProgressView(value: fraction).progressViewStyle(.linear).tint(UIUIStyle.accent).frame(width: 120)
                            .accessibilityLabel("Speech model progress").accessibilityValue("\(Int(fraction * 100)) percent")
                    } else { ProgressView().controlSize(.small).accessibilityLabel("Setting up speech") }
                } else {
                    Button(SpeechLanguageOptions.setupButtonTitle(locale: model.settings.speechLocale, modelInstalled: LocalSpeechModel.isInstalled)) {
                        model.prepareSpeechModel()
                    }.font(.system(size: 11))
                }
            }
            Divider().opacity(0.4)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Microphone and speech access").font(.system(size: 12, weight: .medium))
                    Text(model.speechAccessStatus)
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(model.speechEngineDescription).font(.system(size: 10)).foregroundStyle(.secondary)
                    if let warning = model.speechEngineWarning {
                        Text(warning).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Status: \(model.speechStatus)")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Check permissions") { model.requestPermissions() }.font(.system(size: 11))
            }
        }
        SettingsCard(title: "Look", symbol: "macbook", compact: true) {
            settingToggle("Show uiui at the notch", detail: "Shows recording and status at the top of the screen.", value: $model.settings.notchEnabled)
            Divider().opacity(0.4)
            NotchStylePicker(selection: $model.settings.notchVisualStyle)
            Divider().opacity(0.4)
            NotchSizePicker(selection: $model.settings.notchSize)
            Divider().opacity(0.4)
            AccentPicker(choice: $model.settings.accent, customHex: $model.settings.accentCustomHex)
            Divider().opacity(0.4)
            settingToggle("Open on hover", detail: "Opens the notch when you point at it.", value: $model.settings.openOnHover)
            Divider().opacity(0.4)
            settingToggle("Quiet mode", detail: "Keeps the notch closed when you point at it, even if Open on hover is on.", value: $model.settings.quietMode)
            Divider().opacity(0.4)
            settingToggle("Launch at login", detail: "Opens uiui when you log in to your Mac.", value: $model.settings.launchAtLogin)
        }
        SettingsCard(title: "Sound and feel", symbol: "speaker.wave.1", compact: true) {
            settingToggle("Sound feedback", detail: "A soft sound when recording starts, finishes or is cancelled.", value: $model.settings.soundFeedbackEnabled)
            if model.settings.soundFeedbackEnabled {
                SoundChoice(pack: $model.settings.soundPack, volume: $model.settings.soundVolume,
                            preview: { model.previewRecordingSound() })
            }
            Divider().opacity(0.4)
            settingToggle("Trackpad feedback", detail: "A light tap on the trackpad at the same moments. You feel it only while a finger is on the trackpad.", value: $model.settings.trackpadFeedbackEnabled)
        }
        if let updater = model.updater { UpdatesCard(updater: updater) }
    }

    // MARK: Shortcut

    @ViewBuilder private var shortcut: some View {
        SettingsCard(title: "Voice shortcut", symbol: "keyboard", compact: true) {
            settingToggle("Use the voice shortcut", detail: "uiui watches for this key only. The microphone stays off until you press it.", value: $model.settings.voiceTriggerEnabled)
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
                    Button("Keyboard settings…") { SystemSetup.shared.open(.keyboard) }.font(.system(size: 11))
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
    }

    // MARK: Dictionary

    @ViewBuilder private var dictionary: some View {
        SettingsCard(title: "Dictionary", symbol: "text.badge.checkmark", compact: true) {
            Text("Add a name or word the way you want it written. uiui listens for anything that sounds like it. Saved on this Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.settings.vocabulary.isEmpty {
                Text("No words yet. Add a name below, like Priya.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 7)
            } else {
                ForEach(model.settings.vocabulary) { entry in
                    HStack(spacing: 10) {
                        Group {
                            if !entry.isSpellingOnly {
                                Text(entry.heard).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                            Text(entry.replacement).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                            if entry.project != "All projects" {
                                Text(entry.project).font(.system(size: 9)).foregroundStyle(.tertiary)
                                    .accessibilityLabel("Word group \(entry.project)")
                            }
                        }.accessibilityElement(children: .combine)
                        QuietIconButton(symbol: "pencil", label: "Edit \(entry.replacement)") {
                            editingVocabularyID = entry.id
                            heard = entry.isSpellingOnly ? "" : entry.heard; replacement = entry.replacement; vocabularyProject = entry.project
                            usesShorthand = !entry.isSpellingOnly
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
                if usesShorthand {
                    TextField("When I say…", text: $heard).textFieldStyle(.roundedBorder).accessibilityLabel("When I say")
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                TextField(usesShorthand ? "Write this" : "Name or word", text: $replacement).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(usesShorthand ? "Write this" : "Name or word")
            }.font(.system(size: 11))
            HStack {
                Toggle("Say one thing, write another", isOn: $usesShorthand).toggleStyle(.checkbox)
                    .help("For shorthand, like “q three” written as Q3. Names don’t need this.")
                Spacer()
                if editingVocabularyID != nil { Button("Cancel edit") { resetDictionaryForm() } }
                Button(editingVocabularyID == nil ? "Add word" : "Save word") { saveWord() }
                    .disabled(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (usesShorthand && heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.font(.system(size: 11))
            if let dictionaryIssue {
                Text(dictionaryIssue).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if hasScopedEntries {
                Divider().opacity(0.4)
                DisclosureGroup("Advanced: word groups") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Some of your words belong to a group, so they apply only while that group is active. Words without a group always apply.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Picker("Group in use", selection: $model.captureProject) {
                            ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                        }.font(.system(size: 11)).disabled(model.hasCancellableVoiceInput)
                        Picker("New words apply to", selection: $vocabularyProject) {
                            Text("Everything").tag("All projects")
                            ForEach(dictionaryScopes, id: \.self) { Text($0).tag($0) }
                        }.font(.system(size: 11)).disabled(editingVocabularyID != nil)
                    }.padding(.top, 6)
                }.font(.system(size: 11, weight: .medium))
            }
        }
    }

    private func saveWord() {
        let original = model.settings.vocabulary.first { $0.id == editingVocabularyID }
        let spoken = usesShorthand ? heard : replacement
        guard model.addVocabulary(heard: spoken, replacement: replacement, project: vocabularyProject) else {
            dictionaryIssue = "Use 1–120 characters for each term, without line breaks or control characters."
            return
        }
        if let original, original.heard.caseInsensitiveCompare(spoken.trimmingCharacters(in: .whitespaces)) != .orderedSame {
            model.settings.vocabulary.removeAll { $0.id == original.id }
        }
        resetDictionaryForm()
    }

    private func resetDictionaryForm() {
        editingVocabularyID = nil; dictionaryIssue = nil; heard = ""; replacement = ""; vocabularyProject = "All projects"; usesShorthand = false
    }

    // MARK: Privacy

    @ViewBuilder private var privacy: some View {
        SettingsCard(title: "Saved on this Mac", symbol: "internaldrive", compact: true) {
            privacyLine("Dictation history", "The text of finished dictations, when “Keep dictation history” is on.")
            privacyLine("Unfinished recording drafts", "The last 20 drafts of recognized text, when drafts are kept.")
            privacyLine("Dictionary and settings", "Your words, shortcut, language and appearance choices.")
            privacyLine("Usage counts", "How long dictation took, how many words, and how often agents asked and were answered. Never the words themselves.")
            Text("uiui does not save raw audio. Sound is turned into text as you speak and then discarded.")
                .font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
        SettingsCard(title: "Never sent anywhere", symbol: "lock", compact: true) {
            Text("Your voice and your text never leave this Mac. Speech recognition and punctuation both run on the device.")
                .font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text("uiui uses the internet only to check for new versions of uiui, to download an update you choose to install, and to download speech models when you ask. Those requests carry no audio, text or personal data. Hindi uses Apple’s on-device speech, and macOS itself may download Hindi language data. When uiui pastes, it uses your clipboard. If you turn on Agents, each answer you give goes to the agent that asked.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        SettingsCard(title: "What to keep", symbol: "clock.arrow.circlepath", compact: true) {
            settingToggle("Keep dictation history", detail: "Save the text of finished dictations in History on this Mac.", value: $model.settings.saveDictationHistory)
            Divider().opacity(0.4)
            settingToggle("Keep unfinished recording drafts", detail: "Keep the last 20 drafts’ recognized text, without audio, so you can recover them. Turning this off deletes the drafts.", value: Binding(
                get: { model.settings.keepRecordingRecovery },
                set: { enabled in
                    if enabled { model.settings.keepRecordingRecovery = true }
                    else { showDisableRecordingRecovery = true }
                }
            ))
        }
        SettingsCard(title: "Delete everything", symbol: "trash", compact: true) {
            Text("Permanently deletes your dictation history, unfinished recording drafts, usage counts and dictionary words, and overwrites them on disk. Your settings (shortcut, language, appearance) and downloaded speech models stay. Text you already pasted into other apps, or copied to the clipboard, is not touched.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(role: .destructive) { showDeleteEverything = true } label: {
                    Text(deleting ? "Deleting…" : "Delete everything…")
                }.disabled(deleting || model.hasCancellableVoiceInput).font(.system(size: 11))
                if let deleteResult {
                    Text(deleteResult).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(deleteResult)
                }
            }
        }
    }

    private func privacyLine(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    private func settingToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.accessibilityHidden(true)
            Spacer()
            Toggle(title, isOn: value).toggleStyle(.switch).controlSize(.small).labelsHidden()
                .accessibilityLabel(title).accessibilityHint(detail)
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
                .accessibilityAddTraits(.isHeader)
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
        SettingsCard(title: "Setup and permissions", symbol: "checkmark.shield", compact: true) {
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
                Button("Open setup guide…") { model.openOnboarding() }.font(.system(size: 11))
            }
        }
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.accessibilityElement(children: .combine)
            .accessibilityLabel("\(title): \(ok ? "ready" : "needs attention"). \(detail)")
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
                if updater.isBusy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                else if let release = updater.available {
                    Button("Install \(release.version.description)") { updater.installAvailableUpdate() }.font(.system(size: 11))
                } else { Button("Check for updates") { updater.checkNow() }.font(.system(size: 11)) }
            }
            Divider().opacity(0.4)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check automatically").font(.system(size: 12, weight: .medium))
                    Text("At most once a day, when uiui opens or the Mac wakes. App updates never re-download speech models.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.accessibilityHidden(true)
                Spacer()
                Toggle("Check automatically", isOn: $updater.automaticChecks).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("Check for updates automatically")
            }
        }
    }
}
