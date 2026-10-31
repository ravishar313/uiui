import Foundation

/// Recognized text kept separately from saved captures until the user recovers or discards it.
/// Older capture kinds remain decodable; this journal stores recognized text, never audio.
public struct RecordingRecoveryDraft: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var project: String
    public var kind: CaptureKind
    public var startedAt: Date
    public var updatedAt: Date
    public var revision: Int64

    public init(id: UUID = UUID(), text: String, project: String = "Personal", kind: CaptureKind = .note,
                startedAt: Date = Date(), updatedAt: Date = Date(), revision: Int64 = 0) {
        self.id = id
        self.text = text
        self.project = project
        self.kind = kind
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.revision = revision
    }
}
