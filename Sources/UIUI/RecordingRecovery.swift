import Foundation
import Observation
import UIUICore

/// Owns transcript journaling only. Repository actor methods own every disk operation.
@MainActor @Observable
final class RecordingRecovery {
    private(set) var drafts: [RecordingRecoveryDraft] = []
    private(set) var issue: String?
    var enabled = true {
        didSet { if oldValue && !enabled { discardAll() } }
    }

    /// Also permits deterministic failure and scheduling tests without native services.
    struct Storage: Sendable {
        var load: @Sendable () async throws -> [RecordingRecoveryDraft]
        var checkpoint: @Sendable (RecordingRecoveryDraft) async throws -> Void
        var finish: @Sendable (UUID, RecordingRecoveryDraft?) async throws -> Void
        var discard: @Sendable (UUID) async throws -> Void
        var discardAll: @Sendable () async throws -> Void

        init(repository: LibraryRepository) {
            load = { try await repository.loadRecordingDrafts() }
            checkpoint = { try await repository.checkpointRecordingDraft($0) }
            finish = { try await repository.finishRecordingDraft(id: $0, preserving: $1) }
            discard = { try await repository.discardRecordingDraft(id: $0) }
            discardAll = { try await repository.discardAllRecordingDrafts() }
        }

        init(load: @escaping @Sendable () async throws -> [RecordingRecoveryDraft],
             checkpoint: @escaping @Sendable (RecordingRecoveryDraft) async throws -> Void,
             finish: @escaping @Sendable (UUID, RecordingRecoveryDraft?) async throws -> Void,
             discard: @escaping @Sendable (UUID) async throws -> Void,
             discardAll: @escaping @Sendable () async throws -> Void) {
            self.load = load; self.checkpoint = checkpoint; self.finish = finish
            self.discard = discard; self.discardAll = discardAll
        }
    }

    private struct Context {
        var snapshot: RecordingRecoveryDraft
        var dirty = false
        var hasQueuedCheckpoint = false
        var debounce: Task<Void, Never>?
    }
    private enum Operation {
        case checkpoint(RecordingRecoveryDraft)
        case finish(UUID, RecordingRecoveryDraft?)
        case discard(UUID)
        case discardAll

        var recordingID: UUID? {
            switch self {
            case .checkpoint(let draft): return draft.id
            case .finish(let id, _), .discard(let id): return id
            case .discardAll: return nil
            }
        }
    }
    private struct Pending {
        let token = UUID()
        let operation: Operation
    }

    @ObservationIgnored private var contexts: [UUID: Context] = [:]
    @ObservationIgnored private var touchedIDs: Set<UUID> = []
    @ObservationIgnored private var pending: [Pending] = []
    @ObservationIgnored private var storage: Storage?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var clearVersion: UInt64 = 0
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var writeFailure: String?
    @ObservationIgnored private let delay: @Sendable () async throws -> Void

    init(delay: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .milliseconds(500))
    }) { self.delay = delay }

    func connect(_ repository: LibraryRepository) async {
        await connect(storage: Storage(repository: repository))
    }

    func connect(storage: Storage) async {
        generation &+= 1
        let token = generation
        let clearToken = clearVersion
        self.storage = storage
        loading = true
        loadFailed = false
        // A new connection may follow a failed one. Replay the best active snapshot.
        for context in contexts.values where Self.hasText(context.snapshot.text) {
            enqueue(.checkpoint(context.snapshot))
        }
        do {
            let loaded = try await storage.load()
            guard token == generation else { return }
            if enabled && clearToken == clearVersion && !pending.contains(where: {
                if case .discardAll = $0.operation { return true }; return false
            }) {
                let retained = drafts.filter { touchedIDs.contains($0.id) }
                drafts = retained + loaded.filter { !touchedIDs.contains($0.id) }
                trimDrafts()
            }
        } catch {
            guard token == generation else { return }
            loadFailed = true
        }
        loading = false
        refreshIssue()
        startWriter()
        let waiters = connectionWaiters
        connectionWaiters = []
        waiters.forEach { $0.resume() }
    }

    func begin(id: UUID, project: String, kind: CaptureKind, startedAt: Date = Date()) {
        guard enabled, contexts[id] == nil, !touchedIDs.contains(id) else { return }
        touchedIDs.insert(id)
        drafts.removeAll { $0.id == id }
        contexts[id] = Context(snapshot: RecordingRecoveryDraft(id: id, text: "", project: project,
            kind: kind, startedAt: startedAt, updatedAt: startedAt, revision: 0))
    }

    func update(id: UUID, text: String) {
        guard enabled, Self.hasText(text), var context = contexts[id],
              context.snapshot.text != text else { return }
        context.snapshot.text = text
        context.snapshot.updatedAt = Date()
        context.snapshot.revision += 1
        context.dirty = true
        if !context.hasQueuedCheckpoint {
            context.hasQueuedCheckpoint = true
            context.dirty = false
            contexts[id] = context
            enqueue(.checkpoint(context.snapshot))
        } else {
            if context.debounce == nil {
                let delay = delay
                context.debounce = Task { [weak self] in
                    do { try await delay() } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.checkpointPending(id: id)
                }
            }
            contexts[id] = context
        }
    }

    func finish(id: UUID, preserving: Bool) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        context.debounce?.cancel()
        // Closing carries the best snapshot itself; obsolete checkpoints must not
        // block a close after a transient checkpoint failure.
        pending.removeAll {
            if case .checkpoint(let draft) = $0.operation { return draft.id == id }
            return false
        }
        let snapshot = preserving && Self.hasText(context.snapshot.text) ? context.snapshot : nil
        drafts.removeAll { $0.id == id }
        if let snapshot { drafts.append(snapshot) }
        enqueue(.finish(id, snapshot))
        trimDrafts()
    }

    func discard(id: UUID) {
        touchedIDs.insert(id)
        contexts.removeValue(forKey: id)?.debounce?.cancel()
        drafts.removeAll { $0.id == id }
        pending.removeAll { $0.operation.recordingID == id }
        enqueue(.discard(id))
    }

    func discardAll() {
        clearVersion &+= 1
        for context in contexts.values { context.debounce?.cancel() }
        contexts.removeAll()
        drafts = []
        pending.removeAll()
        enqueue(.discardAll)
    }

    /// Forces dirty snapshots into the write chain, without closing crash journals.
    func flush() async {
        for id in Array(contexts.keys) { checkpointPending(id: id) }
        while loading {
            await withCheckedContinuation { connectionWaiters.append($0) }
        }
        startWriter()
        while let writer { await writer.value }
        refreshIssue()
    }

    private func checkpointPending(id: UUID) {
        guard var context = contexts[id] else { return }
        context.debounce?.cancel()
        context.debounce = nil
        let dirty = context.dirty
        context.dirty = false
        contexts[id] = context
        if dirty { enqueue(.checkpoint(context.snapshot)) }
    }

    private func enqueue(_ operation: Operation) {
        // The writer may hold one older in-flight snapshot. Only the latest
        // additional snapshot for this ID belongs in the retry queue.
        if case .checkpoint(let draft) = operation {
            pending.removeAll {
                if case .checkpoint(let queued) = $0.operation { return queued.id == draft.id }
                return false
            }
        }
        pending.append(Pending(operation: operation))
        refreshIssue()
        startWriter()
    }

    private func startWriter() {
        guard writer == nil, !loading, let storage, !pending.isEmpty else { return }
        let token = generation
        writer = Task { [weak self] in
            guard let self else { return }
            while token == self.generation, let next = self.pending.first {
                do {
                    switch next.operation {
                    case .checkpoint(let draft): try await storage.checkpoint(draft)
                    case .finish(let id, let draft): try await storage.finish(id, draft)
                    case .discard(let id): try await storage.discard(id)
                    case .discardAll: try await storage.discardAll()
                    }
                    guard token == self.generation else { break }
                    self.pending.removeAll { $0.token == next.token }
                    self.writeFailure = nil
                } catch {
                    guard token == self.generation else { break }
                    // A finish/discard may have superseded this in-flight write.
                    // Its authoritative close still needs a turn even if this write failed.
                    if !self.pending.contains(where: { $0.token == next.token }) { continue }
                    switch next.operation {
                    case .checkpoint, .finish(_, .some):
                        self.writeFailure = "Recovery could not be saved locally. Text is still held in this session."
                    case .finish(_, .none), .discard, .discardAll:
                        self.writeFailure = "Recovery could not be removed from local storage."
                    }
                    break
                }
            }
            self.writer = nil
            if token == self.generation {
                self.refreshIssue()
            } else {
                self.startWriter()
            }
        }
    }

    private func refreshIssue() {
        if loadFailed {
            issue = "Previous recovery drafts could not be loaded from local storage."
        } else if let writeFailure {
            issue = writeFailure
        } else if storage == nil && !pending.isEmpty {
            issue = "Recovery changes are held in this session until local storage is available."
        } else { issue = nil }
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func trimDrafts() {
        drafts.sort { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
        let evicted = drafts.dropFirst(20).map(\.id)
        // Discard also replaces an evicted queued finish payload with an ID-only
        // tombstone, so reconnection cannot recreate a card outside the bound.
        for id in evicted { discard(id: id) }
    }
}
