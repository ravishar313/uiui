import XCTest
import CSQLite
@testable import UIUICore

final class RecordingRecoveryRepositoryTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("library.sqlite")
    }

    private func snapshot(id: UUID = UUID(), text: String = "recognized words", revision: Int64 = 1,
                          timestamp: Double = 1_000) -> RecordingRecoveryDraft {
        RecordingRecoveryDraft(id: id, text: text, project: "研究 🪷", kind: .dictation,
                               startedAt: Date(timeIntervalSince1970: 100),
                               updatedAt: Date(timeIntervalSince1970: timestamp), revision: revision)
    }

    private func withDatabase<T>(_ url: URL, _ work: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open(url.path, &database)
        guard result == SQLITE_OK, let database else { throw LibraryRepository.RepositoryError.database(result) }
        defer { sqlite3_close(database) }
        return try work(database)
    }

    private func scalar(_ url: URL, _ sql: String) throws -> Int64 {
        try withDatabase(url) { database in
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard result == SQLITE_OK, let statement else { throw LibraryRepository.RepositoryError.database(result) }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw LibraryRepository.RepositoryError.corruptRecord }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func testOpenAndClosedDraftsSurviveRepositoryLifetimeWithExactLongUnicodeText() async throws {
        let url = try location()
        let exactText = " \n\tकिताब e\u{301} 👨‍👩‍👧‍👦\u{0} suffix\r\n" + String(repeating: "段落 🪷\t\n", count: 30_000)
        let open = snapshot(text: exactText, revision: Int64.max - 1)
        let closed = snapshot(text: " cancelled text \n", timestamp: 2_000)
        do {
            let repository = try LibraryRepository(url: url)
            try await repository.checkpointRecordingDraft(open)
            try await repository.finishRecordingDraft(id: closed.id, preserving: closed)
        }
        let reopened = try LibraryRepository(url: url)
        let loaded = try await reopened.loadRecordingDrafts()
        XCTAssertEqual(loaded, [closed, open])
        XCTAssertEqual(loaded.last?.text.utf8.count, exactText.utf8.count)
        let items = try await reopened.loadItems()
        let events = try await reopened.loadEvents(since: .distantPast)
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(events.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testAdditiveVersionOneSchemaLeavesLegacyCapturesAndEventsUntouched() async throws {
        let url = try location()
        let item = CaptureItem(title: "Existing capture", body: "existing library text")
        let event = UsageEvent(date: Date(timeIntervalSince1970: 1_000), action: "capture", wordCount: 3)
        do {
            let repository = try LibraryRepository(url: url)
            try await repository.upsert(item)
            try await repository.appendEvent(event)
        }
        // Removing only the new table recreates the pre-journal version-1 schema and data.
        try withDatabase(url) { database in
            XCTAssertEqual(sqlite3_exec(database, "DROP TABLE recording_drafts", nil, nil, nil), SQLITE_OK)
        }
        let repository = try LibraryRepository(url: url)
        let recovery = snapshot()
        try await repository.checkpointRecordingDraft(recovery)
        try await repository.finishRecordingDraft(id: recovery.id, preserving: recovery)
        let items = try await repository.loadItems()
        let found = try await repository.search("existing")
        let events = try await repository.loadEvents(since: .distantPast)
        XCTAssertEqual(items, [item])
        XCTAssertEqual(found, [item])
        XCTAssertEqual(events.map(\.id), [event.id])
        XCTAssertEqual(events.first?.wordCount, event.wordCount)
        XCTAssertEqual(try scalar(url, "PRAGMA user_version"), 1)
        // An older connection can continue its original operations after journal creation.
        try withDatabase(url) { database in
            XCTAssertEqual(sqlite3_exec(database, "BEGIN IMMEDIATE; UPDATE captures SET title = title; COMMIT", nil, nil, nil), SQLITE_OK)
        }
    }

    func testStaleAndEqualRevisionsCannotReplaceNewerText() async throws {
        let repository = try LibraryRepository(url: location())
        let latest = snapshot(revision: Int64.max - 1)
        try await repository.checkpointRecordingDraft(latest)
        try await repository.checkpointRecordingDraft(snapshot(id: latest.id, text: "old", revision: Int64.max - 2, timestamp: 9_000))
        try await repository.checkpointRecordingDraft(snapshot(id: latest.id, text: "same revision", revision: Int64.max - 1))
        let loaded = try await repository.loadRecordingDrafts()
        XCTAssertEqual(loaded, [latest])
    }

    func testEmptyCheckpointsNeverEraseExistingTextOrCreateRecovery() async throws {
        let repository = try LibraryRepository(url: location())
        let original = snapshot()
        try await repository.checkpointRecordingDraft(original)
        try await repository.checkpointRecordingDraft(snapshot(id: original.id, text: " \n\t\r\u{2003}", revision: 20))
        try await repository.checkpointRecordingDraft(snapshot(text: ""))
        let loaded = try await repository.loadRecordingDrafts()
        XCTAssertEqual(loaded, [original])
        try await repository.finishRecordingDraft(id: original.id, preserving: nil)
        let removed = try await repository.loadRecordingDrafts()
        XCTAssertTrue(removed.isEmpty)
    }

    func testFinishRetainsBestRevisionAndIgnoresLateCheckpointAndRepeatedFinish() async throws {
        let url = try location()
        let repository = try LibraryRepository(url: url)
        let latest = snapshot(revision: 5)
        try await repository.checkpointRecordingDraft(latest)
        try await repository.finishRecordingDraft(id: latest.id, preserving: snapshot(id: latest.id, text: "stale", revision: 4))
        try await repository.finishRecordingDraft(id: latest.id, preserving: nil)
        try await repository.finishRecordingDraft(id: latest.id, preserving: snapshot(id: latest.id, text: "late finish", revision: 99))
        try await repository.checkpointRecordingDraft(snapshot(id: latest.id, text: "late checkpoint", revision: 100))
        let loaded = try await repository.loadRecordingDrafts()
        XCTAssertEqual(loaded, [latest])
        let finalSnapshot = snapshot(text: "final recognition", revision: 10)
        try await repository.checkpointRecordingDraft(snapshot(id: finalSnapshot.id, revision: 1))
        try await repository.finishRecordingDraft(id: finalSnapshot.id, preserving: finalSnapshot)
        let afterFinal = try await repository.loadRecordingDrafts()
        XCTAssertEqual(Set(afterFinal), Set([latest, finalSnapshot]))
        XCTAssertEqual(try scalar(url, "SELECT COUNT(*) FROM recording_drafts WHERE closed = 1"), 2)
    }

    func testEmptyFinalSnapshotPreservesPriorTextAndNilClosePreventsResurrection() async throws {
        let repository = try LibraryRepository(url: location())
        let original = snapshot()
        try await repository.checkpointRecordingDraft(original)
        try await repository.finishRecordingDraft(id: original.id, preserving: snapshot(id: original.id, text: "  \n", revision: 2))
        let preserved = try await repository.loadRecordingDrafts()
        XCTAssertEqual(preserved, [original])
        let completed = snapshot()
        try await repository.finishRecordingDraft(id: completed.id, preserving: nil)
        try await repository.checkpointRecordingDraft(completed)
        let loaded = try await repository.loadRecordingDrafts()
        XCTAssertEqual(loaded, [original])
    }

    func testExplicitDiscardAndDiscardAllCloseOpenAndAlreadyClosedIDs() async throws {
        let url = try location()
        let repository = try LibraryRepository(url: url)
        let closed = snapshot()
        try await repository.finishRecordingDraft(id: closed.id, preserving: closed)
        try await repository.discardRecordingDraft(id: closed.id)
        try await repository.checkpointRecordingDraft(snapshot(id: closed.id, revision: 10))
        let open = snapshot()
        try await repository.checkpointRecordingDraft(open)
        let unknown = snapshot()
        try await repository.discardRecordingDraft(id: unknown.id)
        try await repository.checkpointRecordingDraft(unknown)
        try await repository.discardAllRecordingDrafts()
        try await repository.checkpointRecordingDraft(snapshot(id: open.id, revision: 20))
        try await repository.finishRecordingDraft(id: closed.id, preserving: closed)
        let reopened = try LibraryRepository(url: url)
        let loaded = try await reopened.loadRecordingDrafts()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(try scalar(url, "SELECT COUNT(*) FROM recording_drafts WHERE payload IS NULL AND closed = 1"), 3)
    }

    func testRetentionKeepsNewestTwentyAndEvictedIDsStayClosed() async throws {
        let url = try location()
        let repository = try LibraryRepository(url: url)
        let drafts = (0..<25).map { snapshot(text: "draft \($0)", timestamp: Double($0)) }
        for draft in drafts.reversed() { try await repository.checkpointRecordingDraft(draft) }
        let loaded = try await repository.loadRecordingDrafts()
        XCTAssertEqual(loaded, Array(drafts.suffix(20).reversed()))
        let oldest = drafts[0]
        try await repository.checkpointRecordingDraft(snapshot(id: oldest.id, text: "late", revision: 99, timestamp: 10_000))
        let afterLate = try await repository.loadRecordingDrafts()
        XCTAssertEqual(afterLate, loaded)
        XCTAssertEqual(try scalar(url, "SELECT COUNT(*) FROM recording_drafts WHERE payload IS NULL AND closed = 1"), 5)
    }

    func testTombstoneStorageIsBoundedAndContainsNoPayload() async throws {
        let url = try location()
        let repository = try LibraryRepository(url: url)
        let protected = snapshot()
        try await repository.checkpointRecordingDraft(protected)
        for _ in 0..<1_005 { try await repository.discardRecordingDraft(id: UUID()) }
        XCTAssertEqual(try scalar(url, "SELECT COUNT(*) FROM recording_drafts WHERE payload IS NULL"), 1_000)
        XCTAssertEqual(try scalar(url, "SELECT COUNT(*) FROM recording_drafts"), 1_001)
        let loaded = try await repository.loadRecordingDrafts()
        XCTAssertEqual(loaded, [protected])
    }

    func testConcurrentConnectionsSerializeRevisionAndCloseDecisions() async throws {
        let url = try location()
        let first = try LibraryRepository(url: url)
        let second = try LibraryRepository(url: url)
        let id = UUID()
        let revisions = (1...40).map { snapshot(id: id, text: "revision \($0)", revision: Int64($0)) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, draft) in revisions.enumerated() {
                let repository = index.isMultiple(of: 2) ? first : second
                group.addTask { try await repository.checkpointRecordingDraft(draft) }
            }
            try await group.waitForAll()
        }
        let loaded = try await first.loadRecordingDrafts()
        XCTAssertEqual(loaded, [revisions.last!])
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await first.finishRecordingDraft(id: id, preserving: revisions.last!) }
            group.addTask { try await second.checkpointRecordingDraft(self.snapshot(id: id, revision: 1_000)) }
            try await group.waitForAll()
        }
        try await second.checkpointRecordingDraft(snapshot(id: id, revision: 2_000))
        let final = try await first.loadRecordingDrafts()
        XCTAssertEqual(final.count, 1)
        XCTAssertTrue([Int64(40), 1_000].contains(final[0].revision))
        XCTAssertEqual(try scalar(url, "SELECT closed FROM recording_drafts"), 1)
    }

    func testMismatchedFinishIDDoesNotCloseOrWriteEitherDraft() async throws {
        let repository = try LibraryRepository(url: location())
        let draft = snapshot()
        do {
            try await repository.finishRecordingDraft(id: UUID(), preserving: draft)
            XCTFail("A mismatched recording ID must be rejected")
        } catch LibraryRepository.RepositoryError.invalidRecordingDraft { }
        try await repository.checkpointRecordingDraft(draft)
        let loaded = try await repository.loadRecordingDrafts()
        XCTAssertEqual(loaded, [draft])
    }
}
