import Foundation
import XCTest
import UIUICore
@testable import UIUI

@MainActor
final class HistoryWordFixTests: XCTestCase {
    private func makeModel() async throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-wordfix-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "uiui-wordfix-\(UUID().uuidString)"))
        let model = AppModel(dataDirectory: root.appendingPathComponent("data"), defaults: defaults, persistSettings: false,
                             delivery: WordFixDelivery(), cleanup: WordFixCleanup())
        addTeardownBlock { await MainActor.run { model.shutdown() } }
        await model.start(installSystemServices: false)
        XCTAssertNil(model.errorMessage)
        return model
    }

    private func save(_ body: String, in model: AppModel, at date: Date = Date(), kind: CaptureKind = .dictation) async -> CaptureItem {
        let item = CaptureItem(title: TextProcessing.title(for: body), body: body, kind: kind, createdAt: date, updatedAt: date, sourceApp: "Mail")
        let saved = await model.persist(item)
        XCTAssertTrue(saved)
        return item
    }

    func testFixChangesTextAndDictionaryTogetherAndUndoRestoresBoth() async throws {
        let model = try await makeModel()
        let item = await save("Ask Zelda about the plan.", in: model)
        guard case .fixed(let fix) = await model.fixWord(in: item, heard: "Zelda", correction: "Zelta") else { return XCTFail("Expected a fix") }
        let stored = try XCTUnwrap(model.items.first { $0.id == item.id })
        XCTAssertEqual(stored.body, "Ask Zelta about the plan.")
        XCTAssertEqual(stored.rawText, "Ask Zelda about the plan.")
        XCTAssertEqual(stored.updatedAt, item.updatedAt)
        XCTAssertEqual(model.settings.vocabulary.map(\.heard), ["zelda"])
        XCTAssertEqual(model.settings.vocabulary.map(\.replacement), ["Zelta"])
        XCTAssertEqual(model.settings.vocabulary.first?.project, "All projects")
        let undone = await model.undoWordFix(fix)
        XCTAssertTrue(undone)
        let restored = try XCTUnwrap(model.items.first { $0.id == item.id })
        XCTAssertEqual(restored.body, "Ask Zelda about the plan.")
        XCTAssertNil(restored.rawText)
        XCTAssertTrue(model.settings.vocabulary.isEmpty)
    }

    func testRepeatedFixDoesNotDuplicateTheEntryAndExistingSpellingIsUpdated() async throws {
        let model = try await makeModel()
        let first = await save("Zelda one", in: model)
        let second = await save("Zelda two", in: model)
        _ = await model.fixWord(in: first, heard: "Zelda", correction: "Zelta")
        _ = await model.fixWord(in: second, heard: "Zelda", correction: "Zelta")
        XCTAssertEqual(model.settings.vocabulary.count, 1)
        guard case .fixed(let fix) = await model.fixWord(in: await save("Zelda three", in: model), heard: "Zelda", correction: "ZELTA") else { return XCTFail("Expected a fix") }
        XCTAssertEqual(model.settings.vocabulary.map(\.replacement), ["ZELTA"])
        let undone = await model.undoWordFix(fix)
        XCTAssertTrue(undone)
        XCTAssertEqual(model.settings.vocabulary.map(\.replacement), ["Zelta"])
    }

    func testRejectedFixLeavesTextAndDictionaryUntouched() async throws {
        let model = try await makeModel()
        let item = await save("Nothing to fix here", in: model)
        guard case .rejected(let reason) = await model.fixWord(in: item, heard: "missing", correction: "x") else { return XCTFail("Expected a rejection") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(model.items.first?.body, "Nothing to fix here")
        XCTAssertTrue(model.settings.vocabulary.isEmpty)
    }

    func testUndoIsRefusedWhenTextChangedSince() async throws {
        let model = try await makeModel()
        let item = await save("Zelda again", in: model)
        guard case .fixed(let fix) = await model.fixWord(in: item, heard: "Zelda", correction: "Zelta") else { return XCTFail("Expected a fix") }
        var edited = try XCTUnwrap(model.items.first)
        edited.body = "Something else entirely"
        _ = await model.persist(edited)
        let undone = await model.undoWordFix(fix)
        XCTAssertFalse(undone)
        XCTAssertEqual(model.items.first?.body, "Something else entirely")
        XCTAssertEqual(model.settings.vocabulary.count, 1)
    }

    func testStatsAndRecentDictationsFollowSavedHistory() async throws {
        let model = try await makeModel()
        let now = Date()
        let old = await save("old words here", in: model, at: now.addingTimeInterval(-10 * 86_400))
        let recent = await save("one two three four five", in: model, at: now.addingTimeInterval(-60))
        _ = await save("a note not a dictation", in: model, at: now, kind: .note)
        XCTAssertEqual(model.dictationStats(now: now)?.words, 5)
        XCTAssertEqual(model.recentDictations(limit: 5).map(\.id), [recent.id, old.id])
        XCTAssertEqual(model.recentDictations(limit: 1).count, 1)
        model.delete(recent)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.dictationStats(now: now))
        model.settings.saveDictationHistory = false
        XCTAssertNil(model.dictationStats(now: now))
    }

    func testLatestDictationFallsBackToNewestSavedAfterRestart() async throws {
        let model = try await makeModel()
        XCTAssertNil(model.latestDictation)
        _ = await save("first thing", in: model, at: Date().addingTimeInterval(-500))
        let newest = await save("second thing", in: model, at: Date().addingTimeInterval(-100))
        XCTAssertEqual(model.latestDictation?.text, "second thing")
        XCTAssertEqual(model.latestDictation?.app, "Mail")
        XCTAssertEqual(model.latestDictation?.date, newest.createdAt)
        XCTAssertTrue(model.canCopyLatestDictation)
    }

    func testMenuTitleIsOneTruncatedLine() {
        XCTAssertEqual(StatusMenuController.menuTitle(for: "short\n\n  text"), "short text")
        let long = String(repeating: "word ", count: 30)
        let title = StatusMenuController.menuTitle(for: long)
        XCTAssertLessThanOrEqual(title.count, StatusMenuController.recentTitleLimit)
        XCTAssertTrue(title.hasSuffix("…"))
    }
}

@MainActor
private final class WordFixDelivery: TextDelivering {
    func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult { .held("Synthetic") }
    func cancel() {}
}

@MainActor
private final class WordFixCleanup: DictationCleaning {
    func prepare() {}
    func begin(_ captureID: UUID) {}
    func update(_ text: String, captureID: UUID) {}
    func finish(_ text: String, captureID: UUID) async throws -> String { text }
    func cancel() {}
    func release() {}
}
