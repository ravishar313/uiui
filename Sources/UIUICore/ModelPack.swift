import CryptoKit
import Foundation

/// Speech and cleanup models ship separately from the app. A pack is identified
/// by the first 12 hex characters of the SHA-256 of its manifest file, so a pack
/// directory name pins exactly one set of weights.
public enum ModelPackKind: String, CaseIterable, Sendable {
    case phonon = "Phonon"
    case miniLM = "MiniLM"

    /// The pinned file whose hash identifies the pack.
    public var manifestFile: String { self == .phonon ? "assets.json" : "manifest.json" }
}

public struct ModelPack: Codable, Equatable, Sendable {
    public let name: String
    public let id: String
    public let archive: String
    public let sha256: String
    public let bytes: Int64

    public init(name: String, id: String, archive: String, sha256: String, bytes: Int64) {
        self.name = name; self.id = id; self.archive = archive; self.sha256 = sha256; self.bytes = bytes
    }

    public var kind: ModelPackKind? { ModelPackKind(rawValue: name) }
    /// `<Name>-<id>`, the directory inside Application Support/uiui/Models.
    public var directoryName: String { "\(name)-\(id)" }
    public var releaseTag: String { "models-\(name.lowercased())-\(id)" }

    public static func archiveName(name: String, id: String) -> String { "uiui-model-\(name.lowercased())-\(id).aar" }

    public static func id(manifest: Data) -> String {
        SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    public func downloadURL(repository: String) -> URL? {
        guard ModelPack.isValidRepository(repository) else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/download/\(releaseTag)/\(archive)")
    }

    public static func isValidRepository(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    static func isHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    var isValid: Bool {
        kind != nil && ModelPack.isHex(id, count: 12) && ModelPack.isHex(sha256, count: 64)
            && archive == ModelPack.archiveName(name: name, id: id) && bytes > 0 && bytes <= 4_000_000_000
    }
}

/// `resources/ModelPacks.json`: the packs one app build requires. It is sealed
/// by the app's code signature, so its archive hashes are the download trust anchor.
public struct ModelPackList: Codable, Equatable, Sendable {
    public let schema: Int
    public let packs: [ModelPack]

    public init(schema: Int = 1, packs: [ModelPack]) { self.schema = schema; self.packs = packs }

    public enum Failure: Error, Equatable { case malformed }

    public static func decode(_ data: Data) throws -> ModelPackList {
        guard data.count <= 65_536, let list = try? JSONDecoder().decode(ModelPackList.self, from: data), list.schema == 1,
              !list.packs.isEmpty, list.packs.allSatisfy(\.isValid),
              Set(list.packs.map(\.name)).count == list.packs.count else { throw Failure.malformed }
        return list
    }

    public func pack(_ kind: ModelPackKind) -> ModelPack? { packs.first { $0.name == kind.rawValue } }

    /// Stored directories (`<Name>-<12 hex>`) that no listed pack references.
    public func staleDirectories(among names: [String]) -> [String] {
        let keep = Set(packs.map(\.directoryName))
        return names.filter { name in
            guard !keep.contains(name) else { return false }
            return ModelPackKind.allCases.contains { kind in
                name.hasPrefix(kind.rawValue + "-") && ModelPack.isHex(String(name.dropFirst(kind.rawValue.count + 1)), count: 12)
            }
        }
    }
}
