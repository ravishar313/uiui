import Foundation
import XCTest
@testable import PhononCoreML

final class AudioWindowTests: XCTestCase {
    private final class ReadSource: AudioSource {
        let samples: [Float]
        var ranges: [Range<Int>] = []
        var count: Int { samples.count }
        init(_ samples: [Float]) { self.samples = samples }
        func read(_ range: Range<Int>) throws -> [Float] {
            ranges.append(range)
            return Array(samples[range])
        }
    }

    private func signal(_ count: Int) -> [Float] {
        (0..<count).map { i in
            // Several quiet runs and non-periodic amplitude changes exercise
            // both quiet-cut and overlapped plans, including partial RMS blocks.
            if i % 91_001 < 8_401 { return 0 }
            return Float((i * 17 % 211) - 105) / 256
        }
    }

    func testArrayWindowsBorrowExactRangeAndKeepSnapshotWhenOriginalChanges() throws {
        var samples: [Float] = [11, 0, -0.0, 0.25, -0.5, 12]
        let source = ArraySource(samples)
        let window = try source.readWindow(1..<5)
        XCTAssertEqual(window.map(\.bitPattern), samples[1..<5].map(\.bitPattern))
        // The optimization's purpose is to remove the window-sized allocation.
        // Storage identity checks that performance contract without a timer.
        source.samples.withUnsafeBufferPointer { original in
            window.withUnsafeBufferPointer { borrowed in
                XCTAssertEqual(borrowed.baseAddress, original.baseAddress!.advanced(by: 1))
            }
        }
        samples[2] = 0.75
        XCTAssertEqual(window.map(\.bitPattern), [Float(0), -Float.zero, 0.25, -0.5].map(\.bitPattern))
        XCTAssertEqual(try source.readWindow(5..<5).count, 0)
    }

    func testNonArraySourceKeepsItsReadContract() throws {
        let source = ReadSource([11, 1, 2, 3, 12])
        let window = try source.readWindow(1..<4)
        XCTAssertEqual(Array(window), [1, 2, 3])
        XCTAssertEqual(source.ranges, [1..<4])
    }

    func testBorrowedRMSMatchesStreamedReadsAndPlansAtChunkAndWindowBoundaries() throws {
        let pcm = signal(590_403)
        for count in [0, 1, 799, 800, 801, 159_999, 160_000, 160_001, 239_600, 560_000, pcm.count] {
            let samples = Array(pcm.prefix(count))
            let streamed = ReadSource(samples)
            let expected = try streamed.blockRMS()
            let actual = try ArraySource(samples).blockRMS()
            XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern), "count \(count)")
            XCTAssertEqual(Windower.plan(rms: actual, count: count),
                           Windower.plan(rms: expected, count: count))
            XCTAssertEqual(streamed.ranges.count, (count + 159_999) / 160_000)
        }
    }

    func testRMSReevaluatesReplacedShrunkAndGrowingSourcesWithoutRetainingPriorPCM() throws {
        let original = signal(160_801)
        var changed = original
        changed[10_000] = 100
        let sources = [original, Array(original.prefix(160_003)), changed, original + [0.25, -0.5]]
        for samples in sources {
            XCTAssertEqual(try ArraySource(samples).blockRMS().map(\.bitPattern),
                           try ReadSource(samples).blockRMS().map(\.bitPattern))
        }
        XCTAssertNotEqual(try ArraySource(original).blockRMS(), try ArraySource(changed).blockRMS())
    }

    func testLogMelBorrowedNonzeroBasedWindowsAreBitIdenticalForBothFrameRules() {
        let mel = LogMel(), pcm = signal(5_000)
        for rule in ["hf", "pip"] {
            for count in [0, 1, 159, 160, 161, 319, 320, 321, 4_801] where count > 0 || rule == "hf" {
                let window = pcm[37..<(37 + count)]
                let expected = mel.features(Array(window), rule: rule)
                let actual = mel.features(window: window, rule: rule)
                XCTAssertEqual(actual.1, expected.1, "\(rule), count \(count)")
                XCTAssertEqual(actual.0.map(\.bitPattern), expected.0.map(\.bitPattern), "\(rule), count \(count)")
            }
        }
    }
}
