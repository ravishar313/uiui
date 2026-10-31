import AppKit
import UIUICore

/// The single owner of the menu-bar status item. It reflects the model when the
/// app reports activity and when the menu opens; it never polls or runs a timer.
/// Menu text comes from the user's own saved history and is never logged.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    struct Actions {
        var openWindow: () -> Void
        var openSettings: () -> Void
        var openSetupGuide: () -> Void
        var checkForUpdates: () -> Void
        /// Opens the update prompt the person was told about, only when they choose it.
        var reviewUpdate: () -> Void = {}
        var quit: () -> Void
    }

    static let recentLimit = 5
    static let recentTitleLimit = 48

    private let model: AppModel
    private let actions: Actions
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var statusLine = NSMenuItem()
    private var dictateItem = NSMenuItem()
    private var copyLastItem = NSMenuItem()
    private var recentItems: [UUID: String] = [:]

    init(model: AppModel, actions: Actions) {
        self.model = model
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild()
        refreshState()
    }

    /// One-line, truncated preview for a recent dictation.
    static func menuTitle(for text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > recentTitleLimit else { return flat }
        return String(flat.prefix(recentTitleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func symbolName(paused: Bool, active: Bool) -> String { paused ? "pause.circle.fill" : active ? "mic.fill" : "eyes" }

    /// Cheap and idempotent: called whenever the app reports activity.
    func refreshState() {
        let active = model.microphoneIsActive
        if let button = statusItem.button {
            let name = Self.symbolName(paused: model.isVoicePaused, active: active)
            let description = "uiui, \(model.voiceStatusSummary.lowercased())"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            button.image?.isTemplate = true
            button.toolTip = "uiui · \(model.voiceStatusSummary)"
        }
        statusLine.title = model.voiceStatusSummary
        dictateItem.title = model.voiceIsRecording ? "Finish dictation" : "Start dictation"
        dictateItem.isEnabled = model.captureEnabled || model.voiceIsRecording
        copyLastItem.isEnabled = model.canCopyLatestDictation
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The window may have been used since the last open; rebuild from current state.
        rebuild()
        refreshState()
    }

    private func rebuild() {
        menu.removeAllItems()
        recentItems = [:]

        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        dictateItem = item("Start dictation", #selector(toggleDictation))
        menu.addItem(dictateItem)
        // A quiet mention only: nothing opens until this is chosen.
        if let release = model.updater?.pendingNotice {
            menu.addItem(item("uiui \(release.version) is available · Review…", #selector(reviewUpdate)))
        }
        menu.addItem(.separator())

        copyLastItem = item("Copy last dictation", #selector(copyLast))
        menu.addItem(copyLastItem)
        let header = NSMenuItem(title: "Recent dictations", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let recent = model.recentDictations(limit: Self.recentLimit)
        if recent.isEmpty {
            let empty = NSMenuItem(title: model.settings.saveDictationHistory ? "Nothing dictated yet" : "History is off", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.indentationLevel = 1
            menu.addItem(empty)
        }
        for saved in recent {
            let entry = item(Self.menuTitle(for: saved.body), #selector(copyRecent(_:)))
            entry.indentationLevel = 1
            entry.representedObject = saved.id
            recentItems[saved.id] = saved.body
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        menu.addItem(item("Open uiui", #selector(openWindow)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Setup Guide…", #selector(openSetupGuide)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Quit uiui", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func toggleDictation() { model.toggleVoiceCapture() }
    @objc private func copyLast() { model.copyLatestDictation() }
    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let text = recentItems[id] else { return }
        model.copy(text)
    }
    @objc private func openWindow() { actions.openWindow() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func openSetupGuide() { actions.openSetupGuide() }
    @objc private func checkForUpdates() { actions.checkForUpdates() }
    @objc private func reviewUpdate() { actions.reviewUpdate() }
    @objc private func quit() { actions.quit() }

    /// For tests and the debug preview: the menu's visible titles in order.
    var titles: [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }
    func prepareForInspection() { rebuild(); refreshState() }
}
