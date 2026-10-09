import Foundation
import SwiftData

/// One message in a `ChatSession` transcript.
///
/// Phase 1 stores user prompts and assistant responses. Tool activity
/// (Phase 3) will attach as JSON-encoded activity data on assistant
/// messages, the same pattern Perspective Intelligence uses.
@Model
final class Message {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: UUID
    var roleRaw: String
    var content: String
    var timestamp: Date
    /// Output tokens reported by the model for assistant responses.
    var tokenCount: Int?
    var session: ChatSession?

    init(role: Role, content: String) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.timestamp = Date()
    }

    var role: Role {
        get { Role(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }
}
