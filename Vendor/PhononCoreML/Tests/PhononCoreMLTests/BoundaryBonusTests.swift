import XCTest
import PilotTDT
@testable import PhononCoreML

final class BoundaryBonusTests: XCTestCase {
    func bonuses(emitted: [Int32] = [], suppressed: [Int32] = []) -> [Float] {
        var tokens: [Int32] = [0,1,2], lengths: [Int32] = [3], e=emitted, skip=suppressed
        var scores: [Float] = [0,0,0,0], result=scores
        let selected = tokens.withUnsafeMutableBufferPointer { tp in lengths.withUnsafeMutableBufferPointer { lp in e.withUnsafeMutableBufferPointer { ep in scores.withUnsafeMutableBufferPointer { sp in result.withUnsafeMutableBufferPointer { bp in skip.withUnsafeMutableBufferPointer { kp in
            pilot_bias_probe_suppressed(tp.baseAddress,lp.baseAddress,1,ep.baseAddress,Int32(ep.count),sp.baseAddress,4,3,2,bp.baseAddress,kp.baseAddress,Int32(kp.count))
        }}}}}}
        XCTAssertGreaterThanOrEqual(selected,0)
        return result
    }
    func testDefaultStillRewardsStandaloneBoundary() {
        XCTAssertEqual(bonuses(),[2,0,0,0])
    }
    func testSuppressedBoundaryGetsZeroButEmittedBoundaryAdvancesToLetters() {
        XCTAssertEqual(bonuses(suppressed:[0]),[0,0,0,0])
        XCTAssertEqual(bonuses(emitted:[0],suppressed:[0]),[0,2,0,0])
        XCTAssertEqual(bonuses(emitted:[0,1],suppressed:[0]),[0,0,2,0])
        // Blank still preserves the partial spelling and never receives bonus.
        XCTAssertEqual(bonuses(emitted:[0,3],suppressed:[0]),[0,2,0,0])
    }
    func testOnlyEntireBoundaryOrWhitespacePiecesAreSelected() {
        let vocab=["▁","▁▁"," \t","▁ \n","a","▁A","<pad>","","\u{200b}"]
        XCTAssertEqual(BiasPhrases.boundaryOnlyTokenIDs(in:vocab),[0,1,2,3])
    }
}
