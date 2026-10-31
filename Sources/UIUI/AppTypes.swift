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
    case mosaic, liquid, ribbon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mosaic: "Mosaic"
        case .liquid: "Liquid"
        case .ribbon: "Ribbon"
        }
    }
    var detail: String {
        switch self {
        case .mosaic: "Fine tiles, flowing together."
        case .liquid: "Soft pools of moving light."
        case .ribbon: "A fine ribbon around the edge."
        }
    }
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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case notchEnabled, notchVisualStyle, notchSize, voiceTriggerEnabled, voiceTriggerKey, voiceTriggerMode, openOnHover, quietMode, soundFeedbackEnabled, aiEnabled, speechLocale, saveDictationHistory, keepRecordingRecovery, launchAtLogin, vocabulary, vocabularyScope, customProjects, onboardingCompleted
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Missing keys use current defaults. The retired handsFreeEnabled value is
        // deliberately ignored: upgrading can never reopen the microphone.
        notchEnabled = try values.decodeIfPresent(Bool.self, forKey: .notchEnabled) ?? true
        // A future, missing or malformed style must not discard other saved
        // preferences or dictionary entries when falling back to current Mosaic.
        notchVisualStyle = (try? values.decode(String.self, forKey: .notchVisualStyle))
            .flatMap(NotchVisualStyle.init(rawValue:)) ?? .mosaic
        notchSize = (try? values.decode(String.self, forKey: .notchSize)).flatMap(NotchSize.init(rawValue:)) ?? .standard
        voiceTriggerEnabled = try values.decodeIfPresent(Bool.self, forKey: .voiceTriggerEnabled) ?? true
        // An unknown or malformed trigger falls back to Fn without discarding settings.
        voiceTriggerKey = (try? values.decodeIfPresent(VoiceTriggerKey.self, forKey: .voiceTriggerKey)) ?? .fn
        voiceTriggerMode = try values.decodeIfPresent(VoiceTriggerMode.self, forKey: .voiceTriggerMode) ?? .toggle
        openOnHover = try values.decodeIfPresent(Bool.self, forKey: .openOnHover) ?? false
        quietMode = try values.decodeIfPresent(Bool.self, forKey: .quietMode) ?? false
        soundFeedbackEnabled = try values.decodeIfPresent(Bool.self, forKey: .soundFeedbackEnabled) ?? true
        aiEnabled = try values.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? true
        speechLocale = try values.decodeIfPresent(String.self, forKey: .speechLocale) ?? "en-IN"
        saveDictationHistory = try values.decodeIfPresent(Bool.self, forKey: .saveDictationHistory) ?? true
        keepRecordingRecovery = try values.decodeIfPresent(Bool.self, forKey: .keepRecordingRecovery) ?? true
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        vocabulary = try values.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? []
        vocabularyScope = try values.decodeIfPresent(String.self, forKey: .vocabularyScope) ?? "Personal"
        customProjects = try values.decodeIfPresent([String].self, forKey: .customProjects) ?? ["Personal"]
        onboardingCompleted = try values.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
    }
}
