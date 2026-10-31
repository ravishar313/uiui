import XCTest
@testable import PhononCoreML

final class GluedNumberSpacingTests: XCTestCase {
    func fix(_ s: String) -> String { GluedNumberSpacing.apply(s) }

    func testSplitsProseWordsAndNumbers() {
        XCTAssertEqual(fix("we met at10 today"), "we met at 10 today")
        XCTAssertEqual(fix("in July2020."), "in July 2020.")
        XCTAssertEqual(fix("see statement1"), "see statement 1")
        XCTAssertEqual(fix("wait 5minutes"), "wait 5 minutes")
        XCTAssertEqual(fix("at 3pm sharp"), "at 3 pm sharp")
        XCTAssertEqual(fix("at 3pm sharp".replacingOccurrences(of: "3 pm", with: "3pm")), "at 3 pm sharp")
        XCTAssertEqual(fix("in1940 and 5minutes"), "in 1940 and 5 minutes")
    }

    func testLeavesIdentifiersAlone() {
        for s in ["HbA1c", "x1", "y0", "11th", "1990s", "3D", "md5", "ch1", "str1", "q3", "fy26", "10mm", "70km", "spo2", "80c", "in1"] {
            XCTAssertEqual(fix("the \(s) value"), "the \(s) value", s)
        }
    }

    func testLeavesUrlsEmailsPathsAndCodeAlone() {
        for s in ["https://example.com/statement1", "www.statement1.com", "statement1.example.com", "john at statement1@example.com",
                  "/usr/local/statement1", "C:\\temp\\statement1", "statement1_final", "statement1-b", "#statement1", "a=statement1+2"] {
            XCTAssertEqual(fix(s), s, s)
        }
    }

    func testIdempotentAndUnicodeSafe() {
        let samples = ["at10 July2020 statement1 5minutes 3pm", "नमस्ते at10 है", "कल at10 बजे 5minutes 😀 July2020", "", "no digits here", "e\u{301}at10"]
        for s in samples {
            let once = fix(s)
            XCTAssertEqual(fix(once), once, s)
        }
        XCTAssertEqual(fix("कल at10 बजे 😀 July2020"), "कल at 10 बजे 😀 July 2020")
        XCTAssertEqual(fix("नमस्ते सब ठीक है 12345"), "नमस्ते सब ठीक है 12345")
    }

    @available(macOS 15.0, *)
    func testTranscriptOptionDefaultsOn() {
        XCTAssertTrue(Transcriber.Options().spaceGluedNumbers)
    }

    /// Byte parity with the Python reference. Set DIGSP_PARITY_DIR to a folder holding dev-*.rows.jsonl and dev-*.digfix.rows.jsonl.
    func testParityWithPythonReference() throws {
        guard let dir = ProcessInfo.processInfo.environment["DIGSP_PARITY_DIR"] else { throw XCTSkip("DIGSP_PARITY_DIR not set") }
        func hyps(_ name: String) throws -> [String] {
            try String(contentsOfFile: dir + "/" + name, encoding: .utf8).split(separator: "\n").map {
                (try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])["hypothesis"] as! String
            }
        }
        var rows = 0, diffs = 0, monthOnly = 0
        for set in ["dev-sel", "dev-hold"] {
            let orig = try hyps(set + ".rows.jsonl"), want = try hyps(set + ".digfix.rows.jsonl")
            XCTAssertEqual(orig.count, want.count)
            for (o, w) in zip(orig, want) {
                rows += 1
                if Array(GluedNumberSpacing.apply(o, months: false).utf8) != Array(w.utf8) { diffs += 1 }
                if fix(o) != w { monthOnly += 1 }   // the only intended extension: month names before a year
            }
        }
        print("PARITY rows=\(rows) diffs=\(diffs) withMonths=\(monthOnly)")
        XCTAssertEqual(rows, 4588); XCTAssertEqual(diffs, 0); XCTAssertEqual(monthOnly, 4)
    }
}
