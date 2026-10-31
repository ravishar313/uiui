import Dispatch
import Foundation
import UIUICore
import XCTest
@testable import UIUI

/// These tests substitute only bounded tensor computation. They do not load
/// model weights, create UI, or touch the installed application's library.
final class MiniLMInferenceBoundaryTests: XCTestCase {
    func testRepeatedNormalizedWordsReuseEncodingOnlyWithinTheRequest() throws {
        let inference = BoundaryInference()
        let runtime = MiniLMFormattingRuntime(inference: inference)
        for _ in 0..<2 {
            XCTAssertEqual(try runtime.generate("hello HELLO hello", check: {}), "Hello hello hello?")
        }
        XCTAssertEqual(inference.encodedInputs,
                       ["hello", "hello hello hello", "hello", "hello hello hello"],
                       "Repeated words share IDs, but the next request must encode its own inputs")
        XCTAssertEqual(inference.predictionCount, 2)
    }

    func testOneWordChunkUsesItsExactExistingEncoding() throws {
        let inference = BoundaryInference()
        let result = try MiniLMFormattingRuntime(inference: inference).generate("hello", check: {})
        XCTAssertEqual(result, "Hello?")
        XCTAssertEqual(inference.encodedInputs, ["hello"])
        XCTAssertEqual(inference.predictionCount, 1)
    }

    func testRepeatedWordsAcrossOverlappingWindowsKeepJoinedAlignmentChecks() throws {
        let source = [String](repeating: "hello", count: 180).joined(separator: " ")
        let inference = BoundaryInference()
        let result = try MiniLMFormattingRuntime(inference: inference).generate(source, check: {})
        XCTAssertEqual(result, "Hello " + [String](repeating: "hello", count: 179).joined(separator: " ") + "?")
        XCTAssertEqual(inference.predictionCount, 2)
        XCTAssertEqual(inference.encodedInputs.map { $0.split(separator: " ").count }, [1, 126, 102],
                       "Each overlapping multiword window must verify its own joined encoding")
    }

    func testJoinedTokenMismatchStillFallsBackAfterWordReuse() throws {
        let inference = BoundaryInference()
        inference.corruptJoinedEncoding = true
        let source = "hello  HELLO hello"
        XCTAssertEqual(try MiniLMFormattingRuntime(inference: inference).generate(source, check: {}), source)
        XCTAssertEqual(inference.encodedInputs, ["hello", "hello hello hello"])
        XCTAssertEqual(inference.predictionCount, 0, "Misaligned word-final offsets must never reach prediction")
    }

    func testCancellationStopsBeforeReusingTheNextWordEncoding() throws {
        let inference = BoundaryInference()
        let cancellation = CleanupCancellation()
        inference.afterEncoding = { cancellation.cancel() }
        XCTAssertThrowsError(try MiniLMFormattingRuntime(inference: inference).generate("hello hello hello", check: {
            if cancellation.isCancelled { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(inference.encodedInputs, ["hello"])
        XCTAssertEqual(inference.predictionCount, 0)
    }

    func testMalformedSecondWindowCannotCommitAnAlreadyFormattedPrefix() throws {
        // More than one context window matters: returning an attractive first
        // window must never authorize dropping or partially cleaning the rest.
        let source = "start\t" + (0..<180).map { "word\($0)" }.joined(separator: "  ") + "\nfinal  "
        for corruption in [BoundaryInference.Corruption.tooShort, .tooLong, .nan, .infinity, .failure] {
            let inference = BoundaryInference()
            inference.corruption = corruption
            inference.corruptPrediction = 2
            let runtime = MiniLMFormattingRuntime(inference: inference)
            let result = try runtime.generate(source, check: {})
            XCTAssertGreaterThanOrEqual(inference.predictionCount, 2, "Fixture must reach the failing window")
            XCTAssertEqual(result, source, "\(corruption) must preserve the complete original, including spacing and tail")
        }
    }

    func testValidFormattingTagsCannotRewriteProtectedSourceSpans() throws {
        let inference = BoundaryInference()
        let runtime = MiniLMFormattingRuntime(inference: inference)
        let source = "can\tOpenAI keep iPhone build-42 and 1,000 don't-change items"
        // URLs and decimal literals deliberately bypass model cleanup. These
        // lexical spans are admitted, so this must exercise reconstruction.
        _ = try XCTUnwrap(DictationCleanupText.accepted(source, for: source))
        let result = try runtime.generate(source, check: {})
        XCTAssertEqual(inference.predictionCount, 1)
        XCTAssertEqual(result, "Can\tOpenAI keep iPhone build-42 and 1,000 don't-change items?")
        XCTAssertNotEqual(result, source, "The fixture must exercise formatting rather than only the fallback")
        XCTAssertNotNil(DictationCleanupText.accepted(result, for: source))
    }

    func testCancellationRaisedDuringBackendComputationEscapesInsteadOfBecomingFallback() throws {
        let inference = BoundaryInference()
        let cancellation = CleanupCancellation()
        inference.afterComputation = { cancellation.cancel() }
        let runtime = MiniLMFormattingRuntime(inference: inference)
        XCTAssertThrowsError(try runtime.generate("keep the complete original", check: {
            if cancellation.isCancelled { throw CancellationError() }
        })) { error in
            XCTAssertTrue(error is CancellationError, "Cancellation must not turn into successful source fallback")
        }
        XCTAssertEqual(inference.predictionCount, 1)
    }

    func testSerialEngineRejectsLateNativeResultAndCanServeTheNextCapture() async throws {
        let inference = BoundaryInference()
        let engine = MiniLMCleanupEngine(inferenceFactory: { inference })
        await engine.prepare()
        guard engine.isReady else {
            await engine.shutdown()
            XCTFail("Injected model-free backend should prepare successfully")
            return
        }
        let entered = expectation(description: "native computation entered")
        let resume = DispatchSemaphore(value: 0)
        inference.armBarrier(entered: { entered.fulfill() }, resume: resume)
        let cancellation = CleanupCancellation()
        let request = Task { try await engine.generate("keep every original word", cancellation: cancellation) }
        await fulfillment(of: [entered], timeout: 2)
        // Native computation deliberately ignores cancellation until it returns.
        // This models a GPU/ORT call that cannot be interrupted mid-kernel.
        cancellation.cancel()
        resume.signal()
        do {
            _ = try await request.value
            XCTFail("A completed native result must not cross a cancelled capture boundary")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            XCTAssertTrue(engine.isReady, "Cancelling a capture should not destroy the prepared backend")
            let next = try await engine.generate("keep the next capture", cancellation: CleanupCancellation())
            XCTAssertEqual(next, "Keep the next capture?")
        } catch {
            await engine.shutdown()
            throw error
        }
        await engine.shutdown()
        XCTAssertFalse(engine.isReady)
    }


}

/// Small deterministic test vocabulary: one piece per whitespace-delimited
/// word, stable between isolated and joined encodes. No production tokenizer or
/// encoder algorithm is copied; only the inference seam's tensor shape is faked.
private final class BoundaryInference: MiniLMWindowInference, @unchecked Sendable {
    enum Corruption { case tooShort, tooLong, nan, infinity, failure }
    private struct Barrier {
        let entered: () -> Void
        let resume: DispatchSemaphore
    }
    private let lock = NSLock()
    private var barrier: Barrier?
    private var predictions = 0
    private var encodings: [String] = []
    var encodedInputs: [String] { lock.withLock { encodings } }
    var corruptJoinedEncoding = false
    var afterEncoding: (() -> Void)?
    var corruption: Corruption?
    var corruptPrediction = 1
    var afterComputation: (() -> Void)?
    var predictionCount: Int { lock.withLock { predictions } }

    func armBarrier(entered: @escaping () -> Void, resume: DispatchSemaphore) {
        lock.withLock { barrier = Barrier(entered: entered, resume: resume) }
    }

    func encode(_ text: String, check: () throws -> Void) throws -> [Int64] {
        lock.withLock { encodings.append(text) }
        var ids = text.split(whereSeparator: \.isWhitespace).map { word in
            Int64(word.utf8.reduce(17) { ($0 * 31 + Int($1)) % 30_000 } + 4)
        }
        if corruptJoinedEncoding && text.contains(" ") { ids.append(4) }
        afterEncoding?()
        return ids
    }

    func predict(_ ids: [Int64], check: () throws -> Void) throws -> [Float] {
        let state = lock.withLock { () -> (Int, Barrier?) in
            predictions += 1
            let blocked = barrier
            barrier = nil
            return (predictions, blocked)
        }
        if let blocked = state.1 {
            blocked.entered()
            guard blocked.resume.wait(timeout: .now() + 5) == .success else { throw CleanupFailure.unavailable }
        }
        var logits = [Float](repeating: -10, count: ids.count * 8)
        for token in ids.indices {
            // One strong punctuation/casing label per token. The first source
            // word is capitalized and the final source word gets a question.
            logits[token * 8 + (token == ids.count - 2 ? 3 : 0)] = 10
            logits[token * 8 + 5 + (token == 1 ? 1 : 0)] = 10
        }
        afterComputation?()
        if state.0 == corruptPrediction, let corruption {
            switch corruption {
            case .tooShort: logits.removeLast()
            case .tooLong: logits.append(0)
            case .nan: logits[0] = .nan
            case .infinity: logits[0] = .infinity
            case .failure: throw CleanupFailure.unavailable
            }
        }
        return logits
    }
}
