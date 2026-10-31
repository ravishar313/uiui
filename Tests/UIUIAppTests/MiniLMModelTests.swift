import CryptoKit
import Foundation
import XCTest
@testable import UIUI

final class MiniLMModelTests: XCTestCase {
    private func withAssets(_ run: (MiniLMModel.Assets) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-minilm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var files: [[String: Any]] = []
        for (name, bytes) in [("model_quantized.onnx", Data([1, 2, 3])), ("sentencepiece.bpe.model", Data([4, 5, 6]))] {
            try bytes.write(to: directory.appendingPathComponent(name))
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            files.append(["path": name, "bytes": bytes.count, "sha256": hash])
        }
        let manifest = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["files": files]).write(to: manifest)
        try await run(MiniLMModel.explicit(modelURL: directory.appendingPathComponent("model_quantized.onnx"),
                                           tokenizerURL: directory.appendingPathComponent("sentencepiece.bpe.model")))
    }

    func testManifestVerificationDetectsSameSizeTamperingWithoutLoadingModel() async throws {
        try await withAssets { assets in
            XCTAssertNoThrow(try MiniLMModel.verify(assets, cancellation: CleanupCancellation()))
            try Data([1, 2, 9]).write(to: assets.modelURL)
            XCTAssertThrowsError(try MiniLMModel.verify(assets, cancellation: CleanupCancellation()))
        }
    }

    func testManifestCannotAuthorizeAnUnlistedTokenizerOrPathTraversal() async throws {
        try await withAssets { assets in
            let foreign = assets.tokenizerURL.deletingLastPathComponent().appendingPathComponent("other.model")
            try Data([4, 5, 6]).write(to: foreign)
            let mismatched = MiniLMModel.explicit(modelURL: assets.modelURL, tokenizerURL: foreign)
            XCTAssertThrowsError(try MiniLMModel.verify(mismatched, cancellation: CleanupCancellation()))
            let hash = SHA256.hash(data: Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined()
            try JSONSerialization.data(withJSONObject: ["files": [["path": "../model_quantized.onnx", "bytes": 3, "sha256": hash]]])
                .write(to: assets.manifestURL)
            XCTAssertThrowsError(try MiniLMModel.verify(assets, cancellation: CleanupCancellation()))
        }
    }

    func testCancelledVerificationAndUnavailableEngineFailClosed() async throws {
        try await withAssets { assets in
            let cancellation = CleanupCancellation(); cancellation.cancel()
            XCTAssertThrowsError(try MiniLMModel.verify(assets, cancellation: cancellation)) { error in
                XCTAssertTrue(error is CancellationError)
            }
            // Missing manifest prevents native context creation; these are tiny
            // fixture bytes, not model assets, and inference is never reached.
            let engine = MiniLMCleanupEngine(modelURL: assets.modelURL, tokenizerURL: assets.tokenizerURL,
                                             manifestURL: assets.manifestURL.appendingPathExtension("missing"))
            await engine.prepare()
            XCTAssertFalse(engine.isReady)
            do {
                _ = try await engine.generate("hello", cancellation: CleanupCancellation())
                XCTFail("Unavailable engine must reject admission")
            } catch { XCTAssertTrue(error is CleanupFailure) }
            do {
                _ = try await engine.generate("hello", cancellation: cancellation)
                XCTFail("Cancelled request must reject admission")
            } catch { XCTAssertTrue(error is CancellationError) }
            await engine.shutdown()
            XCTAssertFalse(engine.isReady)
        }
    }
}
