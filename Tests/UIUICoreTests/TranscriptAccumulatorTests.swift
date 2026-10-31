import Foundation
import XCTest
@testable import UIUICore

final class TranscriptAccumulatorTests: XCTestCase {
    func testDisjointWindowRetainsShortWordImmediatelyBeforeBoundary() {
        var accumulator = TranscriptAccumulator()
        accumulator.update("one two three four", segments: segments("one two three four", start: 0, step: 0.1))
        XCTAssertEqual(accumulator.update("five", segments: segments("five", start: 0.4, step: 0.1)), "one two three four five")
    }
    func testLongRollingWindowsAndFinalTailRetainAll480WordsWithoutDuplicates() {
        var accumulator = TranscriptAccumulator()
        let words = (0..<480).map { "word\($0)" }
        for start in stride(from: 0, through: 360, by: 60) {
            var window = Array(words[start..<(start + 120)])
            if start == 360 { window[119] = "misheard" }
            let text = window.joined(separator: " ")
            accumulator.update(text, segments: segments(text, start: Double(start) * 0.2, step: 0.2))
            let expected = Array(words[..<(start + 120)]).dropLast().joined(separator: " ") + " " + window.last!
            XCTAssertEqual(accumulator.text, expected)
        }
        let finalTail = words[460...].joined(separator: " ")
        XCTAssertEqual(accumulator.update(finalTail, segments: segments(finalTail, start: 92, step: 0.2)), words.joined(separator: " "))
        XCTAssertEqual(accumulator.text.split(separator: " ").count, 480)
    }

    func testOrdinaryRevisionsAndBothLeadingAndTrailingRetractionsReplaceWindow() {
        var accumulator = TranscriptAccumulator()
        accumulator.update("I really want blue", segments: segments("I really want blue", start: 0, step: 0.4))
        XCTAssertEqual(accumulator.update("really want blue", segments: segments("really want blue", start: 0.4, step: 0.4)), "really want blue")
        XCTAssertEqual(accumulator.update("really want", segments: segments("really want", start: 0.4, step: 0.4)), "really want")
        XCTAssertEqual(accumulator.update("really wanted green", segments: segments("really wanted green", start: 0.4, step: 0.4)), "really wanted green")
    }

    func testPauseCreatesDisjointWindowAndItsRevisionsDoNotDuplicatePrefix() {
        var accumulator = TranscriptAccumulator()
        accumulator.update("One sentence.", segments: segments("One sentence.", start: 1))
        XCTAssertEqual(accumulator.update("Next after pause.", segments: segments("Next after pause.", start: 30)), "One sentence. Next after pause.")
        XCTAssertEqual(accumulator.update("Next after a pause!", segments: segments("Next after a pause!", start: 30)), "One sentence. Next after a pause!")
    }

    func testExplicitNewTaskEpochHandlesResetTimestampsExactlyOnce() {
        var accumulator = TranscriptAccumulator()
        accumulator.update("First task.", segments: segments("First task.", start: 0), recognitionEpoch: 1)
        XCTAssertEqual(accumulator.update("New task", segments: segments("New task", start: 0), recognitionEpoch: 2), "First task. New task")
        XCTAssertEqual(accumulator.update("New task revised.", segments: segments("New task revised.", start: 0), recognitionEpoch: 2), "First task. New task revised.")
        XCTAssertEqual(accumulator.update("stale task text", segments: segments("stale task text", start: 1), recognitionEpoch: 1), "First task. New task revised.")
    }

    func testMissingOrInvalidTimingNeverBlindlyAppendsShorterHypothesis() {
        var accumulator = TranscriptAccumulator()
        accumulator.update("alpha beta gamma")
        XCTAssertEqual(accumulator.update("beta"), "beta")
        XCTAssertEqual(accumulator.update(""), "")
        XCTAssertEqual(accumulator.update("revision", segments: [TranscriptSegment(timestamp: .nan, duration: 1, range: NSRange(location: 0, length: 8))]), "revision")
        XCTAssertEqual(accumulator.update("new", segments: [TranscriptSegment(timestamp: 20, duration: 1, range: NSRange(location: NSNotFound, length: 1))]), "new")
        let zeroTimes = [TranscriptSegment(timestamp: 0, duration: 0, range: NSRange(location: 0, length: 3)), TranscriptSegment(timestamp: 0, duration: 0, range: NSRange(location: 4, length: 4))]
        XCTAssertEqual(accumulator.update("two more", segments: zeroTimes), "two more")
    }

    func testMissingOrZeroTimingAfterProvenWindowAdvancePreservesFullBestTranscript() {
        let words = (0..<180).map { "word\($0)" }
        for zeroTiming in [false, true] {
            var accumulator = TranscriptAccumulator()
            let first = words[..<120].joined(separator: " ")
            let later = words[60...].joined(separator: " ")
            accumulator.update(first, segments: segments(first, start: 0, step: 0.2))
            accumulator.update(later, segments: segments(later, start: 12, step: 0.2))
            let finalTail = words[160...].joined(separator: " ")
            let unavailable = zeroTiming ? segments(finalTail, start: 0, step: 0) : []
            XCTAssertEqual(accumulator.update(finalTail, segments: unavailable), words.joined(separator: " "))
            XCTAssertTrue(accumulator.hasUnalignedHypothesis)
            // A later authoritative timed tail can still reconcile and confirm.
            XCTAssertEqual(accumulator.update(finalTail, segments: segments(finalTail, start: 32, step: 0.2)), words.joined(separator: " "))
            XCTAssertFalse(accumulator.hasUnalignedHypothesis)
        }
    }

    func testUnalignedTailAfterLongFirstWindowRetainsEntireRecoverableDraft() {
        let words = ["किताब", "café", "🪷."] + (0..<117).map { "word\($0)" }
        let draft = words.joined(separator: " ")
        let tail = words.suffix(12).joined(separator: " ") + "!"
        let unavailableTimings: [[TranscriptSegment]] = [
            [],
            segments(tail, start: 0, step: 0),
            [TranscriptSegment(timestamp: .nan, duration: 1, range: NSRange(tail.startIndex..., in: tail))]
        ]
        for unavailable in unavailableTimings {
            var accumulator = TranscriptAccumulator()
            accumulator.update(draft, segments: segments(draft, start: 0, step: 0.2))
            XCTAssertEqual(accumulator.update(tail, segments: unavailable), draft)
            XCTAssertTrue(accumulator.hasUnalignedHypothesis)
            XCTAssertEqual(accumulator.text.split(separator: " ").count, 120)
            // Usable full-window timing can resolve the ambiguity and revise text.
            let revised = draft + " Corrected."
            XCTAssertEqual(accumulator.update(revised, segments: segments(revised, start: 0, step: 0.2)), revised)
            XCTAssertFalse(accumulator.hasUnalignedHypothesis)
        }
    }

    func testUnalignedBackwardTimingAfterLongWindowRetainsEntireRecoverableDraft() {
        var accumulator = TranscriptAccumulator()
        let draft = (["किताब", "café", "🪷."] + (0..<117).map { "word\($0)" }).joined(separator: " ")
        accumulator.update(draft, segments: segments(draft, start: 20, step: 0.2))
        XCTAssertEqual(accumulator.update("reset tail!", segments: segments("reset tail!", start: 0)), draft)
        XCTAssertTrue(accumulator.hasUnalignedHypothesis)
    }

    func testCatastrophicFinalTimingContractionRetainsEntireRecoverableDraft() {
        var accumulator = TranscriptAccumulator()
        let words = ["किताब", "café", "🪷."] + (0..<117).map { "word\($0)" }
        let draft = words.joined(separator: " ")
        accumulator.update(draft, segments: segments(draft, start: 0, step: 0.2))
        let tail = words.suffix(12).joined(separator: " ") + "!"
        XCTAssertEqual(accumulator.update(tail, segments: segments(tail, start: 0, step: 0.2)), draft)
        XCTAssertTrue(accumulator.hasUnalignedHypothesis)
    }

    func testAlignedFinalSuffixCorrectsLongDraftWithoutDuplicatingUnicodeText() {
        var accumulator = TranscriptAccumulator()
        let words = ["किताब", "café", "🪷."] + (0..<117).map { "word\($0)" }
        let draft = words.joined(separator: " ")
        accumulator.update(draft, segments: segments(draft, start: 0, step: 0.2))
        let tail = words.suffix(12).joined(separator: " ") + "!"
        XCTAssertEqual(accumulator.update(tail, segments: segments(tail, start: 21.6, step: 0.2)), draft + "!")
        XCTAssertFalse(accumulator.hasUnalignedHypothesis)
        XCTAssertEqual(accumulator.text.split(separator: " ").count, 120)
    }

    func testShortFinalTimingContractionRemainsAnOrdinaryRetraction() {
        var accumulator = TranscriptAccumulator()
        accumulator.update("I really want blue", segments: segments("I really want blue", start: 0, step: 0.4))
        XCTAssertEqual(accumulator.update("really want", segments: segments("really want", start: 0.4, step: 0.4)), "really want")
        XCTAssertFalse(accumulator.hasUnalignedHypothesis)
    }

    func testLongSameStartPartialResetAndFollowingFinalRetainEntireRecoverableDraft() {
        var accumulator = TranscriptAccumulator()
        let words = ["किताब", "café", "🪷."] + (0..<117).map { "word\($0)" }
        let draft = words.joined(separator: " ")
        accumulator.update(draft, segments: segments(draft, start: 0, step: 0.2))
        let tail = words.suffix(12).joined(separator: " ") + "!"
        XCTAssertEqual(accumulator.update(tail, segments: segments(tail, start: 0, step: 0.2)), draft)
        XCTAssertTrue(accumulator.hasUnalignedHypothesis)
        // A repeated final must not validate the already-shortened partial.
        XCTAssertEqual(accumulator.update(tail, segments: segments(tail, start: 0, step: 0.2)), draft)
        XCTAssertTrue(accumulator.hasUnalignedHypothesis)
        XCTAssertEqual(accumulator.text.split(separator: " ").count, 120)
    }

    func testEarlierStartPartialResetCannotErasePreservedRollingWindows() {
        var accumulator = TranscriptAccumulator()
        let words = ["किताब", "café", "🪷."] + (0..<177).map { "word\($0)" }
        let first = words[..<120].joined(separator: " ")
        let later = words[60...].joined(separator: " ")
        accumulator.update(first, segments: segments(first, start: 0, step: 0.2))
        accumulator.update(later, segments: segments(later, start: 12, step: 0.2))
        // Zero matches an old boundary, but its contracted coverage cannot
        // establish that this tail is a whole-session revision.
        let tail = words.suffix(12).joined(separator: " ") + "!"
        XCTAssertEqual(accumulator.update(tail, segments: segments(tail, start: 0, step: 0.2)), words.joined(separator: " "))
        XCTAssertTrue(accumulator.hasUnalignedHypothesis)
        XCTAssertEqual(accumulator.text.split(separator: " ").count, 180)
    }

    func testResetTimingRemainsUncertainEvenWhenLatestWindowTextMatches() {
        var accumulator = TranscriptAccumulator()
        let words = (0..<180).map { "word\($0)" }
        let first = words[..<120].joined(separator: " ")
        let later = words[60...].joined(separator: " ")
        accumulator.update(first, segments: segments(first, start: 0, step: 0.2))
        accumulator.update(later, segments: segments(later, start: 12, step: 0.2))
        XCTAssertEqual(accumulator.update(later, segments: segments(later, start: 0, step: 0.2)), words.joined(separator: " "))
        XCTAssertTrue(accumulator.hasUnalignedHypothesis)
    }

    func testSameTaskBackwardTimestampsAreRevisionRatherThanGuessedNewAudio() {
        var accumulator = TranscriptAccumulator()
        accumulator.update("Before", segments: segments("Before", start: 20))
        accumulator.update("Later", segments: segments("Later", start: 50))
        XCTAssertEqual(accumulator.text, "Before Later")
        XCTAssertEqual(accumulator.update("Revised whole", segments: segments("Revised whole", start: 0)), "Revised whole")
    }

    func testUTF16RangesPreserveUnicodePunctuationAndLiteralRepetition() {
        var accumulator = TranscriptAccumulator()
        let first = "किताब café 🪷."
        accumulator.update(first, segments: segments(first, start: 1))
        let later = "नहीं, 42 — café café!"
        XCTAssertEqual(accumulator.update(later, segments: segments(later, start: 30)), first + " " + later)
        XCTAssertEqual(accumulator.update(later, segments: segments(later, start: 30)), first + " " + later)
    }

    private func segments(_ text: String, start: Double, step: Double = 0.3) -> [TranscriptSegment] {
        let regex = try! NSRegularExpression(pattern: "\\S+")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated().map {
            TranscriptSegment(timestamp: start + Double($0.offset) * step, duration: step * 0.8, range: $0.element.range)
        }
    }
}
