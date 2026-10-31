import CryptoKit
import Foundation

/// Local, manifest-verified assets. This owner never downloads anything and
/// accepts a separate manifest for a locally exported/tuned model.
enum MiniLMModel {
    struct Assets: Sendable {
        let modelURL: URL
        let tokenizerURL: URL
        let manifestURL: URL
    }

    private struct Manifest: Decodable {
        struct File: Decodable { let path: String; let bytes: Int64; let sha256: String }
        let files: [File]
    }

    static var bundled: Assets? {
        let directory = ModelStore.directory(for: .miniLM)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let manifest = try? readManifest(manifestURL),
              let model = manifest.files.first(where: { $0.path.hasSuffix(".onnx") }),
              let tokenizer = manifest.files.first(where: { $0.path.hasSuffix("sentencepiece.bpe.model") }),
              let modelURL = assetURL(model.path, relativeTo: directory),
              let tokenizerURL = assetURL(tokenizer.path, relativeTo: directory) else { return nil }
        return Assets(modelURL: modelURL, tokenizerURL: tokenizerURL, manifestURL: manifestURL)
    }

    static func explicit(modelURL: URL, tokenizerURL: URL, manifestURL: URL? = nil) -> Assets {
        // The probe's original layout is root/manifest.json + root/assets/*;
        // app exports may instead put their files directly beside the manifest.
        var candidate = modelURL.deletingLastPathComponent()
        var discovered: URL?
        for _ in 0..<3 {
            let file = candidate.appendingPathComponent("manifest.json")
            let shared = tokenizerURL.standardizedFileURL.path.hasPrefix(candidate.standardizedFileURL.path + "/")
            if shared, FileManager.default.fileExists(atPath: file.path) { discovered = file; break }
            candidate.deleteLastPathComponent()
        }
        return Assets(modelURL: modelURL, tokenizerURL: tokenizerURL,
                      manifestURL: manifestURL ?? discovered ?? modelURL.deletingLastPathComponent().appendingPathComponent("manifest.json"))
    }

    static func verify(_ assets: Assets, cancellation: CleanupCancellation) throws {
        let manifest = try readManifest(assets.manifestURL)
        let directory = assets.manifestURL.deletingLastPathComponent()
        for selected in [assets.modelURL, assets.tokenizerURL] {
            try check(cancellation)
            let matches = manifest.files.filter {
                assetURL($0.path, relativeTo: directory)?.standardizedFileURL == selected.standardizedFileURL
            }
            guard matches.count == 1, let item = matches.first,
                  item.bytes > 0, item.sha256.count == 64,
                  item.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: selected.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == item.bytes else { throw CleanupFailure.unavailable }
            let handle = try FileHandle(forReadingFrom: selected)
            defer { try? handle.close() }
            var digest = SHA256(), count: Int64 = 0
            while true {
                try check(cancellation)
                let bytesRead: Int = try autoreleasepool {
                    guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return 0 }
                    digest.update(data: data)
                    return data.count
                }
                if bytesRead == 0 { break }
                count += Int64(bytesRead)
                guard count <= item.bytes else { throw CleanupFailure.unavailable }
            }
            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard count == item.bytes, actual == item.sha256.lowercased() else { throw CleanupFailure.unavailable }
        }
        try check(cancellation)
    }

    private static func readManifest(_ url: URL) throws -> Manifest {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= 1_048_576 else { throw CleanupFailure.unavailable }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private static func assetURL(_ path: String, relativeTo directory: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        return directory.appendingPathComponent(path).standardizedFileURL
    }

    private static func check(_ cancellation: CleanupCancellation) throws {
        if cancellation.isCancelled { throw CancellationError() }
    }
}
