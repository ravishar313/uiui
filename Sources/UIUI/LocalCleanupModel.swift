import Foundation
import UIUICore

/// The application chooses one cleanup runtime. Benchmarks inject their own
/// engine through DictationCleanup; capture never downloads cleanup weights.
enum LocalCleanupModel {
    static let name = "MiniLM"

    static func makeEngine() -> any CleanupGenerating {
        MiniLMCleanupEngine()
    }

    static var speechSummary: String {
        "uiui S1 for speech and uiui P1 for punctuation, both on this Mac. Both models are included on macOS 15 and later."
    }

    static func prepare(progress: (@Sendable (String) -> Void)?) async throws {
        guard let assets = MiniLMModel.bundled else {
            throw SpeechCaptureFailure.message("uiui’s punctuation model is missing. Reinstall the complete app bundle.")
        }
        progress?("Verifying local punctuation model…")
        let cancellation = CleanupCancellation()
        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try MiniLMModel.verify(assets, cancellation: cancellation)
                }.value
            } onCancel: { cancellation.cancel() }
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw SpeechCaptureFailure.message("uiui’s punctuation model could not be verified. Reinstall the complete app bundle.")
        }
    }

    #if DEBUG
    /// Explicit developer check of the signed bundle's selected assets/runtime.
    /// It runs before application setup and never opens audio or user storage.
    static func smoke() async throws {
        let engine = makeEngine()
        await engine.prepare()
        guard engine.isReady else { throw CleanupFailure.unavailable }
        do {
            let source = "what time is the meeting"
            let output = try await engine.generate(source, cancellation: CleanupCancellation())
            guard DictationCleanupText.accepted(output, for: source) != nil else { throw CleanupFailure.unavailable }
            await engine.shutdown()
            guard !engine.isReady else { throw CleanupFailure.unavailable }
            print("LOCAL_CLEANUP_SMOKE passed engine=\(name) source_words_retained=true audio=not-opened")
        } catch {
            await engine.shutdown()
            throw error
        }
    }
    #endif
}
