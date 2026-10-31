import FluidAudio
import Foundation

/// One artifact contract shared by explicit setup and local-only capture startup.
/// The 1120 ms tier is a separate encoder export of the same Unified checkpoint.
enum ParakeetSpeechModel {
    static let repository = "FluidInference/parakeet-unified-en-0.6b-coreml"
    static let revision = "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
    static let modelDescription = "Parakeet Unified · English · on device"
    static let latencyMilliseconds = 1120
    static let encoderFileName = "parakeet_unified_encoder_streaming_70_7_7_int8.mlmodelc"
    static let downloadVariant = "streaming"
    static let config = UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7)
    static let requiredNames: Set<String> = [
        encoderFileName,
        "parakeet_unified_decoder.mlmodelc",
        "parakeet_unified_joint_decision_single_step.mlmodelc",
        "vocab.json", "metadata.json"
    ]
    static let requiredBundleFiles = ["coremldata.bin", "model.mil", "weights/weight.bin"]

    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("uiui/Models/ParakeetUnifiedStreaming", isDirectory: true)
    }
    /// ModelHub appends this repository's folder name to the download root.
    static var directory: URL { rootDirectory.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true) }
    static var isInstalled: Bool { isInstalled(at: directory) }

    static func isInstalled(at directory: URL, fileManager: FileManager = .default) -> Bool {
        guard let installedRevision = try? String(contentsOf: directory.appendingPathComponent(".fluidaudio-revision"), encoding: .utf8),
              installedRevision.trimmingCharacters(in: .whitespacesAndNewlines) == revision else { return false }
        for name in requiredNames {
            let url = directory.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                for relativePath in requiredBundleFiles {
                    guard isNonemptyFile(url.appendingPathComponent(relativePath), fileManager: fileManager) else { return false }
                }
            } else {
                guard isNonemptyFile(url, fileManager: fileManager),
                      let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      ((json as? [String: Any])?.isEmpty == false || (json as? [Any])?.isEmpty == false) else { return false }
            }
        }
        return true
    }

    static func supports(locale: String) -> Bool {
        locale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased() == "en"
    }

    static func configureLibraryLogging() {
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
    }

    private static func isNonemptyFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }
}
