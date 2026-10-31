import Foundation
import XCTest
@testable import PhononCoreML

final class DecoderContainerTests: XCTestCase {
    // Synthetic zero tables exercise only validation, never native allocation.
    func header() -> ([String: Any], Int) {
        var arrays: [[String: Any]] = [], offset = 0
        func add(_ name: String, _ shape: [Int], _ dtype: String) {
            offset = (offset + 63) / 64 * 64
            let n = shape.reduce(1, *), bytes = dtype == "int6p" ? ((n + 3) / 4) * 3 : n * 2
            arrays.append(["name": name, "dtype": dtype, "shape": shape, "offset": offset, "bytes": bytes]); offset += bytes
        }
        func matrix(_ name: String, _ rows: Int, _ cols: Int) { add(name + ".q", [rows,cols], "int6p"); add(name + ".scale", [rows], "float16") }
        matrix("decoder.embedding.weight",8193,640)
        for l in 0..<2 { for k in ["ih","hh"] { matrix("decoder.lstm.weight_\(k)_l\(l)",2560,640); add("decoder.lstm.bias_\(k)_l\(l)",[2560],"float16") } }
        matrix("decoder.decoder_projector.weight",640,640); matrix("joint.head.weight",8198,640)
        add("decoder.decoder_projector.bias",[640],"float16");add("joint.head.bias",[8198],"float16")
        return (["format":"phonon2-decoder-bin-v2","V":8193,"E":640,"H":640,"nhead":8198,"blank":8192,"max_symbols":10,"durations":[0,1,2,3,4],"container_sha256":String(repeating:"0",count:64),"vocab":Array(repeating:"a",count:8192),"arrays":arrays],offset)
    }
    /// v3 container: every matrix uncompressed under its own name (no .q/.scale), biases in the same dtype.
    func floatHeader(_ dtype: String) -> ([String: Any], Int) {
        var arrays: [[String: Any]] = [], offset = 0
        let width = dtype == "float32" ? 4 : 2
        func add(_ name: String, _ shape: [Int]) {
            offset = (offset + 63) / 64 * 64
            let bytes = shape.reduce(1, *) * width
            arrays.append(["name": name, "dtype": dtype, "shape": shape, "offset": offset, "bytes": bytes]); offset += bytes
        }
        add("decoder.embedding.weight", [8193, 640])
        for l in 0..<2 { for k in ["ih", "hh"] { add("decoder.lstm.weight_\(k)_l\(l)", [2560, 640]); add("decoder.lstm.bias_\(k)_l\(l)", [2560]) } }
        add("decoder.decoder_projector.weight", [640, 640]); add("joint.head.weight", [8198, 640])
        add("decoder.decoder_projector.bias", [640]); add("joint.head.bias", [8198])
        return (["format":"phonon2-decoder-bin-v3","V":8193,"E":640,"H":640,"nhead":8198,"blank":8192,"max_symbols":10,"durations":[0,1,2,3,4],"container_sha256":String(repeating:"0",count:64),"vocab":Array(repeating:"a",count:8192),"arrays":arrays],offset)
    }
    func testFloatContainersValidateAndStayLargerThanV2Limit() throws {
        for dtype in ["float32", "float16"] {
            let (h, size) = floatHeader(dtype)
            XCTAssertEqual(try DecoderTables.validatedHeader(in: data(h, bodySize: size)).format, "phonon2-decoder-bin-v3")
        }
    }
    func testFloatContainerRejectsMixedDtypeScalesNonfiniteAndWrongSizes() throws {
        func invalid(_ mutate: (inout [String: Any], inout [[String: Any]]) -> Void) throws {
            var (h, size) = floatHeader("float32"); var a = h["arrays"] as! [[String: Any]]
            mutate(&h, &a); h["arrays"] = a
            XCTAssertThrowsError(try DecoderTables.validatedHeader(in: data(h, bodySize: size)))
        }
        try invalid { _, a in a[1]["dtype"] = "float16"; a[1]["bytes"] = 2560 * 2 }        // bias dtype differs from the matrices
        try invalid { _, a in a[0]["dtype"] = "int6p" }
        try invalid { _, a in a[0]["dtype"] = "int8"; a[0]["bytes"] = 8193 * 640 }
        try invalid { _, a in a[0]["shape"] = [640, 8193] }
        try invalid { _, a in a[0]["bytes"] = 8193 * 640 * 2 }
        try invalid { _, a in a.append(["name": "joint.head.weight.scale", "dtype": "float16", "shape": [8198], "offset": 0, "bytes": 16396]) }
        try invalid { h, _ in h["format"] = "phonon2-decoder-bin-v4" }
        // v2 keeps the 32 MB bound, v3 does not
        var (v2, v2size) = header(); v2["format"] = "phonon2-decoder-bin-v2"
        XCTAssertNoThrow(try DecoderTables.validatedHeader(in: data(v2, bodySize: v2size)))
        XCTAssertThrowsError(try DecoderTables.validatedHeader(in: data(v2, bodySize: 33 * 1024 * 1024)))
        let (h, size) = floatHeader("float32"), arrays = h["arrays"] as! [[String: Any]]
        let json = try JSONSerialization.data(withJSONObject: h, options: [.sortedKeys]), body = 4 + json.count
        for name in ["decoder.embedding.weight", "joint.head.bias"] {
            let offset = body + (arrays.first { $0["name"] as? String == name }!["offset"] as! Int)
            for bits: UInt32 in [0x7f800000, 0x7fc00000, 0xff800000] {
                var d = try data(h, bodySize: size)
                for k in 0..<4 { d[offset + k] = UInt8((bits >> (8 * UInt32(k))) & 255) }
                XCTAssertThrowsError(try DecoderTables.validatedHeader(in: d))
            }
        }
    }
    func data(_ h: [String: Any], bodySize: Int) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject:h,options:[.sortedKeys]); var length = UInt32(json.count).littleEndian
        var d = withUnsafeBytes(of:&length) { Data($0) };d.append(json);d.append(Data(count:bodySize));return d
    }
    func assertInvalid(_ mutate: (inout [String: Any]) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        var (h,size) = header();mutate(&h)
        XCTAssertThrowsError(try DecoderTables.validatedHeader(in:data(h,bodySize:size)),file:file,line:line)
    }
    func testValidSyntheticSchemaAndOddHeaderAlignment() throws {
        let (h,size) = header(); let d = try data(h,bodySize:size)
        XCTAssertEqual(try DecoderTables.validatedHeader(in:d).vocab.count,8192)
    }
    func testShortAndOutOfRangeHeadersThrowThroughInitializer() throws {
        let cases = [Data(),Data([1,2,3]),Data([255,255,255,255]),Data([10,0,0,0,123,125])]
        for d in cases {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try d.write(to:url);defer { try? FileManager.default.removeItem(at:url) }
            XCTAssertThrowsError(try DecoderTables(url:url))
        }
    }
    func testSchemaMismatchRejectsVocabularyDimensionsDurationsAndSymbolLimits() throws {
        for key in ["V","E","H","nhead","blank","max_symbols"] { try assertInvalid { $0[key] = -1 } }
        try assertInvalid { $0["vocab"] = ["one"] }
        try assertInvalid { $0["durations"] = [0,-1,2,3,4] }
        try assertInvalid { $0["durations"] = [0,1,2,3,100000] }
        try assertInvalid { $0["container_sha256"] = "invalid" }
    }
    func testMissingDuplicateUnknownAndWrongDtypeArrays() throws {
        try assertInvalid { h in var a=h["arrays"] as! [[String:Any]];a.removeLast();h["arrays"]=a }
        try assertInvalid { h in var a=h["arrays"] as! [[String:Any]];a[1]=a[0];h["arrays"]=a }
        for (key,value): (String,Any) in [("name","unknown"),("dtype","float32"),("shape",[-1,640]),("shape",[Int.max,Int.max])] {
            try assertInvalid { h in var a=h["arrays"] as! [[String:Any]];a[0][key]=value;h["arrays"]=a }
        }
    }
    func testSpansRejectNegativeOverflowTruncatedOverlapAndAlignment() throws {
        for (key,value) in [("offset",-64),("offset",Int.max),("bytes",-1),("bytes",Int.max),("offset",1),("bytes",3932639)] {
            try assertInvalid { h in var a=h["arrays"] as! [[String:Any]];a[0][key]=value;h["arrays"]=a }
        }
        try assertInvalid { h in var a=h["arrays"] as! [[String:Any]];a[1]["offset"]=0;h["arrays"]=a }
        let (h,size) = header();var d=try data(h,bodySize:size);d.removeLast()
        XCTAssertThrowsError(try DecoderTables.validatedHeader(in:d))
    }
    func testNonfiniteScalesBiasesAndNegativeScalesReject() throws {
        let (h,size)=header(), arrays=h["arrays"] as! [[String:Any]]
        let json=try JSONSerialization.data(withJSONObject:h,options:[.sortedKeys]),body=4+json.count
        for name in ["decoder.embedding.weight.scale","joint.head.bias"] {
            let a=arrays.first { $0["name"] as? String == name }!, offset=body+(a["offset"] as! Int)
            for bits: UInt16 in [0x7c00,0x7e00,0xfc00] { var d=try data(h,bodySize:size);d[offset]=UInt8(bits&255);d[offset+1]=UInt8(bits>>8);XCTAssertThrowsError(try DecoderTables.validatedHeader(in:d)) }
        }
        let a=arrays.first { ($0["name"] as! String).hasSuffix(".scale") }!,offset=body+(a["offset"] as! Int)
        var d=try data(h,bodySize:size);d[offset]=0;d[offset+1]=0xbc
        XCTAssertThrowsError(try DecoderTables.validatedHeader(in:d))
    }
}
