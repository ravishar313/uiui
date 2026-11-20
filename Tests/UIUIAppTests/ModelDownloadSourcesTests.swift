import CryptoKit
import Foundation
import XCTest
import UIUICore
@testable import UIUI

/// Model packs come from Hugging Face first, then GitHub. These tests replace the
/// network fetch, so they check the source loop and the pinned-hash gate only.
final class ModelDownloadSourcesTests: XCTestCase {
    private let good = Data("the pinned model archive".utf8)
    private let huggingFace = URL(string: "https://huggingface.co/o/m/resolve/models-phonon-0123456789ab/a.aar")!
    private let gitHub = URL(string: "https://github.com/o/r/releases/download/models-phonon-0123456789ab/a.aar")!
    private var destination: URL!

    override func setUpWithError() throws {
        destination = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-sources-\(UUID().uuidString).aar")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: destination) }

    private var pack: ModelPack {
        let digest = SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined()
        return ModelPack(name: "Phonon", id: "0123456789ab", archive: "a.aar", sha256: digest, bytes: Int64(good.count))
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }

    private func run(serving body: @escaping (URL) throws -> Data) async throws -> [URL] {
        let calls = Calls()
        let destination = destination!
        try await ModelStore.download(from: [huggingFace, gitHub], to: destination, pack: pack, reporter: nil) { url in
            calls.add(url)
            try body(url).write(to: destination)
        }
        return calls.all
    }

    func testUsesHuggingFaceAndSkipsGitHubWhenItMatches() async throws {
        let calls = try await run { _ in self.good }
        XCTAssertEqual(calls, [huggingFace])
        XCTAssertEqual(try Data(contentsOf: destination), good)
    }

    func testFallsBackToGitHubWhenHuggingFaceFails() async throws {
        let calls = try await run { url in
            if url == self.huggingFace { throw URLError(.notConnectedToInternet) }
            return self.good
        }
        XCTAssertEqual(calls, [huggingFace, gitHub])
        XCTAssertEqual(try Data(contentsOf: destination), good)
    }

    func testFallsBackToGitHubWhenHuggingFaceServesOtherBytes() async throws {
        // Same size, different content: only the hash catches it.
        var tampered = good
        tampered[0] ^= 0xff
        let calls = try await run { url in url == self.huggingFace ? tampered : self.good }
        XCTAssertEqual(calls, [huggingFace, gitHub])
        XCTAssertEqual(try Data(contentsOf: destination), good)
    }

    func testFallsBackWhenHuggingFaceServesWrongSize() async throws {
        let calls = try await run { url in url == self.huggingFace ? self.good + Data([0]) : self.good }
        XCTAssertEqual(calls, [huggingFace, gitHub])
    }

    func testFailsAndLeavesNothingWhenEverySourceIsWrong() async throws {
        do {
            _ = try await run { _ in Data("wrong".utf8) }
            XCTFail("expected a checksum failure")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("checksum"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancellationDoesNotFallBack() async throws {
        let calls = Calls()
        do {
            try await ModelStore.download(from: [huggingFace, gitHub], to: destination, pack: pack, reporter: nil) { url in
                calls.add(url)
                throw CancellationError()
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(calls.all, [huggingFace])
    }
}
