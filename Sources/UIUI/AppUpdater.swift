import AppKit
import CryptoKit
import Foundation
import Observation
import Security
import UIUICore

/// What a found release is allowed to do. An update never opens a window or takes
/// focus because dictation went idle: only a person's own choice (Check for Updates,
/// the menu item, or Settings) opens the prompt, and never while dictation is in flight.
/// Pure: no timers, no observation.
enum UpdatePresentation: Equatable {
    /// Open the prompt now: the person asked for it and nothing is in flight.
    case promptNow
    /// Show the quiet indication (menu item, Home, Settings); no window.
    case indicate

    static func forFoundRelease(userInitiated: Bool, workInFlight: Bool) -> UpdatePresentation {
        userInitiated && !workInFlight ? .promptNow : .indicate
    }

    /// Whether a modal alert may be shown at all right now.
    static func mayShowModal(workInFlight: Bool) -> Bool { !workInFlight }
}

enum UpdatePromptChoice: Equatable { case install, later, skip }

/// Single owner of update side effects: one GitHub release lookup per check,
/// download, verification, bundle replacement and relaunch. No timers or polling.
@MainActor @Observable final class AppUpdater {
    private(set) var status: String
    private(set) var isBusy = false
    private(set) var available: UpdateRelease?
    /// A found release that the menu and the app mention quietly until the person
    /// reviews it. Cleared when they skip it or start installing.
    private(set) var pendingNotice: UpdateRelease?
    var automaticChecks: Bool {
        didSet { defaults.set(automaticChecks, forKey: Keys.automatic) }
    }

    @ObservationIgnored private let repository: String?
    @ObservationIgnored private let currentVersionText: String
    @ObservationIgnored private let currentVersion: UpdateVersion?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    /// True while a capture, cleanup or paste is in flight. The prompt and the
    /// relaunch wait for false; the app reports changes via `activityChanged()`.
    @ObservationIgnored var isWorkInFlight: () -> Bool = { false }
    /// Show the prompt and return the choice. Replaceable so tests never open a window.
    @ObservationIgnored var promptUser: @MainActor (UpdateRelease, String) -> UpdatePromptChoice = AppUpdater.runPrompt
    /// Show a plain alert. Replaceable so tests never open a window.
    @ObservationIgnored var showNotice: @MainActor (String, String) -> Void = AppUpdater.runAlert
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private enum Keys {
        static let automatic = "uiui.updates.automatic"
        static let lastCheck = "uiui.updates.lastCheck"
        static let skipped = "uiui.updates.skippedVersion"
        static let cleanup = "uiui.updates.cleanup"
    }

    private struct UpdateFailure: Error { let message: String }

    init(repository: String? = Bundle.main.object(forInfoDictionaryKey: "UIUIUpdateRepository") as? String,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         defaults: UserDefaults = .standard,
         session: URLSession = .shared) {
        let valid = repository.flatMap { Self.isValidRepository($0) ? $0 : nil }
        self.repository = valid
        currentVersionText = currentVersion
        self.currentVersion = UpdateVersion(currentVersion)
        self.defaults = defaults
        self.session = session
        automaticChecks = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        status = valid == nil ? "Updates are not configured." : "uiui \(currentVersion)."
        removeLeftoverUpdate()
    }

    /// The previous version and downloads stay in the update's temporary folder
    /// until the next launch. Only a system temporary-items folder is removed.
    private func removeLeftoverUpdate() {
        guard let path = defaults.string(forKey: Keys.cleanup) else { return }
        defaults.removeObject(forKey: Keys.cleanup)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard path.contains("TemporaryItems"), url.lastPathComponent.hasPrefix("NSIRD_"),
              url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
              !Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func isValidRepository(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// Whether a found release should interrupt the user without being asked.
    nonisolated static func shouldPrompt(release: UpdateVersion, current: UpdateVersion?, skipped: String?, userInitiated: Bool) -> Bool {
        guard let current, release > current else { return false }
        if !userInitiated, let skipped, UpdateVersion(skipped) == release { return false }
        return true
    }

    // MARK: Checking

    /// Event-driven: the app calls this whenever dictation activity changes. It only
    /// releases an install that was waiting for idle; it never opens a prompt.
    func activityChanged() {
        guard !isWorkInFlight() else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitUntilIdle() async {
        while isWorkInFlight() {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    func checkOnLaunchIfDue() {
        guard automaticChecks, repository != nil, !isBusy else { return }
        if let last = defaults.object(forKey: Keys.lastCheck) as? Date, Date().timeIntervalSince(last) < 24 * 3600, last <= Date() { return }
        Task { if let release = await check(userInitiated: false) { await install(release) } }
    }

    func checkNow() {
        guard !isBusy else { return }
        Task { if let release = await check(userInitiated: true) { await install(release) } }
    }

    func installAvailableUpdate() {
        guard !isBusy, let release = available else { return }
        Task { await install(release) }
    }

    /// The person chose the quiet indication: open the prompt now, unless dictation is
    /// in flight, when it waits for them to choose again.
    func presentPendingUpdate() {
        guard !isBusy, let release = pendingNotice ?? available else { return }
        guard UpdatePresentation.mayShowModal(workInFlight: isWorkInFlight()) else {
            status = "uiui \(release.version) is available. Choose it again when dictation is finished."
            return
        }
        Task { if prompt(release) { await install(release) } }
    }

    /// Returns the release the user chose to install. Installing happens after
    /// the check has finished, so the busy flag never blocks the user's choice.
    func check(userInitiated: Bool) async -> UpdateRelease? {
        guard let repository, let currentVersion else {
            status = "Updates are not configured."
            if userInitiated { showAlert(title: "Updates are unavailable", text: "This build has no update source.") }
            return nil
        }
        isBusy = true
        status = "Checking…"
        defer { isBusy = false }
        do {
            let release = try await fetchLatest(repository: repository)
            defaults.set(Date(), forKey: Keys.lastCheck)
            if release.version > currentVersion {
                available = release
                status = "uiui \(release.version) is available."
                if Self.shouldPrompt(release: release.version, current: currentVersion,
                                     skipped: defaults.string(forKey: Keys.skipped), userInitiated: userInitiated) {
                    pendingNotice = release
                    switch UpdatePresentation.forFoundRelease(userInitiated: userInitiated, workInFlight: isWorkInFlight()) {
                    case .promptNow:
                        if prompt(release) { return release }
                    case .indicate:
                        status = "uiui \(release.version) is available. Review it from the menu bar when you are ready."
                    }
                }
            } else {
                available = nil
                pendingNotice = nil
                status = "uiui \(currentVersionText) is up to date."
                if userInitiated { showAlert(title: "uiui is up to date", text: "You have the latest version, \(currentVersionText).") }
            }
        } catch {
            status = userInitiated ? "Update check failed." : "uiui \(currentVersionText)."
            if userInitiated { showAlert(title: "Could not check for updates", text: Self.reason(error)) }
        }
        return nil
    }

    private func fetchLatest(repository: String) async throws -> UpdateRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { throw UpdateFailure(message: "The update address is invalid.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("uiui/\(currentVersionText)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateFailure(message: "No response from the update server.") }
        guard http.statusCode == 200 else {
            throw UpdateFailure(message: http.statusCode == 404 ? "No release has been published yet." : "The update server answered with status \(http.statusCode).")
        }
        return try UpdateRelease.parse(data)
    }

    private static func reason(_ error: Error) -> String {
        if let failure = error as? UpdateFailure { return failure.message }
        if let release = error as? UpdateReleaseError { return release.message }
        if let model = error as? ModelStore.Failure { return model.message }
        if error is URLError { return "The update server could not be reached." }
        return "Something went wrong (\(error.localizedDescription))."
    }

    // MARK: Prompt

    /// True when the user chose to install now.
    private func prompt(_ release: UpdateRelease) -> Bool {
        guard UpdatePresentation.mayShowModal(workInFlight: isWorkInFlight()) else { return false }
        switch promptUser(release, currentVersionText) {
        case .install:
            pendingNotice = nil
            return true
        case .skip:
            defaults.set(release.version.description, forKey: Keys.skipped)
            pendingNotice = nil
        case .later:
            break
        }
        return false
    }

    private static func runPrompt(_ release: UpdateRelease, currentVersion: String) -> UpdatePromptChoice {
        let alert = NSAlert()
        alert.messageText = "uiui \(release.version) is available"
        let notes = release.displayNotes()
        alert.informativeText = (notes.isEmpty ? "" : notes + "\n\n") + "You have version \(currentVersion)."
        // Later is the default button, so a stray Return keypress postpones and never installs.
        let install = alert.addButton(withTitle: "Install and Relaunch")
        let later = alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        install.keyEquivalent = ""
        later.keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .install
        case .alertThirdButtonReturn: return .skip
        default: return .later
        }
    }

    /// A modal alert only while nothing is being dictated; otherwise the status line says it.
    private func showAlert(title: String, text: String) {
        guard UpdatePresentation.mayShowModal(workInFlight: isWorkInFlight()) else { status = title + "."; return }
        showNotice(title, text)
    }

    private static func runAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Install

    private func install(_ release: UpdateRelease) async {
        guard !isBusy, let currentVersion else { return }
        isBusy = true
        pendingNotice = nil
        defer { isBusy = false }
        let target = Bundle.main.bundleURL
        do {
            try Self.checkReplaceable(target)
            status = "Downloading uiui \(release.version)…"
            let session = session
            // On the app's own volume, so the swap is a rename. The next launch
            // removes this folder, which ends up holding the previous version.
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            defaults.set(work.path, forKey: Keys.cleanup)
            let staged = try await Self.download(release, session: session, into: work)
            status = "Verifying uiui \(release.version)…"
            let newApp = try await Task.detached(priority: .userInitiated) {
                try Self.verifyAndExtract(archive: staged.archive, expectedDigest: staged.digest, release: release, current: currentVersion, into: work)
            }.value
            try? FileManager.default.removeItem(at: staged.archive)
            try await installModels(forNewApp: newApp)
            // Model downloads can take minutes; the staged bundle must still be
            // exactly what was verified when it replaces this app.
            try Self.verifySignature(of: newApp)
            if isWorkInFlight() {
                status = "Ready to install uiui \(release.version) once dictation is finished…"
                await waitUntilIdle()
            }
            status = "Installing uiui \(release.version)…"
            try Self.replace(target: target, with: newApp, work: work)
            status = "Relaunching…"
            // The new bundle now sits at the original path; one owner relaunches.
            if !SystemSetup.shared.relaunch(at: target) {
                status = "uiui \(release.version) is installed. Quit and reopen uiui to finish."
                showAlert(title: "Reopen uiui to finish updating",
                          text: "uiui \(release.version) is installed but couldn’t restart itself. Quit uiui from the menu bar and open it again.")
            }
        } catch {
            status = "Update failed."
            showAlert(title: "uiui could not be updated", text: Self.reason(error) + " The current version is unchanged.")
        }
    }

    /// Models are separate from the app. Before swapping bundles, make sure every pack
    /// the new app needs is stored (copied from this app when ids match, else downloaded).
    private func installModels(forNewApp newApp: URL) async throws {
        let resources = newApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let list = ModelStore.requiredPacks(in: resources) else {
            let bundled = ModelPackKind.allCases.allSatisfy { FileManager.default.fileExists(atPath: resources.appendingPathComponent($0.rawValue).path) }
            if bundled { return }
            throw UpdateFailure(message: "The update does not say which models it needs.")
        }
        let repository = repository
        for pack in list.packs where ModelStore.usable(pack) && !ModelStore.isInstalled(pack, bundleResources: resources) {
            try await ModelStore.install(pack, copyingFrom: Bundle.main.resourceURL, repository: repository) { [weak self] text in
                Task { @MainActor in self?.status = text }
            }
        }
    }

    private nonisolated static func checkReplaceable(_ target: URL) throws {
        let path = target.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            throw UpdateFailure(message: "uiui is running from a disk image or a temporary location. Drag uiui into Applications, open it from there, then update.")
        }
        let values = try? target.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        let parent = target.deletingLastPathComponent().path
        if values?.volumeIsReadOnly == true || !FileManager.default.isWritableFile(atPath: parent) {
            throw UpdateFailure(message: "uiui cannot replace itself where it is installed. Drag uiui into Applications, open it from there, then update.")
        }
    }

    private nonisolated static func download(_ release: UpdateRelease, session: URLSession, into work: URL) async throws -> (archive: URL, digest: String) {
        let checksumTemp = try await fetchFile(release.checksumAsset.url, session: session, maxBytes: 4096)
        defer { try? FileManager.default.removeItem(at: checksumTemp) }
        let text = try String(contentsOf: checksumTemp, encoding: .utf8)
        let digest = try UpdateRelease.parseChecksum(text, expectedName: release.archive.name)
        let archiveTemp = try await fetchFile(release.archive.url, session: session, maxBytes: 1_500_000_000)
        let archive = work.appendingPathComponent(release.archive.name)
        try FileManager.default.moveItem(at: archiveTemp, to: archive)
        return (archive, digest)
    }

    private nonisolated static func fetchFile(_ url: URL, session: URLSession, maxBytes: Int64) async throws -> URL {
        guard UpdateRelease.isTrustedDownload(url) else { throw UpdateFailure(message: UpdateReleaseError.untrustedDownloadURL.message) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("uiui", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url, UpdateRelease.isTrustedDownload(final) else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateFailure(message: "The download failed.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        guard size > 0, size <= maxBytes else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateFailure(message: "The download has an unexpected size.")
        }
        return file
    }

    private nonisolated static func verifyAndExtract(archive: URL, expectedDigest: String, release: UpdateRelease, current: UpdateVersion, into work: URL) throws -> URL {
        guard try sha256(of: archive) == expectedDigest else { throw UpdateFailure(message: "The download does not match its checksum.") }
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path], failure: "The download could not be unpacked.")
        let entries = try FileManager.default.contentsOfDirectory(atPath: extracted.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        guard entries == ["uiui.app"] else { throw UpdateFailure(message: "The download does not contain exactly one uiui app.") }
        let app = extracted.appendingPathComponent("uiui.app", isDirectory: true)
        let kind = try? FileManager.default.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType
        guard kind == .typeDirectory else { throw UpdateFailure(message: "The download does not contain a uiui app.") }
        let bundle = Bundle(url: app)
        guard bundle?.bundleIdentifier == "app.uiui.mac" else { throw UpdateFailure(message: "The download is not uiui.") }
        guard let versionText = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = UpdateVersion(versionText), version == release.version, version > current else {
            throw UpdateFailure(message: "The downloaded version does not match the release.")
        }
        try verifySignature(of: app)
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], failure: "")
        return app
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Requires the new bundle to satisfy the running app's designated requirement
    /// (same certificate and identifier), so privacy grants carry over.
    private nonisolated static func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, SecCSFlags(), &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, SecCSFlags(), &requirement) == errSecSuccess, let requirement else {
            throw UpdateFailure(message: "This copy of uiui cannot check update signatures.")
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &newCode) == errSecSuccess, let newCode else {
            throw UpdateFailure(message: "The downloaded app could not be inspected.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess else {
            throw UpdateFailure(message: "The downloaded app is not signed by the same identity as this one.")
        }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure(message: failure) }
    }

    /// Renaming the running bundle keeps its open files valid; on failure the old bundle is restored.
    private nonisolated static func replace(target: URL, with newApp: URL, work: URL) throws {
        let fileManager = FileManager.default
        let previous = work.appendingPathComponent("previous.app", isDirectory: true)
        do { try fileManager.moveItem(at: target, to: previous) } catch {
            throw UpdateFailure(message: "The installed app could not be replaced.")
        }
        do { try fileManager.moveItem(at: newApp, to: target) } catch {
            try? fileManager.moveItem(at: previous, to: target)
            throw UpdateFailure(message: "The new version could not be installed.")
        }
    }
}
