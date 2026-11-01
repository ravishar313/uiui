import Foundation

public enum CaptureKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case note, thought, dictation, reminder
    public var id: String { rawValue }
    public var title: String { switch self { case .note: "Note"; case .thought: "Thought"; case .dictation: "Dictation"; case .reminder: "Reminder" } }
    public var symbol: String { switch self { case .note: "note.text"; case .thought: "sparkle"; case .dictation: "waveform"; case .reminder: "bell" } }
}

public struct CaptureItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var kind: CaptureKind
    public var project: String
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var reminderDate: Date?
    public var isCompleted: Bool
    public var isPinned: Bool
    public var sourceApp: String?
    public var rawText: String?
    public init(id: UUID = UUID(), title: String, body: String, kind: CaptureKind = .note, project: String = "Personal", tags: [String] = [], createdAt: Date = Date(), updatedAt: Date = Date(), reminderDate: Date? = nil, isCompleted: Bool = false, isPinned: Bool = false, sourceApp: String? = nil, rawText: String? = nil) {
        self.id = id; self.title = title; self.body = body; self.kind = kind; self.project = project; self.tags = tags; self.createdAt = createdAt; self.updatedAt = updatedAt; self.reminderDate = reminderDate; self.isCompleted = isCompleted; self.isPinned = isPinned; self.sourceApp = sourceApp; self.rawText = rawText
    }
}

public struct UsageEvent: Identifiable, Codable, Sendable {
    public var id: UUID
    public var date: Date
    public var action: String
    public var durationMS: Double?
    public var wordCount: Int
    public var succeeded: Bool
    public init(id: UUID = UUID(), date: Date = Date(), action: String, durationMS: Double? = nil, wordCount: Int = 0, succeeded: Bool = true) {
        self.id = id; self.date = date; self.action = action; self.durationMS = durationMS; self.wordCount = wordCount; self.succeeded = succeeded
    }
}

public struct VocabularyEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var heard: String
    public var replacement: String
    public var project: String
    public init(id: UUID = UUID(), heard: String, replacement: String, project: String = "All projects") { self.id = id; self.heard = heard; self.replacement = replacement; self.project = project }

    /// Just a spelling, not a rule: uiui also listens for words that sound like it.
    public var isSpellingOnly: Bool {
        heard.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(replacement.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Built-in spellings that always apply after the user's own entries, so a
    /// user entry for the same phrase wins. Speech models hear the app's name as
    /// letters or as two words.
    /// A spoken or written form is one to 120 characters with no control or format characters.
    public static func isValidTerm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, term.count <= 120 else { return false }
        return !term.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }
    }

    public static let builtIn: [VocabularyEntry] = ["UI UI", "U I U I", "U.I.U.I.", "U.I. U.I.", "UI-UI", "UIUI",
                                                    "you eye you eye", "you I you I"].map {
        VocabularyEntry(heard: $0, replacement: "uiui")
    }
}
