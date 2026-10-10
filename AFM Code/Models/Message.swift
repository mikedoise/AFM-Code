import Foundation
import SwiftData

/// One message in a `ChatSession` transcript.
///
/// User messages hold the prompt text. Assistant messages hold the
/// response text plus, from Phase 3 on, JSON-encoded tool activity
/// (`[ToolStep]`) so resumed sessions render the same history — the
/// same pattern Perspective Intelligence uses.
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
    /// JSON-encoded `[ToolStep]` for assistant messages.
    var toolActivityData: Data?
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

    var toolActivity: [ToolStep]? {
        get {
            guard let data = toolActivityData else { return nil }
            return try? JSONDecoder().decode([ToolStep].self, from: data)
        }
        set {
            guard let newValue, !newValue.isEmpty else {
                toolActivityData = nil
                return
            }
            toolActivityData = try? JSONEncoder().encode(newValue)
        }
    }
}
