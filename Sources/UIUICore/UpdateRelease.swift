import Foundation

/// Dotted numeric version such as `1.2.10`. A leading `v` is tolerated. A
/// `-suffix` (for example `-beta.1`) marks a prerelease that orders before the
/// same numeric core; `+build` metadata is ignored. Missing components count as 0.
public struct UpdateVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        var suffix: String?
        if let dash = value.firstIndex(of: "-") {
            suffix = String(value[value.index(after: dash)...])
            value = String(value[..<dash])
            if suffix?.isEmpty == true { return nil }
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers
        prerelease = suffix
    }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "")
    }

    public var isPrerelease: Bool { prerelease != nil }

    public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(left), .some(right)): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }

    public static func == (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }
}

public enum UpdateReleaseError: Error, Equatable, Sendable {
    case malformedRelease
    case draftOrPrerelease
    case invalidVersion
    case missingArchive
    case missingChecksum
    case untrustedDownloadURL
    case malformedChecksum
    case checksumNameMismatch

    public var message: String {
        switch self {
        case .malformedRelease: "The release information could not be read."
        case .draftOrPrerelease: "The latest release is not a public release."
        case .invalidVersion: "The release version is not valid."
        case .missingArchive: "The release has no app download for this Mac."
        case .missingChecksum: "The release has no checksum file."
        case .untrustedDownloadURL: "The release download address is not trusted."
        case .malformedChecksum: "The release checksum file is malformed."
        case .checksumNameMismatch: "The release checksum does not match the download."
        }
    }
}

public struct UpdateAsset: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let size: Int?
}

/// A validated, installable release.
public struct UpdateRelease: Equatable, Sendable {
    public let version: UpdateVersion
    public let tag: String
    public let title: String
    public let notes: String
    public let pageURL: URL?
    public let archive: UpdateAsset
    public let checksumAsset: UpdateAsset

    public static let allowedHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    public static func archiveName(version: String) -> String { "uiui-\(version)-arm64.zip" }

    public static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return allowedHosts.contains(host)
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int?
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    /// Decodes the GitHub "latest release" response and selects the arm64 archive
    /// plus checksum assets. Throws for drafts, prereleases and untrusted assets.
    public static func parse(_ data: Data) throws -> UpdateRelease {
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch { throw UpdateReleaseError.malformedRelease }
        if payload.draft == true || payload.prerelease == true { throw UpdateReleaseError.draftOrPrerelease }
        guard let version = UpdateVersion(payload.tag_name), !version.isPrerelease else { throw UpdateReleaseError.invalidVersion }
        let versionText = version.description
        let archiveName = archiveName(version: versionText)
        let assets = payload.assets ?? []
        guard let archive = assets.first(where: { $0.name == archiveName }) else { throw UpdateReleaseError.missingArchive }
        guard let checksum = assets.first(where: { $0.name == archiveName + ".sha256" }) else { throw UpdateReleaseError.missingChecksum }
        func asset(_ raw: Payload.Asset) throws -> UpdateAsset {
            guard let url = URL(string: raw.browser_download_url), isTrustedDownload(url) else { throw UpdateReleaseError.untrustedDownloadURL }
            return UpdateAsset(name: raw.name, url: url, size: raw.size)
        }
        return UpdateRelease(version: version, tag: payload.tag_name, title: payload.name ?? payload.tag_name,
                             notes: payload.body ?? "", pageURL: payload.html_url.flatMap(URL.init(string:)),
                             archive: try asset(archive), checksumAsset: try asset(checksum))
    }

    /// Parses `<64 hex>  <filename>` as written by `shasum -a 256`; returns the
    /// lowercase digest. The filename (when given, `*` binary marker allowed) must
    /// equal `expectedName`.
    public static func parseChecksum(_ text: String, expectedName: String) throws -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let digest = fields.first, digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw UpdateReleaseError.malformedChecksum
        }
        if fields.count == 2 {
            var name = fields[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard name == expectedName else { throw UpdateReleaseError.checksumNameMismatch }
        }
        return digest.lowercased()
    }

    /// Release notes trimmed and capped for display.
    public func displayNotes(limit: Int = 700) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
