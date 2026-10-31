import AVFoundation
import Foundation

/// Explicit live-input diagnostic. Uses the production session, keeps no audio
/// or transcript, and reports aggregate health counters only. Never prompts for
/// access or delivers text to another app.
@MainActor
enum MicrophoneNativeSmoke {
    static func run() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw SpeechCaptureFailure.message("Microphone access must already be approved for this diagnostic.")
        }
        let capture = SpeechCapture()
        defer { capture.cancel() }
        var levels = 0, audibleLevels = 0, snapshots = 0
        var completion: SpeechCompletion?
        capture.onAudioLevel = { level in
            levels += 1
            if level > 0.001 { audibleLevels += 1 }
        }
        capture.onPartial = { if !$0.isEmpty { snapshots += 1 } }
        capture.onCompletion = { completion = $0 }
        let started = ContinuousClock.now
        try await capture.start(locale: "en-IN", contextualStrings: [])
        let ready = started.duration(to: .now)
        try await Task.sleep(for: .seconds(6))
        capture.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while completion == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let completion, levels > 0 else {
            throw SpeechCaptureFailure.message("The live input did not complete with microphone level callbacks.")
        }
        let readyMilliseconds = Double(ready.components.seconds) * 1_000 + Double(ready.components.attoseconds) / 1e15
        print(String(format: "MICROPHONE_SMOKE ready_ms=%.3f level_callbacks=%d audible_callbacks=%d text_snapshots=%d final=%@ microphone_stopped=true", readyMilliseconds, levels, audibleLevels, snapshots, String(describing: completion.reason)))
        guard completion.reason == .final else {
            throw SpeechCaptureFailure.message("Live recognition ended without a complete final result.")
        }
    }
}
