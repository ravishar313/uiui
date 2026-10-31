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

    private func fix(_ model: AppModel, _ item: CaptureItem, _ word: String, nth: Int = 0, to correction: String,
                     others: Bool = false, dictionary: Bool = true) async -> AppModel.WordFixOutcome {
        let text = item.body as NSString
        var range = NSRange(location: 0, length: 0), from = 0
        for _ in 0...nth {
            range = text.range(of: word, options: [], range: NSRange(location: from, length: text.length - from))
            from = NSMaxRange(range)
        }
        return await model.fixWord(in: item, wordRange: range, heard: word, correction: correction,
                                   alsoFixOtherMatches: others, addToDictionary: dictionary)
    }

    func testFixChangesOnlyTheClickedWordAndDictionaryAndUndoRestoresBoth() async throws {
        let model = try await makeModel()
        let item = await save("Ask Karan about the plan. Karan knows.", in: model)
        guard case .fixed(let applied) = await fix(model, item, "Karan", nth: 1, to: "Kiran") else { return XCTFail("Expected a fix") }
        let stored = try XCTUnwrap(model.items.first { $0.id == item.id })
        XCTAssertEqual(stored.body, "Ask Karan about the plan. Kiran knows.")
        XCTAssertEqual(stored.rawText, "Ask Karan about the plan. Karan knows.")
        XCTAssertEqual(stored.updatedAt, item.updatedAt)
        XCTAssertEqual(model.settings.vocabulary.map(\.heard), ["karan"])
        XCTAssertEqual(model.settings.vocabulary.map(\.replacement), ["Kiran"])
        XCTAssertEqual(model.settings.vocabulary.first?.project, "All projects")
        let undone = await model.undoWordFix(applied)
        XCTAssertTrue(undone)
        let restored = try XCTUnwrap(model.items.first { $0.id == item.id })
        XCTAssertEqual(restored.body, "Ask Karan about the plan. Karan knows.")
        XCTAssertNil(restored.rawText)
        XCTAssertTrue(model.settings.vocabulary.isEmpty)
    }

    func testAlsoFixOthersAndDictionaryOptOut() async throws {
        let model = try await makeModel()
        let item = await save("Karan and karan and Karan", in: model)
        guard case .fixed(let applied) = await fix(model, item, "Karan", to: "Kiran", others: true, dictionary: false) else { return XCTFail("Expected a fix") }
        XCTAssertEqual(model.items.first?.body, "Kiran and karan and Kiran")
        XCTAssertEqual(applied.replacedCount, 2)
        XCTAssertTrue(model.settings.vocabulary.isEmpty, "Opting out leaves the dictionary alone")
    }

    func testUndoKeepsAPinToggledAfterTheFix() async throws {
        let model = try await makeModel()
        let item = await save("Ask Karan today", in: model)
        guard case .fixed(let applied) = await fix(model, item, "Karan", to: "Kiran") else { return XCTFail("Expected a fix") }
        var pinned = try XCTUnwrap(model.items.first { $0.id == item.id })
        pinned.isPinned = true
        _ = await model.persist(pinned)
        let undone = await model.undoWordFix(applied)
        XCTAssertTrue(undone)
        let restored = try XCTUnwrap(model.items.first { $0.id == item.id })
        XCTAssertEqual(restored.body, "Ask Karan today")
        XCTAssertTrue(restored.isPinned, "Undo restores only what the fix changed")
    }

    func testUndoStaysAvailableFromTheModelAndStepsBackThroughSeveralFixes() async throws {
        let model = try await makeModel()
        let item = await save("Ask Karan and Priyaa today", in: model)
        XCTAssertNil(model.undoableFix(for: item.id))
        _ = await fix(model, item, "Karan", to: "Kiran")
        let afterFirst = try XCTUnwrap(model.items.first { $0.id == item.id })
        _ = await fix(model, afterFirst, "Priyaa", to: "Priya")
        // No view holds the fix: the model still offers the newest one.
        let newest = try XCTUnwrap(model.undoableFix(for: item.id))
        XCTAssertEqual(newest.correction, "Priya")
        let undoneNewest = await model.undoWordFix(newest)
        XCTAssertTrue(undoneNewest)
        XCTAssertEqual(model.items.first { $0.id == item.id }?.body, "Ask Kiran and Priyaa today")
        let older = try XCTUnwrap(model.undoableFix(for: item.id))
        XCTAssertEqual(older.correction, "Kiran")
        let undoneOlder = await model.undoWordFix(older)
        XCTAssertTrue(undoneOlder)
        XCTAssertNil(model.undoableFix(for: item.id))
        XCTAssertEqual(model.items.first { $0.id == item.id }?.body, "Ask Karan and Priyaa today")
    }

    func testRepeatedFixDoesNotDuplicateTheEntryAndExistingSpellingIsUpdated() async throws {
        let model = try await makeModel()
        let first = await save("Karan one", in: model)
        let second = await save("Karan two", in: model)
        _ = await fix(model, first, "Karan", to: "Kiran")
        _ = await fix(model, second, "Karan", to: "Kiran")
        XCTAssertEqual(model.settings.vocabulary.count, 1)
        guard case .fixed(let applied) = await fix(model, await save("Karan three", in: model), "Karan", to: "KIRAN") else { return XCTFail("Expected a fix") }
        XCTAssertEqual(model.settings.vocabulary.map(\.replacement), ["KIRAN"])
        let undone = await model.undoWordFix(applied)
        XCTAssertTrue(undone)
        XCTAssertEqual(model.settings.vocabulary.map(\.replacement), ["Kiran"])
    }

    func testRejectedFixLeavesTextAndDictionaryUntouched() async throws {
        let model = try await makeModel()
        let item = await save("Nothing to fix here", in: model)
        guard case .rejected(let reason) = await model.fixWord(in: item, wordRange: NSRange(location: 0, length: 7), heard: "missing", correction: "x")
        else { return XCTFail("Expected a rejection") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(model.items.first?.body, "Nothing to fix here")
        XCTAssertTrue(model.settings.vocabulary.isEmpty)
        XCTAssertNil(model.undoableFix(for: item.id))
    }

    func testUndoIsRefusedWhenTextChangedSince() async throws {
        let model = try await makeModel()
        let item = await save("Karan again", in: model)
        guard case .fixed(let applied) = await fix(model, item, "Karan", to: "Kiran") else { return XCTFail("Expected a fix") }
        var edited = try XCTUnwrap(model.items.first)
        edited.body = "Something else entirely"
        _ = await model.persist(edited)
        XCTAssertNil(model.undoableFix(for: item.id))
        let undone = await model.undoWordFix(applied)
        XCTAssertFalse(undone)
        XCTAssertEqual(model.items.first?.body, "Something else entirely")
        XCTAssertEqual(model.settings.vocabulary.count, 1)
    }

    func testDeletingAnItemDropsItsUndo() async throws {
        let model = try await makeModel()
        let item = await save("Karan leaves", in: model)
        _ = await fix(model, item, "Karan", to: "Kiran")
        model.delete(item)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.undoableFix(for: item.id))
        XCTAssertTrue(model.wordFixStacks[item.id] == nil)
    }

    /// Item 5: fix mode is one text view, so a 10,000-word item costs one layout and
    /// hit tests stay local. Measured numbers are printed for the record.
    func testFixModeHandlesATenThousandWordItemWithOneView() throws {
        let words = (0..<10_000).map { "word\($0 % 97)" }
        let body = words.joined(separator: " ")
        let view = FixTextView(usingTextLayoutManager: false)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        let clock = ContinuousClock()
        let layout = clock.measure {
            view.configure(text: body)
            let height = view.height(forWidth: 640)
            view.frame = CGRect(x: 0, y: 0, width: 640, height: height)
        }
        XCTAssertGreaterThan(view.frame.height, 1000, "The text was laid out")
        XCTAssertEqual(view.subviews.count, 0, "No per-word views")
        // Hit-test the first, a middle and the last word.
        var hits: [String] = []
        let hitTime = clock.measure {
            for target in [0, 5_000, 9_999] {
                let range = (body as NSString).range(of: " " + words[target] + (target == 9_999 ? "" : " "))
                let location = target == 0 ? 0 : range.location + 1
                let rect = view.rect(of: NSRange(location: location, length: 4))
                if let found = view.word(at: CGPoint(x: rect.midX, y: rect.midY)) { hits.append((body as NSString).substring(with: found)) }
            }
        }
        XCTAssertEqual(hits, [words[0], words[5_000], words[9_999]])
        let relayout = clock.measure { _ = view.height(forWidth: 641) }
        print("FIXMODE_MEASURED words=10000 first_layout=\(layout) three_hit_tests=\(hitTime) relayout_new_width=\(relayout)")
        XCTAssertLessThan(layout, .seconds(3))
        XCTAssertLessThan(hitTime, .milliseconds(500))
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
