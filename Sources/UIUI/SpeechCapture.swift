import AppKit
import AVFoundation
import Observation
import Speech
import UIUICore

struct SpeechCompletion: Equatable, Sendable {
    enum Reason: Equatable, Sendable { case final, timedOut, recognitionError, unreconciledFinal }
    let text: String
    let reason: Reason
    let wasExplicitlyStopped: Bool

    var recoveryMessage: String {
        if reason != .final, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Speech recognition stopped before any words were captured. Check the system microphone and try again."
        }
        switch reason {
        case .final: return ""
        case .timedOut: return "Speech recognition did not confirm a final result. Your words are kept here."
        case .recognitionError: return "On-device speech recognition stopped. Your words are kept here; check your microphone and speech language."
        case .unreconciledFinal: return "Speech recognition could not confirm a complete transcript. Your best full transcript is kept here for review."
        }
    }
}

/// Main-actor observable state; the serial audio owner performs all native engine work.
@MainActor @Observable
final class SpeechCapture {
    private(set) var isRecording = false
    private(set) var transcript = ""
    private(set) var stateDescription = "Ready"
    private(set) var engineDescription = "On-device speech"
    private(set) var engineWarning: String?
    /// Set when a session starts, from the engine actually chosen. False until then.
    private(set) var supportsPause = false
    @ObservationIgnored private var finalizationWaitMilliseconds = 1200
    @ObservationIgnored private var requiresCompleteFinalization = false
    var hasActiveSession: Bool { isStarting || isRecording || isFinishing || completingGeneration != nil }
    var isPreparing: Bool { isStarting }
    var isFinalizing: Bool { isFinishing || completingGeneration != nil }
    /// Published after terminal result admission, when another capture may start.
    var onSessionEnded: (() -> Void)?
    /// Legacy callback only receives a recognizer-confirmed final result.
    var onFinal: ((String) -> Void)?
    /// When installed, receives all completion reasons instead of legacy callbacks.
    var onCompletion: ((SpeechCompletion) -> Void)?
    var onFinalization: ((Double) -> Void)?
    var onPartial: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    var onRecovery: ((String) -> Void)?
    var onRecordingSound: ((RecordingSound) -> Void)?

    @ObservationIgnored private let audioOwner: SpeechAudioOwner
    @ObservationIgnored private let permissionOwner: SpeechAuthorization
    @ObservationIgnored private let authorizationOverride: (@MainActor () async -> Bool)?
    @ObservationIgnored private var accumulator = TranscriptAccumulator()
    @ObservationIgnored private var lease: SpeechAudioLease?
    @ObservationIgnored private var stoppedAt: UInt64?
    @ObservationIgnored private var finalWait: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activeGeneration: UInt64?
    private var isStarting = false
    private var isFinishing = false
    private var completingGeneration: UInt64?
    @ObservationIgnored private var startupEvents = SpeechStartupEventBuffer()

    init(audioOwner: SpeechAudioOwner = SpeechAudioOwner(), authorization: (@MainActor () async -> Bool)? = nil, permissionOwner: SpeechAuthorization? = nil) {
        self.audioOwner = audioOwner
        self.permissionOwner = permissionOwner ?? .shared
        authorizationOverride = authorization
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        finalWait?.cancel()
        completionTask?.cancel()
        if let lease { audioOwner.cancel(lease) }
    }

    func requestAuthorization() async -> Bool { await requestAuthorization(requiresSpeechRecognition: true) }

    func requestAuthorization(requiresSpeechRecognition: Bool) async -> Bool {
        if let authorizationOverride { return await authorizationOverride() }
        let token = generation
        let allowed = await permissionOwner.request(requiresSpeechRecognition: requiresSpeechRecognition) { [weak self] in self?.generation == token }
        return allowed && token == generation && !Task.isCancelled
    }

    func start(locale: String, contextualStrings: [String]) async throws {
        cancel()
        let token = generation
        let lease = SpeechAudioLease()
        self.lease = lease
        transcript = ""
        isStarting = true
        engineDescription = "Preparing on-device speech"
        supportsPause = false
        engineWarning = nil
        stateDescription = "Checking speech permissions…"
        let requiresSpeechRecognition = !LocalSpeechModel.supports(locale: locale)
        do {
            guard await requestAuthorization(requiresSpeechRecognition: requiresSpeechRecognition) else {
                guard token == generation, !Task.isCancelled else { throw CancellationError() }
                throw SpeechCaptureFailure.message(permissionOwner.guidance(requiresSpeechRecognition: requiresSpeechRecognition))
            }
            guard token == generation, !Task.isCancelled, lease.mayStart else { throw CancellationError() }
            activeGeneration = token
            let configuration = SpeechAudioConfiguration(
                locale: locale, vocabulary: Array(contextualStrings.prefix(100)), reportLevels: onAudioLevel != nil,
                onRecognition: { [weak self] event in
                    Task { @MainActor [weak self] in self?.receive(event, token: token) }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeGeneration == token,
                              self.generation == token, self.isRecording else { return }
                        self.onAudioLevel?(level)
                    }
                }
            )
            let owner = audioOwner
            let engineStatus = try await withTaskCancellationHandler {
                try await owner.start(configuration, lease: lease)
            } onCancel: { owner.cancel(lease) }
            guard token == generation, activeGeneration == token, !Task.isCancelled else { throw CancellationError() }
            try lease.requireActiveInput()
            isStarting = false
            isRecording = true
            engineDescription = engineStatus.description
            engineWarning = engineStatus.warning
            supportsPause = engineStatus.supportsPause
            finalizationWaitMilliseconds = engineStatus.finalizationWaitMilliseconds
            requiresCompleteFinalization = engineStatus.requiresCompleteFinalization
            stateDescription = engineStatus.warning ?? "Listening on device · \(engineStatus.description)"
            if let event = startupEvents.take() {
                publish(event, token: token)
            }
            if generation == token, activeGeneration == token, isRecording { onRecordingSound?(.ready) }
        } catch {
            audioOwner.cancel(lease)
            guard token == generation else { throw CancellationError() }
            activeGeneration = nil
            self.lease = nil
            generation &+= 1
            isStarting = false
            isRecording = false
            startupEvents = SpeechStartupEventBuffer()
            stateDescription = error is CancellationError ? "Ready" : error.localizedDescription
            onRecordingSound?(.cancelled)
            throw error
        }
    }

    /// Closes audio acceptance synchronously. Native microphone/tap teardown runs
    /// on the serial owner; final callbacks wait until that teardown has completed.
    func stop() {
        if isStarting { cancel(); return }
        guard let token = activeGeneration, let lease, !isFinishing else { return }
        isFinishing = true
        isRecording = false
        stoppedAt = DispatchTime.now().uptimeNanoseconds
        audioOwner.finishInput(lease)
        stateDescription = "Finishing…"
        onRecordingSound?(.finished)
        // Modern analysis drains its complete accepted input and final result sequence.
        // A bounded timeout always remains an explicitly incomplete result.
        let waitMilliseconds = finalizationWaitMilliseconds
        let requireCompleteFinalization = requiresCompleteFinalization
        finalWait = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(waitMilliseconds)) } catch { return }
            guard let self, self.activeGeneration == token else { return }
            self.complete(reason: requireCompleteFinalization ? .unreconciledFinal : .timedOut, token: token)
        }
    }

    /// Pause/resume inside one capture. Audio is dropped at the tap while paused; the
    /// accumulated transcript, lease and recovery identity are untouched, so finish
    /// and cancel behave exactly as in an unpaused session. Returns whether it applied.
    @discardableResult
    func setPaused(_ paused: Bool) -> Bool {
        guard supportsPause || !paused, isRecording, !isFinishing, let lease else { return false }
        lease.setPaused(paused)
        stateDescription = paused ? "Paused" : "Listening on device · \(engineDescription)"
        return true
    }

    func cancel() {
        let cancelledCapture = hasActiveSession
        supportsPause = false
        generation &+= 1
        activeGeneration = nil
        finalWait?.cancel(); finalWait = nil
        completionTask?.cancel(); completionTask = nil
        completingGeneration = nil
        if let lease { audioOwner.cancel(lease) }
        lease = nil
        stoppedAt = nil
        startupEvents = SpeechStartupEventBuffer()
        accumulator = TranscriptAccumulator()
        isStarting = false
        isFinishing = false
        isRecording = false
        stateDescription = "Ready"
        if cancelledCapture { onRecordingSound?(.cancelled) }
    }

    private func receive(_ event: SpeechRecognitionEvent, token: UInt64) {
        guard activeGeneration == token, generation == token else { return }
        // A frozen startup final owns its transcript as well as its terminal
        // status. Rejected callbacks must not mutate the full-session ledger.
        if isStarting, !startupEvents.append(event) { return }
        if let text = event.text {
            transcript = event.fullSnapshot ? text : accumulator.update(text, segments: event.segments, recognitionEpoch: event.recognitionEpoch)
        }
        if isStarting { return }
        publish(event, token: token)
    }

    private func publish(_ event: SpeechRecognitionEvent, token: UInt64) {
        guard activeGeneration == token, generation == token else { return }
        if event.text != nil {
            onPartial?(transcript)
            guard activeGeneration == token, generation == token else { return }
        }
        if (event.failed || event.isFinal) && (event.incomplete || lease?.hasIncompleteAudio == true) { complete(reason: .unreconciledFinal, token: token) }
        else if event.isFinal { complete(reason: accumulator.hasUnalignedHypothesis ? .unreconciledFinal : .final, token: token) }
        else if event.failed { complete(reason: event.incomplete ? .unreconciledFinal : .recognitionError, token: token) }
    }

    private func complete(reason: SpeechCompletion.Reason, token: UInt64) {
        guard activeGeneration == token, generation == token, let lease else { return }
        let endedWhileRecording = isRecording
        let completion = SpeechCompletion(text: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                                          reason: reason, wasExplicitlyStopped: isFinishing)
        let stoppedAt = stoppedAt
        let completionCallback = onCompletion
        let finalCallback = onFinal
        let recoveryCallback = onRecovery
        let errorCallback = onError
        let timingCallback = onFinalization
        activeGeneration = nil
        generation &+= 1
        let completionToken = generation
        completingGeneration = completionToken
        finalWait?.cancel(); finalWait = nil
        isStarting = false
        isFinishing = false
        isRecording = false
        self.stoppedAt = nil
        self.lease = nil
        let owner = audioOwner
        // Queue teardown now, before a new capture can enqueue startup on the
        // shared queue. The task below waits for that already requested cleanup.
        owner.cancel(lease)
        if endedWhileRecording { onRecordingSound?(reason == .final ? .finished : .cancelled) }
        completionTask = Task { @MainActor [weak self] in
            await owner.cancelAndWait(lease)
            guard let self else { return }
            defer {
                if self.completingGeneration == completionToken {
                    self.completingGeneration = nil
                    self.completionTask = nil
                    self.onSessionEnded?()
                }
            }
            guard self.generation == completionToken, !Task.isCancelled else { return }
            self.stateDescription = reason == .final ? (completion.text.isEmpty ? "No speech detected" : "Ready") : completion.recoveryMessage
            if let stoppedAt {
                timingCallback?(Double(DispatchTime.now().uptimeNanoseconds - stoppedAt) / 1_000_000)
            }
            guard self.generation == completionToken else { return }
            if let completionCallback { completionCallback(completion) }
            else if reason == .final { finalCallback?(completion.text) }
            else if !completion.text.isEmpty {
                recoveryCallback?(completion.text)
                guard self.generation == completionToken else { return }
                errorCallback?(completion.recoveryMessage)
            }
        }
    }
}

enum SpeechCaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

struct SpeechRecognitionEvent: Equatable, Sendable {
    let text: String?
    let isFinal: Bool
    let failed: Bool
    let segments: [TranscriptSegment]
    let recognitionEpoch: UInt64
    let fullSnapshot: Bool
    let incomplete: Bool

    init(text: String?, isFinal: Bool, failed: Bool, segments: [TranscriptSegment] = [], recognitionEpoch: UInt64 = 0, fullSnapshot: Bool = false, incomplete: Bool = false) {
        self.text = text
        self.isFinal = isFinal
        self.failed = failed
        self.segments = segments
        self.recognitionEpoch = recognitionEpoch
        self.fullSnapshot = fullSnapshot
        self.incomplete = incomplete
    }
}

extension SpeechRecognitionEvent {
    /// A classic recognizer can finish by itself after a pause or service limit.
    /// That is an incomplete capture, never an implicit user command or paste.
    static func legacy(text: String?, isFinal: Bool, failed: Bool, segments: [TranscriptSegment], lease: SpeechAudioLease) -> SpeechRecognitionEvent {
        let endedEarly = isFinal && lease.mayStart
        if endedEarly { lease.markIncomplete() }
        return .init(text: text, isFinal: isFinal && !endedEarly, failed: failed || endedEarly,
                     segments: segments, incomplete: endedEarly)
    }
}

/// Coalesces callbacks arriving before native startup returns. A textless terminal
/// event retains the latest hypothesis, and later partials cannot erase termination.
struct SpeechStartupEventBuffer {
    private var pending: SpeechRecognitionEvent?

    @discardableResult
    mutating func append(_ event: SpeechRecognitionEvent) -> Bool {
        // A confirmed final owns both its text and terminal status permanently.
        guard pending?.isFinal != true else { return false }
        pending = SpeechRecognitionEvent(text: event.text ?? pending?.text,
                                         isFinal: event.isFinal,
                                         failed: event.failed || pending?.failed == true,
                                         segments: event.text == nil ? pending?.segments ?? [] : event.segments,
                                         recognitionEpoch: event.text == nil ? pending?.recognitionEpoch ?? event.recognitionEpoch : event.recognitionEpoch,
                                         fullSnapshot: event.text == nil ? pending?.fullSnapshot ?? event.fullSnapshot : event.fullSnapshot,
                                         incomplete: event.incomplete || pending?.incomplete == true)
        return true
    }

    mutating func take() -> SpeechRecognitionEvent? {
        defer { pending = nil }
        return pending
    }
}

struct SpeechAudioConfiguration {
    let locale: String
    let vocabulary: [String]
    let reportLevels: Bool
    let onRecognition: (SpeechRecognitionEvent) -> Void
    let onLevel: (Float) -> Void
}

/// Lock protects only small flags, never a native audio operation. An in-flight
/// callback may finish its buffer, but every subsequent buffer sees the closed gate.
final class SpeechAudioLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var acceptsAudio = true
    private var incompleteAudio = false
    var mayStart: Bool { lock.lock(); defer { lock.unlock() }; return valid && acceptsAudio }
    private var paused = false
    /// Pause keeps the session and its transcript but drops every buffer at the tap,
    /// so no audio reaches the recogniser. Taps use this instead of mayStart.
    var acceptsTapAudio: Bool { lock.lock(); defer { lock.unlock() }; return valid && acceptsAudio && !paused }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    func setPaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    var hasIncompleteAudio: Bool { lock.lock(); defer { lock.unlock() }; return incompleteAudio }
    func markIncomplete() { lock.lock(); incompleteAudio = true; acceptsAudio = false; lock.unlock() }
    func closeInput() { lock.lock(); acceptsAudio = false; lock.unlock() }
    func invalidate() { lock.lock(); valid = false; acceptsAudio = false; lock.unlock() }
    /// Failure closes input too, but must not be mistaken for a user cancel.
    func requireActiveInput() throws {
        let state = lock.withLock { (valid, acceptsAudio, incompleteAudio) }
        guard state.0 else { throw CancellationError() }
        guard !state.2 else {
            throw SpeechCaptureFailure.message("The microphone or speech engine stopped during startup. Check the system microphone and try again.")
        }
        guard state.1 else { throw CancellationError() }
    }
}

struct SpeechEngineStatus: Equatable, Sendable {
    let description: String
    let warning: String?
    let finalizationWaitMilliseconds: Int
    let requiresCompleteFinalization: Bool
    /// Whether pausing (dropping audio at the tap for a while) is proven safe for this
    /// engine. Off unless an engine is known to carry on unharmed: the classic
    /// recogniser can end by itself after silence or a time limit, which a pause would trigger.
    let supportsPause: Bool
    init(description: String, warning: String?, finalizationWaitMilliseconds: Int, requiresCompleteFinalization: Bool = false,
         supportsPause: Bool = false) {
        self.description = description; self.warning = warning
        self.finalizationWaitMilliseconds = finalizationWaitMilliseconds
        self.requiresCompleteFinalization = requiresCompleteFinalization
        self.supportsPause = supportsPause
    }
    static let legacy = SpeechEngineStatus(description: "Classic on-device dictation", warning: nil, finalizationWaitMilliseconds: 1200)
}

protocol SpeechAudioSession: AnyObject, Sendable {
    var engineStatus: SpeechEngineStatus { get }
    func prepare(lease: SpeechAudioLease) async throws
    func start(lease: SpeechAudioLease) throws
    func waitForInputReady(lease: SpeechAudioLease) async throws
    func stopAudio()
    func finishRecognition()
    func cancel()
}

extension SpeechAudioSession {
    var engineStatus: SpeechEngineStatus { .legacy }
    func prepare(lease: SpeechAudioLease) async throws {}
    func waitForInputReady(lease: SpeechAudioLease) async throws {}
}

/// All SpeechCapture instances share one serial queue, so switching between
/// manual and triggered capture cannot overlap their native engine lifecycle work.
final class SpeechAudioOwner: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "uiui.speech.audio", qos: .userInitiated)
    private let makeSession: (SpeechAudioConfiguration) throws -> any SpeechAudioSession
    private var current: (lease: SpeechAudioLease, session: any SpeechAudioSession)?

    init(makeSession: @escaping (SpeechAudioConfiguration) throws -> any SpeechAudioSession = NativeSpeechAudioSession.init) {
        self.makeSession = makeSession
    }

    @discardableResult
    func start(_ configuration: SpeechAudioConfiguration, lease: SpeechAudioLease) async throws -> SpeechEngineStatus {
        let session: any SpeechAudioSession = try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    guard lease.mayStart else { throw CancellationError() }
                    if let current = self.current { current.lease.invalidate(); current.session.cancel(); self.current = nil }
                    let session = try self.makeSession(configuration)
                    self.current = (lease, session)
                    continuation.resume(returning: session)
                } catch { continuation.resume(throwing: error) }
            }
        }
        do {
            // Async model preparation never occupies the serial native-audio queue.
            try await session.prepare(lease: lease)
            let status: SpeechEngineStatus = try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    do {
                        guard lease.mayStart, self.current?.lease === lease else { throw CancellationError() }
                        try session.start(lease: lease)
                        try lease.requireActiveInput()
                        continuation.resume(returning: session.engineStatus)
                    } catch { self.release(lease); continuation.resume(throwing: error) }
                }
            }
            // A successful engine.start() does not prove the hardware is feeding
            // PCM. Keep startup cancellable and the native owner queue available.
            try await session.waitForInputReady(lease: lease)
            guard !Task.isCancelled else { throw CancellationError() }
            try lease.requireActiveInput()
            return status
        } catch {
            await cancelAndWait(lease)
            throw error
        }
    }

    func finishInput(_ lease: SpeechAudioLease) {
        lease.closeInput()
        Self.queue.async {
            guard let current = self.current, current.lease === lease else { return }
            current.session.stopAudio()
            current.session.finishRecognition()
        }
    }

    func cancel(_ lease: SpeechAudioLease) {
        lease.invalidate()
        Self.queue.async { self.release(lease) }
    }

    func cancelAndWait(_ lease: SpeechAudioLease) async {
        lease.invalidate()
        await withCheckedContinuation { continuation in
            Self.queue.async { self.release(lease); continuation.resume() }
        }
    }

    private func release(_ lease: SpeechAudioLease) {
        guard let current, current.lease === lease else { return }
        current.session.cancel()
        self.current = nil
    }
}

/// Constructed, started and released only on SpeechAudioOwner's serial queue.
final class LegacySpeechAudioSession: SpeechAudioSession, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    private var hasTap = false
    private let configuration: SpeechAudioConfiguration

    init(configuration: SpeechAudioConfiguration) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: configuration.locale)) else {
            throw SpeechCaptureFailure.message("Speech recognition is unavailable for \(configuration.locale). Choose another speech language in Settings.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechCaptureFailure.message("On-device speech recognition is unavailable for \(configuration.locale). Enable or download this language in macOS Dictation settings, or choose a supported language in uiui. Audio was not sent to a server.")
        }
        guard recognizer.isAvailable else {
            throw SpeechCaptureFailure.message("On-device speech recognition is currently unavailable. Check the selected language in macOS Dictation settings and try again.")
        }
        self.recognizer = recognizer
        self.configuration = configuration
        request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = configuration.vocabulary
    }

    func start(lease: SpeechAudioLease) throws {
        guard lease.mayStart else { throw CancellationError() }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechCaptureFailure.message("No microphone input is available. Select an input device in System Settings → Sound.")
        }
        guard lease.mayStart else { throw CancellationError() }
        let request = request
        let configuration = configuration
        let meter = CaptureLevelMeter()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard lease.acceptsTapAudio else { return }
            request.append(buffer)
            if configuration.reportLevels, let level = meter.measureIfDue(buffer) { configuration.onLevel(level) }
        }
        hasTap = true
        task = recognizer.recognitionTask(with: request) { result, error in
            guard lease.isValid else { return }
            let transcription = result?.bestTranscription
            let segments = transcription?.segments.map {
                TranscriptSegment(timestamp: $0.timestamp, duration: $0.duration, range: $0.substringRange)
            } ?? []
            configuration.onRecognition(.legacy(text: transcription?.formattedString,
                                                  isFinal: result?.isFinal ?? false, failed: error != nil,
                                                  segments: segments, lease: lease))
        }
        guard lease.mayStart else { throw CancellationError() }
        engine.prepare()
        guard lease.mayStart else { throw CancellationError() }
        try engine.start()
        // Native start cannot be interrupted while in the driver. A cancellation
        // closes the input gate immediately and this check tears down on return.
        guard lease.mayStart else { throw CancellationError() }
    }

    func stopAudio() {
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        engine?.reset()
        engine = nil
    }

    func finishRecognition() { request.endAudio(); task?.finish() }

    func cancel() {
        stopAudio()
        request.endAudio()
        task?.cancel()
        task = nil
    }
}

/// One instance per tap. Only that tap's serial audio callback accesses its state.
/// Samples are read in place, with at most 256 values inspected per measurement.
final class CaptureLevelMeter {
    private var lastMeasurement: UInt64 = 0

    func measureIfDue(_ buffer: AVAudioPCMBuffer) -> Float? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastMeasurement >= 100_000_000 else { return nil }
        lastMeasurement = now
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channel = buffer.floatChannelData?[0] else { return nil }
        let count = min(256, frameCount)
        let step = max(1, frameCount / count)
        var squares: Double = 0
        for index in 0..<count {
            let sample = Double(channel[index * step])
            squares += sample * sample
        }
        let rms = Float(sqrt(squares / Double(count)))
        return rms.isFinite ? rms : nil
    }
}
