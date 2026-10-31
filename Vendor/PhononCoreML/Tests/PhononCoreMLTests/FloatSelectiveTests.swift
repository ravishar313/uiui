import XCTest
import PilotTDT

/// Selective vocabulary bias on float-format (decoder.bin v3) tables. These handles have no compiled
/// reference decoder; the unbiased reference is a plain greedy decode over the same float weights.
final class FloatSelectiveTests: XCTestCase {
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        mutating func value(_ scale: Float) -> Float { Float(Int(next() >> 32) % 2001 - 1000) / 1000 * scale }
    }
    private let V: Int32 = 8, E: Int32 = 6, H: Int32 = 6, blank: Int32 = 7
    private let durations: [Int32] = [0, 1, 2]

    /// Tiny random float model. The handle owns copies of the bytes until `free()`.
    private final class Model {
        var handle: UnsafeMutableRawPointer?
        var buffers: [UnsafeMutableRawPointer] = []
        func free() { if let handle { pilot_tdt_destroy(handle) }; handle = nil; buffers.forEach { $0.deallocate() }; buffers = [] }
        deinit { free() }
    }
    private func makeModel(seed: UInt64, half: Bool) -> Model {
        var random = Generator(state: seed &* 0x9E3779B97F4A7C15 | 1)
        let m = Model()
        func table(_ count: Int, _ scale: Float) -> UnsafeRawPointer {
            let values = (0..<count).map { _ in random.value(scale) }
            let bytes = half ? 2 : 4
            let p = UnsafeMutableRawPointer.allocate(byteCount: count * bytes, alignment: 64)
            if half { let q = p.bindMemory(to: UInt16.self, capacity: count); for i in 0..<count { q[i] = Float16(values[i]).bitPattern } }
            else { let q = p.bindMemory(to: Float.self, capacity: count); for i in 0..<count { q[i] = values[i] } }
            m.buffers.append(p); return UnsafeRawPointer(p)
        }
        let v = Int(V), e = Int(E), h = Int(H), nhead = v + durations.count
        let emb = table(v * e, 2), ih0 = table(4 * h * e, 1.5), bih0 = table(4 * h, 0.5), hh0 = table(4 * h * h, 1.5), bhh0 = table(4 * h, 0.5)
        let ih1 = table(4 * h * h, 1.5), bih1 = table(4 * h, 0.5), hh1 = table(4 * h * h, 1.5), bhh1 = table(4 * h, 0.5)
        let proj = table(h * h, 1.5), projB = table(h, 0.5), head = table(nhead * h, 3), headB = table(nhead, 1)
        var d = durations
        m.handle = pilot_tdt_create_float(V, E, H, Int32(nhead), Int32(d.count), &d, blank, 4, half ? 1 : 0,
            emb, ih0, bih0, hh0, bhh0, ih1, bih1, hh1, bhh1, proj, projB, head, headB)
        return m
    }
    private func encoder(seed: UInt64, frames: Int) -> [Float] {
        var random = Generator(state: seed &* 0xD1B54A32D192ED03 | 1)
        return (0..<frames * Int(H)).map { _ in random.value(2) }
    }
    private struct Result: Equatable { var tokens: [Int32]; var frames: [Int32]; var durations: [Int32] }
    private func decode(_ handle: UnsafeMutableRawPointer, _ enc: [Float], frames: Int) -> Result {
        var out = [Int32](repeating: -1, count: 256), fr = out, du = out
        let n = Int(pilot_tdt_decode_timed(handle, enc, Int32(frames), &out, &fr, &du, 256))
        return Result(tokens: Array(out.prefix(n)), frames: Array(fr.prefix(n)), durations: Array(du.prefix(n)))
    }
    /// Configure vocabulary bias exactly like `DecoderBin` does: custom path, trie, word starts, optional selective.
    private func configure(_ handle: UnsafeMutableRawPointer, terms: [[Int32]], selective: Bool, strength: Float = 6, margin: Float = 6) {
        pilot_tdt_reference(handle, 0)
        var flat = terms.flatMap { $0 }, lengths = terms.map { Int32($0.count) }
        pilot_tdt_bias(handle, &flat, &lengths, Int32(lengths.count), strength)
        guard selective else { return }
        var starts: [Int32] = [1, 3, 5], boundaries: [Int32] = [1, 3, 5, 6]
        pilot_tdt_word_starts(handle, &starts, Int32(starts.count))
        pilot_tdt_selective(handle, &boundaries, Int32(boundaries.count), margin)
    }
    private func plain(_ model: Model, _ enc: [Float], frames: Int) -> Result {
        let h = pilot_tdt_clone(model.handle)!; defer { pilot_tdt_destroy(h) }
        pilot_tdt_reference(h, 1)
        return decode(h, enc, frames: frames)
    }

    func testReferenceIsPlainGreedyAndSelectiveWithoutTermsMatchesIt() {
        for half in [false, true] {
            let model = makeModel(seed: 3, half: half); defer { model.free() }
            XCTAssertNotNil(model.handle)
            for s in 0..<6 {
                let frames = 14, enc = encoder(seed: UInt64(s), frames: frames)
                let reference = plain(model, enc, frames: frames)
                // Unbiased custom path (strength 0) is the same greedy decode.
                let h = pilot_tdt_clone(model.handle)!; defer { pilot_tdt_destroy(h) }
                pilot_tdt_reference(h, 0)
                XCTAssertEqual(decode(h, enc, frames: frames), reference)
                XCTAssertFalse(reference.tokens.isEmpty)
            }
        }
    }

    /// Search for a seed/term where the selective path commits a name, then check the transaction semantics.
    func testSelectiveCommitsOnlyAcousticallyPlausibleCompleteNamesAndNeverWorsensRollback() {
        for half in [false, true] {
            var commitsSeen = 0, rollbacksSeen = 0
            for seed in 0..<40 {
                let model = makeModel(seed: UInt64(seed), half: half); defer { model.free() }
                for s in 0..<6 {
                    let frames = 14, enc = encoder(seed: UInt64(seed * 7 + s), frames: frames)
                    let reference = plain(model, enc, frames: frames)
                    for term in [[Int32(1), 2], [3, 4], [5, 2], [1, 3, 4], [3], [5]] {
                        let h = pilot_tdt_clone(model.handle)!; defer { pilot_tdt_destroy(h) }
                        configure(h, terms: [term], selective: true)
                        XCTAssertEqual(pilot_tdt_configuration_status(h), 0)
                        let selective = decode(h, enc, frames: frames)
                        var attempts: Int32 = 0, commits: Int32 = 0, steps: Int32 = 0; var regret: Float = 0
                        pilot_tdt_statistics(h, &attempts, &commits, &steps, &regret)
                        // Deterministic, and the reference pass leaves the prediction budget (4*T+64) intact.
                        XCTAssertEqual(decode(h, enc, frames: frames), selective)
                        if commits == 0 {
                            XCTAssertEqual(selective, reference, "no commit must return the unbiased reference exactly")
                            rollbacksSeen += 1
                        } else {
                            commitsSeen += 1
                            XCTAssertNotEqual(selective, reference)
                            XCTAssertGreaterThan(regret, 0)
                            XCTAssertLessThanOrEqual(regret, 6 * Float(commits))
                            XCTAssertTrue(selective.tokens.contains(term[0]))
                            XCTAssertTrue(zip(selective.frames, selective.frames.dropFirst()).allSatisfy { $0 <= $1 })
                        }
                        // Plain (non-selective) bias on the same float weights is still available and finite.
                        let p = pilot_tdt_clone(model.handle)!; defer { pilot_tdt_destroy(p) }
                        configure(p, terms: [term], selective: false)
                        XCTAssertFalse(decode(p, enc, frames: frames).tokens.isEmpty)
                    }
                }
            }
            XCTAssertGreaterThan(rollbacksSeen, 0)
            XCTAssertGreaterThan(commitsSeen, 0, "fixture search found no committed selective bias (half=\(half))")
        }
    }

    func testCancellationIsHonoredWithoutAReferenceHandle() {
        let model = makeModel(seed: 5, half: false); defer { model.free() }
        let frames = 14, enc = encoder(seed: 1, frames: frames)
        let h = pilot_tdt_clone(model.handle)!; defer { pilot_tdt_destroy(h) }
        configure(h, terms: [[1, 2]], selective: true)
        pilot_tdt_cancellation(h, { _ in 1 }, nil)
        XCTAssertEqual(decode(h, enc, frames: frames).tokens, [])
    }
}
