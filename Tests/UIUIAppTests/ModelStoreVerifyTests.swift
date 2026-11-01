import CryptoKit
import XCTest
@testable import UIUI
@testable import UIUICore

final class ModelStoreVerifyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    /// Writes a pack for a model this app has never heard of and returns its id.
    private func writeFuturePack() throws -> String {
        let weights = Data("future weights".utf8)
        try weights.write(to: directory.appendingPathComponent("decoder.bin"))
        let hash = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()
        let manifest = Data("""
        {"repository":"uiui/S2","revision":"future","container_sha256":"\(String(repeating: "0", count: 64))",\
        "files":[{"path":"decoder.bin","bytes":\(weights.count),"sha256":"\(hash)"}]}
        """.utf8)
        try manifest.write(to: directory.appendingPathComponent("assets.json"))
        return ModelPack.id(manifest: manifest)
    }

    func testAnUpdateCanInstallANewerModelThanTheRunningApp() throws {
        XCTAssertNoThrow(try ModelStore.verify(.phonon, at: directory, expectedID: try writeFuturePack()))
    }

    func testADamagedFileStillFails() throws {
        let id = try writeFuturePack()
        try Data("tampered weights".utf8).write(to: directory.appendingPathComponent("decoder.bin"))
        XCTAssertThrowsError(try ModelStore.verify(.phonon, at: directory, expectedID: id))
    }

    func testAManifestOtherThanThePinnedOneStillFails() throws {
        _ = try writeFuturePack()
        XCTAssertThrowsError(try ModelStore.verify(.phonon, at: directory, expectedID: "000000000000"))
    }
}
