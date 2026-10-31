import XCTest
import PilotTDT

final class QuantizedTests: XCTestCase {
    private struct Generator {
        var state: UInt64 = 0x6d6174726978
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func value() -> Float { Float(Int(next() >> 32) % 2001 - 1000) / 1000 }
    }

    private func compare(rows: Int, cols: Int, scales: [UInt16]? = nil) {
        var random = Generator()
        let codes = (0..<rows*cols).map { _ in Int8(Int(random.next() >> 32) % 64 - 32) }
        let scale = scales ?? (0..<rows).map { _ in Float16(Float(abs(random.value())) / 8).bitPattern }
        let x = (0..<cols).map { _ in random.value() }
        let bias = (0..<rows).map { _ in random.value() }
        var output = [Float](repeating: .nan, count: rows)
        var dense = output
        var compactBytes: UInt64 = 0, floatBytes: UInt64 = UInt64.max, scratchBytes: UInt64 = 0
        XCTAssertEqual(pilot_quantized_probe(codes, scale, Int32(rows), Int32(cols), x, bias,
            &output, &dense, &compactBytes, &floatBytes, &scratchBytes), 0)
        for i in 0..<rows {
            XCTAssertTrue(output[i].isFinite)
            XCTAssertEqual(output[i], dense[i], accuracy: max(0.00002, abs(dense[i]) * 0.000002), "row \(i)")
        }
        XCTAssertEqual(output.indices.max(by: { output[$0] < output[$1] }), dense.indices.max(by: { dense[$0] < dense[$1] }))
        XCTAssertEqual(compactBytes, UInt64(rows * cols + rows * 2))
        XCTAssertEqual(floatBytes, 0, "Scoring must never retain an r*c FP32 weight table")
        XCTAssertEqual(scratchBytes, 65_536)
        if rows * cols > 16_384 { XCTAssertLessThan(scratchBytes, UInt64(rows * cols * 4)) }
    }

    func testSeededRandomGEMVMatchesDenseBLASAcrossBlockAndVectorTails() {
        for shape in [(1, 1), (17, 7), (65, 257), (73, 640), (129, 641), (640, 640), (8198, 640)] {
            compare(rows: shape.0, cols: shape.1)
        }
    }

    func testFiniteHalfExtremeScalesAndCancellationMatchDenseBLAS() {
        // zero, minimum subnormal, maximum subnormal, minimum normal, a typical
        // scale, the largest finite half, and negative finite values.
        let extremes: [UInt16] = [0, 1, 0x03ff, 0x0400, 0x2400, 0x7bff, 0x8001, 0xfbff]
        compare(rows: 80, cols: 640, scales: (0..<80).map { extremes[$0 % extremes.count] })
    }

    func testEmbeddingDequantizesOnlyRequestedRowWithIdenticalRounding() {
        let codes: [Int8] = [-32, -1, 0, 31, 3, 2, 1, 0]
        let scales: [UInt16] = [Float16(0.03125).bitPattern, 1]
        var output = [Float](repeating: .nan, count: 4)
        XCTAssertEqual(pilot_quantized_row_probe(codes, scales, 2, 4, 0, &output), 0)
        XCTAssertEqual(output, codes.prefix(4).map { Float($0) * Float(Float16(bitPattern: scales[0])) })
        XCTAssertEqual(pilot_quantized_row_probe(codes, scales, 2, 4, 1, &output), 0)
        XCTAssertEqual(output, codes.suffix(4).map { Float($0) * Float(Float16(bitPattern: scales[1])) })
        XCTAssertEqual(pilot_quantized_row_probe(codes, scales, 2, 4, -1, &output), -1)
        XCTAssertEqual(pilot_quantized_row_probe(codes, scales, 2, 4, 2, &output), -1)
    }

    func testInvalidDimensionsNonfiniteInputsAndOverflowReject() {
        let codes: [Int8] = [31], scale: [UInt16] = [Float16(1).bitPattern]
        var output: [Float] = [0]
        func probe(_ rows: Int32, _ cols: Int32, _ scales: [UInt16], _ input: [Float], _ bias: [Float]) -> Int32 {
            pilot_quantized_probe(codes, scales, rows, cols, input, bias, &output, nil, nil, nil, nil)
        }
        XCTAssertEqual(probe(0, 1, scale, [1], [0]), -1)
        XCTAssertEqual(probe(1, 0, scale, [1], [0]), -1)
        XCTAssertEqual(probe(Int32.max, Int32.max, scale, [1], [0]), -1)
        for bits: UInt16 in [0x7c00, 0xfc00, 0x7e00] {
            XCTAssertEqual(probe(1, 1, [bits], [1], [0]), -1)
        }
        for value: Float in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(probe(1, 1, scale, [value], [0]), -1)
            XCTAssertEqual(probe(1, 1, scale, [1], [value]), -1)
        }
        XCTAssertEqual(probe(1, 1, [0x7bff], [.greatestFiniteMagnitude], [0]), -1)
    }

    func testParallelWorkersKeepIdenticalBlockShapesAndExactRowResults() {
        for (rows, cols) in [(65, 640), (129, 257), (8198, 640)] {
            var random = Generator()
            let codes = (0..<rows*cols).map { _ in Int8(Int(random.next() >> 32) % 64 - 32) }
            let scales = (0..<rows).map { _ in Float16(abs(random.value()) / 8).bitPattern }
            let input = (0..<cols).map { _ in random.value() }
            let bias = (0..<rows).map { _ in random.value() }
            var serial: [Float] = []
            for workers: Int32 in [1, 2, 4] {
                var result = [Float](repeating: .nan, count: rows), dense = result
                var compact: UInt64 = 0, floats: UInt64 = UInt64.max, scratch: UInt64 = 0
                XCTAssertEqual(pilot_quantized_parallel_probe(codes, scales, Int32(rows), Int32(cols), workers,
                    input, bias, &result, &dense, &compact, &floats, &scratch), 0)
                if workers == 1 { serial = result }
                XCTAssertEqual(result.map(\.bitPattern), serial.map(\.bitPattern), "workers=\(workers)")
                for i in result.indices {
                    XCTAssertEqual(result[i], dense[i], accuracy: max(0.00002, abs(dense[i]) * 0.000002))
                }
                XCTAssertEqual(floats, 0)
                XCTAssertEqual(compact, UInt64(rows * cols + rows * 2))
                let blockRows = 16_384 / cols
                let jobs = min(Int(workers), (rows + blockRows - 1) / blockRows)
                XCTAssertEqual(scratch, UInt64(jobs * 65_536))
            }
        }
        var output: Float = 0
        for workers: Int32 in [0, 5] {
            XCTAssertEqual(pilot_quantized_parallel_probe([Int8(1)], [Float16(1).bitPattern], 1, 1, workers,
                [Float(1)], [Float(0)], &output, nil, nil, nil, nil), -1)
        }
    }

    // MARK: uncompressed float matrices (decoder.bin v3)

    private func floatMatrixReference(_ w: [Float], _ x: [Float], _ b: [Float], rows: Int, cols: Int) -> [Double] {
        (0..<rows).map { i in (0..<cols).reduce(Double(b[i])) { $0 + Double(w[i * cols + $1]) * Double(x[$1]) } }
    }

    func testFloat32AndFloat16GEMVMatchDoubleReferenceAcrossWorkers() {
        var random = Generator()
        for (rows, cols) in [(1, 1), (17, 7), (73, 640), (640, 640), (8198, 640)] {
            let w = (0..<rows * cols).map { _ in random.value() }
            let x = (0..<cols).map { _ in random.value() }, b = (0..<rows).map { _ in random.value() }
            let half = w.map { Float16($0).bitPattern }
            let wHalf = half.map { Float(Float16(bitPattern: $0)) }
            for workers in Int32(1)...4 {
                var out32 = [Float](repeating: .nan, count: rows), out16 = out32
                XCTAssertEqual(pilot_float_matrix_probe(w, 0, Int32(rows), Int32(cols), workers, x, b, &out32), 0)
                XCTAssertEqual(pilot_float_matrix_probe(half, 1, Int32(rows), Int32(cols), workers, x, b, &out16), 0)
                let ref32 = floatMatrixReference(w, x, b, rows: rows, cols: cols)
                let ref16 = floatMatrixReference(wHalf, x, b, rows: rows, cols: cols)
                for i in 0..<rows {
                    XCTAssertEqual(Double(out32[i]), ref32[i], accuracy: 1e-3 + abs(ref32[i]) * 1e-5, "f32 row \(i)")
                    // float16 weights widen exactly, so the result equals the float32 GEMV on the widened values
                    XCTAssertEqual(Double(out16[i]), ref16[i], accuracy: 1e-3 + abs(ref16[i]) * 1e-5, "f16 row \(i)")
                }
            }
        }
    }

    func testFloatMatrixRejectsNonfiniteValuesBadDtypeAndWorkers() {
        var output = [Float](repeating: 0, count: 1)
        for bad: Float in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(pilot_float_matrix_probe([bad], 0, 1, 1, 1, [1], [0], &output), -1)
        }
        for bits: UInt16 in [0x7c00, 0x7e00, 0xfc00] {
            XCTAssertEqual(pilot_float_matrix_probe([bits], 1, 1, 1, 1, [1], [0], &output), -1)
        }
        XCTAssertEqual(pilot_float_matrix_probe([Float(1)], 2, 1, 1, 1, [1], [0], &output), -1)
        XCTAssertEqual(pilot_float_matrix_probe([Float(1)], 0, 1, 1, 5, [1], [0], &output), -1)
        XCTAssertEqual(pilot_float_matrix_probe([Float(2)], 0, 1, 1, 1, [3], [1], &output), 0)
        XCTAssertEqual(output[0], 7)
    }
}
