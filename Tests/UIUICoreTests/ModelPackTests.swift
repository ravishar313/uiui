import XCTest
@testable import UIUICore

final class ModelPackTests: XCTestCase {
    private let digestText = String(repeating: "a1", count: 32)

    private func pack(name: String = "Phonon", id: String = "0123456789ab") -> ModelPack {
        ModelPack(name: name, id: id, archive: ModelPack.archiveName(name: name, id: id), sha256: digestText, bytes: 100)
    }

    func testIdIsFirstTwelveHexOfManifestHash() {
        // sha256("abc") = ba7816bf8f01cfea...
        XCTAssertEqual(ModelPack.id(manifest: Data("abc".utf8)), "ba7816bf8f01")
    }

    func testNamesAndDownloadURL() {
        let phonon = pack()
        XCTAssertEqual(phonon.directoryName, "Phonon-0123456789ab")
        XCTAssertEqual(phonon.releaseTag, "models-phonon-0123456789ab")
        XCTAssertEqual(phonon.downloadURL(repository: "ravishar313/uiui")?.absoluteString,
                       "https://github.com/ravishar313/uiui/releases/download/models-phonon-0123456789ab/uiui-model-phonon-0123456789ab.aar")
        XCTAssertNil(phonon.downloadURL(repository: "evil.com/../x y"))
        XCTAssertTrue(UpdateRelease.isTrustedDownload(phonon.downloadURL(repository: "a/b")!))
    }

    func testSourcesTryHuggingFaceFirstThenGitHub() {
        let phonon = pack()
        XCTAssertEqual(phonon.downloadSources(repository: "ravishar313/uiui", huggingFace: "ravishar313/uiui-models").map(\.absoluteString), [
            "https://huggingface.co/ravishar313/uiui-models/resolve/models-phonon-0123456789ab/uiui-model-phonon-0123456789ab.aar",
            "https://github.com/ravishar313/uiui/releases/download/models-phonon-0123456789ab/uiui-model-phonon-0123456789ab.aar",
        ])
        // Missing or malformed configuration drops that source only.
        XCTAssertEqual(phonon.downloadSources(repository: "a/b", huggingFace: nil).map(\.host), ["github.com"])
        XCTAssertEqual(phonon.downloadSources(repository: "a/b", huggingFace: "../x y").map(\.host), ["github.com"])
        XCTAssertEqual(phonon.downloadSources(repository: nil, huggingFace: "a/b").map(\.host), ["huggingface.co"])
        XCTAssertTrue(phonon.downloadSources(repository: nil, huggingFace: nil).isEmpty)
    }

    func testHuggingFaceHostsTrustedForModelPacksOnly() {
        let huggingFace = ["https://huggingface.co/a/b/resolve/t/x.aar", "https://us.aws.cdn.hf.co/xet-bridge-us/x",
                           "https://cas-bridge.xethub.hf.co/x", "https://cdn-lfs-us-1.hf.co/x", "https://cdn-lfs.huggingface.co/x"]
        for text in huggingFace {
            let url = URL(string: text)!
            XCTAssertTrue(ModelPack.isTrustedDownload(url), text)
            XCTAssertFalse(UpdateRelease.isTrustedDownload(url), "app update zips must stay on GitHub: \(text)")
        }
        XCTAssertTrue(ModelPack.isTrustedDownload(URL(string: "https://release-assets.githubusercontent.com/x")!))
        for text in ["http://huggingface.co/x", "https://hf.co.evil.example/x", "https://evilhf.co/x", "https://huggingface.co.evil.example/x",
                     "https://user@huggingface.co/x", "https://evil.example/x"] {
            XCTAssertFalse(ModelPack.isTrustedDownload(URL(string: text)!), text)
        }
    }

    func testListRoundTripAndLookup() throws {
        let list = ModelPackList(packs: [pack(), pack(name: "MiniLM", id: "ffffffffffff")])
        let decoded = try ModelPackList.decode(JSONEncoder().encode(list))
        XCTAssertEqual(decoded, list)
        XCTAssertEqual(decoded.pack(.miniLM)?.id, "ffffffffffff")
    }

    func testRejectsInvalidLists() throws {
        func encode(_ packs: [ModelPack], schema: Int = 1) throws -> Data { try JSONEncoder().encode(ModelPackList(schema: schema, packs: packs)) }
        XCTAssertThrowsError(try ModelPackList.decode(encode([]))) // empty
        XCTAssertThrowsError(try ModelPackList.decode(encode([pack()], schema: 2)))
        XCTAssertThrowsError(try ModelPackList.decode(encode([pack(), pack()]))) // duplicate name
        XCTAssertThrowsError(try ModelPackList.decode(encode([pack(name: "Other")]))) // unknown name
        XCTAssertThrowsError(try ModelPackList.decode(encode([pack(id: "XYZ")]))) // bad id
        XCTAssertThrowsError(try ModelPackList.decode(encode([ModelPack(name: "Phonon", id: "0123456789ab", archive: "../x.zip", sha256: digestText, bytes: 1)])))
        XCTAssertThrowsError(try ModelPackList.decode(encode([ModelPack(name: "Phonon", id: "0123456789ab", archive: ModelPack.archiveName(name: "Phonon", id: "0123456789ab"), sha256: "abc", bytes: 1)])))
        XCTAssertThrowsError(try ModelPackList.decode(Data("nope".utf8)))
    }

    func testStaleDirectoriesOnlyMatchPackPattern() {
        let list = ModelPackList(packs: [pack()])
        let names = ["Phonon-0123456789ab", "Phonon-aaaaaaaaaaaa", "MiniLM-bbbbbbbbbbbb", "Phonon-notes", "Other-aaaaaaaaaaaa", ".install-1", "Phonon-AAAAAAAAAAAA"]
        XCTAssertEqual(list.staleDirectories(among: names), ["Phonon-aaaaaaaaaaaa", "MiniLM-bbbbbbbbbbbb"])
    }
}
