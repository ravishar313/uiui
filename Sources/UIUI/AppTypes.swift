import CoreGraphics
import Foundation
import UIUICore

enum WorkspaceSheet: String, Identifiable {
    case settings
    var id: String { rawValue }
}

struct VoiceActionFeedback: Identifiable, Equatable {
    enum State { case working, success, needsInput, failure, information }
    /// Receipt meaning is explicit; display copy never determines its behavior.
    enum Presentation { case message, pasteDispatch, copiedOnly, cancellation }
    let id = UUID()
    let state: State
    let title: String
    let detail: String
    var presentation: Presentation = .message
    /// A paste receipt that keeps Undo and Copy reachable for a few seconds.
    var offersUndo = false

    var symbol: String {
        if presentation == .cancellation { return "xmark.circle" }
        if presentation == .copiedOnly { return "doc.on.clipboard" }
        switch state {
        case .working: return "clock"
        case .success: return "checkmark.circle.fill"
        case .needsInput: return "questionmark.circle"
        case .failure: return "exclamationmark.circle.fill"
        case .information: return "sparkles"
        }
    }
    var compactText: String { title + (detail.isEmpty ? "" : " · " + detail) }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case dictations, settings
    var id: String { rawValue }
    var title: String { self == .dictations ? "History" : "Settings" }
    var symbol: String { self == .dictations ? "clock.arrow.circlepath" : "slider.horizontal.3" }
}

enum CaptureSaveSource { case composer, dictationCompletion }

enum CaptureMode: String, CaseIterable, Identifiable {
    case dictation
    var id: String { rawValue }
    var title: String { "Dictate" }
    var symbol: String { "waveform" }
    var kind: CaptureKind { .dictation }
}

enum NotchVisualStyle: String, Codable, CaseIterable, Identifiable {
    case mosaic, eyes, bars, words
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mosaic: "Mosaic"
        case .eyes: "Eyes"
        case .bars: "Voice bars"
        case .words: "Words first"
        }
    }
    var detail: String {
        switch self {
        case .mosaic: "Fine tiles, flowing together."
        case .eyes: "The uiui eyes, listening and blinking."
        case .bars: "Thin bars that follow your voice."
        case .words: "Your words are the show."
        }
    }
    /// Retired and unknown stored values fall back to Mosaic.
    init(stored raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .mosaic }
}

/// How much room the notch takes beside the camera. The part over the camera
/// always matches the hardware; only the wings, the text row and its type grow.
enum NotchSize: String, Codable, CaseIterable, Identifiable {
    case compact, standard, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .large: "Large"
        }
    }
    /// Width added beside the camera while closed, and while open.
    var closedWings: CGFloat { switch self { case .compact: 72; case .standard: 96; case .large: 132 } }
    var expandedWings: CGFloat { switch self { case .compact: 108; case .standard: 148; case .large: 220 } }
    var minimumExpandedWidth: CGFloat { switch self { case .compact: 300; case .standard: 360; case .large: 440 } }
    var closedWidthWithoutCamera: CGFloat { switch self { case .compact: 150; case .standard: 180; case .large: 220 } }
    /// The live-transcript row below the header.
    var rowHeight: CGFloat { switch self { case .compact: 16; case .standard: 18; case .large: 22 } }
    var transcriptFontSize: CGFloat { switch self { case .compact: 11; case .standard: 12; case .large: 14 } }
    var bodyHeight: CGFloat { rowHeight + 9 }
}

struct UIUISettings: Codable {
    var notchEnabled = true
    var notchVisualStyle: NotchVisualStyle = .mosaic
    var notchSize: NotchSize = .standard
    var voiceTriggerEnabled = true
    var voiceTriggerKey: VoiceTriggerKey = .fn
    var voiceTriggerMode: VoiceTriggerMode = .toggle
    var openOnHover = false
    var quietMode = false
    var soundFeedbackEnabled = true
    /// Optional trackpad tap on start, stop and cancel. Off unless the user turns it on.
    var trackpadFeedbackEnabled = false
    var soundPack: SoundPack = .soft
    /// 0 to 1, relative to each pack's normal level.
    var soundVolume = 1.0
    var accent: UIUIAccent = .lime
    /// RRGGBB, used when `accent` is custom.
    var accentCustomHex = ""
    var aiEnabled = true
    var speechLocale = "en-IN"
    var saveDictationHistory = true
    var keepRecordingRecovery = true
    var launchAtLogin = false
    var vocabulary: [VocabularyEntry] = []
    var vocabularyScope = "Personal"
    var customProjects: [String] = ["Personal"]
    /// The setup guide finished or was dismissed. Missing in older settings, so
    /// existing installs see the guide once to grant anything still missing.
    var onboardingCompleted = false
    /// Lets agents on this Mac ask questions through `uiui ask`. Off until turned on.
    var agentAskEnabled = false
    /// The answer key's one-time hint has done its job.
    var agentAnswerKeyLearned = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case notchEnabled, notchVisualStyle, notchSize, voiceTriggerEnabled, voiceTriggerKey, voiceTriggerMode, openOnHover, quietMode, soundFeedbackEnabled, trackpadFeedbackEnabled, soundPack, soundVolume, accent, accentCustomHex, aiEnabled, speechLocale, saveDictationHistory, keepRecordingRecovery, launchAtLogin, vocabulary, vocabularyScope, customProjects, onboardingCompleted, agentAskEnabled, agentAnswerKeyLearned
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Missing keys use current defaults. The retired handsFreeEnabled value is
        // deliberately ignored: upgrading can never reopen the microphone.
        notchEnabled = try values.decodeIfPresent(Bool.self, forKey: .notchEnabled) ?? true
        // A future, missing or malformed style must not discard other saved
        // preferences or dictionary entries when falling back to current Mosaic.
        notchVisualStyle = NotchVisualStyle(stored: try? values.decode(String.self, forKey: .notchVisualStyle))
        notchSize = (try? values.decode(String.self, forKey: .notchSize)).flatMap(NotchSize.init(rawValue:)) ?? .standard
        voiceTriggerEnabled = try values.decodeIfPresent(Bool.self, forKey: .voiceTriggerEnabled) ?? true
        // An unknown or malformed trigger falls back to Fn without discarding settings.
        voiceTriggerKey = (try? values.decodeIfPresent(VoiceTriggerKey.self, forKey: .voiceTriggerKey)) ?? .fn
        voiceTriggerMode = try values.decodeIfPresent(VoiceTriggerMode.self, forKey: .voiceTriggerMode) ?? .toggle
        openOnHover = try values.decodeIfPresent(Bool.self, forKey: .openOnHover) ?? false
        quietMode = try values.decodeIfPresent(Bool.self, forKey: .quietMode) ?? false
        soundFeedbackEnabled = try values.decodeIfPresent(Bool.self, forKey: .soundFeedbackEnabled) ?? true
        trackpadFeedbackEnabled = try values.decodeIfPresent(Bool.self, forKey: .trackpadFeedbackEnabled) ?? false
        soundPack = (try? values.decodeIfPresent(SoundPack.self, forKey: .soundPack)) ?? .soft
        soundVolume = min(1, max(0, (try? values.decodeIfPresent(Double.self, forKey: .soundVolume)) ?? 1))
        accent = (try? values.decodeIfPresent(UIUIAccent.self, forKey: .accent)) ?? .lime
        accentCustomHex = (try? values.decodeIfPresent(String.self, forKey: .accentCustomHex)) ?? ""
        aiEnabled = try values.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? true
        speechLocale = try values.decodeIfPresent(String.self, forKey: .speechLocale) ?? "en-IN"
        saveDictationHistory = try values.decodeIfPresent(Bool.self, forKey: .saveDictationHistory) ?? true
        keepRecordingRecovery = try values.decodeIfPresent(Bool.self, forKey: .keepRecordingRecovery) ?? true
        agentAskEnabled = try values.decodeIfPresent(Bool.self, forKey: .agentAskEnabled) ?? false
        agentAnswerKeyLearned = try values.decodeIfPresent(Bool.self, forKey: .agentAnswerKeyLearned) ?? false
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        vocabulary = try values.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? []
        vocabularyScope = try values.decodeIfPresent(String.self, forKey: .vocabularyScope) ?? "Personal"
        customProjects = try values.decodeIfPresent([String].self, forKey: .customProjects) ?? ["Personal"]
        onboardingCompleted = try values.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
    }
}
