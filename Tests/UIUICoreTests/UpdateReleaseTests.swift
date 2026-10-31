import XCTest
@testable import UIUICore

final class UpdateReleaseTests: XCTestCase {
    private let digest = String(repeating: "ab", count: 32)

    private func json(tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false,
                      archiveURL: String = "https://github.com/ravishar313/uiui/releases/download/v1.2.0/uiui-1.2.0-arm64.zip",
                      assets: [String]? = nil) -> Data {
        let names = assets ?? ["uiui-1.2.0-arm64.zip", "uiui-1.2.0-arm64.zip.sha256"]
        let list = names.map { name -> String in
            let url = name.hasSuffix(".zip") ? archiveURL : "https://github.com/ravishar313/uiui/releases/download/v1.2.0/\(name)"
            return #"{"name":"\#(name)","browser_download_url":"\#(url)","size":1234}"#
        }.joined(separator: ",")
        return Data(#"{"tag_name":"\#(tag)","name":"uiui 1.2.0","body":"Notes","html_url":"https://github.com/x/y/releases/tag/v1.2.0","draft":\#(draft),"prerelease":\#(prerelease),"assets":[\#(list)]}"#.utf8)
    }

    func testVersionOrderingIsNumericNotLexical() {
        XCTAssertGreaterThan(UpdateVersion("1.2.10")!, UpdateVersion("1.2.9")!)
        XCTAssertGreaterThan(UpdateVersion("v2.0")!, UpdateVersion("1.99.99")!)
        XCTAssertEqual(UpdateVersion("v1.2")!, UpdateVersion("1.2.0")!)
        XCTAssertEqual(UpdateVersion("1.2")!.hashValue, UpdateVersion("1.2.0")!.hashValue)
    }

    func testPrereleaseOrdersBeforeItsRelease() {
        XCTAssertLessThan(UpdateVersion("1.3.0-beta.2")!, UpdateVersion("1.3.0")!)
        XCTAssertLessThan(UpdateVersion("1.3.0-beta.2")!, UpdateVersion("1.3.0-beta.10")!)
        XCTAssertGreaterThan(UpdateVersion("1.3.0-beta.1")!, UpdateVersion("1.2.9")!)
        XCTAssertEqual(UpdateVersion("1.3.0+build5")!, UpdateVersion("1.3.0")!)
    }

    func testRejectsMalformedVersions() {
        for text in ["", "v", "1..2", "a.b", "1.2.x", "1.2-", "1.2.3.4.5", "-1.0"] {
            XCTAssertNil(UpdateVersion(text), text)
        }
    }

    func testParsesLatestRelease() throws {
        let release = try UpdateRelease.parse(json())
        XCTAssertEqual(release.version, UpdateVersion("1.2.0"))
        XCTAssertEqual(release.archive.name, "uiui-1.2.0-arm64.zip")
        XCTAssertEqual(release.checksumAsset.name, "uiui-1.2.0-arm64.zip.sha256")
        XCTAssertEqual(release.archive.size, 1234)
        XCTAssertEqual(release.notes, "Notes")
    }

    func testRejectsDraftsPrereleasesAndPrereleaseTags() {
        XCTAssertThrowsError(try UpdateRelease.parse(json(draft: true))) { XCTAssertEqual($0 as? UpdateReleaseError, .draftOrPrerelease) }
        XCTAssertThrowsError(try UpdateRelease.parse(json(prerelease: true))) { XCTAssertEqual($0 as? UpdateReleaseError, .draftOrPrerelease) }
        XCTAssertThrowsError(try UpdateRelease.parse(json(tag: "v1.2.0-beta.1"))) { XCTAssertEqual($0 as? UpdateReleaseError, .invalidVersion) }
        XCTAssertThrowsError(try UpdateRelease.parse(json(tag: "latest"))) { XCTAssertEqual($0 as? UpdateReleaseError, .invalidVersion) }
    }

    func testRejectsMissingAssetsAndGarbage() {
        XCTAssertThrowsError(try UpdateRelease.parse(json(assets: ["uiui-1.2.0-arm64.zip"]))) { XCTAssertEqual($0 as? UpdateReleaseError, .missingChecksum) }
        XCTAssertThrowsError(try UpdateRelease.parse(json(assets: ["uiui-1.1.0-arm64.zip", "uiui-1.1.0-arm64.zip.sha256"]))) { XCTAssertEqual($0 as? UpdateReleaseError, .missingArchive) }
        XCTAssertThrowsError(try UpdateRelease.parse(Data("[]".utf8))) { XCTAssertEqual($0 as? UpdateReleaseError, .malformedRelease) }
    }

    func testRejectsUntrustedDownloadURLs() {
        for url in ["http://github.com/a/uiui-1.2.0-arm64.zip", "https://evil.example/uiui-1.2.0-arm64.zip",
                    "https://github.com.evil.example/a.zip", "https://user@github.com/a.zip", "ftp://github.com/a.zip"] {
            XCTAssertThrowsError(try UpdateRelease.parse(json(archiveURL: url)), url) { XCTAssertEqual($0 as? UpdateReleaseError, .untrustedDownloadURL) }
        }
        XCTAssertTrue(UpdateRelease.isTrustedDownload(URL(string: "https://objects.githubusercontent.com/x")!))
        XCTAssertTrue(UpdateRelease.isTrustedDownload(URL(string: "https://release-assets.githubusercontent.com/x")!))
    }

    func testChecksumParsing() throws {
        let name = "uiui-1.2.0-arm64.zip"
        XCTAssertEqual(try UpdateRelease.parseChecksum("\(digest.uppercased())  \(name)\n", expectedName: name), digest)
        XCTAssertEqual(try UpdateRelease.parseChecksum("\(digest) *\(name)", expectedName: name), digest)
        XCTAssertEqual(try UpdateRelease.parseChecksum(digest, expectedName: name), digest)
        XCTAssertThrowsError(try UpdateRelease.parseChecksum("\(digest)  other.zip", expectedName: name)) { XCTAssertEqual($0 as? UpdateReleaseError, .checksumNameMismatch) }
        for bad in ["", "abc  \(name)", String(repeating: "g", count: 64) + "  \(name)", digest + "00  \(name)"] {
            XCTAssertThrowsError(try UpdateRelease.parseChecksum(bad, expectedName: name), bad) { XCTAssertEqual($0 as? UpdateReleaseError, .malformedChecksum) }
        }
    }

    func testDisplayNotesAreCapped() throws {
        var release = try UpdateRelease.parse(json())
        release = UpdateRelease(version: release.version, tag: release.tag, title: release.title, notes: "\n" + String(repeating: "x", count: 2000),
                                pageURL: nil, archive: release.archive, checksumAsset: release.checksumAsset)
        XCTAssertEqual(release.displayNotes(limit: 100).count, 101)
    }
}
