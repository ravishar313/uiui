import Foundation
import XCTest
@testable import UIUI

final class PhononStreamingTests: XCTestCase {
    func testLowGainSpeechReachesPreviewAndFinalWithoutBeingTreatedAsQuiet() throws {
        var decoded: [[Float]] = []
        let session = PhononPhraseSession { decoded.append($0); return "soft speech" }
        let samples = [Float](repeating: 0.001, count: 5_619)
        XCTAssertEqual(try session.append(samples), "soft speech")
        XCTAssertEqual(try session.finish(), "soft speech")
        XCTAssertEqual(decoded.first, Array(samples.prefix(5_600)))
        XCTAssertEqual(decoded.last, samples)
        XCTAssertEqual(session.discardedQuietSamples, 0)
    }

    func testExplicitStopDecodesNonzeroPCMAtRMSGateFloorButPureZeroNeverRunsASR() throws {
        var decoded: [[Float]] = []
        let session = PhononPhraseSession { decoded.append($0); return "quiet final" }
        let samples: [Float] = [0, 0, 0.0001, 0, -0.0001]
        XCTAssertEqual(try session.append(samples), "")
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(try session.finish(), "quiet final")
        XCTAssertEqual(decoded, [samples])

        var zeroCalls = 0
        let pureQuiet = PhononPhraseSession { _ in zeroCalls += 1; return "unexpected" }
        XCTAssertEqual(try pureQuiet.append([Float](repeating: 0, count: 16_000)), "")
        XCTAssertEqual(try pureQuiet.finish(), "")
        XCTAssertEqual(zeroCalls, 0)
    }

    func testQuietClosesPhrasesButCumulativeSessionContinuesUntilExplicitFinish() throws {
        var results = ["first preview", "first final", "first final", "second preview", "second final"]
        var decoded: [[Float]] = []
        let session = PhononPhraseSession { samples in
            decoded.append(samples)
            return results.removeFirst()
        }
        let firstVoice = [Float](repeating: 0.1, count: 5_600)
        XCTAssertEqual(try session.append(firstVoice), "first preview")
        XCTAssertEqual(try session.append([Float](repeating: 0, count: 11_200)), "first final")
        let secondVoice = [Float](repeating: 0.2, count: 5_600)
        XCTAssertEqual(try session.append(secondVoice), "first final second preview")
        XCTAssertEqual(try session.finish(), "first final second final")
        XCTAssertEqual(try session.finish(), "first final second final", "Finish is idempotent")
        XCTAssertEqual(decoded.count, 5, "The growing prefix may preview once during trailing quiet")
        XCTAssertEqual(decoded[2], firstVoice + [Float](repeating: 0, count: 11_200))
        XCTAssertEqual(decoded[4], secondVoice)
        XCTAssertEqual(session.acceptedSamples, session.finalizedSamples)
        XCTAssertEqual(session.retainedSamples, 0)
        XCTAssertThrowsError(try session.append([0.1]), "Only explicit finish closes input")
    }

    func testResidualPCMAndShortFirstWordReachFinalDecodeWithoutAnyPreview() throws {
        var decoded: [[Float]] = []
        let session = PhononPhraseSession { samples in decoded.append(samples); return "Okay." }
        let first = [Float](repeating: 0.1, count: 713)
        let last = [Float](repeating: 0.2, count: 991)
        XCTAssertEqual(try session.append(first), "")
        XCTAssertEqual(try session.append(last), "")
        XCTAssertEqual(try session.finish(), "Okay.")
        XCTAssertEqual(decoded, [first + last], "All sub-block and resampler residue must survive stop")
        XCTAssertEqual(session.acceptedSamples, 1_704)
        XCTAssertEqual(session.finalizedSamples, 1_704)
    }

    func testContinuousVoicedPhraseBeyondThirtySecondsIsNeverCutOrTrimmed() throws {
        var decodedCounts: [Int] = []
        let session = PhononPhraseSession { samples in
            decodedCounts.append(samples.count)
            return "growing phrase"
        }
        let frames = 31 * 16_000 + 137
        let input = (0..<frames).map { Float(($0 % 20) + 1) / 100 }
        _ = try session.append(input)
        XCTAssertEqual(session.finalizedSamples, 0, "There must be no arbitrary voiced 30-second phrase boundary")
        XCTAssertEqual(session.retainedSamples, frames)
        XCTAssertEqual(session.discardedQuietSamples, 0)
        XCTAssertEqual(try session.finish(), "growing phrase")
        XCTAssertEqual(decodedCounts.last, frames, "The vendor long-audio planner receives the entire phrase")
        XCTAssertEqual(session.finalizedSamples, frames)
    }

    func testOnlyPureQuietMayBeTrimmedAndLastSecondPrecedesFollowingSpeech() throws {
        var decoded: [[Float]] = []
        let session = PhononPhraseSession { samples in decoded.append(samples); return "word" }
        XCTAssertEqual(try session.append([Float](repeating: 0, count: 480_000)), "")
        XCTAssertTrue(decoded.isEmpty, "Pure quiet must not run native inference")
        XCTAssertEqual(session.retainedSamples, 16_000)
        XCTAssertEqual(session.discardedQuietSamples, 464_000)
        let speech = [Float](repeating: 0.1, count: 819)
        _ = try session.append(speech)
        XCTAssertEqual(try session.finish(), "word")
        XCTAssertEqual(decoded.last, [Float](repeating: 0, count: 16_000) + speech)
        XCTAssertEqual(session.acceptedSamples, session.finalizedSamples + session.discardedQuietSamples)
    }

    func testEmptyPreviewDoesNotErasePriorHypothesisAndFinalCanReviseIt() throws {
        var results = ["early words", "", "correct final"]
        let session = PhononPhraseSession { _ in results.removeFirst() }
        XCTAssertEqual(try session.append([Float](repeating: 0.1, count: 5_600)), "early words")
        XCTAssertEqual(try session.append([Float](repeating: 0.1, count: 8_000)), "early words")
        XCTAssertEqual(try session.finish(), "correct final")
    }

    func testEmptyFinalKeepsLastHypothesisExactlyOnceAcrossQuietAndNextPhrase() throws {
        var results = ["first words", "", "", "second words", ""]
        let session = PhononPhraseSession { _ in results.removeFirst() }
        _ = try session.append([Float](repeating: 0.1, count: 5_600))
        XCTAssertEqual(try session.append([Float](repeating: 0, count: 11_200)), "first words")
        XCTAssertEqual(try session.append([Float](repeating: 0, count: 3_200)), "first words")
        XCTAssertEqual(try session.append([Float](repeating: 0.1, count: 5_600)), "first words second words")
        XCTAssertEqual(try session.finish(), "first words second words")
        XCTAssertEqual(try session.finish(), "first words second words")
        XCTAssertTrue(results.isEmpty)
    }

    func testFailedFinalDecodeKeepsAcceptedSourceForTruthfulFailure() throws {
        enum Failure: Error { case prediction }
        var fail = false
        let session = PhononPhraseSession { _ in
            if fail { throw Failure.prediction }
            return "preview"
        }
        _ = try session.append([Float](repeating: 0.1, count: 5_600))
        fail = true
        XCTAssertThrowsError(try session.finish())
        XCTAssertEqual(session.snapshot, "preview")
        XCTAssertEqual(session.retainedSamples, 5_600)
        XCTAssertEqual(session.finalizedSamples, 0)
    }

    func testCancellationBetweenPredictionsRejectsLatePreviewAndRetainsEachAcceptedSampleOnce() throws {
        let cancellation = PhononOperationCancellation()
        var calls = 0
        let session = PhononPhraseSession(checkCancellation: { try cancellation.check() }) { _ in
            calls += 1
            cancellation.cancel()
            return "late native text"
        }
        let frames = 16_137
        XCTAssertThrowsError(try session.append([Float](repeating: 0.1, count: frames))) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(calls, 1, "Cancellation must prevent all subsequent preview calls")
        XCTAssertEqual(session.snapshot, "", "A result arriving after cancellation must not be published")
        XCTAssertEqual(session.acceptedSamples, frames)
        XCTAssertEqual(session.retainedSamples, frames)
        XCTAssertEqual(session.finalizedSamples, 0)
    }

    func testGenericPCMConditioningPreservesEverySourceSampleAndDefaultIsIdentity() throws {
        let source: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(PhononPCMConditioning().apply(to: source), source)
        XCTAssertEqual(PhononPCMConditioning(leadingSilenceFrames: -1, trailingSilenceFrames: -2).apply(to: source), source)
        var decoded: [[Float]] = []
        let session = PhononPhraseSession(conditioning: .init(leadingSilenceFrames: 3, trailingSilenceFrames: 5)) {
            decoded.append($0); return "word"
        }
        _ = try session.append(source)
        XCTAssertEqual(try session.finish(), "word")
        XCTAssertEqual(decoded, [[0, 0, 0] + source + [0, 0, 0, 0, 0]])
        XCTAssertEqual(session.finalizedSamples, source.count, "Synthetic context is not accepted microphone PCM")
    }
}
