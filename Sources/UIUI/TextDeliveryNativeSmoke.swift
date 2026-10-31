#if DEBUG
import AppKit
import ApplicationServices
import Darwin
import CryptoKit
import Foundation

/// Explicit, synthetic native acceptance check. The receiver is a separate process
/// running this executable, never a window or draft belonging to another app.
@MainActor
enum TextDeliveryNativeSmoke {
    /// CUA supplies two real Escape presses to an owned receiver: the first
    /// cancels uiui, the second must reach the receiver after cancellation.
    /// This diagnostic never opens the microphone or reads/writes the clipboard.
    static func runEscape() async throws {
        guard AXIsProcessTrusted() else { throw SmokeFailure.accessibility }
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-delivery-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let child = Process()
        let shortcuts = GlobalShortcuts()
        var cancellations = 0
        shortcuts.onEscape = {
            cancellations += 1
            shortcuts.setEscapeCancellationEnabled(false)
        }
        defer {
            shortcuts.remove()
            let wasFixture = child.processIdentifier > 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            if wasFixture { previousApp?.activate() }
            try? FileManager.default.removeItem(at: directory)
        }
        try write(Command(sequence: 1, scenario: .short), named: "command.json", in: directory)
        // A distinct bundle identity lets native UI automation address the
        // receiver instead of Launch Services resolving our accessory parent.
        let receiver = try makeReceiverFixture(in: directory)
        child.executableURL = receiver.appendingPathComponent("Contents/MacOS/uiui")
        child.arguments = ["--delivery-fixture", directory.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        _ = try await awaitStatus(in: directory, child: child, stage: "escape-ready") {
            $0.ready && NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
        }
        shortcuts.setEscapeCancellationEnabled(true)
        print("ESCAPE_SMOKE phase=active-ready receiver_pid=\(child.processIdentifier) receiver_bundle=\(receiver.path) microphone=not-opened clipboard=untouched"); fflush(stdout)
        // Native automation may spend a round trip resolving this disposable
        // bundle. Keep the interaction bounded without racing that setup.
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while cancellations == 0 {
            guard .now < deadline, child.isRunning else { throw SmokeFailure.fixtureExited }
            try await Task.sleep(for: .milliseconds(15))
        }
        // Allow the same physical Escape's release to traverse the event tap.
        try await Task.sleep(for: .milliseconds(250))
        let active = try await awaitStatus(in: directory, child: child, stage: "active-cancel") { $0.ordinaryDownEvents > 0 }
        guard cancellations == 1, active.escapeDownEvents == 0, active.escapeUpEvents == 0 else {
            throw SmokeFailure.dispatch("Escape leaked to the owned receiver during cancellation")
        }
        print("ESCAPE_SMOKE phase=idle-ready cancellations=1 active_escape_down=0 active_escape_up=0 ordinary_key_passed=true"); fflush(stdout)
        let idleDeadline = ContinuousClock.now.advanced(by: .seconds(180))
        var idle: Status?
        while .now < idleDeadline, child.isRunning {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")),
               let status = try? JSONDecoder().decode(Status.self, from: data),
               status.pid == child.processIdentifier, status.escapeDownEvents == 1, status.escapeUpEvents == 1 {
                idle = status; break
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        guard idle != nil, cancellations == 1 else { throw SmokeFailure.dispatch("Idle Escape did not reach the owned receiver") }
        print("ESCAPE_SMOKE passed=true cancellations=1 idle_escape_down=1 idle_escape_up=1 own_receiver=true")
    }

    private static func makeReceiverFixture(in directory: URL) throws -> URL {
        let receiver = directory.appendingPathComponent("uiui Native Test.app", isDirectory: true)
        try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: receiver)
        let info = receiver.appendingPathComponent("Contents/Info.plist")
        guard var values = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any] else {
            throw SmokeFailure.fixtureDirectory
        }
        let identifier = "app.uiui.native-fixture." + UUID().uuidString.lowercased()
        values["CFBundleIdentifier"] = identifier
        values["CFBundleName"] = "uiui Native Test"
        values["CFBundleDisplayName"] = "uiui Native Test"
        values["LSUIElement"] = false
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info, options: .atomic)
        // Only this disposable copy is ad-hoc signed. The installed app and
        // persistent signing key are untouched; the receiver needs no OS grants.
        let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--identifier", identifier, receiver.path]
        signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        guard signer.terminationStatus == 0 else { throw SmokeFailure.fixtureDirectory }
        return receiver
    }

    static func run() async throws {
        guard AXIsProcessTrusted() else { throw SmokeFailure.accessibility }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let pasteboard = NSPasteboard.general
        let originalCount = pasteboard.changeCount
        guard let originalItems = snapshot(pasteboard, expectedCount: originalCount) else {
            throw SmokeFailure.clipboardSnapshot
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-delivery-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let child = Process()
        var ownedClipboardCount: Int?
        var ownedPayload: String?
        defer {
            // A newer copy wins, including one made while the fixture is closing.
            if let ownedClipboardCount, let ownedPayload,
               pasteboard.changeCount == ownedClipboardCount,
               pasteboard.string(forType: .string) == ownedPayload,
               pasteboard.changeCount == ownedClipboardCount {
                let clearedCount = pasteboard.clearContents()
                if pasteboard.changeCount == clearedCount, !originalItems.isEmpty {
                    _ = pasteboard.writeObjects(originalItems)
                }
            }
            if child.processIdentifier > 0 {
                let wasFixture = NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
                if child.isRunning { child.terminate(); child.waitUntilExit() }
                if wasFixture, let previousApp, !previousApp.isTerminated {
                    previousApp.activate(options: [.activateIgnoringOtherApps])
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        try write(Command(sequence: 1, scenario: .short), named: "command.json", in: directory)
        child.executableURL = try makeReceiverFixture(in: directory).appendingPathComponent("Contents/MacOS/uiui")
        child.arguments = ["--delivery-fixture", directory.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()

        let initial = try await awaitStatus(in: directory, child: child, stage: "short-ready") {
            $0.sequence == 1 && $0.ready && NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
        }
        guard initial.pid == child.processIdentifier else { throw SmokeFailure.fixtureIdentity }
        guard let shortTarget = TextDelivery.captureTarget(), shortTarget.appPID == child.processIdentifier else {
            throw SmokeFailure.fixtureFocus
        }
        let delivery = TextDelivery()
        let shortPayload = Scenario.short.payload
        guard pasteboard.changeCount == originalCount else { throw SmokeFailure.clipboardChanged }
        ownedClipboardCount = originalCount + 1
        ownedPayload = shortPayload
        try requireSent(await delivery.deliver(shortPayload, to: shortTarget), stage: "short")
        let shortResult = try await awaitStatus(in: directory, child: child, stage: "short-insertion") {
            $0.sequence == 1 && $0.matchesExpected && $0.changeEvents > 0
        }
        guard pasteboard.changeCount == ownedClipboardCount,
              pasteboard.string(forType: .string) == shortPayload else { throw SmokeFailure.clipboardChanged }

        // Capture before replacing the NSTextView. A target anchors the app, not
        // an obsolete AX element or selection captured at recording time.
        guard let changedElementTarget = TextDelivery.captureTarget(),
              changedElementTarget.appPID == child.processIdentifier else { throw SmokeFailure.fixtureFocus }
        try write(Command(sequence: 2, scenario: .long), named: "command.json", in: directory)
        _ = try await awaitStatus(in: directory, child: child, stage: "long-ready") {
            $0.sequence == 2 && $0.ready && NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier else {
            throw SmokeFailure.fixtureFocus
        }
        guard pasteboard.changeCount == ownedClipboardCount,
              pasteboard.string(forType: .string) == shortPayload else { throw SmokeFailure.clipboardChanged }
        let longPayload = Scenario.long.payload
        ownedClipboardCount = (ownedClipboardCount ?? originalCount) + 1
        ownedPayload = longPayload
        try requireSent(await delivery.deliver(longPayload, to: changedElementTarget), stage: "long")
        let longResult = try await awaitStatus(in: directory, child: child, stage: "long-insertion") {
            $0.sequence == 2 && $0.matchesExpected && $0.changeEvents > 0
        }
        // Reuse one receiver for repetition: launching overlapping app instances
        // with the same bundle identity tests Launch Services activation instead
        // of paste reliability. Each turn still replaces the editor and selection.
        var confirmedPastes = 2
        for sequence in 3...10 {
            guard let target = TextDelivery.captureTarget(), target.appPID == child.processIdentifier else {
                throw SmokeFailure.fixtureFocus
            }
            let scenario: Scenario = sequence.isMultiple(of: 2) ? .long : .short
            try write(Command(sequence: sequence, scenario: scenario), named: "command.json", in: directory)
            _ = try await awaitStatus(in: directory, child: child, stage: "repeat-ready") { $0.sequence == sequence && $0.ready }
            guard pasteboard.changeCount == ownedClipboardCount,
                  pasteboard.string(forType: .string) == ownedPayload else { throw SmokeFailure.clipboardChanged }
            ownedClipboardCount = (ownedClipboardCount ?? originalCount) + 1
            ownedPayload = scenario.payload
            try requireSent(await delivery.deliver(scenario.payload, to: target), stage: "repeat-\(sequence)")
            let result = try await awaitStatus(in: directory, child: child, stage: "repeat-insertion") {
                $0.sequence == sequence && $0.matchesExpected && $0.changeEvents > 0
            }
            guard result.pasteAttempts == 1 else { throw SmokeFailure.dispatch("duplicate paste in owned receiver") }
            confirmedPastes += 1
        }
        // Keep the production consumption lease alive before tearing down its receiver.
        try await Task.sleep(for: .milliseconds(450))
        print("DELIVERY_SMOKE confirmed_pastes=\(confirmedPastes) short_inserted=\(shortResult.matchesExpected) short_utf16=\(shortResult.utf16Count) short_paste_attempts=\(shortResult.pasteAttempts) long_inserted=\(longResult.matchesExpected) long_utf16=\(longResult.utf16Count) long_paste_attempts=\(longResult.pasteAttempts) changed_element=true own_process=true")
    }

    /// Full model-to-paste operations run only after our disposable receiver
    /// owns focus. Digest readback verifies the exact generated payload without
    /// logging it or touching a personal editor.
    final class PayloadRegistration {
        private let register: (String) throws -> Void
        init(_ register: @escaping (String) throws -> Void) { self.register = register }
        func willDeliver(_ text: String) throws { try register(text) }
    }

    static func runFlows(_ operations: [@MainActor (DeliveryTarget, PayloadRegistration) async throws -> String]) async throws {
        guard AXIsProcessTrusted() else { throw SmokeFailure.accessibility }
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let pasteboard = NSPasteboard.general
        let originalCount = pasteboard.changeCount
        guard let originalItems = snapshot(pasteboard, expectedCount: originalCount) else { throw SmokeFailure.clipboardSnapshot }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-delivery-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let child = Process()
        var ownedCount: Int?
        var ownedPayload: String?
        var pendingCount: Int?
        var pendingPayload: String?
        defer {
            if let pendingCount, let pendingPayload, pasteboard.changeCount == pendingCount,
               pasteboard.string(forType: .string) == pendingPayload { ownedCount = pendingCount; ownedPayload = pendingPayload }
            if let ownedCount, let ownedPayload, pasteboard.changeCount == ownedCount,
               pasteboard.string(forType: .string) == ownedPayload, pasteboard.changeCount == ownedCount {
                let cleared = pasteboard.clearContents()
                if pasteboard.changeCount == cleared, !originalItems.isEmpty { _ = pasteboard.writeObjects(originalItems) }
            }
            let wasFixture = child.processIdentifier > 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            if wasFixture { previousApp?.activate() }
            try? FileManager.default.removeItem(at: directory)
        }
        try write(Command(sequence: 1, scenario: .short), named: "command.json", in: directory)
        child.executableURL = try makeReceiverFixture(in: directory).appendingPathComponent("Contents/MacOS/uiui")
        child.arguments = ["--delivery-fixture", directory.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        for (index, operation) in operations.enumerated() {
            let sequence = index + 1
            if sequence > 1 { try write(Command(sequence: sequence, scenario: .short), named: "command.json", in: directory) }
            _ = try await awaitStatus(in: directory, child: child, stage: "flow-ready") {
                $0.sequence == sequence && $0.ready && NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
            }
            guard let target = TextDelivery.captureTarget(), target.appPID == child.processIdentifier,
                  pasteboard.changeCount == (ownedCount ?? originalCount) else { throw SmokeFailure.fixtureFocus }
            let expectedCount = (ownedCount ?? originalCount) + 1
            let registration = PayloadRegistration { payload in
                // Inference can take seconds. A newer user copy during that
                // interval wins; abort before the native delivery writes.
                guard pasteboard.changeCount == expectedCount - 1 else { throw SmokeFailure.clipboardChanged }
                pendingCount = expectedCount; pendingPayload = payload
            }
            let payload = try await operation(target, registration)
            guard pasteboard.changeCount == expectedCount, pasteboard.string(forType: .string) == payload else { throw SmokeFailure.clipboardChanged }
            ownedCount = expectedCount; ownedPayload = payload; pendingCount = nil; pendingPayload = nil
            let expected = digest(Scenario.prefix + payload + Scenario.suffix)
            let result = try await awaitStatus(in: directory, child: child, stage: "flow-insertion") {
                $0.sequence == sequence && $0.textDigest == expected && $0.pasteAttempts == 1
            }
            print("CLEANUP_FLOW native_paste=\(sequence) exact_readback=true paste_attempts=\(result.pasteAttempts) utf16=\(result.utf16Count) own_receiver=true")
        }
        try await Task.sleep(for: .milliseconds(450))
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func requireSent(_ result: DeliveryResult, stage: String) throws {
        switch result {
        case .pasteSent: return
        case .copied(let reason): throw SmokeFailure.dispatch("\(stage): copied; \(reason)")
        case .held(let reason): throw SmokeFailure.dispatch("\(stage): held; \(reason)")
        }
    }

    /// Called by bootstrap before constructing the ordinary app or its model.
    /// This owns a bounded native event loop and returns after the fixture stops.
    static func runFixture(directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard directory.lastPathComponent.hasPrefix("uiui-delivery-smoke-"),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700 else {
            throw SmokeFailure.fixtureDirectory
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = Fixture(directory: directory)
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
    }

    private enum Scenario: String, Codable {
        case short, long
        var payload: String {
            switch self {
            case .short: return "uiui synthetic paste · café 漢字 🧪"
            case .long:
                return (0..<50).map { line in
                    (0..<20).map { word in "sample\(line)_\(word)·café·漢字·🧪" }.joined(separator: " ")
                }.joined(separator: "\n")
            }
        }
        static let prefix = "Synthetic prefix · ["
        static let placeholder = "replace this synthetic selection"
        static let suffix = "]\nSynthetic suffix · complete"
        var expected: String { Self.prefix + payload + Self.suffix }
    }

    private struct Command: Codable {
        let sequence: Int
        let scenario: Scenario
    }

    private struct Status: Codable {
        let pid: pid_t
        let sequence: Int
        let ready: Bool
        let matchesExpected: Bool
        let utf16Count: Int
        let changeEvents: Int
        let pasteAttempts: Int
        let textDigest: String
        let escapeDownEvents: Int
        let escapeUpEvents: Int
        let ordinaryDownEvents: Int
    }

    private static func write<T: Encodable>(_ value: T, named name: String, in directory: URL) throws {
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Smoke-only preservation: production intentionally does not materialize
    /// arbitrary clipboard providers. Refuse this opt-in check when a complete,
    /// modest-sized snapshot cannot be made before any synthetic write.
    private static func snapshot(_ pasteboard: NSPasteboard, expectedCount: Int) -> [NSPasteboardItem]? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        let originals = pasteboard.pasteboardItems ?? []
        guard originals.count <= 16,
              !originals.isEmpty || (pasteboard.types ?? []).isEmpty else { return nil }
        var totalBytes = 0
        var copies: [NSPasteboardItem] = []
        for original in originals {
            guard original.types.count <= 32 else { return nil }
            let copy = NSPasteboardItem()
            for type in original.types {
                guard clock.now < deadline, pasteboard.changeCount == expectedCount,
                      let data = original.data(forType: type) else { return nil }
                totalBytes += data.count
                guard totalBytes <= 8 * 1024 * 1024, clock.now < deadline,
                      copy.setData(data, forType: type) else { return nil }
            }
            copies.append(copy)
        }
        return pasteboard.changeCount == expectedCount ? copies : nil
    }

    private static func awaitStatus(in directory: URL, child: Process, stage: String,
                                    matching predicate: (Status) -> Bool) async throws -> Status {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var latest: Status?
        while clock.now < deadline {
            guard child.isRunning else { throw SmokeFailure.fixtureExited }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")),
               let status = try? JSONDecoder().decode(Status.self, from: data) {
                guard status.pid == child.processIdentifier else { throw SmokeFailure.fixtureIdentity }
                latest = status
                if predicate(status) { return status }
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw SmokeFailure.timeout(stage, latest)
    }

    /// Counts action routing only inside the disposable receiver. No keyboard
    /// events, source-app content, or clipboard values are observed or logged.
    @MainActor
    private final class FixtureTextView: NSTextView {
        private(set) var pasteAttempts = 0
        var onPasteAttempt: (() -> Void)?
        private(set) var escapeDownEvents = 0
        private(set) var escapeUpEvents = 0
        private(set) var ordinaryDownEvents = 0
        var onKeyEvent: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { escapeDownEvents += 1 }
            else { ordinaryDownEvents += 1 }
            super.keyDown(with: event)
            onKeyEvent?()
        }
        override func keyUp(with event: NSEvent) {
            if event.keyCode == 53 { escapeUpEvents += 1 }
            super.keyUp(with: event)
            onKeyEvent?()
        }

        override func paste(_ sender: Any?) {
            pasteAttempts += 1
            super.paste(sender)
            onPasteAttempt?()
        }
    }

    @MainActor
    private final class Fixture: NSObject, NSApplicationDelegate, NSTextViewDelegate {
        private let directory: URL
        private var window: NSWindow?
        private var textView: FixtureTextView?
        private var command: Command?
        private var changeEvents = 0
        private var source: DispatchSourceFileSystemObject?
        private var deadline: Timer?

        init(directory: URL) { self.directory = directory }

        func applicationDidFinishLaunching(_ notification: Notification) {
            let menu = NSMenu()
            // AppKit reserves the first top-level item for the application menu.
            // Keep Edit separate so its Cmd-V equivalent uses responder routing.
            let application = NSMenuItem(title: "uiui paste test", action: nil, keyEquivalent: "")
            let applicationMenu = NSMenu(title: "uiui paste test")
            applicationMenu.addItem(withTitle: "Quit paste test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            application.submenu = applicationMenu
            menu.addItem(application)
            let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Edit")
            submenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            edit.submenu = submenu
            menu.addItem(edit)
            NSApplication.shared.mainMenu = menu
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "uiui paste test · disposable"
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
            // Directory notifications cover atomic command-file replacement;
            // there is no idle command polling or observation of other apps.
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { NSApplication.shared.terminate(nil); return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.readCommand() }
            source.setCancelHandler { close(descriptor) }
            self.source = source
            source.resume()
            deadline = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in
                NSApplication.shared.terminate(nil)
            }
            readCommand()
        }

        private func readCommand() {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
                  let next = try? JSONDecoder().decode(Command.self, from: data),
                  (1...10).contains(next.sequence),
                  next.sequence > (command?.sequence ?? 0) else { return }
            command = next
            changeEvents = 0
            let view = FixtureTextView(frame: NSRect(x: 16, y: 16, width: 588, height: 328))
            view.isRichText = false
            view.isEditable = true
            view.isSelectable = true
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.smartInsertDeleteEnabled = false
            view.string = Scenario.prefix + Scenario.placeholder + Scenario.suffix
            view.setSelectedRange(NSRange(location: Scenario.prefix.utf16.count, length: Scenario.placeholder.utf16.count))
            view.delegate = self
            view.onPasteAttempt = { [weak self] in self?.publishStatus() }
            view.onKeyEvent = { [weak self] in self?.publishStatus() }
            // Replacing the content view deliberately destroys the first AX element.
            textView?.delegate = nil
            window?.contentView = view
            textView = view
            window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window?.makeFirstResponder(view)
            publishStatus()
        }

        func textDidChange(_ notification: Notification) {
            guard let changed = notification.object as? NSTextView, changed === textView else { return }
            changeEvents += 1
            publishStatus()
        }

        private func publishStatus() {
            guard let command, let textView else { return }
            let status = Status(pid: getpid(), sequence: command.sequence,
                                ready: window?.firstResponder === textView,
                                matchesExpected: textView.string == command.scenario.expected,
                                utf16Count: textView.string.utf16.count, changeEvents: changeEvents,
                                pasteAttempts: textView.pasteAttempts, textDigest: TextDeliveryNativeSmoke.digest(textView.string),
                                escapeDownEvents: textView.escapeDownEvents, escapeUpEvents: textView.escapeUpEvents,
                                ordinaryDownEvents: textView.ordinaryDownEvents)
            try? TextDeliveryNativeSmoke.write(status, named: "status.json", in: directory)
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
        func applicationWillTerminate(_ notification: Notification) {
            deadline?.invalidate()
            source?.cancel()
        }
    }

    private enum SmokeFailure: LocalizedError {
        case accessibility, clipboardSnapshot, clipboardChanged, fixtureIdentity, fixtureFocus
        case fixtureDirectory, fixtureExited, dispatch(String)
        case timeout(String, Status?)
        var errorDescription: String? {
            switch self {
            case .accessibility: return "Accessibility permission is required for the synthetic native paste check."
            case .clipboardSnapshot: return "The original clipboard could not be materialized safely."
            case .clipboardChanged: return "The clipboard changed during the synthetic check."
            case .fixtureIdentity: return "The disposable receiver identity did not match the owned child process."
            case .fixtureFocus: return "The disposable receiver is not the focused app."
            case .fixtureDirectory: return "The disposable receiver directory failed ownership validation."
            case .fixtureExited: return "The disposable receiver exited before readback."
            case .dispatch(let reason): return "Production delivery did not dispatch a paste to the disposable receiver: \(reason)"
            case .timeout(let stage, let status):
                guard let status else {
                    return "The disposable receiver timed out stage=\(stage) status_received=false."
                }
                return "The disposable receiver timed out stage=\(stage) sequence=\(status.sequence) ready=\(status.ready) matches_expected=\(status.matchesExpected) utf16=\(status.utf16Count) change_events=\(status.changeEvents) paste_attempts=\(status.pasteAttempts)."
            }
        }
    }
}
#endif
