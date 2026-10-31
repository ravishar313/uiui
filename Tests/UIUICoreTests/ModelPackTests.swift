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
