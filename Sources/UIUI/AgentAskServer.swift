import AppKit
import Foundation
import UIUICore

/// The one owner of the agent socket and the lock and sleep events that answer it.
/// The socket exists only while the person has agents turned on and is reachable only
/// by this user's processes. It is event-driven: nothing runs while nobody is asking.
/// Questions and answers pass through and are never written down.
final class AgentAskServer: @unchecked Sendable {
    static func socketURL(dataDirectory: URL) -> URL { dataDirectory.appendingPathComponent("ask.sock") }

    /// All callbacks arrive on the main actor.
    var onRequest: (@MainActor (UUID, AskRequest) -> Void)?
    var onDisconnect: (@MainActor (UUID) -> Void)?
    var onLockChanged: (@MainActor (Bool) -> Void)?
    var onSleep: (@MainActor () -> Void)?

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var answered = false
        var requestReceived = false
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    private let queue = DispatchQueue(label: "app.uiui.agent-ask")
    private let path: String
    private var listener: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(socketURL: URL) { path = socketURL.path }

    func start() throws {
        guard listener == nil else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        unlink(path)
        // The file mode is set before anything can connect, so no other user ever can.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); unlink(path); throw POSIXError(.EADDRINUSE) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
        observeSystemEvents()
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        queue.sync {
            listener?.cancel(); listener = nil
            for connection in connections.values { connection.source.cancel() }
            connections = [:]
        }
        unlink(path)
    }

    func reply(_ id: UUID, _ response: AskResponse) {
        reply(id, data: (try? JSONEncoder().encode(response)) ?? Data())
    }

    func reply(_ id: UUID, data: Data) {
        queue.async { [weak self] in
            guard let self, let connection = connections.removeValue(forKey: id) else { return }
            connection.answered = true
            var payload = data
            payload.append(0x0A)
            payload.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = write(connection.fd, bytes.baseAddress! + sent, bytes.count - sent)
                    if count <= 0 { break }
                    sent += count
                }
            }
            connection.source.cancel()
        }
    }

    private func observeSystemEvents() {
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let observer = distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLockChanged?(locked) }
            }
            observers.append((distributed, observer))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSleep?() }
        }
        observers.append((workspace, sleep))
    }

    private func accept(on listenerFD: Int32) {
        let fd = Darwin.accept(listenerFD, nil, nil)
        guard fd >= 0 else { return }
        var uid = uid_t(); var gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let id = UUID()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let connection = Connection(fd: fd, source: source)
        connections[id] = connection
        source.setEventHandler { [weak self] in self?.readable(id) }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func readable(_ id: UUID) {
        guard let connection = connections[id] else { return }
        var bytes = [UInt8](repeating: 0, count: 2_048)
        let count = read(connection.fd, &bytes, bytes.count)
        if count < 0, errno == EAGAIN { return }
        guard count > 0 else {
            // The caller went away, whether it finished, timed out or died.
            connections.removeValue(forKey: id)
            connection.source.cancel()
            if connection.requestReceived { deliverDisconnect(id) }
            return
        }
        guard !connection.requestReceived else { return }
        connection.buffer.append(contentsOf: bytes[0..<count])
        guard connection.buffer.count <= AskRequest.maximumEncodedSize else {
            connections.removeValue(forKey: id)
            connection.source.cancel()
            return
        }
        guard let end = connection.buffer.firstIndex(of: 0x0A) else { return }
        guard let request = try? JSONDecoder().decode(AskRequest.self, from: connection.buffer[..<end]) else {
            connections.removeValue(forKey: id)
            connection.source.cancel()
            return
        }
        connection.requestReceived = true
        connection.buffer = Data()
        Task { @MainActor [weak self] in self?.onRequest?(id, request) }
    }

    private func deliverDisconnect(_ id: UUID) {
        Task { @MainActor [weak self] in self?.onDisconnect?(id) }
    }
}

/// `uiui ask` and `uiui stats`: a small client inside the same binary, run by agents.
/// It never launches the app; if uiui is not listening it says so at once.
enum AgentAskCommand {
    static let defaultTimeout: TimeInterval = 600
    private static let usage = """
    Usage:
      uiui ask "question" [--from name] [--timeout seconds]
      uiui stats

    Prints the person's exact spoken words and exits 0. Nothing else goes to stdout.
    Exit codes: 2 usage, 3 uiui not available, 4 Mac locked or asleep, 5 timed out.
    """

    /// Returns an exit code if this launch is a command rather than the app.
    static func runIfRequested(arguments: [String], dataDirectory: URL) -> Int32? {
        guard arguments.count >= 2 else { return nil }
        switch arguments[1] {
        case "ask": return ask(Array(arguments.dropFirst(2)), dataDirectory: dataDirectory)
        case "stats": return stats(dataDirectory: dataDirectory)
        default: return nil
        }
    }

    private static func ask(_ arguments: [String], dataDirectory: URL) -> Int32 {
        var question: String?
        var agent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
        var timeout = defaultTimeout
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--from" || argument == "--timeout" {
                guard index + 1 < arguments.count else { return usageError() }
                let value = arguments[index + 1]
                if argument == "--from" { agent = value }
                else {
                    guard let seconds = TimeInterval(value), seconds > 0 else { return usageError() }
                    timeout = seconds
                }
                index += 2
            } else if question == nil, !argument.hasPrefix("--") {
                question = argument
                index += 1
            } else { return usageError() }
        }
        guard let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return usageError() }
        let request = AskRequest(kind: .ask, agent: agent, question: question)
        guard let reply = exchange(request, timeout: timeout, dataDirectory: dataDirectory) else {
            return report(.unavailable)
        }
        if case .timedOut = reply { return report(.timeout) }
        guard case .data(let data) = reply, let response = try? JSONDecoder().decode(AskResponse.self, from: data) else {
            return report(.unavailable)
        }
        guard response.outcome == .answered else { return report(response.outcome) }
        print(response.text)
        return AskOutcome.answered.exitCode
    }

    private static func stats(dataDirectory: URL) -> Int32 {
        guard case .data(let data)? = exchange(AskRequest(kind: .stats), timeout: 5, dataDirectory: dataDirectory),
              let response = try? JSONDecoder().decode(AskResponse.self, from: data) else { return report(.unavailable) }
        print(response.text)
        return 0
    }

    private static func usageError() -> Int32 {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 2
    }

    private static func report(_ outcome: AskOutcome) -> Int32 {
        let message: String
        switch outcome {
        case .answered: return outcome.exitCode
        case .away: message = "uiui: the Mac is locked or asleep."
        case .timeout: message = "uiui: no answer in time."
        case .unavailable: message = "uiui: not available. Open uiui and turn on Settings > Agents."
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return outcome.exitCode
    }

    private enum Reply { case data(Data), timedOut }

    private static func exchange(_ request: AskRequest, timeout: TimeInterval, dataDirectory: URL) -> Reply? {
        guard var payload = try? JSONEncoder().encode(request), payload.count < AskRequest.maximumEncodedSize else { return nil }
        payload.append(0x0A)
        let path = AgentAskServer.socketURL(dataDirectory: dataDirectory).path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let wrote = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote == payload.count else { return nil }
        var received = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { return nil }
            if ready == 0 { continue }
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else { return received.isEmpty ? nil : .data(received) }
            received.append(contentsOf: bytes[0..<count])
            if let end = received.firstIndex(of: 0x0A) { return .data(received.subdata(in: received.startIndex..<end)) }
        }
    }
}
