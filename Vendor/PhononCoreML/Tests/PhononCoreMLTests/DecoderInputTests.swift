import XCTest
@testable import PhononCoreML

final class DecoderInputTests: XCTestCase {
    func testExactFiniteInputAndEmptyBoundaryAreValid() {
        XCTAssertTrue(TDTDecoder.validEncoder([],frames:0))
        XCTAssertTrue(TDTDecoder.validEncoder([Float](repeating:0,count:1280),frames:2))
    }
    func testShapeMismatchNegativeHugeAndOverLimitFramesReject() {
        XCTAssertFalse(TDTDecoder.validEncoder([0],frames:2))
        XCTAssertFalse(TDTDecoder.validEncoder([],frames:-1))
        XCTAssertFalse(TDTDecoder.validEncoder([],frames:Int.min))
        XCTAssertFalse(TDTDecoder.validEncoder([],frames:Int.max))
        XCTAssertFalse(TDTDecoder.validEncoder([],frames:TDTDecoder.maximumEncoderFrames + 1))
        XCTAssertFalse(TDTDecoder.validEncoder([0],frames:0))
        XCTAssertFalse(TDTDecoder.validEncoder([Float](repeating:0,count:641),frames:1))
    }
    func testNonfiniteValuesRejectBeforeNativePointerAccess() {
        for value: Float in [.nan,.infinity,-.infinity] {
            var frames=[Float](repeating:0,count:640);frames[639]=value
            XCTAssertFalse(TDTDecoder.validEncoder(frames,frames:1))
        }
    }
}
