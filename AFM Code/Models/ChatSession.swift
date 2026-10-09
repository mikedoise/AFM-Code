import Foundation
import SwiftData

/// A single conversation thread with the coding agent.
@Model
final class ChatSession {
    var id: UUID
    var title: String
    var createdAt: Date
    var lastMessageAt: Date
    /// `ModelDescriptor.Kind.rawValue` selected for this session.
    /// `nil` means "best available on-device model".
    var modelKindRaw: String?
    /// JSON-encoded `FoundationModels.Transcript`, used to resume the
    /// model session with its full prior history (prompts, responses,
    /// and — from Phase 3 onward — tool calls/outputs).
    var transcriptData: Data?
    /// Token count of the last measured transcript, for the context meter.
    var lastTokenCount: Int?

    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    var messages: [Message]?

    init(title: String = "New Session") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.lastMessageAt = Date()
    }

    var modelKind: ModelDescriptor.Kind? {
        get { modelKindRaw.flatMap(ModelDescriptor.Kind.init(rawValue:)) }
        set { modelKindRaw = newValue?.rawValue }
    }

    /// Messages in chronological order (SwiftData to-many is unordered).
    var messageList: [Message] {
        (messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    /// Adopt the first user message as a short session title, once.
    func setInitialTitle(from firstMessage: String) {
        guard title == "New Session" else { return }
        let trimmed = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let words = trimmed.components(separatedBy: .whitespaces)
        title = words.count > 8
            ? words.prefix(8).joined(separator: " ") + "…"
            : trimmed
    }
}
