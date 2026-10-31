import Foundation
import XCTest
@testable import UIUI

final class PhononVocabularySessionTests: XCTestCase {
    func testCaptureVocabularyReplacesAndClearsOnTheSameWarmNativeModel() async throws {
        guard #available(macOS 15.0, *) else { return }
        let fixture = VocabularyNativeFixture()
        let model = fixture.makeModel()
        let pool = ReadySpeechModelPool(factory: { model }, reset: { try await $0.reset() }, dispose: { await $0.dispose() })
        try await pool.warm()
        for words in [["GlobalSpelling", "PersonalSpelling"], ["GlobalSpelling", "ResearchSpelling"], []] {
            let decoder = PhononStreamingDecoder(vocabulary: words, modelLease: lease(pool))
            try await decoder.loadModel(from: PhononSpeechModel.directory)
            XCTAssertEqual(fixture.activeWords, words)
            let final = try await decoder.finish()
            XCTAssertEqual(final, "") // No audio or inference is required to prepare/return a session.
            XCTAssertEqual(fixture.activeWords, [], "Idle warm models must retain no previous capture vocabulary")
            await decoder.cleanup()
        }
        XCTAssertEqual(fixture.configurations, [["GlobalSpelling", "PersonalSpelling"], [],
                                              ["GlobalSpelling", "ResearchSpelling"], [], [], []])
        XCTAssertEqual(fixture.resetConfigurations, fixture.configurations,
                       "Vocabulary must be configured before resetting each capture or idle model")
        XCTAssertFalse(fixture.ranOnMain)
        await pool.clear()
    }

    func testCancelledPreparationCannotReturnOrReconfigureModelUntilNativeWorkDrains() async throws {
        guard #available(macOS 15.0, *) else { return }
        let entered = expectation(description: "Native vocabulary configuration entered")
        let release = DispatchSemaphore(value: 0)
        let fixture = VocabularyNativeFixture(beforeConfigure: { words in
            guard !words.isEmpty else { return }
            entered.fulfill()
            release.wait() // A native configuration may finish after cancellation.
        })
        let model = fixture.makeModel()
        let pool = ReadySpeechModelPool(factory: { model }, reset: { try await $0.reset() }, dispose: { await $0.dispose() })
        let decoder = PhononStreamingDecoder(vocabulary: ["PreviousProject"], modelLease: lease(pool))
        let preparing = Task { try await decoder.loadModel(from: PhononSpeechModel.directory) }
        await fulfillment(of: [entered], timeout: 2)
        preparing.cancel()
        await decoder.cleanup()
        XCTAssertTrue(fixture.configurations.isEmpty, "Cleanup cannot reset while native configuration still owns the lease")
        release.signal()
        do { try await preparing.value; XCTFail("Cancelled preparation must reject native completion") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.configurations, [["PreviousProject"], []])
        XCTAssertEqual(fixture.activeWords, [])
        // A subsequent capture with no dictionary must prepare and finish on
        // the same reusable instance, with no stale previous-project context.
        let next = PhononStreamingDecoder(modelLease: lease(pool))
        try await next.loadModel(from: PhononSpeechModel.directory)
        XCTAssertEqual(fixture.activeWords, [])
        _ = try await next.finish()
        await pool.clear()
    }

    func testDecoderKeepsAnImmutableBoundedSnapshotWithoutChangingSpellings() async throws {
        guard #available(macOS 15.0, *) else { return }
        var words = ["Muesli", "Lauki", "", String(repeating: "x", count: 257)]
        let decoder = try XCTUnwrap(LocalSpeechModel.makeDecoder(vocabulary: words) as? PhononStreamingDecoder)
        words[0] = "ChangedAfterCapture"
        let snapshot = await decoder.vocabulary
        XCTAssertEqual(snapshot, ["Muesli", "Lauki"])
        let many = PhononStreamingDecoder(vocabulary: Array(repeating: "word", count: 101))
        let count = await many.vocabulary.count
        XCTAssertEqual(count, 100)
        let large = PhononStreamingDecoder(vocabulary: Array(repeating: String(repeating: "a", count: 256), count: 100))
        let bytes = await large.vocabulary.reduce(0) { $0 + $1.utf8.count }
        XCTAssertEqual(bytes, 8_192)
        let empty = try XCTUnwrap(LocalSpeechModel.makeDecoder() as? PhononStreamingDecoder)
        let defaults = await empty.vocabulary
        XCTAssertTrue(defaults.isEmpty)
    }

    @available(macOS 15.0, *)
    private func lease(_ pool: ReadySpeechModelPool<PhononNativeModel>) -> ExclusiveSpeechModelLease<PhononNativeModel> {
        ExclusiveSpeechModelLease(checkOut: { try await pool.checkOut() }, checkIn: { await pool.checkIn($0) })
    }
}

private final class VocabularyNativeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [String] = []
    private var history: [[String]] = []
    private var resetHistory: [[String]] = []
    private var mainThread = false
    private let beforeConfigure: ([String]) -> Void

    init(beforeConfigure: @escaping ([String]) -> Void = { _ in }) { self.beforeConfigure = beforeConfigure }
    var activeWords: [String] { lock.withLock { words } }
    var configurations: [[String]] { lock.withLock { history } }
    var resetConfigurations: [[String]] { lock.withLock { resetHistory } }
    var ranOnMain: Bool { lock.withLock { mainThread } }

    @available(macOS 15.0, *)
    func makeModel() -> PhononNativeModel {
        PhononNativeModel(operations: PhononNativeOperations(
            configureVocabulary: { [self] words in
                beforeConfigure(words)
                lock.withLock { self.words = words; history.append(words); mainThread = mainThread || Thread.isMainThread }
            },
            reset: { [self] in lock.withLock { resetHistory.append(words) } }, speechProbability: { _ in 0 },
            transcribe: { _ in XCTFail("These session tests must never run inference"); return "" }))
    }
}
