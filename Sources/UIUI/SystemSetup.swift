import AppKit
import ApplicationServices
import Observation

/// One owner for first-run OS setup: Accessibility trust, System Settings panes,
/// the app's install location and relaunching. State refreshes on app activation
/// and while the setup guide is open; nothing runs while uiui is idle.
@MainActor @Observable
final class SystemSetup {
    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"
        case speechRecognition = "Privacy_SpeechRecognition"
        case keyboard
    }

    /// What pressing the Fn / Globe key does in macOS (System Settings → Keyboard).
    enum FnKeyAction: Int {
        case nothing = 0, changeInputSource = 1, emojiAndSymbols = 2, startDictation = 3
        var title: String {
            switch self {
            case .nothing: "Do Nothing"
            case .changeInputSource: "Change Input Source"
            case .emojiAndSymbols: "Show Emoji & Symbols"
            case .startDictation: "Start Dictation"
            }
        }
    }

    static let shared = SystemSetup()

    private(set) var accessibilityTrusted = AXIsProcessTrusted()
    /// Event posting can lag a fresh Accessibility grant until relaunch.
    private(set) var canPostEvents = CGPreflightPostEventAccess()
    /// Accessibility was granted while this process was running.
    private(set) var accessibilityGrantedThisLaunch = false
    private(set) var fnKeyAction: FnKeyAction?
    private(set) var lastIssue: String?
    /// Lets the shortcut owner install its global monitor as soon as access arrives.
    @ObservationIgnored var onAccessibilityChanged: (() -> Void)?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    private init() {
        fnKeyAction = Self.readFnKeyAction()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted && !accessibilityTrusted { accessibilityGrantedThisLaunch = true }
        let changed = trusted != accessibilityTrusted
        accessibilityTrusted = trusted
        canPostEvents = CGPreflightPostEventAccess()
        fnKeyAction = Self.readFnKeyAction()
        if changed { onAccessibilityChanged?() }
    }

    /// Paste is reliable once both the trust check and event posting agree.
    var pasteReady: Bool { accessibilityTrusted && canPostEvents }
    var needsRelaunchForAccessibility: Bool { accessibilityTrusted && (!canPostEvents || accessibilityGrantedThisLaunch) }

    /// Adds uiui to the Accessibility list with macOS's prompt, then opens the pane.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // CGRequestPostEventAccess registers the same app for synthetic keys.
        _ = CGRequestPostEventAccess()
        open(.accessibility)
        refresh()
    }

    /// A stale entry from an earlier build can show uiui switched on while macOS
    /// rejects this copy. Resetting only uiui's own entry lets the user add it again.
    func resetAccessibility() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "app.uiui.mac"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            lastIssue = process.terminationStatus == 0 ? nil
                : "macOS didn’t reset the entry. Remove uiui from the Accessibility list with −, then add it again."
        } catch {
            lastIssue = "macOS didn’t reset the entry. Remove uiui from the Accessibility list with −, then add it again."
        }
        requestAccessibility()
    }

    func open(_ pane: Pane) {
        let address = pane == .keyboard
            ? "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
            : "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func readFnKeyAction() -> FnKeyAction? {
        guard let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int else { return nil }
        return FnKeyAction(rawValue: value)
    }

    // MARK: Install location

    /// Opened from a download or disk image, macOS runs a randomized read-only
    /// copy, and privacy grants and updates don't stick to it.
    var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }
    var isOnReadOnlyVolume: Bool {
        (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }
    var isInApplications: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        return path == "/Applications"
            || path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL.path
    }
    var shouldMoveToApplications: Bool { isTranslocated || isOnReadOnlyVolume || !isInApplications }

    /// Copies this app into Applications, replacing an older copy (moved to the
    /// Trash), clears the download quarantine, and relaunches from there.
    func moveToApplicationsAndRelaunch() {
        let fileManager = FileManager.default
        let source = Bundle.main.bundleURL
        var folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if !fileManager.isWritableFile(atPath: folder.path) {
            folder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        }
        let destination = folder.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                guard destination.standardizedFileURL != source.standardizedFileURL else { relaunch(); return }
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
            }
            try fileManager.copyItem(at: source, to: destination)
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
            try xattr.run()
            xattr.waitUntilExit()
            lastIssue = nil
            relaunch(at: destination)
        } catch {
            lastIssue = "uiui couldn’t move itself. Drag uiui into the Applications folder in Finder, then open it from there."
        }
    }

    /// Opens a fresh instance after this one quits normally, so shutdown still
    /// flushes recovery data and only one copy owns the shortcut and notch.
    @discardableResult
    func relaunch(at url: URL = Bundle.main.bundleURL) -> Bool {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                            "sh", String(ProcessInfo.processInfo.processIdentifier), url.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            NSApplication.shared.terminate(nil)
            return true
        } catch {
            lastIssue = "uiui couldn’t restart itself. Quit uiui from the menu bar and open it again."
            return false
        }
    }
}
