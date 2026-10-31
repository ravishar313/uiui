import AppKit
import Foundation
import SwiftUI
import UIUICore

@main
struct UIUIBootstrap {
    @MainActor static func main() async {
        // Test and developer commands exist only in debug builds. Release
        // binaries ignore these flags and always start the app.
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--app-preview") {
            guard index + 1 < CommandLine.arguments.count else { print("APP_PREVIEW requires OUTPUT"); exit(2) }
            do {
                try await AppPreviewSmoke.run(output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                exit(0)
            } catch { print("APP_PREVIEW failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--settings-preview") {
            guard index + 1 < CommandLine.arguments.count else { print("SETTINGS_PREVIEW requires OUTPUT"); exit(2) }
            do {
                NSApplication.shared.setActivationPolicy(.accessory)
                try await SettingsNativeSmoke.run(output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                exit(0)
            } catch { print("SETTINGS_PREVIEW failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--notch-handoff-preview") {
            guard index + 1 < CommandLine.arguments.count else { print("NOTCH_HANDOFF requires OUTPUT"); exit(2) }
            do {
                try await NotchHandoffNativeSmoke.run(output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                exit(0)
            } catch { print("NOTCH_HANDOFF failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--notch-style-preview") ?? CommandLine.arguments.firstIndex(of: "--mosaic-preview") {
            guard index + 1 < CommandLine.arguments.count else { print("MOSAIC_PREVIEW requires OUTPUT"); exit(2) }
            do {
                try await MosaicNativeSmoke.run(output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                exit(0)
            } catch { print("MOSAIC_PREVIEW failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--optimization-round1-audio") {
            guard index + 2 < CommandLine.arguments.count else { print("ROUND1_AUDIO requires MANIFEST OUTPUT"); exit(2) }
            do {
                try await OptimizationRound1Smoke.runAudioFlow(manifest: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2]), pace: CommandLine.arguments.contains("--optimization-round1-paced"), renderUI: true)
                exit(0)
            } catch { print("ROUND1_AUDIO failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--optimization-round1-text") {
            guard index + 2 < CommandLine.arguments.count else { print("ROUND1_TEXT requires MANIFEST OUTPUT"); exit(2) }
            do {
                try await OptimizationRound1Smoke.runTextCorpus(manifest: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
                exit(0)
            } catch { print("ROUND1_TEXT failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--local-speech-cancel"), index + 1 < CommandLine.arguments.count {
            do {
                let restart = CommandLine.arguments.firstIndex(of: "--integration-cancel-restart")
                if let restart, restart + 2 >= CommandLine.arguments.count { throw CleanupFailure.unavailable }
                try await LocalSpeechCorpusSmoke.runCancellation(audio: URL(fileURLWithPath: CommandLine.arguments[index + 1]), vocabulary: integrationVocabulary(), diagnostics: integrationDiagnostics,
                    restartAudio: restart.map { URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) },
                    restartReference: restart.map { URL(fileURLWithPath: CommandLine.arguments[$0 + 2]) })
                exit(0)
            } catch { print("LOCAL_SPEECH_CANCEL failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--local-speech-transport"), index + 2 < CommandLine.arguments.count {
            do {
                try await LocalSpeechCorpusSmoke.runTransport(audio: URL(fileURLWithPath: CommandLine.arguments[index + 1]), reference: URL(fileURLWithPath: CommandLine.arguments[index + 2]), vocabulary: integrationVocabulary(), diagnostics: integrationDiagnostics,
                    withMiniLM: CommandLine.arguments.contains("--integration-minilm"))
                exit(0)
            } catch { print("LOCAL_SPEECH_TRANSPORT failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--local-speech-corpus"), index + 2 < CommandLine.arguments.count {
            do {
                try await LocalSpeechCorpusSmoke.run(manifest: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2]), vocabulary: integrationVocabulary(), diagnostics: integrationDiagnostics)
                exit(0)
            } catch { print("LOCAL_SPEECH_CORPUS failed: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--local-cleanup-smoke") {
            do { try await LocalCleanupModel.smoke(); exit(0) }
            catch { print("LOCAL_CLEANUP_SMOKE failed"); exit(1) }
        }
        if CommandLine.arguments.contains("--microphone-smoke") {
            do { try await MicrophoneNativeSmoke.run(); exit(0) }
            catch { print("MICROPHONE_SMOKE failed: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--escape-flow-smoke") {
            // Quartz taps are CFRunLoop sources. An async CLI's dispatch loop
            // alone does not service them; use the same AppKit loop as the app.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                do { try await TextDeliveryNativeSmoke.runEscape(); exit(0) }
                catch { print("ESCAPE_SMOKE failed: \(error.localizedDescription)"); exit(1) }
            }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--speech-short-smoke"), index + 2 < CommandLine.arguments.count {
            do {
                try await SpeechModelSmoke.runShort(audioURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                                   referenceURL: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
                exit(0)
            } catch { print("SPEECH_SHORT_SMOKE failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--delivery-fixture"), index + 1 < CommandLine.arguments.count {
            do { try TextDeliveryNativeSmoke.runFixture(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { print("DELIVERY_FIXTURE failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--cleanup-flow-smoke"), index + 4 < CommandLine.arguments.count {
            do {
                try await NativeCleanupSmoke.run(shortAudio: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                                 shortReference: URL(fileURLWithPath: CommandLine.arguments[index + 2]),
                                                 longAudio: URL(fileURLWithPath: CommandLine.arguments[index + 3]),
                                                 longReference: URL(fileURLWithPath: CommandLine.arguments[index + 4]),
                                                 vocabulary: integrationVocabulary(), diagnostics: integrationDiagnostics)
                exit(0)
            } catch { print("CLEANUP_FLOW failed: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--delivery-smoke") {
            do { try await TextDeliveryNativeSmoke.run(); exit(0) }
            catch { print("DELIVERY_SMOKE failed: \(error.localizedDescription)"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--speech-smoke"), index + 2 < CommandLine.arguments.count {
            do {
                try await SpeechModelSmoke.run(audioURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                               referenceURL: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
                exit(0)
            } catch { print("SPEECH_SMOKE failed: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--prepare-speech") {
            let locale: String
            if let index = CommandLine.arguments.firstIndex(of: "--speech-locale"), index + 1 < CommandLine.arguments.count {
                locale = CommandLine.arguments[index + 1]
            } else { locale = "en-IN" }
            do { try await SpeechAssets.prepare(localeIdentifier: locale); exit(0) }
            catch { print("SPEECH_ASSETS failed: \(error.localizedDescription)"); exit(1) }
        }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    #if DEBUG
    private static var integrationDiagnostics: Bool {
        CommandLine.arguments.contains("--integration-diagnostics")
    }

    /// Explicit public-fixture diagnostics only. Normal app launch never reads
    /// this file or exports the user's dictionary into benchmark artifacts.
    private static func integrationVocabulary() throws -> [String] {
        guard let index = CommandLine.arguments.firstIndex(of: "--integration-vocabulary") else { return [] }
        guard index + 1 < CommandLine.arguments.count else { throw CleanupFailure.unavailable }
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 65_536 else { throw CleanupFailure.unavailable }
        return Array(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)).prefix(100))
    }
    #endif
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var panels: PanelCoordinator?
    private var statusMenu: StatusMenuController?
    private let shortcuts = GlobalShortcuts()
    private let updater = AppUpdater()
    private var speechWarmup: Task<Void, Never>?
    private var terminating = false
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        let panels = PanelCoordinator(model: model); self.panels = panels
        model.onOpenHome = { [weak panels] in panels?.openHome() }
        model.onOpenLibrary = { [weak panels] in panels?.openLibrary() }
        model.onOpenCapture = { [weak panels] in panels?.openCapture() }
        model.onOpenOnboarding = { [weak panels] in panels?.openOnboarding() }
        model.onNotchPreviewChanged = { [weak panels] active in panels?.setNotchStylePreview(active) }
        model.updater = updater
        updater.isWorkInFlight = { [weak model] in model?.isDictationWorkInFlight ?? false }
        model.onSettingsChanged = { [weak self, weak panels] in
            panels?.updateNotch()
            self?.configureVoiceTrigger()
        }
        model.onSpeechPreferencesChanged = { [weak self] in self?.refreshSpeechWarmth() }
        model.onActivityChanged = { [weak self, weak panels] in
            self?.model.resumeQueuedVoiceCaptureIfReady()
            panels?.activityChanged()
            self?.refreshEscapeCancellation()
            self?.updater.activityChanged()
            self?.statusMenu?.refreshState()
        }
        shortcuts.onVoicePressed = { [weak model] in model?.voiceTriggerPressed() }
        shortcuts.onVoiceReleased = { [weak model] in model?.voiceTriggerReleased() }
        shortcuts.onVoiceCancelled = { [weak model] in model?.voiceTriggerCancelled() }
        shortcuts.onEscape = { [weak model, weak panels] in
            model?.cancelVoiceInputFromEscape()
            panels?.dismissCaptureUI()
        }
        shortcuts.onStatusChanged = { [weak model] status in model?.voiceTriggerStatus = status }
        SystemSetup.shared.onAccessibilityChanged = { [weak self] in self?.shortcuts.refreshGlobalAccess() }
        model.onVoiceTriggerAccess = { [weak self] in
            SystemSetup.shared.requestAccessibility()
            self?.shortcuts.refreshGlobalAccess()
        }
        configureVoiceTrigger()
        installStatusMenu()
        Task {
            await model.start()
            refreshSpeechWarmth()
            panels.updateNotch()
            model.voiceTriggerStatus = shortcuts.status
            // First run, an install that predates the guide, or a copy macOS runs
            // from a download: walk through setup. Otherwise check for an update
            // once (at most daily), never while setup is open.
            if !model.settings.onboardingCompleted || SystemSetup.shared.isTranslocated {
                panels.openOnboarding()
            } else {
                if !CommandLine.arguments.contains("--background") { panels.openHome() }
                updater.checkOnLaunchIfDue()
                // A menu-bar app can run for weeks. Waking the Mac repeats the
                // same at-most-daily check, event-driven, never on a timer.
                self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.model.settings.onboardingCompleted, !self.model.hasCancellableVoiceInput else { return }
                        self.updater.checkOnLaunchIfDue()
                    }
                }
                // Off the main actor; removes only uiui's own unreferenced packs.
                Task.detached(priority: .background) { ModelStore.pruneStale() }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        speechWarmup?.cancel()
        model.shutdown()
        Task {
            await model.recordingRecovery.flush()
            await model.cleanup.shutdown()
            await LocalSpeechModel.clear()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        speechWarmup?.cancel()
        Task { await LocalSpeechModel.clear() }
        model.shutdown(); panels?.shutdown(); shortcuts.remove()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { panels?.openHome(); return true }

    private func installStatusMenu() {
        statusMenu = StatusMenuController(model: model, actions: .init(
            openWindow: { [weak self] in self?.model.openHome() },
            openSettings: { [weak self] in self?.model.openSettings() },
            openSetupGuide: { [weak self] in self?.model.openOnboarding() },
            checkForUpdates: { [weak self] in self?.updater.checkNow() },
            reviewUpdate: { [weak self] in self?.updater.presentPendingUpdate() },
            quit: { NSApplication.shared.terminate(nil) }))
    }
    private func configureVoiceTrigger() {
        // The recorder in Settings or setup owns key presses while it listens.
        shortcuts.install(key: model.settings.voiceTriggerKey,
                          enabled: model.settings.voiceTriggerEnabled && !model.isRecordingShortcut)
        refreshEscapeCancellation()
        model.voiceTriggerStatus = shortcuts.status
    }
    private func refreshSpeechWarmth() {
        speechWarmup?.cancel()
        let keepReady = model.settings.voiceTriggerEnabled && LocalSpeechModel.supports(locale: model.settings.speechLocale)
        if keepReady { model.cleanup.prepare() } else { model.cleanup.release() }
        speechWarmup = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }
            if keepReady { await LocalSpeechModel.warmIfInstalled() }
            else { await LocalSpeechModel.clear() }
        }
    }
    private func refreshEscapeCancellation() {
        shortcuts.setEscapeCancellationEnabled(model.hasCancellableVoiceInput)
    }
    private func installApplicationMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "uiui")
        appMenu.addItem(withTitle: "About uiui", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Hide uiui", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit uiui", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu; root.addItem(appItem)
        let file = NSMenuItem(); let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open uiui", action: #selector(home), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "w").target = self
        file.submenu = fileMenu; root.addItem(file)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"); redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; root.addItem(edit); NSApplication.shared.mainMenu = root
    }
    @objc private func dictate() { model.prepareDictation() }
    @objc private func triggerVoice() { model.toggleVoiceCapture() }
    @objc private func home() { model.openHome() }
    @objc private func closeWindow() { panels?.closeFrontWindow() }
    @objc private func library() { model.openLibrary() }
    @objc private func settings() { model.openSettings() }
    @objc private func onboarding() { model.openOnboarding() }
    @objc private func checkForUpdates() { updater.checkNow() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func about() { NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "uiui", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", .credits: NSAttributedString(string: "Dictation, history and recovery.\nNative. Local. Ready when you are.")]) }
}
