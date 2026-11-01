import AppKit
import UIUICore

enum RecordingSound: Equatable {
    case ready, finished, cancelled
}

/// The only owner of recording-cue playback and trackpad feedback. Cues are
/// tiny sounds synthesised by UIUICore (no files, no audio engine, no timer);
/// if one cannot be created the matching macOS system sound plays instead.
/// Nothing stays active between cues.
@MainActor
final class RecordingSoundFeedback {
    private var sounds: [String: NSSound] = [:]
    private var playing: NSSound?

    private static func cue(_ sound: RecordingSound) -> SoundCue {
        switch sound {
        case .ready: .start
        case .finished: .stop
        case .cancelled: .cancel
        }
    }

    func play(_ cue: RecordingSound, pack: SoundPack = .soft, volume: Double = 1) {
        let key = "\(pack.rawValue).\(cue)"
        let sound: NSSound
        if let cached = sounds[key] { sound = cached }
        else if let made = NSSound(data: SoundCueSynth.wavData(for: Self.cue(cue), pack: pack)) {
            sounds[key] = made; sound = made
        } else {
            let fallback: String
            switch cue { case .ready: fallback = "Tink"; case .finished: fallback = "Pop"; case .cancelled: fallback = "Funk" }
            guard let native = NSSound(named: NSSound.Name(fallback)) else { return }
            sounds[key] = native; sound = native
        }
        playing?.stop()
        sound.volume = Float(volume) * (cue == .ready ? 0.30 : 0.25)
        playing = sound
        sound.play()
    }

    /// A light tap on the trackpad, felt only while a finger rests on it.
    func tap(_ cue: RecordingSound) {
        NSHapticFeedbackManager.defaultPerformer.perform(cue == .cancelled ? .generic : .alignment, performanceTime: .now)
    }
}
