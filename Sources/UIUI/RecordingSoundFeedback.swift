import AppKit

enum RecordingSound: Equatable {
    case ready, finished, cancelled
}

/// The only owner of recording-cue playback. Uses tiny built-in macOS sounds;
/// no audio engine, timer, files or work remains active between cues.
@MainActor
final class RecordingSoundFeedback {
    private var sounds: [String: NSSound] = [:]
    private var playing: NSSound?

    func play(_ cue: RecordingSound) {
        let name: String
        switch cue {
        case .ready: name = "Tink"
        case .finished: name = "Pop"
        case .cancelled: name = "Funk"
        }
        playing?.stop()
        let sound: NSSound
        if let cached = sounds[name] { sound = cached }
        else {
            guard let native = NSSound(named: NSSound.Name(name)) else { return }
            sounds[name] = native
            sound = native
        }
        sound.volume = cue == .ready ? 0.25 : 0.20
        playing = sound
        sound.play()
    }
}
