import Foundation
import XCTest
@testable import UIUI

final class ParakeetModelPoolTests: XCTestCase {
    func testConsecutiveLeasesReuseOneLoadedModelAfterClearingSessionState() async throws {
        let factory = PoolModelFactory()
        let pool = makePool(factory)
        let first = try await pool.checkOut()
        first.setText("previous session")
        await pool.checkIn(first)
        let second = try await pool.checkOut()
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.text, "")
        let count = await factory.loadCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(first.resetCount, 1)
        await pool.checkIn(second)
        await pool.clear()
        XCTAssertEqual(first.disposeCount, 1)
    }

    func testLeasedModelCannotBeCheckedOutAgainAndWarmDoesNotLoadAnotherIdleModel() async throws {
        let factory = PoolModelFactory()
        let pool = makePool(factory)
        let first = try await pool.checkOut()
        await pool.warmIgnoringFailure()
        let countAfterWarm = await factory.loadCount
        XCTAssertEqual(countAfterWarm, 1)
        let second = try await pool.checkOut()
        XCTAssertFalse(first === second)
        await pool.checkIn(first)
        await pool.checkIn(second)
        XCTAssertEqual(second.disposeCount, 1, "Only one idle model may be retained")
        let third = try await pool.checkOut()
        XCTAssertTrue(third === first)
        await pool.checkIn(third)
        await pool.clear()
    }

    func testConcurrentWarmersShareOneInitialization() async throws {
        let entered = expectation(description: "One cold load started")
        let gate = ModelPoolTestGate(onWait: { entered.fulfill() })
        let factory = PoolModelFactory(firstLoadGate: gate)
        let pool = makePool(factory)
        let first = Task { try await pool.warm() }
        await fulfillment(of: [entered], timeout: 2)
        let joined = expectation(description: "Second warm caller joins")
        let second = Task { joined.fulfill(); try await pool.warm() }
        await fulfillment(of: [joined], timeout: 2)
        await gate.release()
        try await first.value
        try await second.value
        let model = try await pool.checkOut()
        let count = await factory.loadCount
        XCTAssertEqual(count, 1)
        await pool.checkIn(model)
        await pool.clear()
    }

    func testClearEvictsIdleAndFencesAnOlderLeasedReturn() async throws {
        let factory = PoolModelFactory()
        let pool = makePool(factory)
        let idle = try await pool.checkOut()
        await pool.checkIn(idle)
        await pool.clear() // Same path used for warning/critical memory pressure.
        XCTAssertEqual(idle.disposeCount, 1)
        let active = try await pool.checkOut()
        await pool.clear()
        await pool.checkIn(active)
        XCTAssertEqual(active.disposeCount, 1, "A lease from before clear must not refill the cache")
        let replacement = try await pool.checkOut()
        XCTAssertFalse(replacement === active)
        await pool.checkIn(replacement)
        await pool.clear()
    }

    func testClearWhileWarmIsLoadingDisposesItsLateCompletion() async throws {
        let entered = expectation(description: "Cold load suspended")
        let gate = ModelPoolTestGate(onWait: { entered.fulfill() })
        let factory = PoolModelFactory(firstLoadGate: gate)
        let pool = makePool(factory)
        let warming = Task { try await pool.warm() }
        await fulfillment(of: [entered], timeout: 2)
        await pool.clear()
        await gate.release()
        try await warming.value // Fake factory deliberately ignores cancellation.
        let loaded = await factory.models
        XCTAssertEqual(loaded.first?.disposeCount, 1)
        let next = try await pool.checkOut()
        XCTAssertFalse(next === loaded.first)
        let count = await factory.loadCount
        XCTAssertEqual(count, 2)
        await pool.checkIn(next)
        await pool.clear()
    }

    func testNewCheckoutAfterClearRetriesInsteadOfInheritingOldWarmCancellation() async throws {
        let entered = expectation(description: "Old warm load is suspended")
        let gate = ModelPoolTestGate(onWait: { entered.fulfill() })
        let factory = PoolModelFactory(firstLoadGate: gate, throwsWhenCancelled: true)
        let pool = makePool(factory)
        let warming = Task { try await pool.warm() }
        await fulfillment(of: [entered], timeout: 2)
        await pool.clear()
        let checkout = Task { try await pool.checkOut() }
        await gate.release()
        _ = try? await warming.value
        let model = try await checkout.value
        let loaded = await factory.models
        let count = await factory.loadCount
        XCTAssertEqual(count, 2)
        XCTAssertFalse(model === loaded.first)
        XCTAssertEqual(loaded.first?.disposeCount, 1)
        await pool.checkIn(model)
        await pool.clear()
    }

    func testCancelledDelayedWarmCannotStartLoadingAfterClear() async throws {
        let entered = expectation(description: "Old warm task is delayed before actor entry")
        let gate = ModelPoolTestGate(onWait: { entered.fulfill() })
        let factory = PoolModelFactory()
        let pool = makePool(factory)
        let stale = Task {
            await gate.wait()
            do { try await pool.warm(); return false }
            catch is CancellationError { return true }
            catch { XCTFail("Unexpected error: \(error)"); return false }
        }
        await fulfillment(of: [entered], timeout: 2)
        await pool.clear()
        stale.cancel()
        await gate.release()
        let rejected = await stale.value
        XCTAssertTrue(rejected)
        let count = await factory.loadCount
        XCTAssertEqual(count, 0)
    }

    func testCancelledDelayedClearCannotEvictANewerReadyModel() async throws {
        let entered = expectation(description: "Old clear task is delayed before actor entry")
        let gate = ModelPoolTestGate(onWait: { entered.fulfill() })
        let factory = PoolModelFactory()
        let pool = makePool(factory)
        let stale = Task { await gate.wait(); await pool.clear() }
        await fulfillment(of: [entered], timeout: 2)
        try await pool.warm()
        let models = await factory.models
        stale.cancel()
        await gate.release()
        await stale.value
        let ready = try await pool.checkOut()
        XCTAssertTrue(ready === models.first)
        XCTAssertEqual(ready.disposeCount, 0)
        let count = await factory.loadCount
        XCTAssertEqual(count, 1)
        await pool.checkIn(ready)
        await pool.clear()
    }

    func testSuccessfulFinishReturnsResetModelBeforeNextCaptureAndLateCleanupCannotResetNewLease() async throws {
        let factory = PoolModelFactory()
        let pool = makePool(factory)
        let lease = makeLease(pool)
        try await lease.load()
        let result = try await lease.withModel(finishing: true) { model in
            model.setText("final words")
            return model.text
        }
        XCTAssertEqual(result, "final words")
        let next = try await pool.checkOut()
        let count = await factory.loadCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(next.text, "")
        next.setText("new capture")
        await lease.close()
        XCTAssertEqual(next.text, "new capture")
        XCTAssertEqual(next.resetCount, 1)
        await pool.checkIn(next)
        await pool.clear()
    }

    func testCancellationDuringPredictionCannotReturnOrResetModelUntilOldOperationEnds() async throws {
        let factory = PoolModelFactory()
        let pool = makePool(factory)
        let lease = makeLease(pool)
        try await lease.load()
        let loadedModels = await factory.models
        let first = try XCTUnwrap(loadedModels.first)
        let entered = expectation(description: "Old native operation is in flight")
        let gate = ModelPoolTestGate(onWait: { entered.fulfill() })
        let operation = Task {
            do {
                _ = try await lease.withModel { model in
                    model.beginOperation()
                    await gate.wait()
                    model.setText("late old prediction")
                    model.endOperation()
                    return model.text
                }
                return false
            } catch is CancellationError { return true }
            catch { XCTFail("Unexpected error: \(error)"); return false }
        }
        await fulfillment(of: [entered], timeout: 2)
        await lease.close()
        XCTAssertEqual(first.resetCount, 0)
        XCTAssertEqual(first.disposeCount, 0)
        let next = try await pool.checkOut()
        XCTAssertFalse(first === next)
        next.setText("new capture words")
        await gate.release()
        let cancelled = await operation.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(first.resetCount, 1)
        XCTAssertFalse(first.wasResetDuringOperation)
        XCTAssertEqual(next.text, "new capture words")
        await pool.checkIn(next)
        await pool.clear()
    }

    func testCancellationDuringLoadReturnsModelOnlyAfterLoadCompletes() async throws {
        let entered = expectation(description: "Load is suspended")
        let gate = ModelPoolTestGate(onWait: { entered.fulfill() })
        let factory = PoolModelFactory(firstLoadGate: gate)
        let pool = makePool(factory)
        let lease = makeLease(pool)
        let loading = Task {
            do { try await lease.load(); return false }
            catch is CancellationError { return true }
            catch { XCTFail("Unexpected error: \(error)"); return false }
        }
        await fulfillment(of: [entered], timeout: 2)
        await lease.close()
        await gate.release()
        let cancelled = await loading.value
        XCTAssertTrue(cancelled)
        let next = try await pool.checkOut()
        let count = await factory.loadCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(next.resetCount, 1)
        await pool.checkIn(next)
        await pool.clear()
    }

    private func makePool(_ factory: PoolModelFactory) -> ReadySpeechModelPool<PoolTestModel> {
        ReadySpeechModelPool(factory: { try await factory.make() }, reset: { $0.reset() }, dispose: { $0.dispose() })
    }
    private func makeLease(_ pool: ReadySpeechModelPool<PoolTestModel>) -> ExclusiveSpeechModelLease<PoolTestModel> {
        ExclusiveSpeechModelLease(checkOut: { try await pool.checkOut() }, checkIn: { await pool.checkIn($0) })
    }
}

private extension ReadySpeechModelPool {
    func warmIgnoringFailure() async { try? await warm() }
}
private final class PoolTestModel: @unchecked Sendable {
    private let lock = NSLock()
    private var storedText = ""
    private var resets = 0
    private var disposals = 0
    private var operations = 0
    private var resetDuringOperation = false
    var text: String { lock.withLock { storedText } }
    var resetCount: Int { lock.withLock { resets } }
    var disposeCount: Int { lock.withLock { disposals } }
    var wasResetDuringOperation: Bool { lock.withLock { resetDuringOperation } }
    func setText(_ text: String) { lock.withLock { storedText = text } }
    func beginOperation() { lock.withLock { operations += 1 } }
    func endOperation() { lock.withLock { operations -= 1 } }
    func reset() {
        lock.withLock {
            resetDuringOperation = resetDuringOperation || operations > 0
            storedText = ""; resets += 1
        }
    }
    func dispose() { lock.withLock { disposals += 1 } }
}
private actor PoolModelFactory {
    private(set) var models: [PoolTestModel] = []
    private(set) var loadCount = 0
    private let firstLoadGate: ModelPoolTestGate?
    private let throwsWhenCancelled: Bool
    init(firstLoadGate: ModelPoolTestGate? = nil, throwsWhenCancelled: Bool = false) {
        self.firstLoadGate = firstLoadGate; self.throwsWhenCancelled = throwsWhenCancelled
    }
    func make() async throws -> PoolTestModel {
        loadCount += 1
        let first = loadCount == 1
        let model = PoolTestModel()
        models.append(model)
        if first, let firstLoadGate { await firstLoadGate.wait() }
        if throwsWhenCancelled, Task.isCancelled { model.dispose(); throw CancellationError() }
        return model
    }
}
private actor ModelPoolTestGate {
    private let onWait: () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    init(onWait: @escaping () -> Void) { self.onWait = onWait }
    func wait() async { await withCheckedContinuation { continuation = $0; onWait() } }
    func release() { continuation?.resume(); continuation = nil }
}
