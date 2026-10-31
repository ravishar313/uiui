import AVFoundation
import Foundation
import FluidAudio
import Speech

/// Explicit setup only. Capture never initiates a model download, and this path
/// never opens a microphone or sends recorded speech to a service.
enum SpeechAssets {
    // Pin the weights independently from the SDK. A future upstream main must
    // never change an installed user's recognizer without an explicit update.
    private static let parakeetRevision = ParakeetSpeechModel.revision
    static func prepare(localeIdentifier: String, progress: (@Sendable (String) -> Void)? = nil,
                        fraction: ModelStore.Fraction? = nil) async throws {
        if LocalSpeechModel.supports(locale: localeIdentifier) {
            try await ModelStore.ensureInstalled(progress: progress, fraction: fraction)
            fraction?(nil)
            if #available(macOS 15.0, *) {
                progress?("Verifying local Phonon speech model…")
                try await Task.detached(priority: .userInitiated) { try PhononSpeechModel.verify(at: PhononSpeechModel.directory) }.value
            } else if !ParakeetSpeechModel.isInstalled { try await prepareParakeet(progress: progress, fraction: fraction) }
            try await LocalCleanupModel.prepare(progress: progress)
            return
        }
        guard #available(macOS 26.0, *) else {
            throw SpeechCaptureFailure.message("Enhanced on-device speech needs macOS 26 or later.")
        }
        try await prepareModern(localeIdentifier: localeIdentifier)
    }

    private static func prepareParakeet(progress: (@Sendable (String) -> Void)?, fraction: ModelStore.Fraction?) async throws {
        ParakeetSpeechModel.configureLibraryLogging()
        ModelRegistry.revisionOverrides = [ParakeetSpeechModel.repository: parakeetRevision]
        progress?("Downloading Parakeet Unified · about 610 MB, once…")
        let reporter = SpeechSetupProgress(report: progress, fraction: fraction)
        try await ModelHub.download(.parakeetUnified, to: ParakeetSpeechModel.rootDirectory,
                                    variant: ParakeetSpeechModel.downloadVariant,
                                    additionalModelNames: [ParakeetSpeechModel.encoderFileName],
                                    progressHandler: { reporter.update($0.fractionCompleted) })
        try Task.checkCancellation()
        guard ParakeetSpeechModel.isInstalled else {
            throw SpeechCaptureFailure.message("The speech model download is incomplete. Choose Prepare Speech to resume.")
        }
        fraction?(nil)
        progress?("Preparing the Neural Engine…")
        let manager = StreamingUnifiedAsrManager(config: ParakeetSpeechModel.config, encoderPrecision: .int8)
        do { try await manager.loadModels(from: ParakeetSpeechModel.directory) }
        catch { await manager.cleanup(); throw error }
        await manager.cleanup()
        try Task.checkCancellation()
        print("SPEECH_ASSETS ready engine=ParakeetUnified precision=int8 tier=1120ms revision=\(parakeetRevision) audio=not-opened")
    }

    @available(macOS 26.0, *)
    private static func prepareModern(localeIdentifier: String) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw SpeechCaptureFailure.message("Enhanced on-device speech is unavailable for this language on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        let reserved = try await AssetInventory.reserve(locale: locale)
        do {
            let before = await AssetInventory.status(forModules: modules)
            if before != .installed {
                print("SPEECH_ASSETS preparing system-managed language assets locale=\(locale.identifier)")
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    try await installation.downloadAndInstall()
                }
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                throw SpeechCaptureFailure.message("No compatible format is available for enhanced speech.")
            }
            let analyzer = SpeechAnalyzer(modules: modules)
            do { try await analyzer.prepareToAnalyze(in: format) }
            catch { await analyzer.cancelAndFinishNow(); throw error }
            await analyzer.cancelAndFinishNow()
            let status = await AssetInventory.status(forModules: modules)
            guard status == .installed else {
                throw SpeechCaptureFailure.message("The speech model prepared, but macOS has not confirmed its assets are installed.")
            }
            print("SPEECH_ASSETS ready locale=\(locale.identifier) engine=SpeechTranscriber audio=not-opened")
        } catch {
            if reserved { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }
}

private final class SpeechSetupProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private let report: (@Sendable (String) -> Void)?
    private let fraction: ModelStore.Fraction?
    init(report: (@Sendable (String) -> Void)?, fraction: ModelStore.Fraction?) { self.report = report; self.fraction = fraction }
    func update(_ value: Double) {
        guard report != nil, value.isFinite else { return }
        let percent = Int((min(1, max(0, value)) * 100).rounded(.down))
        guard lock.withLock({
            if percent <= lastPercent { return false }
            lastPercent = percent
            return true
        }) else { return }
        fraction?(min(1, max(0, value)))
        report?("Downloading Parakeet Unified · \(percent)%")
    }
}
