import Foundation
import SwiftData

/// A coding project: a named workspace rooted at a folder on disk.
///
/// The folder is referenced by a **security-scoped bookmark** so the
/// sandboxed app can read and write inside it. From Phase 3 on, all
/// file and shell tools operate only within this root; nothing here
/// ever writes outside it.
@Model
final class Project {
    var id: UUID
    var name: String
    /// The folder's name when the project was added, so the UI can
    /// still show where the project came from if the folder moves.
    var folderName: String
    /// Security-scoped bookmark for the project folder.
    var bookmarkData: Data?
    /// `ModelDescriptor.Kind.rawValue` used for new sessions in this
    /// project. `nil` means "best available on-device model".
    var modelKindRaw: String?
    var createdAt: Date
    var lastOpenedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatSession.project)
    var sessions: [ChatSession]?

    init(name: String, folderName: String? = nil) {
        self.id = UUID()
        self.name = name
        self.folderName = folderName ?? name
        self.createdAt = Date()
        self.lastOpenedAt = Date()
    }

    var modelKind: ModelDescriptor.Kind? {
        get { modelKindRaw.flatMap(ModelDescriptor.Kind.init(rawValue:)) }
        set { modelKindRaw = newValue?.rawValue }
    }

    /// Most recent sessions first.
    var sessionList: [ChatSession] {
        (sessions ?? []).sorted { $0.lastMessageAt > $1.lastMessageAt }
    }
}
