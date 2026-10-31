import XCTest
import PilotTDT

final class PredictorCacheTests: XCTestCase {
    func testImmutableHistorySharesCacheAcrossBlankAndBranchCopiesButInvalidatesOnNonblank() {
        // The native probe uses tiny deterministic compact matrices, compares
        // all recurrent states and logits exactly against cache-off scoring,
        // and proves frame-dependent head work is fresh after a blank.
        XCTAssertEqual(pilot_predictor_cache_invariant_probe(), 0)
    }
}

final class ConfigurationFailureTests: XCTestCase {
    func testAllocatingSettersContainExceptionsAndInvalidateUnpublishedHandle() {
        XCTAssertEqual(pilot_configuration_failure_probe(), 0)
    }
}
