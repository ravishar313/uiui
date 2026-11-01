import Foundation

/// The three recording cues, synthesised here so uiui ships no audio files and
/// no third-party sound licences. Each cue is a few soft sine notes with a quick
/// attack and an exponential decay, rendered once into a small mono WAV.
public enum SoundCue: Sendable, CaseIterable {
    case start, stop, cancel
}

/// The sets of cues offered in Settings. All are synthesised here.
public enum SoundPack: String, Codable, CaseIterable, Identifiable, Sendable {
    case soft, chime, click, marimba
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .soft: "Soft"
        case .chime: "Chime"
        case .click: "Click"
        case .marimba: "Marimba"
        }
    }
    /// How much of the second harmonic each note carries, and how fast it decays.
    fileprivate var overtone: Double { switch self { case .soft: 0.18; case .chime: 0.08; case .click: 0.45; case .marimba: 0.32 } }
    fileprivate var decay: Double { switch self { case .soft: 5.5; case .chime: 3.5; case .click: 8; case .marimba: 6.5 } }
}

public enum SoundCueSynth {
    public static let sampleRate = 44_100

    private struct Note { var frequency: Double; var start: Double; var length: Double; var level: Double }

    private static func notes(for cue: SoundCue, pack: SoundPack) -> [Note] {
        switch (pack, cue) {
        // Bell-like with a longer ring.
        case (.chime, .start): return [Note(frequency: 1046.5, start: 0, length: 0.12, level: 0.7),
                                       Note(frequency: 1318.5, start: 0.07, length: 0.14, level: 0.8),
                                       Note(frequency: 1568.0, start: 0.14, length: 0.2, level: 0.9)]
        case (.chime, .stop): return [Note(frequency: 1568.0, start: 0, length: 0.12, level: 0.8),
                                      Note(frequency: 1046.5, start: 0.08, length: 0.22, level: 0.9)]
        case (.chime, .cancel): return [Note(frequency: 659.3, start: 0, length: 0.2, level: 0.7)]
        // A single very short tick.
        case (.click, .start): return [Note(frequency: 2093.0, start: 0, length: 0.018, level: 0.9)]
        case (.click, .stop): return [Note(frequency: 1396.9, start: 0, length: 0.018, level: 0.9)]
        case (.click, .cancel): return [Note(frequency: 698.5, start: 0, length: 0.024, level: 0.9)]
        // Low, woody notes.
        case (.marimba, .start): return [Note(frequency: 523.3, start: 0, length: 0.09, level: 0.9),
                                         Note(frequency: 784.0, start: 0.075, length: 0.12, level: 1.0)]
        case (.marimba, .stop): return [Note(frequency: 784.0, start: 0, length: 0.09, level: 0.9),
                                        Note(frequency: 523.3, start: 0.075, length: 0.14, level: 1.0)]
        case (.marimba, .cancel): return [Note(frequency: 293.7, start: 0, length: 0.13, level: 0.9)]
        case (.soft, _): break
        }
        return switch cue {
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
    public static func samples(for cue: SoundCue, pack: SoundPack = .soft) -> [Int16] {
        let notes = notes(for: cue, pack: pack)
        let total = (notes.map { $0.start + $0.length }.max() ?? 0) + 0.04
        var mix = [Double](repeating: 0, count: Int(total * Double(sampleRate)))
        for note in notes {
            let first = Int(note.start * Double(sampleRate))
            let count = Int((note.length + 0.04) * Double(sampleRate))
            for i in 0..<count where first + i < mix.count {
                let t = Double(i) / Double(sampleRate)
                let attack = min(1, t / 0.004)
                let decay = exp(-t * pack.decay / max(note.length, 0.05))
                let tail = min(1, Double(count - i) / (0.012 * Double(sampleRate)))
                let phase = 2 * Double.pi * note.frequency * t
                let tone = sin(phase) + pack.overtone * sin(2 * phase)
                mix[first + i] += tone * attack * decay * tail * note.level * 0.55
            }
        }
        return mix.map { Int16(max(-1, min(1, $0)) * 32_000) }
    }

    /// A complete WAV file for NSSound(data:).
    public static func wavData(for cue: SoundCue, pack: SoundPack = .soft) -> Data {
        let pcm = samples(for: cue, pack: pack)
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
