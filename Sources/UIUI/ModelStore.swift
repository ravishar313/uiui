import CryptoKit
import Foundation
import UIUICore

/// Owner of where model packs live and how a missing pack is obtained. Packs are
/// installed once under Application Support/uiui/Models/<Name>-<id>, independent
/// of app updates. Trust anchor: the archive hash in the signed ModelPacks.json.
enum ModelStore {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    typealias Progress = @Sendable (String) -> Void
    /// Download completion from 0 to 1, or nil when the current step has no measure.
    typealias Fraction = @Sendable (Double?) -> Void

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var resolved: [String: URL] = [:]

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uiui", isDirectory: true).appendingPathComponent("Models", isDirectory: true)
    }

    static func requiredPacks(in resources: URL?) -> ModelPackList? {
        guard let resources, let data = try? Data(contentsOf: resources.appendingPathComponent("ModelPacks.json")) else { return nil }
        return try? ModelPackList.decode(data)
    }

    static var required: ModelPackList? { requiredPacks(in: Bundle.main.resourceURL) }

    private static func bundledID(_ kind: ModelPackKind, resources: URL) -> String? {
        let file = resources.appendingPathComponent(kind.rawValue).appendingPathComponent(kind.manifestFile)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 1_048_576,
              let data = try? Data(contentsOf: file) else { return nil }
        return ModelPack.id(manifest: data)
    }

    /// Bundled copy when its manifest matches the pinned id (or the build has no
    /// pack list, as in a bare dev build); otherwise the Application Support copy.
    static func directory(for kind: ModelPackKind) -> URL {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let bundled = resources.appendingPathComponent(kind.rawValue, isDirectory: true)
        guard let pack = required?.pack(kind) else { return bundled }
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = resolved[pack.directoryName] { return cached }
        let found: URL
        if bundledID(kind, resources: resources) == pack.id { found = bundled }
        else {
            let stored = modelsDirectory.appendingPathComponent(pack.directoryName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: stored.appendingPathComponent(kind.manifestFile).path) else { return bundled }
            found = stored
        }
        resolved[pack.directoryName] = found
        return found
    }

    static func isInstalled(_ pack: ModelPack, bundleResources: URL? = Bundle.main.resourceURL) -> Bool {
        guard let kind = pack.kind else { return false }
        if let bundleResources, bundledID(kind, resources: bundleResources) == pack.id { return true }
        return FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(pack.directoryName).appendingPathComponent(kind.manifestFile).path)
    }

    /// Packs the running app requires that are neither bundled nor stored.
    static func missingPacks() -> [ModelPack] { required?.packs.filter { usable($0) && !isInstalled($0) } ?? [] }

    /// Phonon runs only on macOS 15 or later; macOS 14 uses Parakeet instead and
    /// must not download a pack it can't load.
    static func usable(_ pack: ModelPack) -> Bool {
        guard pack.kind == .phonon else { return true }
        if #available(macOS 15.0, *) { return true }
        return false
    }

    static var repository: String? {
        (Bundle.main.object(forInfoDictionaryKey: "UIUIUpdateRepository") as? String).flatMap { ModelPack.isValidRepository($0) ? $0 : nil }
    }

    /// Installs everything the running app needs; no-op when nothing is missing.
    static func ensureInstalled(progress: Progress? = nil, fraction: Fraction? = nil) async throws {
        let missing = missingPacks()
        guard !missing.isEmpty else { return }
        for pack in missing { try await install(pack, copyingFrom: Bundle.main.resourceURL, repository: repository, progress: progress, fraction: fraction) }
        pruneStale()
    }

    /// Obtains `pack` into Models/<Name>-<id>: copy from `copyingFrom` Resources when
    /// its id matches, otherwise download and check against the pack's pinned hash.
    static func install(_ pack: ModelPack, copyingFrom resources: URL?, repository: String?, progress: Progress?,
                        fraction: Fraction? = nil) async throws {
        guard let kind = pack.kind else { throw Failure(message: "Unknown model pack.") }
        let fileManager = FileManager.default
        let final = modelsDirectory.appendingPathComponent(pack.directoryName, isDirectory: true)
        if isInstalled(pack, bundleResources: nil) { return }
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let temp = modelsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }
        let staged = temp.appendingPathComponent(kind.rawValue, isDirectory: true)
        if let resources, bundledID(kind, resources: resources) == pack.id {
            progress?("Copying \(pack.name) model…")
            try fileManager.copyItem(at: resources.appendingPathComponent(kind.rawValue, isDirectory: true), to: staged)
        } else {
            guard let repository, let url = pack.downloadURL(repository: repository) else { throw Failure(message: "This build has no model download source.") }
            let archive = temp.appendingPathComponent(pack.archive)
            progress?("Downloading \(pack.name) model · \(pack.bytes / 1_000_000) MB, once…")
            try await download(url, to: archive, pack: pack, progress: progress, fraction: fraction)
            fraction?(nil)
            progress?("Unpacking \(pack.name) model…")
            let extracted = temp.appendingPathComponent("extracted", isDirectory: true)
            try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
            try await Task.detached { try unpack(archive, into: extracted) }.value
            let entries = try fileManager.contentsOfDirectory(atPath: extracted.path).filter { $0 != "__MACOSX" }
            guard entries == [kind.rawValue] else { throw Failure(message: "The \(pack.name) model download has an unexpected layout.") }
            try fileManager.moveItem(at: extracted.appendingPathComponent(kind.rawValue), to: staged)
            try? fileManager.removeItem(at: archive)
        }
        progress?("Verifying \(pack.name) model…")
        try await Task.detached(priority: .userInitiated) { try verify(kind, at: staged, expectedID: pack.id) }.value
        if isInstalled(pack, bundleResources: nil) { return }
        do { try fileManager.moveItem(at: staged, to: final) }
        catch { throw Failure(message: "The \(pack.name) model could not be installed.") }
        forget(pack.directoryName)
    }

    private static func forget(_ name: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        resolved[name] = nil
    }

    /// Removes stored packs the running app no longer references, and staging
    /// folders an interrupted install left behind. Run once after launch.
    static func pruneStale() {
        guard let list = required,
              let names = try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path) else { return }
        // An hour-old staging folder can't belong to an install still running.
        let interrupted = names.filter { name in
            guard name.hasPrefix(".install-") else { return false }
            let url = modelsDirectory.appendingPathComponent(name, isDirectory: true)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return modified.map { Date().timeIntervalSince($0) > 3600 } ?? false
        }
        for name in list.staleDirectories(among: names) + interrupted {
            try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: Verification and I/O

    private struct FileList: Decodable {
        struct File: Decodable { let path: String; let bytes: Int64; let sha256: String }
        let files: [File]
    }

    static func verify(_ kind: ModelPackKind, at directory: URL, expectedID: String) throws {
        let manifest = directory.appendingPathComponent(kind.manifestFile)
        guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), size.isRegularFile == true,
              let bytes = size.fileSize, bytes > 0, bytes <= 1_048_576,
              let data = try? Data(contentsOf: manifest), ModelPack.id(manifest: data) == expectedID else {
            throw Failure(message: "The \(kind.rawValue) model does not match what this version of uiui needs.")
        }
        if kind == .phonon {
            do { try PhononSpeechModel.verify(at: directory) } catch { throw Failure(message: "The Phonon model failed verification.") }
            return
        }
        guard let list = try? JSONDecoder().decode(FileList.self, from: data), !list.files.isEmpty, list.files.count <= 32 else {
            throw Failure(message: "The \(kind.rawValue) model manifest is invalid.")
        }
        let root = directory.resolvingSymlinksInPath().path + "/"
        for item in list.files {
            let pieces = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !item.path.hasPrefix("/"), pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), item.bytes > 0 else {
                throw Failure(message: "The \(kind.rawValue) model manifest is invalid.")
            }
            let url = directory.appendingPathComponent(item.path)
            guard url.resolvingSymlinksInPath().path.hasPrefix(root),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == item.bytes,
                  try sha256(of: url) == item.sha256 else { throw Failure(message: "The \(kind.rawValue) model failed verification.") }
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let count: Int = try autoreleasepool {
                let data = try handle.read(upToCount: 1 << 20) ?? Data()
                hasher.update(data: data)
                return data.count
            }
            if count == 0 { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Packs are LZMA Apple Archives (about 20% smaller than zip for the speech
    /// weights), unpacked by macOS's own tool after the pinned hash matched.
    private static func unpack(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/aa")
        process.arguments = ["extract", "-i", archive.path, "-d", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: "The model download could not be unpacked.") }
    }

    private static func download(_ url: URL, to destination: URL, pack: ModelPack, progress: Progress?, fraction: Fraction?) async throws {
        guard UpdateRelease.isTrustedDownload(url) else { throw Failure(message: "The model download address is not trusted.") }
        let reporter = DownloadReporter(label: pack.name, total: pack.bytes, report: progress, fraction: fraction)
        // Several connections are usually much faster than one from GitHub's CDN.
        // Any problem falls back to a single stream; the pinned hash decides either way.
        do { try await rangedDownload(url, to: destination, pack: pack, reporter: reporter) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try? FileManager.default.removeItem(at: destination)
            reporter.reset()
            try await singleDownload(url, to: destination, pack: pack, reporter: reporter)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? -1
        guard size == pack.bytes, try sha256(of: destination) == pack.sha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure(message: "The \(pack.name) model download does not match its expected checksum.")
        }
    }

    private static func request(_ url: URL, range: ClosedRange<Int64>? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("uiui", forHTTPHeaderField: "User-Agent")
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return request
    }

    private static func singleDownload(_ url: URL, to destination: URL, pack: ModelPack, reporter: DownloadReporter) async throws {
        let (file, response) = try await URLSession.shared.download(for: request(url), delegate: reporter.part(0))
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url, UpdateRelease.isTrustedDownload(final) else {
            throw Failure(message: "The \(pack.name) model download failed.")
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private static func rangedDownload(_ url: URL, to destination: URL, pack: ModelPack, reporter: DownloadReporter) async throws {
        // A one-byte probe follows the release redirect and confirms range support.
        let (_, probe) = try await URLSession.shared.data(for: request(url, range: 0...0))
        guard let http = probe as? HTTPURLResponse, http.statusCode == 206, let final = http.url,
              UpdateRelease.isTrustedDownload(final),
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              contentRange.split(separator: "/").last.flatMap({ Int64($0) }) == pack.bytes else {
            throw Failure(message: "Ranged download unavailable.")
        }
        let partCount = Int(max(1, min(6, pack.bytes / 16_000_000)))
        let partSize = (pack.bytes + Int64(partCount) - 1) / Int64(partCount)
        let ranges = (0..<partCount).map { index -> ClosedRange<Int64> in
            let lower = Int64(index) * partSize
            return lower...min(pack.bytes - 1, lower + partSize - 1)
        }
        var parts = [URL?](repeating: nil, count: partCount)
        defer { for case let part? in parts { try? FileManager.default.removeItem(at: part) } }
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (index, range) in ranges.enumerated() {
                group.addTask {
                    let (file, response) = try await URLSession.shared.download(for: request(final, range: range), delegate: reporter.part(index))
                    let kept = file.deletingLastPathComponent().appendingPathComponent("uiui-part-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: file, to: kept)
                    let size = (try? FileManager.default.attributesOfItem(atPath: kept.path)[.size] as? Int64) ?? -1
                    guard (response as? HTTPURLResponse)?.statusCode == 206, size == Int64(range.count) else {
                        try? FileManager.default.removeItem(at: kept)
                        throw Failure(message: "A part of the \(pack.name) model download failed.")
                    }
                    return (index, kept)
                }
            }
            for try await (index, file) in group { parts[index] = file }
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw Failure(message: "The \(pack.name) model could not be saved.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for case let part? in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
        }
    }
}

/// Sums progress across parallel parts and reports at most once per percent.
private final class DownloadReporter: @unchecked Sendable {
    private let label: String
    private let total: Int64
    private let report: ModelStore.Progress?
    private let fraction: ModelStore.Fraction?
    private let lock = NSLock()
    private var written: [Int: Int64] = [:]
    private var lastPercent = -1
    init(label: String, total: Int64, report: ModelStore.Progress?, fraction: ModelStore.Fraction?) {
        self.label = label; self.total = total; self.report = report; self.fraction = fraction
    }
    func part(_ index: Int) -> PartDelegate { PartDelegate(index: index, owner: self) }
    func reset() { lock.withLock { written = [:]; lastPercent = -1 } }
    func update(part index: Int, bytes: Int64) {
        let snapshot: Int64? = lock.withLock {
            written[index] = bytes
            let sum = written.values.reduce(0, +)
            let percent = Int(Double(sum) / Double(max(1, total)) * 100)
            guard percent != lastPercent else { return nil }
            lastPercent = percent
            return sum
        }
        guard let sum = snapshot else { return }
        fraction?(min(1, Double(sum) / Double(max(1, total))))
        report?("Downloading \(label) model · \(sum / 1_000_000) of \(total / 1_000_000) MB")
    }
}

private final class PartDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let index: Int
    let owner: DownloadReporter
    init(index: Int, owner: DownloadReporter) { self.index = index; self.owner = owner }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        owner.update(part: index, bytes: totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
