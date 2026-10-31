import Dispatch
import Foundation
import PhononCoreML

/// Dispatch closures do not inherit Swift task cancellation. Each queued native
/// job carries an explicit token so cancelled jobs skip inference and an active
/// job checks cancellation between predictions. A running Core ML kernel itself
/// is not preempted; its late output is rejected by the token and model lease.
final class PhononOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

/// The vendor's window workers may check cancellation on their own queues.
/// Only this tiny token reference crosses those queues; native model/phrase
/// state remains confined to the serial executor.
private final class PhononCancellationContext: @unchecked Sendable {
    private let lock = NSLock()
    private var active: PhononOperationCancellation?
    func set(_ token: PhononOperationCancellation?) { lock.withLock { active = token } }
    func check() throws { try lock.withLock { active }?.check() }
}

/// One event-driven native checkout at a time, including cancelled captures
/// whose uninterruptible kernel is still returning. Waiting never polls, loads
/// a second model, or blocks a thread. Cancelled waiters cannot hold the gate.
actor PhononExclusiveCheckoutGate {
    private var owner: UUID?
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var waitingCount: Int { waiters.count }

    func acquire() async throws -> UUID {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if owner == nil {
                    owner = id
                    continuation.resume()
                } else {
                    order.append(id)
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Cancellation can race a release promoting this waiter. If ownership
        // was already transferred, return it before reporting cancellation.
        do { try Task.checkCancellation() }
        catch { release(id); throw error }
        return id
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        while !order.isEmpty {
            let next = order.removeFirst()
            guard let continuation = waiters.removeValue(forKey: next) else { continue }
            owner = next
            continuation.resume()
            break
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}

final class PhononSerialExecutor: Sendable {
    private let queue = DispatchQueue(label: "uiui.phonon.native", qos: .userInitiated)

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (PhononOperationCancellation) throws -> Value
    ) async throws -> Value {
        let cancellation = PhononOperationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let value = try operation(cancellation)
                        try cancellation.check()
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

/// Native closures retain the transcriber and classifier together. Only the
/// serial model executor may call or release them; tests inject local stubs at
/// this boundary without opening a microphone or loading Core ML.
struct PhononNativeOperations {
    let configureVocabulary: ([String]) throws -> Void
    let reset: () -> Void
    let speechProbability: PhononPhraseSession.SpeechProbability
    let transcribe: PhononPhraseSession.Transcribe
}

/// The vendor transcriber is not Sendable. Every read, mutation, prediction and
/// release of it and its phrase state occurs on one private serial executor.
@available(macOS 15.0, *)
final class PhononNativeModel: @unchecked Sendable {
    private let executor = PhononSerialExecutor()
    private var operations: PhononNativeOperations?
    private var session: PhononPhraseSession?
    private let cancellationContext = PhononCancellationContext()

    private init() {}

    init(operations: PhononNativeOperations) { self.operations = operations }

    static func load() async throws -> PhononNativeModel {
        let model = PhononNativeModel()
        do {
            try await model.executor.perform { cancellation in
                guard PhononSpeechModel.isInstalled else {
                    throw SpeechCaptureFailure.message("Prepare the Phonon speech model in Settings before recording.")
                }
                try PhononSpeechModel.verify(at: PhononSpeechModel.directory, checkCancellation: { try cancellation.check() })
                try cancellation.check()
                var options = PhononSpeechModel.makeOptions()
                options.checkCancellation = { [weak model] in try model?.cancellationContext.check() }
                let transcriber = try Transcriber(bundle: PhononSpeechModel.directory, options: options)
                try cancellation.check()
                guard transcriber.loadedFunctions == [15] else {
                    throw SpeechCaptureFailure.message("The prepared speech model has an unexpected function profile.")
                }
                let activity = try PhononSpeechActivity(modelURL: PhononSpeechModel.speechActivityURL)
                model.operations = PhononNativeOperations(
                    configureVocabulary: { try transcriber.configureVocabulary($0) },
                    reset: { transcriber.resetTiming(); activity.reset() },
                    speechProbability: { try activity.probability($0) },
                    transcribe: { try transcriber.transcribe($0).text })
            }
            return model
        } catch {
            await model.dispose()
            throw error
        }
    }

    func beginSession(conditioning: PhononPCMConditioning, vocabulary: [String] = []) async throws {
        try await executor.perform { [self] cancellation in
            guard let operations else { throw CancellationError() }
            cancellationContext.set(cancellation)
            defer { cancellationContext.set(nil) }
            // Always configure, including an empty capture. A pooled instance
            // must never carry the previous capture's project vocabulary.
            try operations.configureVocabulary(vocabulary)
            try cancellation.check()
            operations.reset()
            session = PhononPhraseSession(conditioning: conditioning,
                speechProbability: operations.speechProbability,
                checkCancellation: { [weak self] in try self?.cancellationContext.check() },
                transcribe: operations.transcribe)
            try cancellation.check()
        }
    }

    func append(_ samples: [Float]) async throws -> String {
        try await executor.perform { [self] cancellation in
            guard let session else { throw CancellationError() }
            cancellationContext.set(cancellation)
            defer { cancellationContext.set(nil) }
            return try session.append(samples)
        }
    }

    func finish() async throws -> String {
        try await executor.perform { [self] cancellation in
            guard let session else { throw CancellationError() }
            cancellationContext.set(cancellation)
            defer { cancellationContext.set(nil) }
            return try session.finish()
        }
    }

    func reset() async throws {
        try await executor.perform { [self] _ in
            session = nil; cancellationContext.set(nil)
            try operations?.configureVocabulary([])
            operations?.reset()
        }
    }

    func dispose() async {
        // Disposal must run even if its caller was cancelled. Pool epochs keep
        // it out of the idle slot; the executor keeps it behind active work.
        await Task.detached { [self] in
            try? await executor.perform { [self] _ in
                session = nil; cancellationContext.set(nil); operations = nil
            }
        }.value
    }
}

/// Exactly one idle retained model. Warming loads prepared local artifacts;
/// there is no warm-up audio, polling, download, or microphone ownership here.
@available(macOS 15.0, *)
actor PhononModelPool {
    static let shared = PhononModelPool()
    private let pool: ReadySpeechModelPool<PhononNativeModel>
    private let gate = PhononExclusiveCheckoutGate()
    private var checkoutTickets: [ObjectIdentifier: UUID] = [:]
    private let memoryPressure: any DispatchSourceMemoryPressure

    private init() {
        pool = ReadySpeechModelPool(factory: { try await PhononNativeModel.load() },
                                   reset: { try await $0.reset() }, dispose: { await $0.dispose() })
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        memoryPressure = pressure
        pressure.setEventHandler { [weak self] in Task { await self?.clear() } }
        pressure.resume()
    }

    func warmIfInstalled() async {
        guard !Task.isCancelled, PhononSpeechModel.isInstalled else { return }
        try? await pool.warm()
    }
    func clear() async { await pool.clear() }
    func checkOut() async throws -> PhononNativeModel {
        let ticket = try await gate.acquire()
        do {
            let model = try await pool.checkOut()
            checkoutTickets[ObjectIdentifier(model)] = ticket
            return model
        } catch {
            await gate.release(ticket)
            throw error
        }
    }
    func checkIn(_ model: PhononNativeModel) async {
        guard let ticket = checkoutTickets.removeValue(forKey: ObjectIdentifier(model)) else { return }
        await pool.checkIn(model)
        await gate.release(ticket)
    }
}
