import SwiftUI
import UIUICore

/// First-run setup: install location, microphone, Accessibility (shortcut and
/// paste), trigger key, notch style, speech model, and a real paste test.
/// The current step survives the relaunch macOS may need after Accessibility.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, shortcut, style, speech, test
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .shortcut: "Shortcut"
            case .style: "Notch"
            case .speech: "Speech"
            case .test: "Try it"
            }
        }
    }
    static let stepKey = "uiui.onboarding.step"

    @Bindable var model: AppModel
    let onFinish: () -> Void
    @State private var step: Step
    @State private var askedAccessibility = false
    @State private var practiceText = ""
    init(model: AppModel, initialStep: Step? = nil, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
        _step = State(initialValue: initialStep ?? Step(rawValue: UserDefaults.standard.integer(forKey: Self.stepKey)) ?? .welcome)
    }
    private var setup: SystemSetup { SystemSetup.shared }
    private var permissions: SpeechAuthorization { SpeechAuthorization.shared }
    private var needsSpeechRecognition: Bool { !LocalSpeechModel.supports(locale: model.settings.speechLocale) }

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.horizontal, 28).padding(.top, 30)
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32).padding(.vertical, 22)
            }
            Divider().opacity(0.5)
            footer.padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: 620, height: 600)
        .onChange(of: step) { _, value in UserDefaults.standard.set(value.rawValue, forKey: Self.stepKey) }
        .task(id: step) {
            // Only while the guide shows a step waiting on System Settings.
            permissions.refresh(); setup.refresh()
            guard step == .accessibility || step == .microphone || step == .test else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                permissions.refresh(); setup.refresh()
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                VStack(spacing: 5) {
                    Capsule().fill(item.rawValue <= step.rawValue ? UIUIStyle.accent : Color.primary.opacity(0.1)).frame(height: 4)
                    Text(item.title).font(.system(size: 9, weight: item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? .primary : .secondary)
                }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .microphone: microphone
        case .accessibility: accessibility
        case .shortcut: shortcut
        case .style: style.task { await previewNotchStyle() }
        case .speech: speech.onAppear { prepareIfNeeded() }
        case .test: test.onAppear { prepareIfNeeded() }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                UIUIMark(size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up uiui").font(.system(size: 24, weight: .semibold))
                    Text("Press a key, speak, press again. Your words are typed where your cursor is.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Text("This takes about two minutes. uiui needs two permissions: the microphone, to hear you while you dictate, and Accessibility, to see your shortcut in other apps and paste the text. Audio stays on this Mac.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if setup.shouldMoveToApplications {
                StepCard(state: .warning, title: "Move uiui to Applications first",
                         detail: setup.isTranslocated || setup.isOnReadOnlyVolume
                            ? "uiui is running from a download or disk image. macOS forgets permissions for copies like this, and updates can’t install."
                            : "uiui works best from the Applications folder, where permissions and updates stick.") {
                    Button("Move to Applications and reopen") { setup.moveToApplicationsAndRelaunch() }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                }
            } else {
                StepCard(state: .done, title: "Installed in Applications", detail: "Permissions and updates will stick to this copy.") { EmptyView() }
            }
            if let issue = setup.lastIssue { issueText(issue) }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Allow the microphone", "uiui opens the microphone only after you press your shortcut, and closes it when you finish.")
            StepCard(state: cardState(permissions.microphoneStatus), title: "Microphone · \(permissions.microphoneStatus.title)",
                     detail: permissions.microphoneStatus == .denied || permissions.microphoneStatus == .restricted
                        ? "macOS remembers a denial. Open System Settings, switch on uiui under Microphone, then come back."
                        : "macOS will ask once.") {
                permissionButton(permissions.microphoneStatus, pane: .microphone, request: "Allow microphone")
            }
            if needsSpeechRecognition {
                StepCard(state: cardState(permissions.speechStatus), title: "Speech recognition · \(permissions.speechStatus.title)",
                         detail: "Needed for \(languageName) with Apple’s on-device recognizer.") {
                    permissionButton(permissions.speechStatus, pane: .speechRecognition, request: "Allow speech recognition")
                }
            }
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Allow Accessibility", "This lets uiui notice your shortcut while you’re in other apps and paste your words with ⌘V. uiui never reads what you type.")
            if setup.pasteReady && !setup.needsRelaunchForAccessibility {
                StepCard(state: .done, title: "Accessibility is on", detail: "Shortcut and automatic paste work in every app.") { EmptyView() }
            } else if setup.needsRelaunchForAccessibility {
                StepCard(state: .warning, title: "Accessibility is on. Reopen uiui once",
                         detail: "macOS applies the new permission to paste after uiui restarts. Setup continues where you left off.") {
                    Button("Reopen uiui") {
                        UserDefaults.standard.set(Step.shortcut.rawValue, forKey: Self.stepKey)
                        setup.relaunch()
                    }.buttonStyle(PrimaryButtonStyle(compact: true))
                }
            } else {
                StepCard(state: askedAccessibility ? .waiting : .todo, title: "Accessibility · Not allowed yet",
                         detail: "Click the button, then switch on uiui in the list System Settings opens. If uiui isn’t listed, click +, choose uiui in Applications, and switch it on.") {
                    Button("Open Accessibility settings") { askedAccessibility = true; setup.requestAccessibility() }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                }
                if askedAccessibility {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("uiui is switched on but this still says not allowed?").font(.system(size: 11, weight: .medium))
                        Text("An older copy of uiui may own that entry. Reset it, then switch uiui on again.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Reset uiui’s Accessibility entry") { setup.resetAccessibility() }.controlSize(.small)
                    }
                }
            }
            if let issue = setup.lastIssue { issueText(issue) }
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Choose your shortcut", "Pick any key: a single modifier like Fn or Right ⌘, a function key, or a combination like ⌃⌥Space.")
            ShortcutRecorder(model: model)
            Picker("Activation", selection: $model.settings.voiceTriggerMode) {
                Text("Press to start, press to finish").tag(VoiceTriggerMode.toggle)
                Text("Hold to talk").tag(VoiceTriggerMode.hold)
            }.pickerStyle(.radioGroup).font(.system(size: 12))
            if model.settings.voiceTriggerKey == .fn, setup.fnKeyAction != .nothing {
                StepCard(state: .warning, title: "Set the Fn / Globe key to “Do Nothing”",
                         detail: "macOS currently uses it to \(setup.fnKeyAction?.title.lowercased() ?? "show emoji or switch input"). In Keyboard settings, set “Press 🌐 key to” Do Nothing, or pick another shortcut here.") {
                    Button("Open keyboard settings") { setup.open(.keyboard) }.controlSize(.small)
                }
            }
            if !model.settings.voiceTriggerKey.isModifierOnly || setup.accessibilityTrusted {
                Text(model.voiceTriggerStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var style: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Pick a look", "Watch the notch at the top of your screen: it’s showing the selected style and size as if you were dictating.")
            NotchStylePicker(selection: $model.settings.notchVisualStyle)
            NotchSizePicker(selection: $model.settings.notchSize)
            Toggle("Show uiui at the notch", isOn: $model.settings.notchEnabled).toggleStyle(.switch).font(.system(size: 12))
            Toggle("Sound when recording starts and stops", isOn: $model.settings.soundFeedbackEnabled).toggleStyle(.switch).font(.system(size: 12))
            Toggle("Open uiui when I log in", isOn: $model.settings.launchAtLogin).toggleStyle(.switch).font(.system(size: 12))
        }
    }

    /// Drives a speech-like level while this step is visible; the microphone
    /// stays off. Ends, and the notch collapses, when the step goes away.
    private func previewNotchStyle() async {
        model.notchStylePreviewActive = true
        let start = Date()
        while !Task.isCancelled {
            let t = Date().timeIntervalSince(start)
            let syllables = abs(sin(t * 7.3)) * (0.55 + 0.45 * sin(t * 1.7))
            let pause = sin(t * 0.6) > 0.85 ? 0.15 : 1.0
            model.notchPreviewLevel = max(0.05, min(1, syllables * pause))
            try? await Task.sleep(for: .milliseconds(60))
        }
        model.notchStylePreviewActive = false
        model.notchPreviewLevel = 0
    }

    private var speech: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Set up speech", "Recognition runs entirely on this Mac.")
            Picker("Language", selection: $model.settings.speechLocale) {
                Text(SpeechLanguageOptions.primary.title).tag(SpeechLanguageOptions.primary.locale)
                Divider()
                Section("Other languages") {
                    ForEach(SpeechLanguageOptions.others(including: model.settings.speechLocale)) { Text($0.title).tag($0.locale) }
                }
            }.frame(maxWidth: 340)
                .onChange(of: model.settings.speechLocale) { _, _ in model.speechPreparationStatus = "" ; prepareIfNeeded() }
            Text(SpeechLanguageOptions.detail(for: model.settings.speechLocale))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            StepCard(state: speechReady ? .done : (model.isPreparingSpeech ? .waiting : .todo),
                     title: speechReady ? "Speech is ready" : "Speech model",
                     detail: model.speechPreparationStatus.isEmpty ? "Checks the speech model and gets it ready. Downloads it first if this copy doesn’t include it." : model.speechPreparationStatus) {
                if model.isPreparingSpeech {
                    if model.speechPreparationFraction == nil { ProgressView().controlSize(.small) }
                }
                else if !speechReady { Button(speechFailed ? "Try again" : SpeechLanguageOptions.setupButtonTitle(locale: model.settings.speechLocale, modelInstalled: LocalSpeechModel.isInstalled)) { model.prepareSpeechModel() }.buttonStyle(PrimaryButtonStyle(compact: true)) }
            }
            if model.isPreparingSpeech, let fraction = model.speechPreparationFraction {
                ProgressView(value: fraction) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(fraction * 100))%").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }.progressViewStyle(.linear).tint(UIUIStyle.accent)
            }
            if model.isPreparingSpeech {
                // Only a real download says "download"; a copy with the models
                // built in just checks them, which takes a few seconds.
                Text(model.speechDownloadActive
                     ? "You can continue setup while this finishes. The download keeps going in the background."
                     : "Checking the speech models on this Mac. Nothing is being downloaded. You can continue while this finishes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !speechReady {
                Text("If you skip this, dictation won’t work until the speech model is ready. You can do that later in Settings → General → Speech model.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if needsSpeechRecognition && permissions.speechStatus != .authorized {
                StepCard(state: cardState(permissions.speechStatus), title: "Speech recognition · \(permissions.speechStatus.title)",
                         detail: "\(languageName) uses Apple’s on-device recognizer, which needs this permission.") {
                    permissionButton(permissions.speechStatus, pane: .speechRecognition, request: "Allow speech recognition")
                }
            }
        }
    }

    private func prepareIfNeeded() {
        guard !speechReady, !model.isPreparingSpeech, !model.voiceIsRecording else { return }
        model.prepareSpeechModel()
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Try it", "Say a real sentence and watch it appear. Then check that everything below is green.")
            practice
            checklist
            StepCard(state: .todo, title: "Test paste",
                     detail: model.pasteTestStatus.isEmpty ? "Click the button, then click into a text field in another app, such as Notes. uiui pastes a test line there after 5 seconds." : model.pasteTestStatus) {
                Button(model.pasteTestRunning ? "Waiting…" : "Test paste") { model.runPasteTest() }
                    .disabled(model.pasteTestRunning).controlSize(.small)
            }
            StepCard(state: .todo, title: "Dictate in another app",
                     detail: model.dictationFeedback.map(\.compactText)
                        ?? "Open Notes, \(model.settings.voiceTriggerMode == .hold ? "hold" : "press") \(model.settings.voiceTriggerKey.title), say something, then \(model.settings.voiceTriggerMode == .hold ? "release it" : "press it again"). Escape cancels.") { EmptyView() }
        }
    }

    /// A real sentence, dictated through the normal path. With uiui in front there
    /// is no app to paste into, so the result is copied as usual and shown here.
    private var practice: some View {
        let verb = model.settings.voiceTriggerMode == .hold ? "Hold" : "Press"
        let finish = model.settings.voiceTriggerMode == .hold ? "release it" : "press it again"
        return VStack(alignment: .leading, spacing: 8) {
            Text("Say this, the way you would normally say it:").font(.system(size: 12, weight: .semibold))
            Text("“\(PracticeSample.sentence)”")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .background(UIUIStyle.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
            Text("\(verb) \(model.settings.voiceTriggerKey.title), speak, then \(finish). Keep this window in front.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                Text(practiceText.isEmpty ? (model.voiceIsRecording ? "Listening…" : "Your words appear here") : practiceText)
                    .font(.system(size: 13)).foregroundStyle(practiceText.isEmpty ? .tertiary : .primary)
                    .padding(10).frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.14)) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Practice result")
            .accessibilityValue(practiceText.isEmpty ? "Empty" : practiceText)
            if !practiceText.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(PracticeSample.message(for: PracticeSample.match(heard: practiceText)))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Try again") { practiceText = "" }.controlSize(.small)
                }
                Text("A copy of this text is also on your clipboard, as with any dictation that has no app to paste into.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: model.lastTypedText) { _, text in
                // Only text produced while this step is open; nothing earlier is read.
                if !text.isEmpty { practiceText = text }
            }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 7) {
            checkRow("Microphone", ok: permissions.microphoneStatus == .authorized, step: .microphone)
            if needsSpeechRecognition { checkRow("Speech recognition", ok: permissions.speechStatus == .authorized, step: .speech) }
            checkRow("Accessibility (shortcut and paste)", ok: setup.pasteReady && !setup.needsRelaunchForAccessibility, step: .accessibility)
            checkRow("Shortcut \(model.settings.voiceTriggerKey.title)", ok: model.voiceTriggerStatus.contains("is ready"), step: .shortcut)
            checkRow(model.isPreparingSpeech ? "Speech model · \(model.speechPreparationFraction.map { "\(Int($0 * 100))%" } ?? "preparing")" : "Speech model",
                     ok: speechReady, step: .speech)
            if model.isPreparingSpeech, let fraction = model.speechPreparationFraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(UIUIStyle.accent)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }

    private func checkRow(_ title: String, ok: Bool, step target: Step) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(title).font(.system(size: 12))
            Spacer()
            if !ok { Button("Fix") { step = target }.controlSize(.small) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome { Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
            Spacer()
            if step == .test {
                Button("Finish") { finish() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                if canSkip { Button("Skip for now") { advance() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12)) }
                Button(primaryTitle) { advance() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!stepComplete)
            }
        }
    }

    private var stepComplete: Bool {
        switch step {
        case .microphone: permissions.microphoneStatus == .authorized && (!needsSpeechRecognition || permissions.speechStatus == .authorized)
        case .accessibility: setup.pasteReady && !setup.needsRelaunchForAccessibility
        default: true
        }
    }
    /// Skipping is offered only where it means something: leaving a permission
    /// or the speech model unfinished. A running download simply continues.
    private var canSkip: Bool { !stepComplete || step == .speech && !speechReady && !model.isPreparingSpeech }
    private var primaryTitle: String {
        if step == .welcome { return "Get started" }
        if step == .speech && model.isPreparingSpeech { return model.speechDownloadActive ? "Continue while downloading" : "Continue while checking" }
        return "Continue"
    }
    private var speechReady: Bool { model.speechPreparationStatus.hasPrefix("Ready") }
    private var speechFailed: Bool { !model.speechPreparationStatus.isEmpty && !speechReady && !model.isPreparingSpeech }
    private var languageName: String { model.settings.speechLocale.hasPrefix("hi") ? "Hindi" : "this language" }

    private func advance() { step = Step(rawValue: step.rawValue + 1) ?? .test }
    private func finish() {
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        model.completeOnboarding()
        onFinish()
    }

    // MARK: Pieces

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func issueText(_ issue: String) -> some View {
        Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cardState(_ permission: CapturePermission) -> StepState {
        switch permission {
        case .authorized: .done
        case .notDetermined: .todo
        case .denied, .restricted: .warning
        }
    }

    @ViewBuilder
    private func permissionButton(_ permission: CapturePermission, pane: SystemSetup.Pane, request: String) -> some View {
        switch permission {
        case .authorized: EmptyView()
        case .notDetermined:
            Button(request) {
                Task { _ = await permissions.request(requiresSpeechRecognition: pane == .speechRecognition || needsSpeechRecognition) }
            }.buttonStyle(PrimaryButtonStyle(compact: true))
        case .denied, .restricted:
            Button("Open System Settings") { setup.open(pane) }.controlSize(.small)
        }
    }
}

enum StepState { case todo, waiting, done, warning }

struct StepCard<Accessory: View>: View {
    let state: StepState
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(state == .todo ? 0.12 : 0.35)) }
    }
    private var symbol: String {
        switch state {
        case .todo: "circle"
        case .waiting: "clock"
        case .done: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }
    private var tint: Color {
        switch state {
        case .todo: .secondary
        case .waiting: .blue
        case .done: .green
        case .warning: .orange
        }
    }
}
