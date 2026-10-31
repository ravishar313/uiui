import Foundation
import PhononCoreML
import XCTest
@testable import UIUI

final class LocalSpeechModelTests: XCTestCase {
    func testProductSelectionAndWarmFactoryUsePhononOnSupportedMacs() {
        if #available(macOS 15.0, *) {
            XCTAssertEqual(LocalSpeechModel.name, "Phonon 2")
            XCTAssertTrue(LocalSpeechModel.makeDecoder() is PhononStreamingDecoder)
            XCTAssertEqual(LocalSpeechModel.directory, PhononSpeechModel.directory)
            XCTAssertEqual(LocalCleanupModel.name, "MiniLM")
            XCTAssertTrue(LocalCleanupModel.speechSummary.contains("Phonon 2"))
            let options = PhononSpeechModel.makeOptions()
            XCTAssertEqual(options.functions, [15])
            XCTAssertEqual(options.eagerFunctions, [15])
            XCTAssertFalse(options.backgroundLoad)
            XCTAssertEqual(options.decoderWorkers, 1)
            XCTAssertEqual(options.encoderInFlight, 1)
            XCTAssertTrue(options.windowDecodeCacheEnabled)
        }
        XCTAssertTrue(LocalSpeechModel.supports(locale: "en-IN"))
        XCTAssertFalse(LocalSpeechModel.supports(locale: "hi-IN"))
    }

    func testEncoderBoundaryPlanningCoversAllPCMWithoutOversizedWindow() {
        if #available(macOS 15.0, *) {
            let options = PhononSpeechModel.makeOptions()
            for count in [239_600, 239_839, 239_840, 239_999, 240_000, 240_001, 480_000] {
                let rms = [Float](repeating: 0.1, count: (count + 799) / 800)
                let windows = Windower.plan(rms: rms, count: count, windowS: options.windowSeconds,
                    bandMinS: options.bandMinSeconds, overlapS: options.overlapSeconds,
                    singleShotMaxS: options.singleShotMaxSeconds!)
                XCTAssertEqual(windows.first?.start, 0)
                XCTAssertEqual(windows.last?.end, count)
                for (index, window) in windows.enumerated() {
                    let requiredSeconds = Double((window.end - window.start) / 160) * 0.01 + 0.02
                    XCTAssertLessThanOrEqual(requiredSeconds, 15)
                    if index > 0 { XCTAssertLessThanOrEqual(window.start, windows[index - 1].end) }
                }
            }
        }
    }

    func testMissingOrTraversingModelManifestFailsWithoutNativeLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(PhononSpeechModel.isInstalled(at: directory))
        let manifest: [String: Any] = ["repository": PhononSpeechModel.repository, "revision": PhononSpeechModel.revision,
             "container_sha256": PhononSpeechModel.containerSHA256,
             "files": [["path": "../decoder.bin", "bytes": 1, "sha256": String(repeating: "a", count: 64)]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("assets.json"))
        XCTAssertFalse(PhononSpeechModel.isInstalled(at: directory))
        XCTAssertThrowsError(try PhononSpeechModel.verify(at: directory))
    }
}
