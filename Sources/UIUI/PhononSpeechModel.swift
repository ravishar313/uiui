import CryptoKit
import Foundation
import PhononCoreML

/// The selected English recognizer. We ship pinned, precompiled assets: neither
/// a trigger nor a warm checkout can download or compile a different model.
enum PhononSpeechModel {
    static let repository = "uiui/S1"
    static let revision = "full-1029-s16000-f16"
    static let containerSHA256 = "1ebefdb308a1b4f4b3fd8df86b1340cb6934b4c935f4c97386ba7119c07ff249"
    static let modelDescription = "uiui S1 · Neural Engine · on device"
    static var directory: URL { ModelStore.directory(for: .phonon) }
    static var speechActivityURL: URL { directory.appendingPathComponent("SpeechActivity.mlmodelc", isDirectory: true) }
    static var isInstalled: Bool { isInstalled(at: directory) }

    struct Assets: Decodable {
        struct File: Decodable { let path: String; let bytes: Int64; let sha256: String }
        let repository: String
        let revision: String
        let container_sha256: String
        let files: [File]
    }
    static func isInstalled(at directory: URL) -> Bool {
        guard let assets = try? readManifest(at: directory), validManifest(assets) else { return false }
        return assets.files.allSatisfy { item in
            guard let url = assetURL(item.path, directory: directory),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return false }
            return Int64(values.fileSize ?? -1) == item.bytes
        }
    }
    /// Hash on the model queue once per new native instance, never on MainActor.
    static func verify(at directory: URL, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        let assets = try readManifest(at: directory)
        guard validManifest(assets) else { throw unavailable() }
        for item in assets.files {
            try checkCancellation()
            guard let url = assetURL(item.path, directory: directory),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == item.bytes else { throw unavailable() }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while true {
                try checkCancellation()
                let count: Int = try autoreleasepool {
                    let data = try file.read(upToCount: 1_048_576) ?? Data()
                    hash.update(data: data)
                    return data.count
                }
                if count == 0 { break }
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == item.sha256 else { throw unavailable() }
        }
    }
    private static func readManifest(at directory: URL) throws -> Assets {
        let url = directory.appendingPathComponent("assets.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 1_048_576 else { throw unavailable() }
        return try JSONDecoder().decode(Assets.self, from: Data(contentsOf: url))
    }
    private static func validManifest(_ assets: Assets) -> Bool {
        let required: Set<String> = ["manifest.json", "decoder.bin", "Phonon-2.mlmodelc/coremldata.bin", "Phonon-2.mlmodelc/model.mil", "Phonon-2.mlmodelc/weights/weight.bin", "SpeechActivity.mlmodelc/coremldata.bin", "SpeechActivity.mlmodelc/model.mil", "SpeechActivity.mlmodelc/weights/weight.bin"]
        let paths = Set(assets.files.map(\.path))
        return assets.repository == repository && assets.revision == revision && assets.container_sha256 == containerSHA256
            && !assets.files.isEmpty && assets.files.count <= 32 && paths.count == assets.files.count && required.isSubset(of: paths)
            && assets.files.allSatisfy { $0.bytes > 0 && $0.sha256.count == 64 }
    }
    private static func assetURL(_ path: String, directory: URL) -> URL? {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let url = directory.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { return nil }
        return url
    }
    private static func unavailable() -> SpeechCaptureFailure {
        .message("uiui’s local speech model is incomplete. Reinstall the complete app bundle.")
    }
    @available(macOS 15.0, *)
    static func makeOptions() -> Transcriber.Options {
        var options = Transcriber.Options()
        options.functions = [15]; options.eagerFunctions = [15]
        // Match the vendor's 400-sample STFT safety margin. Without this,
        // 14.99–15.00s single shots ask the 15s graph for >15s of mel frames.
        options.singleShotMaxSeconds = 15.0 - 400.0 / 16_000
        options.backgroundLoad = false
        options.computeUnits = .cpuAndNeuralEngine
        options.decoderWorkers = 1; options.encoderInFlight = 1
        options.fastDecoderThreads = 4
        // Reuse only identical per-capture windows. The opt-out is confined to
        // explicit developer comparisons; ordinary capture keeps live revisions.
        options.windowDecodeCacheEnabled = !CommandLine.arguments.contains("--integration-no-window-cache")
        return options
    }
}

/// One product choice governs capture, warmup, setup, and model descriptions.
enum LocalSpeechModel {
    static func supports(locale: String) -> Bool {
        locale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased() == "en"
    }
    static var name: String { if #available(macOS 15.0, *) { return "Phonon 2" }; return "Parakeet" }
    static var modelDescription: String { if #available(macOS 15.0, *) { return PhononSpeechModel.modelDescription }; return ParakeetSpeechModel.modelDescription }
    static var directory: URL { if #available(macOS 15.0, *) { return PhononSpeechModel.directory }; return ParakeetSpeechModel.directory }
    static var isInstalled: Bool { if #available(macOS 15.0, *) { return PhononSpeechModel.isInstalled }; return ParakeetSpeechModel.isInstalled }
    static func makeDecoder(vocabulary: [String] = []) -> any ParakeetStreamingDecoding {
        if #available(macOS 15.0, *) { return PhononStreamingDecoder(vocabulary: vocabulary) }
        return NativeParakeetStreamingDecoder()
    }
    static func warmIfInstalled() async {
        if #available(macOS 15.0, *) { await PhononModelPool.shared.warmIfInstalled() }
        else { await ParakeetModelPool.shared.warmIfInstalled() }
    }
    static func clear() async {
        if #available(macOS 15.0, *) { await PhononModelPool.shared.clear() }
        else { await ParakeetModelPool.shared.clear() }
    }
}
