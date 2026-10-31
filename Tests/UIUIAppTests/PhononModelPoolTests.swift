import Foundation
import XCTest
@testable import UIUI

final class PhononModelPoolTests: XCTestCase {
    func testExclusiveCheckoutWaitsForReturnAndCancelledWaiterCannotBlockLaterCapture() async throws {
        let gate = PhononExclusiveCheckoutGate()
        let oldCapture = try await gate.acquire()
        let cancelled = Task { try await gate.acquire() }
        try await waitForWaiters(gate, count: 1)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("A queued cancelled checkout must fail promptly") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await waitForWaiters(gate, count: 0)

        let nextCapture = Task { try await gate.acquire() }
        try await waitForWaiters(gate, count: 1)
        // The old capture keeps ownership while its cancelled native operation
        // and pool reset drain. Only its eventual checkIn releases this ticket.
        await gate.release(UUID())
        let stillWaiting = await gate.waitingCount
        XCTAssertEqual(stillWaiting, 1, "An unrelated or duplicate return cannot unlock the native model")
        await gate.release(oldCapture)
        let nextTicket = try await nextCapture.value
        XCTAssertNotEqual(nextTicket, oldCapture)
        await gate.release(oldCapture)
        let thirdCapture = Task { try await gate.acquire() }
        try await waitForWaiters(gate, count: 1)
        await gate.release(nextTicket)
        let thirdTicket = try await thirdCapture.value
        await gate.release(thirdTicket)
    }

    func testCancelledQueuedNativeJobNeverExecutesAndExecutorRunsOffMain() async throws {
        let executor = PhononSerialExecutor()
        let started = expectation(description: "Private serial queue has active work")
        let queued = expectation(description: "Second task entered")
        let gate = DispatchSemaphore(value: 0)
        let first = Task {
            try await executor.perform { _ in
                started.fulfill()
                gate.wait()
                return Thread.isMainThread
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let counter = PhononTestCounter()
        let second = Task {
            queued.fulfill()
            return try await executor.perform { _ in counter.increment(); return true }
        }
        await fulfillment(of: [queued], timeout: 2)
        second.cancel()
        gate.signal()
        let ranOnMain = try await first.value
        XCTAssertFalse(ranOnMain)
        do { _ = try await second.value; XCTFail("A cancelled native job must not publish a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(counter.value, 0)
    }

    func testCancellationWhileNativeJobIsActiveRejectsLateResult() async throws {
        let executor = PhononSerialExecutor()
        let started = expectation(description: "Native call entered")
        let gate = DispatchSemaphore(value: 0)
        let operation = Task {
            try await executor.perform { _ in
                started.fulfill()
                gate.wait() // Simulates a native kernel which cannot be preempted.
                return "late result"
            }
        }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        gate.signal()
        do { _ = try await operation.value; XCTFail("Cancellation must fence a late native result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let next = try await executor.perform { _ in "new capture" }
        XCTAssertEqual(next, "new capture")
    }

    func testSessionDescriptorUsesInjectedReadinessDirectoryAndStatusWithoutMicrophone() async throws {
        let directory = URL(fileURLWithPath: "/tmp/uiui-phonon-fixture", isDirectory: true)
        let decoder = PhononDescriptorDecoder()
        let configuration = SpeechAudioConfiguration(locale: "en-IN", vocabulary: [], reportLevels: false,
                                                     onRecognition: { _ in }, onLevel: { _ in })
        let descriptor = SpeechModelSessionDescriptor(directory: directory, isInstalled: { true },
                                                     modelDescription: "Fixture speech", setupMessage: "Fixture setup")
        let session = ParakeetSpeechAudioSession(configuration: configuration, decoder: decoder, descriptor: descriptor)
        let lease = SpeechAudioLease()
        try await session.prepare(lease: lease)
        let loaded = await decoder.directory
        XCTAssertEqual(loaded, directory)
        XCTAssertEqual(session.engineStatus.description, "Fixture speech")
        session.cancel()
    }

    func testMissingInjectedModelCannotLoadDecoder() async {
        let decoder = PhononDescriptorDecoder()
        let configuration = SpeechAudioConfiguration(locale: "en-IN", vocabulary: [], reportLevels: false,
                                                     onRecognition: { _ in }, onLevel: { _ in })
        let descriptor = SpeechModelSessionDescriptor(directory: URL(fileURLWithPath: "/tmp/missing"), isInstalled: { false },
                                                     modelDescription: "Fixture", setupMessage: "Prepare fixture first")
        let session = ParakeetSpeechAudioSession(configuration: configuration, decoder: decoder, descriptor: descriptor)
        do { try await session.prepare(lease: SpeechAudioLease()); XCTFail("Unprepared model must be rejected") }
        catch { XCTAssertEqual(error.localizedDescription, "Prepare fixture first") }
        let loaded = await decoder.directory
        XCTAssertNil(loaded)
        session.cancel()
    }

    private func waitForWaiters(_ gate: PhononExclusiveCheckoutGate, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await gate.waitingCount != count {
            guard ContinuousClock.now < deadline else {
                XCTFail("Exclusive checkout did not reach the expected wait state")
                throw GateWaitFailure.deadline
            }
            await Task.yield()
        }
    }
    private enum GateWaitFailure: Error { case deadline }
}

private final class PhononTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor PhononDescriptorDecoder: ParakeetStreamingDecoding {
    private(set) var directory: URL?
    func loadModel(from directory: URL) async throws { self.directory = directory }
    func appendAndDecode(_ input: ParakeetPCMBuffer) async throws -> String { "" }
    func finish() async throws -> String { "" }
    func cleanup() async {}
}
