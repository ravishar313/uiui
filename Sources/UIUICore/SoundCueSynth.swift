import Foundation

/// The three recording cues, synthesised here so uiui ships no audio files and
/// no third-party sound licences. Each cue is a few soft sine notes with a quick
/// attack and an exponential decay, rendered once into a small mono WAV.
public enum SoundCue: Sendable, CaseIterable {
    case start, stop, cancel
}

public enum SoundCueSynth {
    public static let sampleRate = 44_100

    private struct Note { var frequency: Double; var start: Double; var length: Double; var level: Double }

    private static func notes(for cue: SoundCue) -> [Note] {
        switch cue {
        // Two rising notes: "listening".
        case .start: [Note(frequency: 784.0, start: 0, length: 0.085, level: 0.8),
                      Note(frequency: 1174.7, start: 0.055, length: 0.12, level: 1.0)]
        // Two falling notes: "done".
        case .stop: [Note(frequency: 1174.7, start: 0, length: 0.085, level: 0.9),
                     Note(frequency: 783.99, start: 0.055, length: 0.14, level: 0.9)]
        // Two low, short, dull notes: "discarded".
        case .cancel: [Note(frequency: 311.1, start: 0, length: 0.07, level: 0.7),
                       Note(frequency: 233.1, start: 0.05, length: 0.11, level: 0.7)]
        }
    }

    /// Mono 16-bit samples; always start and end near zero.
    public static func samples(for cue: SoundCue) -> [Int16] {
        let notes = notes(for: cue)
        let total = (notes.map { $0.start + $0.length }.max() ?? 0) + 0.04
        var mix = [Double](repeating: 0, count: Int(total * Double(sampleRate)))
        for note in notes {
            let first = Int(note.start * Double(sampleRate))
            let count = Int((note.length + 0.04) * Double(sampleRate))
            for i in 0..<count where first + i < mix.count {
                let t = Double(i) / Double(sampleRate)
                let attack = min(1, t / 0.004)
                let decay = exp(-t * 5.5 / max(note.length, 0.05))
                let tail = min(1, Double(count - i) / (0.012 * Double(sampleRate)))
                let phase = 2 * Double.pi * note.frequency * t
                let tone = sin(phase) + 0.18 * sin(2 * phase)
                mix[first + i] += tone * attack * decay * tail * note.level * 0.55
            }
        }
        return mix.map { Int16(max(-1, min(1, $0)) * 32_000) }
    }

    /// A complete WAV file for NSSound(data:).
    public static func wavData(for cue: SoundCue) -> Data {
        let pcm = samples(for: cue)
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append32(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append32(16)
        append16(1); append16(1); append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(byteCount)
        for sample in pcm { append16(UInt16(bitPattern: sample)) }
        return data
    }
}
