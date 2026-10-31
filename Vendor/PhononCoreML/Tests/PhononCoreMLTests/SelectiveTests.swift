import XCTest
import PilotTDT
@testable import PhononCoreML

final class SelectiveTests: XCTestCase {
    // 0,1 spell the name; 2 is a next-word boundary; 3 is blank.
    // Each frame has independent distributions for each previous token. The
    // duration logits (indices 4/5) are real TDT zero/one-frame choices.
    func fixture(_ rows: [(Int, Int, [Float])], frames: Int = 3, budget: Float = 4, margin: Float = 2, compete: Bool = false, positiveDuration: Int32 = 1, name: [Int32] = [0,1], boundaries boundaryIDs: [Int32] = [2], utterance: Bool = false, cancelAfter: Int32 = 0, predictionLimit: Int32 = 0) -> (tokens: [Int32], frames: [Int32], durations: [Int32], end: Int32) {
        let nhead=positiveDuration>1 ? 7 : 6
        var scores = [Float](repeating: -100, count: frames*4*nhead)
        for t in 0..<frames { for last in 0..<4 {
            let i=(t*4+last)*nhead; scores[i+2]=0; scores[i+5]=0
        }}
        for (t,last,row) in rows { for j in 0..<nhead { scores[(t*4+last)*nhead+j]=row[j] } }
        var term: [Int32] = name, lengths: [Int32] = [Int32(name.count)], boundaries: [Int32] = boundaryIDs
        var out=[Int32](repeating:-1,count:20), fr=out, du=out, end:Int32 = -1
        let n=term.withUnsafeMutableBufferPointer { tp in lengths.withUnsafeMutableBufferPointer { lp in scores.withUnsafeMutableBufferPointer { sp in boundaries.withUnsafeMutableBufferPointer { bp in out.withUnsafeMutableBufferPointer { op in fr.withUnsafeMutableBufferPointer { fp in du.withUnsafeMutableBufferPointer { dp in
            if utterance { return pilot_selective_utterance_probe(tp.baseAddress,lp.baseAddress,1,sp.baseAddress,Int32(frames),4,bp.baseAddress,Int32(bp.count),budget,margin,op.baseAddress,fp.baseAddress,dp.baseAddress,20,&end,cancelAfter,predictionLimit) }
            if compete { return pilot_selective_competition_probe(tp.baseAddress,lp.baseAddress,1,sp.baseAddress,Int32(frames),4,bp.baseAddress,1,budget,margin,op.baseAddress,fp.baseAddress,dp.baseAddress,20,&end,positiveDuration) }
            return pilot_selective_path_probe(tp.baseAddress,lp.baseAddress,1,sp.baseAddress,Int32(frames),4,bp.baseAddress,1,budget,margin,op.baseAddress,fp.baseAddress,dp.baseAddress,20,&end)
        }}}}}}}
        return (Array(out.prefix(Int(n))),Array(fr.prefix(Int(n))),Array(du.prefix(Int(n))),end)
    }
    func testPartialNameCannotAlterThePath() {
        let r=fixture([(0,3,[-1,-100,0,-100,-100,0])])
        XCTAssertEqual(r.tokens,[]); XCTAssertEqual(r.end,0) // complete rollback
    }
    func testCompletionRequiresAnAcousticWordBoundary() {
        let prefix:[(Int,Int,[Float])]=[(0,3,[-1,-100,0,-100,-100,0]),(1,0,[-100,-1,0,-100,-100,0])]
        let rejected=fixture(prefix+[(2,1,[0,-100,-100,-100,-100,0])])
        XCTAssertEqual(rejected.tokens,[]); XCTAssertEqual(rejected.end,0)
        let accepted=fixture(prefix)
        XCTAssertEqual(accepted.tokens,[0,1]); XCTAssertEqual(accepted.frames,[0,1]); XCTAssertEqual(accepted.durations,[1,1]); XCTAssertEqual(accepted.end,2)
    }
    func testAcousticTotalAndPerPieceMarginsBothGateCompletion() {
        let rows:[(Int,Int,[Float])]=[(0,3,[-1.5,-100,0,-100,-100,0]),(1,0,[-100,-1.5,0,-100,-100,0])]
        XCTAssertEqual(fixture(rows,budget:2,margin:2).tokens,[])
        XCTAssertEqual(fixture(rows,budget:4,margin:1).tokens,[])
        XCTAssertEqual(fixture(rows,budget:4,margin:2).tokens,[0,1])
    }
    func testNonblankPredictionStateAndZeroDurationAreBranchLocal() {
        let r=fixture([(0,3,[-1,-100,0,-100,0,-100]),(0,0,[-100,-1,0,-100,-100,0])])
        XCTAssertEqual(r.tokens,[0,1]); XCTAssertEqual(r.frames,[0,0]); XCTAssertEqual(r.durations,[0,1]); XCTAssertEqual(r.end,1)
    }
    func testBlankWaitPreservesPredictionStateAndAdvancesOneFrame() {
        let r=fixture([(0,3,[-1,-100,0,-100,-100,0]),(1,0,[-100,-100,-100,0,0,-100]),(2,0,[-100,-1,0,-100,-100,0])],frames:4)
        XCTAssertEqual(r.tokens,[0,1]); XCTAssertEqual(r.frames,[0,2]); XCTAssertEqual(r.durations,[1,1]); XCTAssertEqual(r.end,3)
    }
    func testCommonHorizonCandidateOvershootsWhileOrdinaryEndsExactlyAtT() {
        // Candidate: token0 duration0 -> token1 duration4 -> raw end4.
        // Ordinary: token2 duration0 -> token1 duration1 -> token2
        // duration1 -> end2 == T. Comparing until raw end4 would read at t2.
        let r=fixture([(0,3,[-1,-100,0,-100,0,-100,-100]),
                       (0,0,[-100,-1,0,-100,-100,-100,0]),
                       (0,2,[-100,0,-100,-100,-100,0,-100])],frames:2,budget:4,margin:2,compete:true,positiveDuration:4)
        XCTAssertEqual(r.tokens,[0,1]);XCTAssertEqual(r.frames,[0,0]);XCTAssertEqual(r.durations,[0,4]);XCTAssertEqual(r.end,4)
    }
    func testCommonHorizonRejectsANameThatConsumesThreeOrdinaryWords() {
        let r=fixture([(0,3,[-1,-100,0,-100,-100,0]),(1,0,[-100,-1,0,-100,-100,0]),(2,1,[-1,-100,0,-100,-100,0])],frames:4,budget:8,margin:2,compete:true,name:[0,1,0])
        XCTAssertEqual(r.tokens,[]);XCTAssertEqual(r.end,0)
    }
    func testFullTransactionRollsBackAnyChangedSuffixWord() {
        // Candidate name0 at frame0 would complete before boundary2. The
        // original continues boundary1, so the entire output must be original.
        let r=fixture([(0,3,[-1,-100,0,-100,-100,0]),
                       (1,0,[-100,-100,0,-100,-100,0]),
                       (1,2,[-100,0,-100,-100,-100,0])],frames:3,name:[0],boundaries:[1,2],utterance:true)
        XCTAssertEqual(r.tokens,[2,1,2]);XCTAssertEqual(r.frames,[0,1,2]);XCTAssertEqual(r.durations,[1,1,1]);XCTAssertEqual(r.end,0)
    }
    func testFullTransactionPredictionBudgetReturnsExactOriginal() {
        let r=fixture([(0,3,[-1,-100,0,-100,-100,0]),(1,0,[-100,-1,0,-100,-100,0])],utterance:true,predictionLimit:2)
        XCTAssertEqual(r.tokens,[2,2,2]);XCTAssertEqual(r.frames,[0,1,2]);XCTAssertEqual(r.durations,[1,1,1]);XCTAssertEqual(r.end,0)
    }
    func testFullTransactionCancellationStopsWithoutReturningPartialText() {
        let r=fixture([(0,3,[-1,-100,0,-100,-100,0]),(1,0,[-100,-1,0,-100,-100,0])],utterance:true,cancelAfter:3)
        XCTAssertEqual(r.tokens,[]);XCTAssertEqual(r.end,0)
    }
    func testFullTransactionCommitsOnlyCompletedNameWithExactSuffix() {
        let r=fixture([(0,3,[-1,-100,0,-100,-100,0])],frames:3,name:[0],utterance:true)
        XCTAssertEqual(r.tokens,[0,2,2]);XCTAssertEqual(r.frames,[0,1,2]);XCTAssertEqual(r.durations,[1,1,1]);XCTAssertEqual(r.end,1)
    }
    func testNonfiniteAndNegativeAcousticCostsCannotPassTheGate() {
        XCTAssertEqual(pilot_selective_gate_probe(.nan,0,4,2,1,1),0)
        XCTAssertEqual(pilot_selective_gate_probe(0,.infinity,4,2,1,1),0)
        XCTAssertEqual(pilot_selective_gate_probe(-1,0,4,2,1,1),0)
        XCTAssertEqual(pilot_selective_gate_probe(1,1,4,2,0,1),0)
        XCTAssertEqual(pilot_selective_gate_probe(1,1,4,2,1,0),0)
    }
    func testWordBoundaryClassificationRejectsInsideWordPieces() {
        XCTAssertEqual(BiasPhrases.wordBoundaryTokenIDs(in:["▁","▁Hello",",","."," ","foo","ki","<pad>","", "'t", "’t", "-based"]),[0,1,2,3,4])
    }
}
