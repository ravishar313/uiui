// UIUI pilot modification: isolated native vocabulary bias and decoder override.
// decoder.bin reader and the compiled greedy decoder (PhononTDT, a prebuilt library in Binaries/).
// The tables are parsed once (DecoderTables) into ONE C handle; every decoder (workers, the single-window handle) is a clone that
// shares those tables, so the file's 17.7 MB live once in memory. Format v2 stores the 6-bit codes packed (4 codes in 3 bytes).
// Format v3 stores every matrix uncompressed (dtype float32 or float16, no scale arrays; biases use the same dtype) and decodes
// with the custom FP32 path only, since the compiled reference decoder reads int8 codes.
import Foundation
import PilotTDT

public final class DecoderTables {
    struct Header: Decodable {
        struct Arr: Decodable { let name: String; let dtype: String; let shape: [Int]; let offset: Int; let bytes: Int }
        let format: String; let arrays: [Arr]; let vocab: [String]; let durations: [Int32]; let blank: Int32; let max_symbols: Int32
        let V: Int32; let E: Int32; let H: Int32; let nhead: Int32; let container_sha256: String
    }
    let header: Header
    let base: UnsafeMutableRawPointer
    public var vocab: [String] { header.vocab }
    public var containerSHA256: String { header.container_sha256 }

    // Validate the complete container before allocating tables or passing any
    // pointer into C. Internal entry point also permits parser-only tests.
    static func validatedHeader(in d: Data) throws -> Header {
        func reject(_ message: String) -> NSError { NSError(domain: "PhononCoreML.DecoderBin", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard d.count >= 4, d.count <= 128 * 1024 * 1024 else { throw reject("decoder.bin size is outside supported bounds") }
        let hlen = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard hlen > 0, hlen <= 2 * 1024 * 1024, hlen <= d.count - 4 else { throw reject("Invalid decoder header length") }
        let header = try JSONDecoder().decode(Header.self, from: d.subdata(in: 4..<(4 + hlen)))
        guard ["phonon2-decoder-bin-v1", "phonon2-decoder-bin-v2", "phonon2-decoder-bin-v3"].contains(header.format) else { throw reject("Unsupported decoder format") }
        let isFloat = header.format == "phonon2-decoder-bin-v3"
        // v1/v2 containers keep their original 32 MB bound; only the uncompressed v3 container may be larger.
        guard isFloat || d.count <= 32 * 1024 * 1024 else { throw reject("decoder.bin size is outside supported bounds") }
        guard header.V == 8193, header.E == 640, header.H == 640, header.nhead == 8198,
              header.blank == 8192, header.max_symbols == 10, header.durations == [0, 1, 2, 3, 4],
              header.vocab.count == 8192, header.vocab.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              header.container_sha256.utf8.count == 64,
              header.container_sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw reject("Decoder does not match the supported Phonon-2 schema")
        }
        let quantized = header.format == "phonon2-decoder-bin-v2" ? "int6p" : "int8"
        // v3: one float dtype for every matrix and bias, taken from the first matrix.
        let floatType = header.arrays.first { $0.name == "decoder.embedding.weight" }?.dtype ?? ""
        guard !isFloat || floatType == "float32" || floatType == "float16" else { throw reject("Unsupported float decoder dtype") }
        let biasType = isFloat ? floatType : "float16"
        var expected: [String: (String, [Int])] = [:]
        func matrix(_ name: String, _ rows: Int, _ columns: Int) {
            if isFloat { expected[name] = (floatType, [rows, columns]); return }
            expected[name + ".q"] = (quantized, [rows, columns])
            expected[name + ".scale"] = ("float16", [rows])
        }
        matrix("decoder.embedding.weight", 8193, 640)
        for layer in 0..<2 { for kind in ["ih", "hh"] {
            matrix("decoder.lstm.weight_\(kind)_l\(layer)", 2560, 640)
            expected["decoder.lstm.bias_\(kind)_l\(layer)"] = (biasType, [2560])
        }}
        matrix("decoder.decoder_projector.weight", 640, 640)
        matrix("joint.head.weight", 8198, 640)
        expected["decoder.decoder_projector.bias"] = (biasType, [640])
        expected["joint.head.bias"] = (biasType, [8198])
        guard header.arrays.count == expected.count else { throw reject("Wrong decoder array count") }
        var seen = Set<String>(), spans: [(Int, Int)] = []
        let body = 4 + hlen, remaining = d.count - body
        for a in header.arrays {
            guard seen.insert(a.name).inserted, let schema = expected[a.name],
                  a.dtype == schema.0, a.shape == schema.1 else { throw reject("Duplicate, unknown, or incompatible decoder array") }
            // Dimensions above are exact, small constants; still use checked
            // arithmetic so future schema changes cannot introduce overflow.
            var n = 1
            for dimension in a.shape {
                let product = n.multipliedReportingOverflow(by: dimension)
                guard dimension > 0, !product.overflow else { throw reject("Invalid decoder shape") }
                n = product.partialValue
            }
            let required: Int
            if a.dtype == "int6p" {
                // Packed reads consume one complete three-byte group per four codes.
                let rounded = n.addingReportingOverflow(3)
                guard !rounded.overflow else { throw reject("Packed decoder shape overflow") }
                let bytes = (rounded.partialValue / 4).multipliedReportingOverflow(by: 3)
                guard !bytes.overflow else { throw reject("Packed decoder byte overflow") }
                required = bytes.partialValue
            } else {
                let bytes = n.multipliedReportingOverflow(by: a.dtype == "float32" ? 4 : a.dtype == "float16" ? 2 : 1)
                guard !bytes.overflow else { throw reject("Decoder byte overflow") }
                required = bytes.partialValue
            }
            let end = a.offset.addingReportingOverflow(a.bytes)
            guard a.offset >= 0, a.offset % 64 == 0, a.bytes == required,
                  !end.overflow, end.partialValue <= remaining else { throw reject("Invalid decoder array span or alignment") }
            spans.append((a.offset, end.partialValue))
            if a.dtype == "float32" {
                try d.withUnsafeBytes { raw in
                    for i in 0..<n {
                        let bits = raw.loadUnaligned(fromByteOffset: body + a.offset + 4 * i, as: UInt32.self).littleEndian
                        guard Float(bitPattern: bits).isFinite else { throw reject("Nonfinite weight") }
                    }
                }
            } else if a.dtype == "float16" {
                try d.withUnsafeBytes { raw in
                    for i in 0..<n {
                        let bits = raw.loadUnaligned(fromByteOffset: body + a.offset + 2 * i, as: UInt16.self).littleEndian
                        let value = Float(Float16(bitPattern: bits))
                        guard value.isFinite, !a.name.hasSuffix(".scale") || value >= 0 else { throw reject("Nonfinite weight or invalid scale") }
                    }
                }
            } else if a.dtype == "int8" {
                try d.withUnsafeBytes { raw in
                    for i in 0..<n {
                        let value = raw.load(fromByteOffset: body + a.offset + i, as: Int8.self)
                        guard (-32...31).contains(Int(value)) else { throw reject("Quantized code exceeds Int6 range") }
                    }
                }
            }
        }
        let sorted = spans.sorted { $0.0 < $1.0 }
        for i in 1..<sorted.count where sorted[i].0 < sorted[i - 1].1 { throw reject("Overlapping decoder arrays") }
        return header
    }

    public init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        let header = try Self.validatedHeader(in: d)
        self.header = header
        let hlen = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        let body = 4 + hlen
        let idx = Dictionary(uniqueKeysWithValues: header.arrays.map { ($0.name, $0) })
        // The JSON header has arbitrary byte length (the official file's body
        // starts at an odd address). Copy to explicitly aligned storage before
        // constructing UInt16 pointers for the C ABI.
        let alignedBody = UnsafeMutableRawPointer.allocate(byteCount: d.count - body, alignment: 64)
        defer { alignedBody.deallocate() }
        d.withUnsafeBytes { raw in alignedBody.copyMemory(from: raw.baseAddress!.advanced(by: body), byteCount: d.count - body) }
        if header.format == "phonon2-decoder-bin-v3" {
            // Float tables: pointers go straight to the 64-byte aligned copy; biases of a float16 file are widened by the C side.
            let half = header.arrays.first { $0.name == "decoder.embedding.weight" }!.dtype == "float16"
            func f(_ n: String) -> UnsafeRawPointer { UnsafeRawPointer(alignedBody.advanced(by: idx[n]!.offset)) }
            var durs = header.durations
            let h = durs.withUnsafeMutableBufferPointer { dp in
                pilot_tdt_create_float(header.V, header.E, header.H, header.nhead, Int32(header.durations.count), dp.baseAddress, header.blank, header.max_symbols, half ? 1 : 0,
                    f("decoder.embedding.weight"),
                    f("decoder.lstm.weight_ih_l0"), f("decoder.lstm.bias_ih_l0"), f("decoder.lstm.weight_hh_l0"), f("decoder.lstm.bias_hh_l0"),
                    f("decoder.lstm.weight_ih_l1"), f("decoder.lstm.bias_ih_l1"), f("decoder.lstm.weight_hh_l1"), f("decoder.lstm.bias_hh_l1"),
                    f("decoder.decoder_projector.weight"), f("decoder.decoder_projector.bias"), f("joint.head.weight"), f("joint.head.bias"))
            }
            guard let h else { throw NSError(domain: "PhononCoreML", code: 2, userInfo: [NSLocalizedDescriptionKey: "pilot_tdt_create_float failed"]) }
            base = h
            return
        }
        var unpacked: [String: [Int8]] = [:]          // v2: 6-bit packed codes -> int8 (temporary; the C side copies)
        for a in header.arrays where a.dtype == "int6p" {
            let n = a.shape.reduce(1, *); var out = [Int8](repeating: 0, count: n)
            d.withUnsafeBytes { raw in
                let p = raw.baseAddress!.advanced(by: body + a.offset).assumingMemoryBound(to: UInt8.self)
                var i = 0, j = 0
                while i < n {   // 4 codes (two's complement 6 bit) in 3 bytes, little-endian bit order
                    let w = UInt32(p[j]) | (UInt32(p[j + 1]) << 8) | (UInt32(p[j + 2]) << 16)
                    for k in 0..<4 where i + k < n { let v = Int32((w >> (6 * UInt32(k))) & 63); out[i + k] = Int8(v >= 32 ? v - 64 : v) }
                    i += 4; j += 3
                }
            }
            unpacked[a.name] = out
        }
        var keep: [[Int8]] = []
        func p(_ n: String) -> UnsafeRawPointer {
            if let u = unpacked[n] { keep.append(u); return keep.last!.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress!) } }
            return UnsafeRawPointer(alignedBody.advanced(by: idx[n]!.offset))
        }
        var durs = header.durations
        let h = durs.withUnsafeMutableBufferPointer { dp in
            pilot_tdt_create(header.V, header.E, header.H, header.nhead, Int32(header.durations.count), dp.baseAddress, header.blank, header.max_symbols,
                p("decoder.embedding.weight.q").assumingMemoryBound(to: Int8.self), p("decoder.embedding.weight.scale").assumingMemoryBound(to: UInt16.self),
                p("decoder.lstm.weight_ih_l0.q").assumingMemoryBound(to: Int8.self), p("decoder.lstm.weight_ih_l0.scale").assumingMemoryBound(to: UInt16.self), p("decoder.lstm.bias_ih_l0").assumingMemoryBound(to: UInt16.self),
                p("decoder.lstm.weight_hh_l0.q").assumingMemoryBound(to: Int8.self), p("decoder.lstm.weight_hh_l0.scale").assumingMemoryBound(to: UInt16.self), p("decoder.lstm.bias_hh_l0").assumingMemoryBound(to: UInt16.self),
                p("decoder.lstm.weight_ih_l1.q").assumingMemoryBound(to: Int8.self), p("decoder.lstm.weight_ih_l1.scale").assumingMemoryBound(to: UInt16.self), p("decoder.lstm.bias_ih_l1").assumingMemoryBound(to: UInt16.self),
                p("decoder.lstm.weight_hh_l1.q").assumingMemoryBound(to: Int8.self), p("decoder.lstm.weight_hh_l1.scale").assumingMemoryBound(to: UInt16.self), p("decoder.lstm.bias_hh_l1").assumingMemoryBound(to: UInt16.self),
                p("decoder.decoder_projector.weight.q").assumingMemoryBound(to: Int8.self), p("decoder.decoder_projector.weight.scale").assumingMemoryBound(to: UInt16.self), p("decoder.decoder_projector.bias").assumingMemoryBound(to: UInt16.self),
                p("joint.head.weight.q").assumingMemoryBound(to: Int8.self), p("joint.head.weight.scale").assumingMemoryBound(to: UInt16.self), p("joint.head.bias").assumingMemoryBound(to: UInt16.self))
        }
        withExtendedLifetime(keep) {}
        guard let h else { throw NSError(domain: "PhononCoreML", code: 2, userInfo: [NSLocalizedDescriptionKey: "pilot_tdt_create failed"]) }
        base = h
    }
    deinit { pilot_tdt_destroy(base) }
}

private final class DecoderCancellation {
    let check: () throws -> Void
    init(_ check: @escaping () throws -> Void) { self.check = check }
    var cancelled: Bool { do { try check(); return false } catch { return true } }
}
enum VocabularyConfigurationError: Error { case capacityExceeded }
enum DecoderConfigurationError: Error { case nativeAllocationFailed }

public final class TDTDecoder {
    let tables: DecoderTables
    private var cancellation: DecoderCancellation?
    private(set) var usesReferenceDecoder = true
    var handle: UnsafeMutableRawPointer?
    public var vocab: [String] { tables.vocab }
    public var containerSHA256: String { tables.containerSHA256 }

    public convenience init(url: URL, threads: Int32 = 1) throws { try self.init(tables: DecoderTables(url: url), threads: threads) }
    public init(tables: DecoderTables, threads: Int32 = 1, hotwords: [BiasTerm] = [], strength: Float = 0, forceCustom: Bool = false, suppressBoundaryBonus: Bool = false, selective: Bool = true, localMargin: Float = 2, checkCancellation: (() throws -> Void)? = nil, contextMode: Int32 = -1, contextMaxLoss: Double = 0, contextWeight: Double = 1, predictorCacheEnabled: Bool = true) throws {
        guard localMargin.isFinite, (0...8).contains(localMargin) else { throw NSError(domain: "PhononCoreML.Vocabulary", code: 3, userInfo: [NSLocalizedDescriptionKey: "Local acoustic margin must be finite and 0...8"]) }
        guard (-1...2).contains(contextMode), contextMaxLoss.isFinite, contextMaxLoss >= 0, contextWeight.isFinite, (1...16).contains(contextWeight) else { throw NSError(domain: "PhononCoreML.Vocabulary", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid vocabulary context configuration"]) }
        self.tables = tables
        handle = pilot_tdt_clone(tables.base)
        guard handle != nil else { throw NSError(domain: "PhononCoreML", code: 2, userInfo: [NSLocalizedDescriptionKey: "pilot_tdt_clone failed"]) }
        var configured = false
        defer { if !configured, let handle { pilot_tdt_destroy(handle); self.handle = nil } }
        if let checkCancellation {
            let box = DecoderCancellation(checkCancellation); self.cancellation = box
            pilot_tdt_cancellation(handle, { context in
                guard let context else { return 0 }
                return Unmanaged<DecoderCancellation>.fromOpaque(context).takeUnretainedValue().cancelled ? 1 : 0
            }, Unmanaged.passUnretained(box).toOpaque())
        }
        pilot_tdt_predictor_cache(handle, predictorCacheEnabled ? 1 : 0)
        pilot_tdt_handle_threads(handle, threads)
        let bias = try BiasPhrases(words: hotwords, vocabulary: tables.vocab, strength: strength)
        usesReferenceDecoder = !forceCustom && bias.phrases.isEmpty
        pilot_tdt_reference(handle, usesReferenceDecoder ? 1 : 0)
        var flat = bias.phrases.flatMap { $0 }; var lengths = bias.phrases.map { Int32($0.count) }
        flat.withUnsafeMutableBufferPointer { fp in lengths.withUnsafeMutableBufferPointer { lp in
            pilot_tdt_bias(handle, fp.baseAddress, lp.baseAddress, Int32(lp.count), strength)
        }}
        if contextMode >= 0 {
            pilot_tdt_context(handle, contextMode, contextMaxLoss)
            pilot_tdt_context_weight(handle, contextWeight)
        }
        if suppressBoundaryBonus {
            var ids = BiasPhrases.boundaryOnlyTokenIDs(in: tables.vocab)
            ids.withUnsafeMutableBufferPointer { p in pilot_tdt_suppress_tokens(handle, p.baseAddress, Int32(p.count)) }
        }
        if selective && !bias.phrases.isEmpty {
            var starts = BiasPhrases.wordStartTokenIDs(in: tables.vocab)
            starts.withUnsafeMutableBufferPointer { p in pilot_tdt_word_starts(handle, p.baseAddress, Int32(p.count)) }
            var boundaries = BiasPhrases.wordBoundaryTokenIDs(in: tables.vocab)
            boundaries.withUnsafeMutableBufferPointer { p in pilot_tdt_selective(handle, p.baseAddress, Int32(p.count), localMargin) }
        }
        guard pilot_tdt_configuration_status(handle) == 0 else {
            throw DecoderConfigurationError.nativeAllocationFailed
        }
        guard bias.phrases.isEmpty || pilot_tdt_bias_states(handle) > 1 else {
            throw VocabularyConfigurationError.capacityExceeded
        }
        configured = true
    }
    public var predictorCacheStatistics: (hits: UInt64, misses: UInt64) {
        var hits: UInt64 = 0, misses: UInt64 = 0
        pilot_tdt_predictor_cache_statistics(handle, &hits, &misses)
        return (hits, misses)
    }
    public var statistics: (attempts: Int, commits: Int, predictionSteps: Int, acceptedRegret: Float) {
        var a: Int32 = 0, c: Int32 = 0, s: Int32 = 0; var r: Float = 0
        pilot_tdt_statistics(handle, &a, &c, &s, &r)
        return (Int(a), Int(c), Int(s), r)
    }
    /// Shared custom weights only; original compiled decoder allocations are
    /// measured separately by the native process memory screen.
    public var weightMemory: [String: UInt64] {
        var compact: UInt64 = 0, floats: UInt64 = 0, biases: UInt64 = 0, scratch: UInt64 = 0
        guard pilot_tdt_weight_memory(handle, &compact, &floats, &biases, &scratch) == 0 else { return [:] }
        return ["compact_coefficient_bytes": compact, "retained_float32_coefficient_bytes": floats,
                "bias_bytes": biases, "maximum_gemv_scratch_bytes": scratch]
    }
    public func setThreads(_ n: Int32) { pilot_tdt_handle_threads(handle, n) }
    deinit { if let h = handle { pilot_tdt_destroy(h) } }

    // Public decode APIs retain the upstream nonthrowing signature. Invalid
    // input returns an empty result before any C call. The cap is deliberately
    // larger than the model's largest 35s function, but bounds output allocation.
    static let maximumEncoderFrames = 4096
    static func validEncoder(_ enc: [Float], frames: Int) -> Bool {
        guard frames >= 0, frames <= maximumEncoderFrames else { return false }
        let count = frames.multipliedReportingOverflow(by: 640)
        guard !count.overflow, enc.count == count.partialValue else { return false }
        return enc.allSatisfy { $0.isFinite }
    }

    /// enc: exact [T * 640] finite Float row-major data, 0...4096 frames.
    /// Invalid input and valid empty input return [] without entering C.
    public func decode(_ enc: [Float], frames T: Int) -> [Int32] {
        guard Self.validEncoder(enc, frames: T), T > 0 else { return [] }
        var out = [Int32](repeating: 0, count: max(64, 12 * T))
        let n = enc.withUnsafeBufferPointer { ep in out.withUnsafeMutableBufferPointer { op in pilot_tdt_decode(handle, ep.baseAddress, Int32(T), op.baseAddress, Int32(op.count)) } }
        return Array(out[0..<Int(n)])
    }
    /// Timed decode: token ids with the encoder frame (80 ms) each was emitted at and its predicted duration in frames.
    /// Invalid input and valid empty input return three empty arrays without entering C.
    public func decodeTimed(_ enc: [Float], frames T: Int) -> (tokens: [Int32], frame: [Int32], duration: [Int32]) {
        guard Self.validEncoder(enc, frames: T), T > 0 else { return ([], [], []) }
        let cap = max(64, 12 * T)
        var out = [Int32](repeating: 0, count: cap), fr = [Int32](repeating: 0, count: cap), du = [Int32](repeating: 0, count: cap)
        let n = enc.withUnsafeBufferPointer { ep in out.withUnsafeMutableBufferPointer { op in fr.withUnsafeMutableBufferPointer { fp in du.withUnsafeMutableBufferPointer { dp in
            pilot_tdt_decode_timed(handle, ep.baseAddress, Int32(T), op.baseAddress, fp.baseAddress, dp.baseAddress, Int32(cap)) } } } }
        return (Array(out[0..<Int(n)]), Array(fr[0..<Int(n)]), Array(du[0..<Int(n)]))
    }
    /// Pieces with the SentencePiece marker turned into a leading space; special tokens dropped (the pip engines' token text).
    public func timedTokens(_ d: (tokens: [Int32], frame: [Int32], duration: [Int32])) -> [TimedToken] {
        var out: [TimedToken] = []
        for i in 0..<d.tokens.count {
            let piece = vocab[Int(d.tokens[i])]
            if (piece.hasPrefix("<|") && piece.hasSuffix("|>")) || piece == "<unk>" || piece == "<pad>" { continue }
            out.append(TimedToken(piece: piece.replacingOccurrences(of: "\u{2581}", with: " "), start: Double(d.frame[i]) * Words.frameS, duration: Double(d.duration[i]) * Words.frameS))
        }
        return out
    }
    public func text(_ toks: [Int32]) -> String {
        var s = ""
        for t in toks {
            let piece = vocab[Int(t)]
            if (piece.hasPrefix("<|") && piece.hasSuffix("|>")) || piece == "<unk>" || piece == "<pad>" { continue }
            s += piece
        }
        return s.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
