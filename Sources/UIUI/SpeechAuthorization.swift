import AVFoundation
import AppKit
import Observation
import Speech

enum CapturePermission: Equatable {
    case notDetermined, authorized, denied, restricted
    var title: String {
        switch self {
        case .notDetermined: return "Not requested"
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }
}

/// One owner for the app's two capture permissions. A shared in-flight request
/// prevents Settings and either capture path from opening competing prompts.
@MainActor @Observable
final class SpeechAuthorization {
    struct Client {
        var speechStatus: () -> CapturePermission
        var microphoneStatus: () -> CapturePermission
        var requestSpeech: () async -> CapturePermission
        var requestMicrophone: () async -> CapturePermission
    }
    static let shared = SpeechAuthorization(client: .native, observesActivation: true)
    private(set) var speechStatus: CapturePermission
    private(set) var microphoneStatus: CapturePermission
    @ObservationIgnored private let client: Client
    @MainActor private struct Requester {
        let requiresSpeechRecognition: Bool
        let whileActive: @MainActor () -> Bool
        let cancellation: PermissionRequestCancellation
        var isActive: Bool { !cancellation.isCancelled && whileActive() }
    }
    private enum PermissionAttempt: Hashable { case speech, microphone }
    @ObservationIgnored private var attemptedPermissions: Set<PermissionAttempt> = []
    @ObservationIgnored private var pendingPermission: PermissionAttempt?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var requesters: [UUID: Requester] = [:]
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(client: Client, observesActivation: Bool = false) {
        self.client = client
        speechStatus = client.speechStatus()
        microphoneStatus = client.microphoneStatus()
        if observesActivation {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        }
    }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }

    func refresh() {
        speechStatus = client.speechStatus()
        microphoneStatus = client.microphoneStatus()
    }
    var summary: String { "Microphone: \(microphoneStatus.title) · Speech: \(speechStatus.title)" }
    var guidance: String { guidance(requiresSpeechRecognition: true) }
    func guidance(requiresSpeechRecognition: Bool) -> String {
        if requiresSpeechRecognition, speechStatus != .authorized {
            return "Speech Recognition is \(speechStatus.title.lowercased()) for uiui. Check uiui in System Settings → Privacy & Security → Speech Recognition."
        }
        return "Microphone access is \(microphoneStatus.title.lowercased()) for uiui. Check uiui in System Settings → Privacy & Security → Microphone."
    }

    func request(requiresSpeechRecognition: Bool = true,
                 whileActive: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        let id = UUID()
        let cancellation = PermissionRequestCancellation()
        requesters[id] = Requester(requiresSpeechRecognition: requiresSpeechRecognition,
                                   whileActive: whileActive, cancellation: cancellation)
        defer {
            requesters.removeValue(forKey: id)
            // A new explicit request may retry, but concurrent waiters belong
            // to the same wave and must never reopen an inconclusive OS dialog.
            if requesters.isEmpty { attemptedPermissions.removeAll() }
            refresh()
        }
        refresh()
        return await withTaskCancellationHandler {
            while !cancellation.isCancelled, whileActive(), !Task.isCancelled {
                if microphoneStatus == .denied || microphoneStatus == .restricted { return false }
                if requiresSpeechRecognition, speechStatus == .denied || speechStatus == .restricted { return false }
                if microphoneStatus == .authorized, !requiresSpeechRecognition || speechStatus == .authorized { return true }
                if requiresSpeechRecognition, speechStatus == .notDetermined,
                   attemptedPermissions.contains(.speech), pendingPermission != .speech { return false }
                if microphoneStatus == .notDetermined,
                   attemptedPermissions.contains(.microphone), pendingPermission != .microphone { return false }
                // One shared OS dialog at a time. A completed step is not a
                // shared grant: every caller checks its own required permissions.
                if let pending { await pending.value }
                else if let step = nextPermissionStep() { await step.value }
                else { return false }
            }
            return false
        } onCancel: { cancellation.cancel() }
    }

    private func nextPermissionStep() -> Task<Void, Never>? {
        let active = requesters.values.filter(\.isActive)
        let needsSpeech = speechStatus == .notDetermined && !attemptedPermissions.contains(.speech)
            && microphoneStatus != .denied && microphoneStatus != .restricted
            && active.contains { $0.requiresSpeechRecognition }
        let needsMicrophone = microphoneStatus == .notDetermined && !attemptedPermissions.contains(.microphone)
            && active.contains { !$0.requiresSpeechRecognition || speechStatus == .authorized }
        guard needsSpeech || needsMicrophone else { return nil }
        let client = client
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pending = nil; self.pendingPermission = nil }
            // Recheck after scheduling. An OS dialog cannot be dismissed, but
            // cancellation must prevent a second prompt when nobody still needs it.
            if needsSpeech {
                guard self.speechStatus == .notDetermined,
                      self.requesters.values.contains(where: { $0.isActive && $0.requiresSpeechRecognition }) else { return }
                self.attemptedPermissions.insert(.speech)
                self.speechStatus = await client.requestSpeech()
            } else {
                guard self.microphoneStatus == .notDetermined,
                      self.requesters.values.contains(where: { $0.isActive && (!$0.requiresSpeechRecognition || self.speechStatus == .authorized) }) else { return }
                self.attemptedPermissions.insert(.microphone)
                self.microphoneStatus = await client.requestMicrophone()
            }
        }
        pendingPermission = needsSpeech ? .speech : .microphone
        pending = task
        return task
    }

}

/// Cancellation can be signaled synchronously from a task cancellation handler;
/// the MainActor remains the only owner that chooses and opens OS dialogs.
private final class PermissionRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

private extension SpeechAuthorization.Client {
    static var native: Self {
        Self(speechStatus: { permission(SFSpeechRecognizer.authorizationStatus()) },
             microphoneStatus: { permission(AVCaptureDevice.authorizationStatus(for: .audio)) },
             requestSpeech: {
                 await withCheckedContinuation { continuation in
                     SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: permission($0)) }
                 }
             },
             requestMicrophone: {
                 let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                 return allowed ? .authorized : permission(AVCaptureDevice.authorizationStatus(for: .audio))
             })
    }

    static func permission(_ value: SFSpeechRecognizerAuthorizationStatus) -> CapturePermission {
        switch value {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
    static func permission(_ value: AVAuthorizationStatus) -> CapturePermission {
        switch value {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
}
