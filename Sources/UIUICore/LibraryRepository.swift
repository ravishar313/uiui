import Foundation
import CSQLite
import Darwin

/// The single owner of the local library database. All operations run on this actor.
public actor LibraryRepository {
    public enum RepositoryError: Error, LocalizedError {
        case database(Int32), unsupportedSchema(Int32), corruptRecord, invalidRecordingDraft
        public var errorDescription: String? {
            switch self {
            case .database(let code): return "The local library could not be accessed (SQLite \(code))."
            case .unsupportedSchema: return "This library was created by a newer version of uiui."
            case .corruptRecord: return "A local library record could not be read."
            case .invalidRecordingDraft: return "The recording recovery draft does not match its recording."
            }
        }
    }

    private let database: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Exclusive creation cannot truncate a database created concurrently by another instance.
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        if descriptor >= 0 { Darwin.close(descriptor) }
        else if errno != EEXIST { throw RepositoryError.database(SQLITE_CANTOPEN) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw RepositoryError.database(result)
        }
        database = connection
        do {
            sqlite3_busy_timeout(connection, 5_000)
            try Self.execute(connection, "PRAGMA foreign_keys = ON")
            let version = try Self.schemaVersion(connection)
            guard version <= 1 else { throw RepositoryError.unsupportedSchema(version) }
            try Self.execute(connection, "PRAGMA journal_mode = WAL")
            try Self.execute(connection, "PRAGMA synchronous = FULL")
            try Self.execute(connection, "BEGIN IMMEDIATE")
            do {
                try Self.execute(connection, "CREATE TABLE IF NOT EXISTS captures (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, project TEXT NOT NULL, tags TEXT NOT NULL, updated_at REAL NOT NULL)")
                try Self.execute(connection, "CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(id UNINDEXED, title, body, project, tags, tokenize='unicode61')")
                try Self.execute(connection, "CREATE TABLE IF NOT EXISTS usage_events (id TEXT PRIMARY KEY NOT NULL, date REAL NOT NULL, payload BLOB NOT NULL)")
                try Self.execute(connection, "CREATE INDEX IF NOT EXISTS usage_events_date ON usage_events(date)")
                // Additive at schema version 1 so an already-running older app can keep using its library.
                try Self.execute(connection, "CREATE TABLE IF NOT EXISTS recording_drafts (id TEXT PRIMARY KEY NOT NULL, payload BLOB, revision INTEGER NOT NULL, closed INTEGER NOT NULL CHECK(closed IN (0,1)), updated_at REAL NOT NULL)")
                try Self.execute(connection, "CREATE INDEX IF NOT EXISTS recording_drafts_updated_at ON recording_drafts(updated_at)")
                try Self.execute(connection, "PRAGMA user_version = 1")
                try Self.execute(connection, "COMMIT")
            } catch {
                try? Self.execute(connection, "ROLLBACK")
                throw error
            }
        } catch {
            sqlite3_close(connection)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func loadItems() throws -> [CaptureItem] {
        try records("SELECT payload FROM captures ORDER BY updated_at DESC, id", as: CaptureItem.self)
    }

    public func search(_ query: String) throws -> [CaptureItem] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return try loadItems() }
        // Every token is an FTS string literal: operators, quotes and column names have no syntax power.
        let literal = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
        let matches = try records("SELECT c.payload FROM captures c JOIN captures_fts f ON c.id = f.id WHERE captures_fts MATCH ? ORDER BY c.updated_at DESC, c.id", text: [literal], as: CaptureItem.self)
        if !matches.isEmpty { return matches }
        // Punctuation-only text is not indexed by FTS. Bind it as literal text in the fallback too.
        return try records("SELECT payload FROM captures WHERE instr(lower(title || char(10) || body || char(10) || project || char(10) || tags), lower(?)) > 0 ORDER BY updated_at DESC, id", text: [query], as: CaptureItem.self)
    }

    public func upsert(_ item: CaptureItem) throws {
        let payload = try encoder.encode(item)
        try transaction {
            try run("INSERT INTO captures(id,payload,title,body,project,tags,updated_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,title=excluded.title,body=excluded.body,project=excluded.project,tags=excluded.tags,updated_at=excluded.updated_at", text: [item.id.uuidString], blob: payload, trailingText: [item.title, item.body, item.project, item.tags.joined(separator: " ")], number: item.updatedAt.timeIntervalSince1970)
            try run("DELETE FROM captures_fts WHERE id = ?", text: [item.id.uuidString])
            try run("INSERT INTO captures_fts(id,title,body,project,tags) VALUES(?,?,?,?,?)", text: [item.id.uuidString, item.title, item.body, item.project, item.tags.joined(separator: " ")])
        }
    }

    public func delete(id: UUID) throws {
        try transaction {
            try run("DELETE FROM captures_fts WHERE id = ?", text: [id.uuidString])
            try run("DELETE FROM captures WHERE id = ?", text: [id.uuidString])
        }
    }

    public func appendEvent(_ event: UsageEvent) throws {
        let payload = try encoder.encode(event)
        try transaction {
            try run("INSERT INTO usage_events(id,payload,date) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,date=excluded.date", text: [event.id.uuidString], blob: payload, number: event.date.timeIntervalSince1970)
            try run("DELETE FROM usage_events WHERE id IN (SELECT id FROM usage_events ORDER BY date DESC, id DESC LIMIT -1 OFFSET 10000)")
        }
    }

    public func loadEvents(since: Date) throws -> [UsageEvent] {
        try records("SELECT payload FROM usage_events WHERE date >= ? ORDER BY date DESC, id", number: since.timeIntervalSince1970, as: UsageEvent.self)
    }

    /// Whitespace-only updates are no-ops: a transient empty recognition result must not erase text.
    public func checkpointRecordingDraft(_ draft: RecordingRecoveryDraft) throws {
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let payload = try encoder.encode(draft)
        try transaction {
            let existing = try recordingDraftRow(id: draft.id)
            guard existing?.closed != true,
                  existing.map({ draft.revision > $0.revision }) ?? true else { return }
            try writeRecordingDraft(id: draft.id, payload: payload, revision: draft.revision,
                                    closed: false, updatedAt: draft.updatedAt)
            try pruneRecordingDrafts()
        }
    }

    /// Atomically closes an ID. A later completion cannot erase a cancellation's retained text.
    /// Passing nil removes content; a supplied snapshot competes with the last checkpoint by revision.
    public func finishRecordingDraft(id: UUID, preserving draft: RecordingRecoveryDraft?) throws {
        guard draft == nil || draft?.id == id else { throw RepositoryError.invalidRecordingDraft }
        let suppliedPayload = try draft.flatMap {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try encoder.encode($0)
        }
        try transaction {
            let existing = try recordingDraftRow(id: id)
            guard existing?.closed != true else { return }
            var payload: Data?
            var updatedAt = Date()
            if let draft {
                if let suppliedPayload, existing.map({ draft.revision > $0.revision }) ?? true {
                    payload = suppliedPayload
                    updatedAt = draft.updatedAt
                } else {
                    payload = existing?.payload
                    updatedAt = existing?.updatedAt ?? draft.updatedAt
                }
            }
            try writeRecordingDraft(id: id, payload: payload,
                                    revision: max(existing?.revision ?? draft?.revision ?? 0,
                                                  draft?.revision ?? existing?.revision ?? 0),
                                    closed: true, updatedAt: payload == nil ? Date() : updatedAt)
            try pruneRecordingDrafts()
        }
    }

    /// Explicit discard also clears a previously closed recovery, while blocking queued checkpoints.
    public func discardRecordingDraft(id: UUID) throws {
        try transaction {
            let existing = try recordingDraftRow(id: id)
            try writeRecordingDraft(id: id, payload: nil, revision: existing?.revision ?? 0,
                                    closed: true, updatedAt: Date())
            try pruneRecordingDrafts()
        }
    }

    public func loadRecordingDrafts() throws -> [RecordingRecoveryDraft] {
        try records("SELECT payload FROM recording_drafts WHERE payload IS NOT NULL ORDER BY updated_at DESC, id", as: RecordingRecoveryDraft.self)
    }

    public func discardAllRecordingDrafts() throws {
        try transaction {
            try run("UPDATE recording_drafts SET payload = NULL, closed = 1, updated_at = ?", number: Date().timeIntervalSince1970)
            try pruneRecordingDrafts()
        }
    }

    private struct RecordingDraftRow {
        var payload: Data?
        var revision: Int64
        var closed: Bool
        var updatedAt: Date
    }

    private func recordingDraftRow(id: UUID) throws -> RecordingDraftRow? {
        let statement = try statement("SELECT payload, revision, closed, updated_at FROM recording_drafts WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind([id.uuidString], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw RepositoryError.database(result) }
        let payload = sqlite3_column_blob(statement, 0).map {
            Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 0)))
        }
        return RecordingDraftRow(payload: payload, revision: sqlite3_column_int64(statement, 1),
                                 closed: sqlite3_column_int(statement, 2) != 0,
                                 updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)))
    }

    private func writeRecordingDraft(id: UUID, payload: Data?, revision: Int64, closed: Bool, updatedAt: Date) throws {
        let statement = try statement("INSERT INTO recording_drafts(id,payload,revision,closed,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revision=excluded.revision,closed=excluded.closed,updated_at=excluded.updated_at")
        defer { sqlite3_finalize(statement) }
        try bind([id.uuidString], to: statement)
        let payloadResult: Int32
        if let payload {
            payloadResult = payload.withUnsafeBytes {
                sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(payload.count), Self.transient)
            }
        } else { payloadResult = sqlite3_bind_null(statement, 2) }
        let results = [payloadResult, sqlite3_bind_int64(statement, 3, revision),
                       sqlite3_bind_int(statement, 4, closed ? 1 : 0),
                       sqlite3_bind_double(statement, 5, updatedAt.timeIntervalSince1970)]
        if let result = results.first(where: { $0 != SQLITE_OK }) { throw RepositoryError.database(result) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw RepositoryError.database(result) }
    }

    private func pruneRecordingDrafts() throws {
        // Never truncate transcript content. Evicted drafts become content-free closed tombstones.
        try run("UPDATE recording_drafts SET payload = NULL, closed = 1 WHERE id IN (SELECT id FROM recording_drafts WHERE payload IS NOT NULL ORDER BY updated_at DESC, id LIMIT -1 OFFSET 20)")
        // Tombstones bound queued-write protection to the most recent 1000 closed IDs.
        try run("DELETE FROM recording_drafts WHERE id IN (SELECT id FROM recording_drafts WHERE payload IS NULL AND closed = 1 ORDER BY updated_at DESC, id LIMIT -1 OFFSET 1000)")
    }

    private func transaction(_ work: () throws -> Void) throws {
        try Self.execute(database, "BEGIN IMMEDIATE")
        do { try work(); try Self.execute(database, "COMMIT") }
        catch { try? Self.execute(database, "ROLLBACK"); throw error }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw RepositoryError.database(result) }
        return statement
    }

    private func bind(_ text: [String], to statement: OpaquePointer, startingAt start: Int32 = 1) throws {
        for (offset, value) in text.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, start + Int32(offset), $0, Int32(value.utf8.count), Self.transient) }
            guard result == SQLITE_OK else { throw RepositoryError.database(result) }
        }
    }

    private func run(_ sql: String, text: [String] = [], blob: Data? = nil, trailingText: [String] = [], number: Double? = nil) throws {
        let statement = try statement(sql)
        defer { sqlite3_finalize(statement) }
        try bind(text, to: statement)
        var index = Int32(text.count + 1)
        if let blob {
            let result = blob.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(blob.count), Self.transient) }
            guard result == SQLITE_OK else { throw RepositoryError.database(result) }
            index += 1
        }
        try bind(trailingText, to: statement, startingAt: index)
        index += Int32(trailingText.count)
        if let number {
            let result = sqlite3_bind_double(statement, index, number)
            guard result == SQLITE_OK else { throw RepositoryError.database(result) }
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw RepositoryError.database(result) }
    }

    private func records<T: Decodable>(_ sql: String, text: [String] = [], number: Double? = nil, as: T.Type) throws -> [T] {
        let statement = try statement(sql)
        defer { sqlite3_finalize(statement) }
        try bind(text, to: statement)
        if let number { sqlite3_bind_double(statement, Int32(text.count + 1), number) }
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw RepositoryError.database(result) }
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw RepositoryError.corruptRecord }
            values.append(try decoder.decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw RepositoryError.database(result) }
    }

    private static func schemaVersion(_ database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw RepositoryError.database(result) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw RepositoryError.corruptRecord }
        return sqlite3_column_int(statement, 0)
    }
}
