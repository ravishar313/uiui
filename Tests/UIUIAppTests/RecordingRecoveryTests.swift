import Foundation
import XCTest
import UIUICore
@testable import UIUI

final class RecordingRecoveryTests: XCTestCase {
    @MainActor
    private func eventually(_ condition: @escaping () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Expected recovery state did not arrive", file: file, line: line)
                throw RecoveryFixture.Failure.unavailable
            }
            await Task.yield()
        }
    }

    @MainActor
    func testFirstPartialWritesImmediatelyAndFlushKeepsExactLatestUnicode() async throws {
        let fixture = RecoveryFixture()
        let gate = RecoveryGate()
        let recovery = RecordingRecovery(delay: { await gate.wait() })
        await recovery.connect(storage: fixture.storage)
        let id = UUID()
        recovery.begin(id: id, project: "Research", kind: .dictation)
        recovery.update(id: id, text: "first partial")
        try await eventually { await fixture.checkpoints.count == 1 }
        let latest = "  " + String(repeating: "हिन्दी 👨‍👩‍👧‍👦 e\u{301}\n", count: 1_000) + "  "
        recovery.update(id: id, text: "second partial")
        recovery.update(id: id, text: latest)
        recovery.update(id: id, text: " \n ")
        await recovery.flush()
        let checkpoints = await fixture.checkpoints
        XCTAssertEqual(checkpoints.count, 2)
        XCTAssertEqual(checkpoints.last?.text, latest)
        XCTAssertGreaterThan(checkpoints.last!.revision, checkpoints.first!.revision)
        XCTAssertTrue(recovery.drafts.isEmpty, "An active capture is not a recovery card")
        await gate.release()
    }

    @MainActor
    func testOneShotDelayCoalescesLatestPartial() async throws {
        let fixture = RecoveryFixture()
        let gate = RecoveryGate()
        let recovery = RecordingRecovery(delay: { await gate.wait() })
        await recovery.connect(storage: fixture.storage)
        let id = UUID()
        recovery.begin(id: id, project: "Personal", kind: .note)
        recovery.update(id: id, text: "first")
        recovery.update(id: id, text: "second")
        recovery.update(id: id, text: "latest")
        try await eventually { await gate.arrivals == 1 }
        await gate.release()
        try await eventually { await fixture.checkpoints.count == 2 }
        let checkpoints = await fixture.checkpoints
        XCTAssertEqual(checkpoints.map(\.text), ["first", "latest"])
        await recovery.flush()
        let count = await fixture.checkpoints.count
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testCancelBeforeDelayRetainsLatestAndIgnoresLateUpdates() async throws {
        let fixture = RecoveryFixture()
        let gate = RecoveryGate()
        let recovery = RecordingRecovery(delay: { await gate.wait() })
        await recovery.connect(storage: fixture.storage)
        let id = UUID()
        recovery.begin(id: id, project: "Inbox", kind: .thought)
        recovery.update(id: id, text: "first")
        recovery.update(id: id, text: "cancelled latest")
        recovery.finish(id: id, preserving: true)
        XCTAssertEqual(recovery.drafts.first?.text, "cancelled latest")
        recovery.update(id: id, text: "late stale callback")
        recovery.finish(id: id, preserving: false)
        await gate.release()
        await recovery.flush()
        let saved = await fixture.rows[id]
        XCTAssertEqual(saved?.text, "cancelled latest")
        let closes = await fixture.finishes.count
        XCTAssertEqual(closes, 1)
    }

    @MainActor
    func testRapidNewCaptureDoesNotInheritEarlierContext() async throws {
        let fixture = RecoveryFixture()
        let recovery = RecordingRecovery()
        await recovery.connect(storage: fixture.storage)
        let first = UUID(), second = UUID()
        recovery.begin(id: first, project: "One", kind: .note)
        recovery.update(id: first, text: "one")
        recovery.finish(id: first, preserving: true)
        recovery.begin(id: second, project: "Two", kind: .dictation)
        recovery.update(id: second, text: "two")
        recovery.update(id: first, text: "stale")
        recovery.finish(id: second, preserving: true)
        await recovery.flush()
        let rows = await fixture.rows
        XCTAssertEqual(rows[first]?.text, "one")
        XCTAssertEqual(rows[first]?.project, "One")
        XCTAssertEqual(rows[second]?.text, "two")
        XCTAssertEqual(rows[second]?.kind, .dictation)
    }

    @MainActor
    func testSuccessfulFinishRemovesJournalWithoutShowingCard() async throws {
        let fixture = RecoveryFixture()
        let recovery = RecordingRecovery()
        await recovery.connect(storage: fixture.storage)
        let id = UUID()
        recovery.begin(id: id, project: "Personal", kind: .note)
        recovery.update(id: id, text: "saved capture")
        recovery.finish(id: id, preserving: false)
        await recovery.flush()
        let rows = await fixture.rows
        XCTAssertNil(rows[id])
        XCTAssertTrue(recovery.drafts.isEmpty)
        XCTAssertNil(recovery.issue)
    }

    @MainActor
    func testBeforeConnectionRetainsTextAndEventuallyPersists() async throws {
        let recovery = RecordingRecovery()
        let id = UUID()
        recovery.begin(id: id, project: "Offline", kind: .note)
        recovery.update(id: id, text: "available in memory")
        recovery.finish(id: id, preserving: true)
        await recovery.flush()
        XCTAssertNotNil(recovery.issue)
        XCTAssertEqual(recovery.drafts.first?.text, "available in memory")
        let fixture = RecoveryFixture()
        await recovery.connect(storage: fixture.storage)
        await recovery.flush()
        let saved = await fixture.rows[id]
        XCTAssertEqual(saved?.text, "available in memory")
        XCTAssertNil(recovery.issue)
    }

    @MainActor
    func testWriteFailureKeepsRecoveryAndRetryClearsWarningOnlyAfterSuccess() async throws {
        let fixture = RecoveryFixture()
        await fixture.setFailing(true)
        let recovery = RecordingRecovery()
        await recovery.connect(storage: fixture.storage)
        let id = UUID()
        recovery.begin(id: id, project: "Personal", kind: .note)
        recovery.update(id: id, text: "unsaved text")
        recovery.finish(id: id, preserving: true)
        await recovery.flush()
        XCTAssertEqual(recovery.drafts.first?.text, "unsaved text")
        XCTAssertNotNil(recovery.issue)
        let failedRows = await fixture.rows
        XCTAssertTrue(failedRows.isEmpty)
        await fixture.setFailing(false)
        await recovery.flush()
        let savedRows = await fixture.rows
        XCTAssertEqual(savedRows[id]?.text, "unsaved text")
        XCTAssertNil(recovery.issue)
    }

    @MainActor
    func testCloseStillRunsWhenSupersededInFlightCheckpointFails() async throws {
        let fixture = RecoveryFixture()
        let gate = RecoveryGate()
        await fixture.blockCheckpoint(on: gate)
        await fixture.failNextCheckpoint()
        let recovery = RecordingRecovery()
        await recovery.connect(storage: fixture.storage)
        let id = UUID()
        recovery.begin(id: id, project: "Personal", kind: .note)
        recovery.update(id: id, text: "first")
        try await eventually { await gate.arrivals == 1 }
        recovery.update(id: id, text: "latest to retain")
        recovery.finish(id: id, preserving: true)
        await gate.release()
        await recovery.flush()
        let saved = await fixture.rows[id]
        XCTAssertEqual(saved?.text, "latest to retain")
        XCTAssertNil(recovery.issue)
    }

    @MainActor
    func testDisableDuringPendingWriteClosesEverythingAndCannotRecreate() async throws {
        let fixture = RecoveryFixture()
        let gate = RecoveryGate()
        await fixture.blockCheckpoint(on: gate)
        let recovery = RecordingRecovery()
        await recovery.connect(storage: fixture.storage)
        let id = UUID()
        recovery.begin(id: id, project: "Personal", kind: .note)
        recovery.update(id: id, text: "in flight")
        try await eventually { await gate.arrivals == 1 }
        recovery.update(id: id, text: "pending")
        recovery.enabled = false
        recovery.enabled = true
        recovery.update(id: id, text: "late after disable")
        recovery.finish(id: id, preserving: true)
        await gate.release()
        await recovery.flush()
        let rows = await fixture.rows
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(recovery.drafts.isEmpty)
        let discarded = await fixture.discardAllCount
        XCTAssertEqual(discarded, 1)
    }

    @MainActor
    func testDiscardDuringLoadCannotResurrectCard() async throws {
        let id = UUID()
        let fixture = RecoveryFixture(rows: [id: .init(id: id, text: "old")])
        let gate = RecoveryGate()
        await fixture.blockLoad(on: gate)
        let recovery = RecordingRecovery()
        let connecting = Task { await recovery.connect(storage: fixture.storage) }
        try await eventually { await gate.arrivals == 1 }
        recovery.discard(id: id)
        await gate.release()
        await connecting.value
        await recovery.flush()
        XCTAssertTrue(recovery.drafts.isEmpty)
        let rows = await fixture.rows
        XCTAssertTrue(rows.isEmpty)
    }

    @MainActor
    func testOlderConnectionLoadCannotReplaceNewRepositoryDrafts() async throws {
        let old = RecoveryFixture(rows: [UUID(): .init(text: "old repository")])
        let fresh = RecoveryFixture(rows: [UUID(): .init(text: "new repository")])
        let gate = RecoveryGate()
        await old.blockLoad(on: gate)
        let recovery = RecordingRecovery()
        let connecting = Task { await recovery.connect(storage: old.storage) }
        try await eventually { await gate.arrivals == 1 }
        await recovery.connect(storage: fresh.storage)
        await gate.release()
        await connecting.value
        XCTAssertEqual(recovery.drafts.map(\.text), ["new repository"])
    }

    @MainActor
    func testFlushWaitsForConnectionAndItsQueuedWrites() async throws {
        let fixture = RecoveryFixture()
        let loadGate = RecoveryGate(), writeGate = RecoveryGate()
        await fixture.blockLoad(on: loadGate)
        await fixture.blockCheckpoint(on: writeGate)
        let recovery = RecordingRecovery()
        let id = UUID()
        recovery.begin(id: id, project: "Personal", kind: .note)
        recovery.update(id: id, text: "before connect")
        let connecting = Task { await recovery.connect(storage: fixture.storage) }
        try await eventually { await loadGate.arrivals == 1 }
        var flushed = false
        let flushing = Task { await recovery.flush(); flushed = true }
        await loadGate.release()
        await connecting.value
        try await eventually { await writeGate.arrivals == 1 }
        XCTAssertFalse(flushed)
        await writeGate.release()
        await flushing.value
        let row = await fixture.rows[id]
        XCTAssertEqual(row?.text, "before connect")
        XCTAssertTrue(flushed)
    }

    @MainActor
    func testDisableBeforeStorageArrivesDoesNotReloadOldCards() async throws {
        let draft = RecordingRecoveryDraft(text: "old stored draft")
        let fixture = RecoveryFixture(rows: [draft.id: draft])
        let recovery = RecordingRecovery()
        recovery.enabled = false
        recovery.enabled = true
        await recovery.connect(storage: fixture.storage)
        XCTAssertTrue(recovery.drafts.isEmpty)
        await recovery.flush()
        let rows = await fixture.rows
        XCTAssertTrue(rows.isEmpty)
    }

    @MainActor
    func testTwentyOneCancellationsBoundCardsAndQueuedFinishPayloadsThroughFailure() async throws {
        let recovery = RecordingRecovery()
        var ids: [UUID] = []
        for index in 0..<21 {
            let id = UUID()
            ids.append(id)
            recovery.begin(id: id, project: "Personal", kind: .note)
            recovery.update(id: id, text: "cancel \(index) " + String(repeating: "🌿", count: 1_000))
            recovery.finish(id: id, preserving: true)
        }
        XCTAssertEqual(recovery.drafts.count, 20)
        let retainedIDs = Set(recovery.drafts.map(\.id))
        let evicted = try XCTUnwrap(Set(ids).subtracting(retainedIDs).first)
        let fixture = RecoveryFixture(rows: [evicted: .init(id: evicted, text: "older disk copy")])
        await fixture.setFailing(true)
        await recovery.connect(storage: fixture.storage)
        await recovery.flush()
        XCTAssertNotNil(recovery.issue)
        XCTAssertEqual(recovery.drafts.count, 20)
        await fixture.setFailing(false)
        await recovery.connect(storage: fixture.storage)
        await recovery.flush()
        let rows = await fixture.rows
        let finishes = await fixture.finishes
        XCTAssertEqual(Set(rows.keys), retainedIDs)
        XCTAssertNil(rows[evicted])
        XCTAssertEqual(finishes.count, 20, "An evicted queued transcript must never be sent to storage")
        XCTAssertFalse(finishes.contains(evicted))
        recovery.update(id: evicted, text: "late discarded text")
        recovery.finish(id: evicted, preserving: true)
        await recovery.flush()
        XCTAssertEqual(Set(recovery.drafts.map(\.id)), retainedIDs)
        XCTAssertNil(recovery.issue)
    }

    @MainActor
    func testFailedGrowingCheckpointQueueReconnectsWithOnlyLatestSnapshot() async throws {
        let fixture = RecoveryFixture()
        await fixture.setFailing(true)
        let recovery = RecordingRecovery()
        await recovery.connect(storage: fixture.storage)
        let id = UUID()
        recovery.begin(id: id, project: "Personal", kind: .dictation)
        var latest = ""
        for index in 1...50 {
            latest = String(repeating: "long partial 🌿 ", count: index * 30)
            recovery.update(id: id, text: latest)
            await recovery.flush()
        }
        XCTAssertNotNil(recovery.issue)
        let fresh = RecoveryFixture()
        await recovery.connect(storage: fresh.storage)
        await recovery.flush()
        let checkpoints = await fresh.checkpoints
        XCTAssertEqual(checkpoints.count, 1, "Failed partials must coalesce instead of retaining every full transcript")
        XCTAssertEqual(checkpoints.first?.text, latest)
        XCTAssertEqual(checkpoints.first?.revision, 50)
        recovery.finish(id: id, preserving: false)
        await recovery.flush()
        let rows = await fresh.rows
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(recovery.drafts.isEmpty)
    }

    @MainActor
    func testBlockedCheckpointRetainsOnlyOneAdditionalLatestWrite() async throws {
        let fixture = RecoveryFixture()
        let gate = RecoveryGate()
        await fixture.blockCheckpoint(on: gate)
        let recovery = RecordingRecovery()
        await recovery.connect(storage: fixture.storage)
        let id = UUID()
        recovery.begin(id: id, project: "Personal", kind: .dictation)
        recovery.update(id: id, text: "first in flight")
        try await eventually { await gate.arrivals == 1 }
        var staged = 0
        var flushes: [Task<Void, Never>] = []
        var latest = ""
        for index in 1...30 {
            let snapshot = String(repeating: "growing partial 🌿 ", count: index * 30)
            latest = snapshot
            flushes.append(Task {
                recovery.update(id: id, text: snapshot)
                staged = index
                await recovery.flush()
            })
            try await eventually { staged == index }
        }
        await gate.release()
        for flush in flushes { await flush.value }
        let checkpoints = await fixture.checkpoints
        XCTAssertEqual(checkpoints.map(\.text), ["first in flight", latest],
                       "A stalled writer may hold its in-flight snapshot and only the latest queued partial")
    }

    @MainActor
    func testRestartLoadsActiveCrashJournalUsingOnlyTemporaryDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let repository = try await Task.detached { try LibraryRepository(url: url) }.value
        let recovery = RecordingRecovery()
        await recovery.connect(repository)
        let id = UUID()
        recovery.begin(id: id, project: "Local", kind: .dictation)
        recovery.update(id: id, text: "crash journal 🌿")
        await recovery.flush()
        XCTAssertTrue(recovery.drafts.isEmpty)
        let reopenedRepository = try await Task.detached { try LibraryRepository(url: url) }.value
        let reopened = RecordingRecovery()
        await reopened.connect(reopenedRepository)
        XCTAssertEqual(reopened.drafts.first?.text, "crash journal 🌿")
        reopened.discard(id: id)
        await reopened.flush()
        let final = try await reopenedRepository.loadRecordingDrafts()
        XCTAssertTrue(final.isEmpty)
    }
}

private actor RecoveryGate {
    private(set) var arrivals = 0
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        arrivals += 1
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private actor RecoveryFixture {
    enum Failure: Error { case unavailable }
    private(set) var rows: [UUID: RecordingRecoveryDraft]
    private(set) var checkpoints: [RecordingRecoveryDraft] = []
    private(set) var finishes: [UUID] = []
    private(set) var discardAllCount = 0
    private var closed: Set<UUID> = []
    private var failing = false
    private var checkpointFailsOnce = false
    private var checkpointGate: RecoveryGate?
    private var loadGate: RecoveryGate?
    init(rows: [UUID: RecordingRecoveryDraft] = [:]) { self.rows = rows }
    nonisolated var storage: RecordingRecovery.Storage {
        .init(load: { try await self.load() }, checkpoint: { try await self.checkpoint($0) },
              finish: { try await self.finish($0, $1) }, discard: { try await self.discard($0) },
              discardAll: { try await self.discardAll() })
    }
    func setFailing(_ value: Bool) { failing = value }
    func failNextCheckpoint() { checkpointFailsOnce = true }
    func blockCheckpoint(on gate: RecoveryGate) { checkpointGate = gate }
    func blockLoad(on gate: RecoveryGate) { loadGate = gate }
    func load() async throws -> [RecordingRecoveryDraft] {
        let snapshot = Array(rows.values)
        if let loadGate { await loadGate.wait() }
        return snapshot
    }
    func checkpoint(_ draft: RecordingRecoveryDraft) async throws {
        if let checkpointGate { await checkpointGate.wait() }
        if failing { throw Failure.unavailable }
        if checkpointFailsOnce { checkpointFailsOnce = false; throw Failure.unavailable }
        checkpoints.append(draft)
        guard !closed.contains(draft.id), rows[draft.id].map({ $0.revision < draft.revision }) ?? true else { return }
        rows[draft.id] = draft
    }
    func finish(_ id: UUID, _ draft: RecordingRecoveryDraft?) throws {
        if failing { throw Failure.unavailable }
        guard !closed.contains(id) else { return }
        finishes.append(id)
        closed.insert(id)
        rows[id] = draft
    }
    func discard(_ id: UUID) throws {
        if failing { throw Failure.unavailable }
        rows[id] = nil
        closed.insert(id)
    }
    func discardAll() throws {
        if failing { throw Failure.unavailable }
        discardAllCount += 1
        closed.formUnion(rows.keys)
        rows = [:]
    }
}
