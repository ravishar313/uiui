import XCTest
@testable import UIUICore

final class SoundCueSynthTests: XCTestCase {
    func testCuesAreShortAudibleUnclippedAndStartAndEndNearZero() {
        for cue in SoundCue.allCases {
            let samples = SoundCueSynth.samples(for: cue)
            let seconds = Double(samples.count) / Double(SoundCueSynth.sampleRate)
            XCTAssertGreaterThan(seconds, 0.1); XCTAssertLessThan(seconds, 0.3)
            XCTAssertLessThan(abs(Int(samples.first ?? 1)), 400)
            XCTAssertLessThan(abs(Int(samples.last ?? 1)), 400)
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, 4_000, "\(cue) is inaudible")
            XCTAssertLessThan(peak, 32_000, "\(cue) clips")
        }
    }

    func testWavHeaderDescribesThePayload() {
        let wav = SoundCueSynth.wavData(for: .start)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        let declared = wav[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        XCTAssertEqual(declared, wav.count - 44)
    }
}
