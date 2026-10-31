import Foundation
import XCTest
@testable import UIUI

final class PhononSpeechActivityTests: XCTestCase {
    private let frame = PhononPhraseSession.classificationFrames

    func testNonzeroRoomNoiseNeverRunsASREvenAtExplicitStop() throws {
        var classificationCounts: [Int] = []
        var asrCalls = 0
        let session = PhononPhraseSession(speechProbability: {
            classificationCounts.append($0.count)
            return 0
        }) { _ in asrCalls += 1; return "hallucinated words" }
        // Nonzero DC and a low fan-like oscillation both passed the old RMS gate.
        let noiseCount = 16_000 * 35 + 173
        let noise: [Float] = (0..<noiseCount).map { index in
            let oscillation = Float(index % 41 - 20) * Float(0.0001)
            return oscillation + Float(0.003)
        }
        XCTAssertEqual(try session.append(noise), "")
        XCTAssertLessThanOrEqual(session.retainedSamples, 8_192 + frame + 799)
        XCTAssertEqual(try session.finish(), "")
        XCTAssertEqual(asrCalls, 0)
        XCTAssertTrue(classificationCounts.allSatisfy { $0 == frame })
        XCTAssertEqual(classificationCounts.count, (noise.count + frame - 1) / frame)
        XCTAssertEqual(session.finalizedSamples, 0)
        XCTAssertEqual(session.discardedQuietSamples, noise.count)
        XCTAssertEqual(session.retainedSamples, 0)
    }

    func testFirstPositiveDecisionAllowsPreviewAt350Milliseconds() throws {
        var decoded: [[Float]] = []
        let session = PhononPhraseSession(speechProbability: { _ in 1 }) {
            decoded.append($0); return "quiet words"
        }
        let speech = [Float](repeating: 0.00001, count: 5_600)
        XCTAssertEqual(try session.append(speech), "quiet words")
        XCTAssertEqual(decoded, [speech], "A second 4096-frame decision must not delay the first preview")
        XCTAssertEqual(try session.finish(), "quiet words")
        XCTAssertEqual(decoded.last, speech, "VAD-confirmed low gain PCM must never be amplitude-filtered")
        XCTAssertEqual(session.finalizedSamples, speech.count)
    }

    func testShortWordGetsPaddedVADDecisionAndUnmodifiedSourceAtStop() throws {
        var classified: [[Float]] = []
        var decoded: [[Float]] = []
        let session = PhononPhraseSession(speechProbability: {
            classified.append($0); return 0.9
        }) { decoded.append($0); return "Okay." }
        let source = (0..<1_704).map { Float($0 % 17) * 0.00001 }
        _ = try session.append(Array(source.prefix(713)))
        _ = try session.append(Array(source.dropFirst(713)))
        XCTAssertTrue(classified.isEmpty)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(try session.finish(), "Okay.")
        XCTAssertEqual(classified, [source + [Float](repeating: 0, count: frame - source.count)])
        XCTAssertEqual(decoded, [source], "Classifier padding must never alter ASR input")
        XCTAssertEqual(session.acceptedSamples, session.finalizedSamples)
        XCTAssertEqual(try session.finish(), "Okay.")
        XCTAssertEqual(decoded.count, 1)
    }

    func testQuietTailIsBoundedAndCannotKeepRevisingTextAfterPhraseCloses() throws {
        var decoded: [[Float]] = []
        let speech = [Float](repeating: 0.1, count: frame * 2)
        let session = PhononPhraseSession(speechProbability: { samples in
            samples.contains(0.1) ? 1 : 0
        }) { samples in decoded.append(samples); return "confirmed words" }
        _ = try session.append(speech)
        XCTAssertEqual(try session.append([Float](repeating: 0.002, count: frame * 4)), "confirmed words")
        let settledCalls = decoded.count
        XCTAssertGreaterThan(settledCalls, 0)
        XCTAssertEqual(decoded.last, speech + [Float](repeating: 0.002, count: 3_200))
        XCTAssertTrue(decoded.allSatisfy { $0.count <= speech.count + 3_200 })
        XCTAssertEqual(try session.append([Float](repeating: 0.002, count: 16_000 * 10)), "confirmed words")
        XCTAssertEqual(try session.finish(), "confirmed words")
        XCTAssertEqual(decoded.count, settledCalls, "An already closed phrase must not decode growing room noise")
        XCTAssertEqual(session.acceptedSamples, session.finalizedSamples + session.discardedQuietSamples)
    }

    func testIntermediateConfidenceNoiseCannotAdvanceASRTailOrKeepPhraseAlive() throws {
        var decoded: [[Float]] = []
        let speech = [Float](repeating: 0.1, count: frame * 2)
        let session = PhononPhraseSession(speechProbability: { samples in
            samples.contains(0.1) ? 0.95 : 0.4
        }) { samples in
            decoded.append(samples)
            return samples.count > speech.count + 3_200 ? "hallucinated tail" : "confirmed words"
        }
        _ = try session.append(speech)
        XCTAssertEqual(try session.append([Float](repeating: 0.002, count: frame * 5)), "confirmed words")
        let settledCalls = decoded.count
        XCTAssertEqual(decoded.last, speech + [Float](repeating: 0.002, count: 3_200))
        XCTAssertGreaterThan(session.finalizedSamples, 0, "Middle confidence must have a bounded hangover")
        XCTAssertEqual(try session.append([Float](repeating: 0.002, count: frame * 10)), "confirmed words")
        XCTAssertEqual(try session.finish(), "confirmed words")
        XCTAssertEqual(decoded.count, settledCalls)
        XCTAssertTrue(decoded.allSatisfy { $0.count <= speech.count + 3_200 })
        XCTAssertEqual(session.acceptedSamples, session.finalizedSamples + session.discardedQuietSamples)
    }

    func testSecondQuietUtteranceAfterPauseKeepsBothPhrasesAndPreroll() throws {
        var decoded: [[Float]] = []
        let session = PhononPhraseSession(speechProbability: { samples in
            samples.contains(where: { $0 == 0.00001 || $0 == 0.00002 }) ? 1 : 0
        }) { samples in
            decoded.append(samples)
            return samples.contains(0.00002) ? "ship it" : "okay"
        }
        _ = try session.append([Float](repeating: 0.00001, count: frame * 2))
        XCTAssertEqual(try session.append([Float](repeating: 0.002, count: frame * 8)), "okay")
        let second = [Float](repeating: 0.00002, count: 1_519)
        _ = try session.append(second)
        XCTAssertEqual(try session.finish(), "okay ship it")
        XCTAssertEqual(Array(try XCTUnwrap(decoded.last).suffix(second.count)), second)
        XCTAssertTrue(try XCTUnwrap(decoded.last).starts(with: [Float](repeating: 0.002, count: 8_192)),
                      "Bounded context before a newly confirmed word must survive the pause")
        XCTAssertEqual(session.acceptedSamples, session.finalizedSamples + session.discardedQuietSamples)
        XCTAssertEqual(session.retainedSamples, 0)
    }

    func testEmptyFinalPreservesOnlyConfirmedPhraseAndDoesNotDuplicateIt() throws {
        var first = true
        let session = PhononPhraseSession(speechProbability: { $0.contains(0.1) ? 1 : 0 }) { _ in
            defer { first = false }
            return first ? "thanks" : ""
        }
        XCTAssertEqual(try session.append([Float](repeating: 0.1, count: 5_600)), "thanks")
        XCTAssertEqual(try session.append([Float](repeating: 0.002, count: frame * 5)), "thanks")
        XCTAssertEqual(try session.finish(), "thanks")
        XCTAssertEqual(try session.finish(), "thanks")
    }

    func testLongConfirmedPhraseRetainsEverySampleWithoutThirtySecondCutoff() throws {
        var lastCount = 0
        let session = PhononPhraseSession(speechProbability: { _ in 1 }) { samples in
            lastCount = samples.count; return "continuous speech"
        }
        let count = 31 * 16_000 + 137
        _ = try session.append([Float](repeating: 0.00001, count: count))
        XCTAssertEqual(session.finalizedSamples, 0)
        XCTAssertEqual(session.retainedSamples, count)
        XCTAssertEqual(try session.finish(), "continuous speech")
        XCTAssertEqual(lastCount, count)
        XCTAssertEqual(session.finalizedSamples, count)
        XCTAssertEqual(session.discardedQuietSamples, 0)
    }

    func testFailedClassifierCanRetryAtStopWithoutLosingOrDuplicatingSource() throws {
        enum Failure: Error { case classification }
        var fail = true
        var decoded: [[Float]] = []
        let session = PhononPhraseSession(speechProbability: { _ in
            if fail { throw Failure.classification }
            return 1
        }) { decoded.append($0); return "ship it" }
        let source = [Float](repeating: 0.00001, count: 4_800)
        XCTAssertThrowsError(try session.append(source))
        XCTAssertEqual(session.retainedSamples, source.count)
        XCTAssertEqual(session.finalizedSamples, 0)
        fail = false
        XCTAssertEqual(try session.finish(), "ship it")
        XCTAssertEqual(decoded, [source])
        XCTAssertEqual(session.acceptedSamples, session.finalizedSamples)
    }

    func testFailedFinalKeepsSourceAndDoesNotRepeatConsumedClassifierFrames() throws {
        enum Failure: Error { case prediction }
        var fail = false
        var classified = 0
        var decoded: [[Float]] = []
        let session = PhononPhraseSession(speechProbability: { samples in
            classified += 1
            return samples.contains(0.1) ? 1 : 0
        }) { samples in
            if fail { throw Failure.prediction }
            decoded.append(samples)
            return "confirmed words"
        }
        let speech = [Float](repeating: 0.1, count: frame * 2)
        _ = try session.append(speech)
        _ = try session.append([Float](repeating: 0.002, count: 8_000))
        fail = true
        XCTAssertThrowsError(try session.append([Float](repeating: 0.002, count: 4_608)))
        XCTAssertEqual(session.snapshot, "confirmed words")
        XCTAssertEqual(session.finalizedSamples, 0)
        let decisionsBeforeRetry = classified
        fail = false
        XCTAssertEqual(try session.finish(), "confirmed words")
        XCTAssertEqual(classified, decisionsBeforeRetry + 1, "Only the remaining partial classifier frame is new")
        XCTAssertEqual(decoded.last, speech + [Float](repeating: 0.002, count: 3_200))
        XCTAssertEqual(session.acceptedSamples, session.finalizedSamples + session.discardedQuietSamples)
    }

    func testClassifierRetryAtStopKeepsFutureSpeechAcrossMultiplePhraseBoundaries() throws {
        enum Failure: Error { case classification }
        var fail = true
        var finalized: [[Float]] = []
        let session = PhononPhraseSession(speechProbability: { samples in
            if fail { fail = false; throw Failure.classification }
            return samples.contains(0.1) || samples.contains(0.2) ? 1 : 0
        }) { samples in
            finalized.append(samples)
            if samples.contains(0.2) { return "second" }
            if samples.contains(0.1) { return "first" }
            return ""
        }
        let first = [Float](repeating: 0.1, count: frame * 2)
        let second = [Float](repeating: 0.2, count: frame * 2)
        let pause = [Float](repeating: 0.002, count: frame * 8)
        let source = first + pause + second + pause
        XCTAssertThrowsError(try session.append(source))
        XCTAssertEqual(session.retainedSamples, source.count)
        XCTAssertEqual(try session.finish(), "first second")
        XCTAssertTrue(finalized.contains { $0.starts(with: first) })
        XCTAssertTrue(finalized.contains { $0.contains(0.2) })
        XCTAssertEqual(session.acceptedSamples, session.finalizedSamples + session.discardedQuietSamples)
        XCTAssertEqual(session.retainedSamples, 0)
    }

    func testCancellationRejectsLateClassifierAndASRResultsWithoutLosingSource() throws {
        let classificationCancellation = PhononOperationCancellation()
        var asrCalls = 0
        let classifierCancelled = PhononPhraseSession(speechProbability: { _ in
            classificationCancellation.cancel(); return 1
        }, checkCancellation: { try classificationCancellation.check() }) { _ in
            asrCalls += 1; return "late classifier words"
        }
        let count = 16_137
        XCTAssertThrowsError(try classifierCancelled.append([Float](repeating: 0.1, count: count))) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(asrCalls, 0)
        XCTAssertEqual(classifierCancelled.snapshot, "")
        XCTAssertEqual(classifierCancelled.retainedSamples, count)

        let asrCancellation = PhononOperationCancellation()
        let asrCancelled = PhononPhraseSession(speechProbability: { _ in 1 },
                                             checkCancellation: { try asrCancellation.check() }) { _ in
            asrCancellation.cancel(); return "late native words"
        }
        XCTAssertThrowsError(try asrCancelled.append([Float](repeating: 0.1, count: count))) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(asrCancelled.snapshot, "")
        XCTAssertEqual(asrCancelled.retainedSamples, count)
        XCTAssertEqual(asrCancelled.finalizedSamples, 0)
    }
}
