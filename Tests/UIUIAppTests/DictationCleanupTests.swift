import Foundation
import XCTest
import UIUICore
@testable import UIUI

final class DictationCleanupTests: XCTestCase {
    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            if .now >= deadline { XCTFail("Cleanup boundary did not arrive"); throw CleanupFailure.unavailable }
            await Task.yield()
        }
    }

    @MainActor
    func testVeryLongRejectedOutputRetainsBeginningMiddleAndEndExactly() async throws {
        let engine = ControlledCleanupEngine()
        engine.transform = { _ in "only the ending" }
        let cleanup = DictationCleanup(engine: engine, finalBudget: .seconds(2))
        let text = (0..<10_000).map { "word\($0)" }.joined(separator: " ")
        let result = try await cleanup.finish(text, captureID: UUID())
        XCTAssertEqual(result, text)
        XCTAssertGreaterThan(engine.inputs.count, 1)
        XCTAssertTrue(engine.inputs.allSatisfy { $0.utf8.count <= 900 })
    }

    @MainActor
    func testFormattedTranscriptKeepsItsOwnPunctuationWithoutInference() async throws {
        let engine = ControlledCleanupEngine()
        engine.transform = { $0.lowercased() }
        let cleanup = DictationCleanup(engine: engine, finalBudget: .seconds(2))
        let id = UUID()
        let text = "Kal Rahul se baat karo, theek hai? Send the Q3 deck to Priya"
        cleanup.begin(id)
        cleanup.update(text, captureID: id)
        let result = try await cleanup.finish(text, captureID: id)
        XCTAssertEqual(result, DictationPunctuation.finalize(text))
        XCTAssertTrue(engine.inputs.isEmpty)
        // Unformatted text (lowercase, no marks) still goes to the model.
        _ = try await cleanup.finish("send the deck to priya", captureID: UUID())
        XCTAssertEqual(engine.inputs, ["send the deck to priya"])
    }

    @MainActor
    func testExplicitFormattedDecisionOverridesTextShapeAndIsCapturedBeforeDictionary() async throws {
        // The dictionary capitalised an entry in already-lowercase raw speech:
        // the caller decided on the raw text (unformatted), so the model runs.
        let engine = ControlledCleanupEngine()
        let cleanup = DictationCleanup(engine: engine, finalBudget: .seconds(2))
        let id = UUID()
        cleanup.begin(id)
        _ = try await cleanup.finish("send it to Priya", captureID: id, formatted: false)
        XCTAssertEqual(engine.inputs, ["send it to Priya"])

        // Raw text was formatted: the model is skipped even if the text looks bare.
        let skipped = ControlledCleanupEngine()
        let second = DictationCleanup(engine: skipped, finalBudget: .seconds(2))
        let result = try await second.finish("send it to priya", captureID: UUID(), formatted: true)
        XCTAssertTrue(skipped.inputs.isEmpty)
        XCTAssertEqual(result, DictationPunctuation.finalize("send it to priya"))

        // Direct callers without a decision derive it from the text: one capital is enough.
        let direct = ControlledCleanupEngine()
        _ = try await DictationCleanup(engine: direct, finalBudget: .seconds(2)).finish("Send it to priya", captureID: UUID())
        XCTAssertTrue(direct.inputs.isEmpty)
    }

    @MainActor
    func testFinalDeadlineReturnsEveryOriginalChunkWithoutStartingInference() async throws {
        let engine = ControlledCleanupEngine()
        let cleanup = DictationCleanup(engine: engine, finalBudget: .zero)
        let text = String(repeating: "keep every original word ", count: 2_000)
        let result = try await cleanup.finish(text, captureID: UUID())
        XCTAssertEqual(result, text)
        XCTAssertTrue(engine.inputs.isEmpty)
    }

    @MainActor
    func testCompletedPrefixIsReusedAndChangedPrefixCannotReuseOldResult() async throws {
        let engine = ControlledCleanupEngine()
        let cleanup = DictationCleanup(engine: engine, finalBudget: .seconds(2))
        let id = UUID()
        let text = (0..<800).map { "word\($0)" }.joined(separator: " ")
        let segments = DictationCleanupText.segments(for: text, maximumUTF8Bytes: 450)
        cleanup.begin(id)
        cleanup.update(text, captureID: id)
        try await eventually { engine.inputs.count == segments.count - 1 }
        _ = try await cleanup.finish(text, captureID: id)
        XCTAssertEqual(engine.inputs.filter { $0 == segments[0].text }.count,
                       segments.dropLast().filter { $0.text == segments[0].text }.count)
        // Unique source words make an earlier stale cleanup identifiable.
        let revised = "revised " + String(text.dropFirst(5))
        let result = try await cleanup.finish(revised, captureID: id)
        XCTAssertTrue(result.hasPrefix("revised "))
        XCTAssertEqual(words(result), words(revised))
    }

    @MainActor
    func testStableTailIsPreparedAndFinishDoesNotGenerateItAgain() async throws {
        let engine = ControlledCleanupEngine()
        let cleanup = DictationCleanup(engine: engine, tailDelay: .zero)
        let id = UUID(), text = "we should review the build"
        cleanup.begin(id)
        cleanup.update(text, captureID: id)
        try await eventually { engine.inputs.count == 1 }
        let result = try await cleanup.finish(text, captureID: id)
        XCTAssertEqual(result, text + ".")
        XCTAssertEqual(engine.inputs, [text])
    }

    @MainActor
    func testChangedTailCancelsOldPreparationAndUsesOnlyExactSource() async throws {
        let engine = ControlledCleanupEngine(); engine.suspend = true
        let cleanup = DictationCleanup(engine: engine, tailDelay: .zero)
        let id = UUID(), original = "we should review the build", revised = "we should review every change"
        cleanup.begin(id)
        cleanup.update(original, captureID: id)
        try await eventually { engine.pendingCount == 1 }
        let oldCancellation = engine.lastCancellation
        cleanup.update(revised, captureID: id)
        XCTAssertTrue(oldCancellation?.isCancelled == true)
        engine.suspend = false
        let result = try await cleanup.finish(revised, captureID: id)
        engine.completePending()
        XCTAssertEqual(result, revised + ".")
        XCTAssertEqual(engine.inputs, [original, revised])
    }

    @MainActor
    func testRescheduledStableTailOnlyPreparesTheLatestTranscript() async throws {
        let engine = ControlledCleanupEngine()
        let cleanup = DictationCleanup(engine: engine, tailDelay: .zero)
        let id = UUID()
        cleanup.begin(id)
        for index in 0..<100 {
            cleanup.update("keep every word revision \(index)", captureID: id)
        }
        try await eventually { engine.inputs.count == 1 }
        let result = try await cleanup.finish("keep every word revision 99", captureID: id)
        XCTAssertEqual(result, "keep every word revision 99.")
        XCTAssertEqual(engine.inputs, ["keep every word revision 99"])
    }

    @MainActor
    func testContinuousChangesDoNotQueueInferenceBehindActiveTail() async throws {
        let engine = ControlledCleanupEngine(); engine.suspend = true
        let cleanup = DictationCleanup(engine: engine, tailDelay: .zero)
        let id = UUID()
        cleanup.begin(id)
        cleanup.update("keep every word zero", captureID: id)
        try await eventually { engine.pendingCount == 1 }
        var latest = ""
        for index in 1...100 {
            latest = "keep every word revision \(index)"
            cleanup.update(latest, captureID: id)
        }
        XCTAssertEqual(engine.inputs.count, 1)
        XCTAssertEqual(engine.pendingCount, 1)
        engine.suspend = false
        engine.completePending()
        try await eventually { engine.inputs.count == 2 }
        let result = try await cleanup.finish(latest, captureID: id)
        XCTAssertEqual(result, latest + ".")
        XCTAssertEqual(engine.inputs.last, latest)
        XCTAssertEqual(engine.inputs.count, 2)
    }

    @MainActor
    func testFinishReusesExactInFlightPrefixWithoutLaunchingMoreBackgroundWork() async throws {
        let engine = ControlledCleanupEngine(); engine.suspend = true
        let cleanup = DictationCleanup(engine: engine)
        let id = UUID()
        let text = (0..<150).map { "word\($0)" }.joined(separator: " ")
        let segments = DictationCleanupText.segments(for: text, maximumUTF8Bytes: 450)
        cleanup.begin(id)
        cleanup.update(text, captureID: id)
        try await eventually { engine.pendingCount == 1 }
        let activeCancellation = engine.lastCancellation
        var finishStarted = false
        let finish = Task { finishStarted = true; return try await cleanup.finish(text, captureID: id) }
        try await eventually { finishStarted }
        XCTAssertFalse(activeCancellation?.isCancelled ?? true)
        XCTAssertEqual(engine.inputs.count, 1)
        engine.suspend = false
        engine.completePending()
        let result = try await finish.value
        XCTAssertEqual(words(result), words(text))
        XCTAssertEqual(engine.inputs, segments.map(\.text))
    }

    @MainActor
    func testInFlightReuseConsumesTheSameFinalBudget() async throws {
        let engine = ControlledCleanupEngine(); engine.suspend = true
        let cleanup = DictationCleanup(engine: engine, finalBudget: .zero)
        let id = UUID()
        let text = (0..<150).map { "word\($0)" }.joined(separator: " ")
        cleanup.begin(id)
        cleanup.update(text, captureID: id)
        try await eventually { engine.pendingCount == 1 }
        let activeCancellation = engine.lastCancellation
        let finish = Task { try await cleanup.finish(text, captureID: id) }
        try await eventually { activeCancellation?.isCancelled == true }
        engine.completePending()
        let result = try await finish.value
        XCTAssertEqual(result, DictationPunctuation.finalize(text))
        XCTAssertEqual(engine.inputs.count, 1)
    }

    @MainActor
    func testCancellingFinishImmediatelyCancelsReusedNativeOperation() async throws {
        let engine = ControlledCleanupEngine(); engine.suspend = true
        let cleanup = DictationCleanup(engine: engine, finalBudget: .seconds(60), tailDelay: .zero)
        let id = UUID(), text = "keep every original word"
        cleanup.begin(id)
        cleanup.update(text, captureID: id)
        try await eventually { engine.pendingCount == 1 }
        let activeCancellation = engine.lastCancellation
        var finishStarted = false
        let finish = Task { finishStarted = true; return try await cleanup.finish(text, captureID: id) }
        // On the main actor, the start flag is visible after finish suspends on
        // the already-running operation, with no wall-clock delay in the test.
        try await eventually { finishStarted }
        XCTAssertFalse(activeCancellation?.isCancelled ?? true)
        finish.cancel()
        try await eventually { activeCancellation?.isCancelled == true }
        engine.completePending()
        do { _ = try await finish.value; XCTFail("Cancelled reuse returned text") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation result") }
        XCTAssertEqual(engine.inputs.count, 1)
    }

    func testCancellationDeadlineCanOnlyBeShortened() {
        let cancellation = CleanupCancellation()
        cancellation.shortenDeadline(to: .now.advanced(by: .seconds(60)))
        XCTAssertFalse(cancellation.isCancelled)
        cancellation.shortenDeadline(to: .now)
        XCTAssertTrue(cancellation.isCancelled)
        cancellation.shortenDeadline(to: .now.advanced(by: .seconds(120)))
        XCTAssertTrue(cancellation.isCancelled)
    }

    @MainActor
    func testCancellationRejectsLateCompletionWithoutRevivingTheCapture() async throws {
        let engine = ControlledCleanupEngine(); engine.suspend = true
        let cleanup = DictationCleanup(engine: engine)
        let work = Task { try await cleanup.finish("can you check the build", captureID: UUID()) }
        try await eventually { engine.pendingCount == 1 }
        cleanup.cancel()
        XCTAssertTrue(engine.lastCancellation?.isCancelled == true)
        engine.completePending()
        do { _ = try await work.value; XCTFail("Cancelled cleanup returned text") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation result") }
    }

    @MainActor
    func testNewCaptureCannotBeOverwrittenByOldModelCompletion() async throws {
        let engine = ControlledCleanupEngine(); engine.suspend = true
        let cleanup = DictationCleanup(engine: engine)
        let old = Task { try await cleanup.finish("old words must not return", captureID: UUID()) }
        try await eventually { engine.pendingCount == 1 }
        let newID = UUID(); cleanup.begin(newID)
        engine.suspend = false
        let newest = try await cleanup.finish("the new capture is ready", captureID: newID)
        engine.completePending()
        do { _ = try await old.value; XCTFail("Old capture returned after replacement") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation result") }
        XCTAssertEqual(newest, "the new capture is ready.")
    }

    @MainActor
    func testUnavailableModelAndStructuredTextNeverWaitForLoading() async throws {
        let engine = ControlledCleanupEngine(); engine.ready = false
        let cleanup = DictationCleanup(engine: engine)
        let fallback = try await cleanup.finish("can you check it", captureID: UUID())
        XCTAssertEqual(fallback, "can you check it?")
        XCTAssertEqual(engine.prepareCalls, 0)
        engine.ready = true
        let literal = try await cleanup.finish("git status", captureID: UUID())
        XCTAssertEqual(literal, "git status")
        XCTAssertTrue(engine.inputs.isEmpty)
    }


    @MainActor
    func testShutdownWaitsForNativeDisposalBeforeReturning() async throws {
        let engine = ControlledCleanupEngine(); engine.suspendShutdown = true
        let cleanup = DictationCleanup(engine: engine)
        var returned = false
        let work = Task { await cleanup.shutdown(); returned = true }
        try await eventually { engine.shutdownPending != nil }
        XCTAssertFalse(returned)
        engine.shutdownPending?.resume(); engine.shutdownPending = nil
        await work.value
        XCTAssertTrue(returned)
    }

    private func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
    }
}

private final class ControlledCleanupEngine: CleanupGenerating, @unchecked Sendable {
    private let lock = NSLock()
    var ready = true
    var suspend = false
    var suspendShutdown = false
    var shutdownPending: CheckedContinuation<Void, Never>?
    var transform: @Sendable (String) -> String = { $0 + "." }
    private var requests: [String] = []
    private var waiting: [(String, CheckedContinuation<String, Error>)] = []
    private var cancellation: CleanupCancellation?
    private(set) var prepareCalls = 0
    var isReady: Bool { ready }
    var inputs: [String] { lock.withLock { requests } }
    var pendingCount: Int { lock.withLock { waiting.count } }
    var lastCancellation: CleanupCancellation? { lock.withLock { cancellation } }
    func prepare() async { prepareCalls += 1 }
    func release() { ready = false }
    func shutdown() async {
        release()
        if suspendShutdown { await withCheckedContinuation { shutdownPending = $0 } }
    }
    func generate(_ text: String, cancellation: CleanupCancellation) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let hold = lock.withLock { () -> Bool in
                requests.append(text); self.cancellation = cancellation
                if suspend { waiting.append((text, continuation)); return true }
                return false
            }
            if !hold { continuation.resume(returning: transform(text)) }
        }
    }
    func completePending() {
        let work = lock.withLock { let work = waiting; waiting.removeAll(); return work }
        for (text, continuation) in work { continuation.resume(returning: transform(text)) }
    }
}
