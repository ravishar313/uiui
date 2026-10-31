import Dispatch
import FluidAudio
import Foundation

/// One ready idle model, with distinct ownership for every checked-out lease.
/// Closures make the same ownership machinery testable without loading a model.
actor ReadySpeechModelPool<Model: AnyObject & Sendable> {
    private struct Load {
        let id: UUID
        let epoch: UInt64
        let task: Task<Model, Error>
    }
    private struct Return {
        let id: UUID
        let model: Model
        let epoch: UInt64
        let task: Task<Void, Error>
    }
    private let factory: @Sendable () async throws -> Model
    private let reset: @Sendable (Model) async throws -> Void
    private let dispose: @Sendable (Model) async -> Void
    private var idle: Model?
    private var loading: Load?
    private var returning: [ObjectIdentifier: Return] = [:]
    private var leased: [ObjectIdentifier: UInt64] = [:]
    private var epoch: UInt64 = 0

    init(factory: @escaping @Sendable () async throws -> Model,
         reset: @escaping @Sendable (Model) async throws -> Void,
         dispose: @escaping @Sendable (Model) async -> Void) {
        self.factory = factory; self.reset = reset; self.dispose = dispose
    }

    func warm() async throws {
        try Task.checkCancellation()
        // Warming is not a second capture. A leased model is already warm and
        // must not cause another model to load just to populate an idle slot.
        guard idle == nil, leased.isEmpty else { return }
        if let pending = returning.values.first { await settleReturn(pending); return }
        try await ensureLoaded()
    }

    func checkOut() async throws -> Model {
        while true {
            try Task.checkCancellation()
            if let model = idle {
                idle = nil
                leased[ObjectIdentifier(model)] = epoch
                return model
            }
            if let pending = returning.values.first { await settleReturn(pending) }
            else { try await ensureLoaded() }
        }
    }

    func checkIn(_ model: Model) async {
        let identity = ObjectIdentifier(model)
        // A duplicate return must never reset a model already checked out again.
        guard let checkedOutEpoch = leased.removeValue(forKey: identity) else { return }
        let reset = reset
        let pending = Return(id: UUID(), model: model, epoch: checkedOutEpoch,
                             task: Task { try await reset(model) })
        returning[identity] = pending
        await settleReturn(pending)
    }

    func clear() async {
        guard !Task.isCancelled else { return }
        epoch &+= 1
        // Fence both an in-flight warm and all models currently leased. Their
        // late completions/returns may dispose, but cannot refill the idle slot.
        loading?.task.cancel()
        let old = idle
        idle = nil
        if let old { await dispose(old) }
    }

    private func ensureLoaded() async throws {
        if idle != nil { return }
        let work: Load
        if let loading { work = loading }
        else {
            let factory = factory
            work = Load(id: UUID(), epoch: epoch, task: Task { try await factory() })
            loading = work
        }
        do {
            let model = try await work.task.value
            // All concurrent warmers await the same task. Only one completion
            // may install or dispose it, even if another waiter checked it out.
            guard loading?.id == work.id else { return }
            loading = nil
            if work.epoch == epoch, idle == nil { idle = model }
            else { await dispose(model) }
        } catch {
            if loading?.id == work.id { loading = nil }
            // A clear invalidates the old shared initialization, not a newer
            // caller awaiting that slot. Checkout retries in the current epoch.
            if work.epoch != epoch { return }
            throw error
        }
    }

    private func settleReturn(_ pending: Return) async {
        let outcome: Result<Void, Error>
        do { try await pending.task.value; outcome = .success(()) }
        catch { outcome = .failure(error) }
        let identity = ObjectIdentifier(pending.model)
        guard returning[identity]?.id == pending.id else { return }
        returning.removeValue(forKey: identity)
        if case .success = outcome, pending.epoch == epoch, idle == nil {
            idle = pending.model
        } else { await dispose(pending.model) }
    }
}

/// A model may return to the pool only after every operation that borrowed it
/// has finished. Actor reentrancy during prediction/load is explicitly counted.
actor ExclusiveSpeechModelLease<Model: AnyObject & Sendable> {
    private let checkOut: @Sendable () async throws -> Model
    private let checkIn: @Sendable (Model) async -> Void
    private var model: Model?
    private var generation: UInt64 = 0
    private var inFlight = 0
    private var loading = false
    private var closed = false
    private var returnRequested = false

    init(checkOut: @escaping @Sendable () async throws -> Model,
         checkIn: @escaping @Sendable (Model) async -> Void) {
        self.checkOut = checkOut; self.checkIn = checkIn
    }

    func load() async throws {
        guard !closed, !loading else { throw CancellationError() }
        if model != nil { return }
        loading = true; inFlight += 1
        let token = generation
        let outcome: Result<Model, Error>
        do { outcome = .success(try await checkOut()) }
        catch { outcome = .failure(error) }
        if case .success(let loaded) = outcome { model = loaded }
        let valid = token == generation && !closed && !Task.isCancelled
        if !valid { closed = true; returnRequested = true }
        loading = false; inFlight -= 1
        await returnIfReady()
        guard valid else { throw CancellationError() }
        _ = try outcome.get()
    }

    func withModel<Value: Sendable>(finishing: Bool = false,
                                    _ operation: @Sendable (Model) async throws -> Value) async throws -> Value {
        guard !closed, let model else { throw CancellationError() }
        inFlight += 1
        let token = generation
        let outcome: Result<Value, Error>
        do { outcome = .success(try await operation(model)) }
        catch { outcome = .failure(error) }
        let valid = token == generation && !closed && !Task.isCancelled
        if finishing, valid, case .success = outcome {
            closed = true; returnRequested = true
        }
        inFlight -= 1
        // A successful final returns a reset model before publishing completion,
        // so the next user-triggered capture can check it out immediately.
        await returnIfReady()
        guard valid, token == generation, !Task.isCancelled else { throw CancellationError() }
        return try outcome.get()
    }

    func close() async {
        generation &+= 1
        closed = true; returnRequested = true
        await returnIfReady()
    }

    private func returnIfReady() async {
        guard returnRequested, inFlight == 0, let model else { return }
        self.model = nil
        await checkIn(model)
    }
}

/// Local-only, event-driven model readiness. No timer, audio engine, network
/// activity, or inference runs while the model waits in the single idle slot.
actor ParakeetModelPool {
    static let shared = ParakeetModelPool()
    private let pool: ReadySpeechModelPool<StreamingUnifiedAsrManager>
    private let memoryPressure: any DispatchSourceMemoryPressure

    private init() {
        pool = ReadySpeechModelPool(factory: {
            ParakeetSpeechModel.configureLibraryLogging()
            guard ParakeetSpeechModel.isInstalled else {
                throw SpeechCaptureFailure.message("Download the speech model in Settings before recording.")
            }
            let manager = StreamingUnifiedAsrManager(config: ParakeetSpeechModel.config, encoderPrecision: .int8)
            do {
                try await manager.loadModels(from: ParakeetSpeechModel.directory)
                try Task.checkCancellation()
                return manager
            } catch { await manager.cleanup(); throw error }
        }, reset: { manager in try await manager.reset() }, dispose: { manager in await manager.cleanup() })
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        memoryPressure = pressure
        pressure.setEventHandler { [weak self] in Task { await self?.clear() } }
        pressure.resume()
    }

    func warmIfInstalled() async {
        guard !Task.isCancelled, ParakeetSpeechModel.isInstalled else { return }
        try? await pool.warm()
    }
    func clear() async { await pool.clear() }
    func checkOut() async throws -> StreamingUnifiedAsrManager { try await pool.checkOut() }
    func checkIn(_ manager: StreamingUnifiedAsrManager) async { await pool.checkIn(manager) }
}
