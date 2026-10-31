import XCTest
@testable import UIUI

final class UpdateInterruptionGateTests: XCTestCase {
    func testIdleReleaseIsPresentedImmediately() {
        var gate = UpdateInterruptionGate<String>()
        XCTAssertEqual(gate.found("1.2", workInFlight: false), "1.2")
        XCTAssertNil(gate.pending)
    }

    func testReleaseFoundDuringWorkWaitsAndIsPresentedOnceWhenIdle() {
        var gate = UpdateInterruptionGate<String>()
        XCTAssertNil(gate.found("1.2", workInFlight: true))
        XCTAssertNil(gate.activityChanged(workInFlight: true), "still busy: stay silent")
        XCTAssertEqual(gate.activityChanged(workInFlight: false), "1.2")
        XCTAssertNil(gate.activityChanged(workInFlight: false), "presented only once")
    }

    func testNewerHeldReleaseReplacesOlderOne() {
        var gate = UpdateInterruptionGate<String>()
        XCTAssertNil(gate.found("1.2", workInFlight: true))
        XCTAssertNil(gate.found("1.3", workInFlight: true))
        XCTAssertEqual(gate.activityChanged(workInFlight: false), "1.3")
    }

    @MainActor
    func testIdleModelReportsNoDictationWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-gate-\(UUID().uuidString)")
        let suite = "uiui-gate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(dataDirectory: root, defaults: defaults, persistSettings: false)
        defer {
            model.shutdown(); try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        XCTAssertFalse(model.isDictationWorkInFlight)
        model.manualCleanupInProgress = true
        XCTAssertTrue(model.isDictationWorkInFlight)
    }
}
