import XCTest
@testable import UIUICore

final class RepositoryTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("library.sqlite")
    }

    func testDurabilityAndExactRoundtrip() async throws {
        let url = try location()
        let repository = try LibraryRepository(url: url)
        let item = CaptureItem(title: "Unicode 🪷", body: " line one\n\nकिताब\t\"quoted\" \u{0} suffix ", kind: .dictation, project: "Lab", tags: ["one", "two words"], reminderDate: Date(timeIntervalSince1970: 2_000_000_000), isCompleted: true, isPinned: true, sourceApp: "Editor", rawText: "  RAW\n words\t🪷 ")
        try await repository.upsert(item)
        let reopened = try LibraryRepository(url: url)
        let items = try await reopened.loadItems()
        XCTAssertEqual(items, [item])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testEditsDeleteAndLiteralSearchMaintainIndex() async throws {
        let repository = try LibraryRepository(url: location())
        var item = CaptureItem(title: "Meeting", body: "Old orchid text", project: "Research", tags: ["priority"])
        try await repository.upsert(item)
        let initial = try await repository.search("orchid")
        XCTAssertEqual(initial.map(\.id), [item.id])
        item.body = "New jasmine text with \"quotes\" and * punctuation"
        try await repository.upsert(item)
        let stale = try await repository.search("orchid")
        let fresh = try await repository.search("jasmine")
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(fresh.map(\.id), [item.id])
        XCTAssertEqual(fresh.first, item)
        for query in ["\"", "*", "jasmine OR orchid", "' OR 1=1 --", "title:jasmine", "NEAR("] {
            _ = try await repository.search(query)
        }
        let injection = try await repository.search("' OR 1=1 --")
        XCTAssertTrue(injection.isEmpty)
        try await repository.delete(id: item.id)
        let deleted = try await repository.search("jasmine")
        let remaining = try await repository.loadItems()
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUsageEventsAreDurableIdempotentAndDateFiltered() async throws {
        let url = try location()
        let repository = try LibraryRepository(url: url)
        let old = UsageEvent(date: Date(timeIntervalSince1970: 100), action: "capture")
        let recent = UsageEvent(date: Date(timeIntervalSince1970: 200), action: "dictate", durationMS: 12.5, wordCount: 4, succeeded: false)
        try await repository.appendEvent(old)
        try await repository.appendEvent(recent)
        try await repository.appendEvent(recent)
        let reopened = try LibraryRepository(url: url)
        let events = try await reopened.loadEvents(since: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, recent.id)
        XCTAssertEqual(events.first?.durationMS, 12.5)
        XCTAssertEqual(events.first?.wordCount, 4)
        XCTAssertEqual(events.first?.succeeded, false)
    }

    func testConcurrentConnectionsPreserveDistinctWritesAndSearchEntries() async throws {
        let url = try location()
        let first = try LibraryRepository(url: url)
        let second = try LibraryRepository(url: url)
        let items = (0..<30).map { CaptureItem(title: "Item \($0)", body: "sharedmarker \($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, item) in items.enumerated() {
                let repository = index.isMultiple(of: 2) ? first : second
                group.addTask { try await repository.upsert(item) }
            }
            try await group.waitForAll()
        }
        let loaded = try await first.loadItems()
        let found = try await second.search("sharedmarker")
        XCTAssertEqual(Set(loaded), Set(items))
        XCTAssertEqual(Set(found.map(\.id)), Set(items.map(\.id)))
    }
}
