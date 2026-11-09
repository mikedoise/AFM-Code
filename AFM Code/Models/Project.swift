import Foundation
import SwiftData

/// A coding project: a named workspace rooted at a folder on disk.
///
/// Ordinary desktop bookmarks and legacy security-scoped bookmarks identify
/// the folder. File tools enforce this root; approved shell commands run from
/// it but may access other locations permitted to the user's Mac account.
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
    /// project. `nil` means "best available" (the on-device model, or
    /// the first ready MLX model).
    var modelKindRaw: String?
    /// The MLX model's Hugging Face repository id for new sessions,
    /// when `modelKindRaw` is `"mlx"`.
    var mlxModelID: String?
    /// Persistent identity of a user-selected Core AI export.
    var coreAIModelID: String?
    /// Commands the user chose "Always Allow" for in this project.
    /// Exact spelling, including quoted whitespace. Optional (not an
    /// empty array) so the schema migration can backfill existing
    /// rows with `nil`.
    var commandAllowlist: [String]?
    /// `ApprovalMode.rawValue` for this project. `nil` means "always
    /// ask". Optional so the schema migration backfills existing rows.
    var approvalModeRaw: String?
    /// Nil on legacy rows. Versioned independently from display preferences.
    var desktopAccessVersion: Int?
    /// Inactive historical grants; never consulted by the approval service.
    var sandboxCommandAllowlist: [String]?
    var sandboxApprovalModeRaw: String?
    var createdAt: Date
    var lastOpenedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatSession.project)
    var sessions: [ChatSession]?

    init(name: String, folderName: String? = nil, commandAllowlist: [String]? = nil) {
        self.id = UUID()
        self.name = name
        self.folderName = folderName ?? name
        self.commandAllowlist = commandAllowlist
        self.desktopAccessVersion = 1
        self.createdAt = Date()
        self.lastOpenedAt = Date()
    }

    var modelKind: ModelDescriptor.Kind? {
        get { modelKindRaw.flatMap(ModelDescriptor.Kind.init(rawValue:)) }
        set { modelKindRaw = newValue?.rawValue }
    }

    /// The project's model choice as a picker value: the two kinds and
    /// a specific MLX repository. An MLX kind without a repository
    /// (which pickers never produce) reads as "best available".
    var modelSelection: ModelSelection? {
        get {
            guard let kind = modelKind else { return .bestAvailable }
            switch kind {
            case .afmCore:
                return .afmCore
            case .afmCoreAdvanced:
                return .afmCoreAdvanced
            case .coreAI:
                return coreAIModelID.map { .coreAI(id: $0) }
            case .mlx:
                if let mlxModelID { return .mlx(repoID: mlxModelID) }
                return .bestAvailable
            }
        }
        set {
            coreAIModelID = nil
            switch newValue ?? .bestAvailable {
            case .bestAvailable:
                modelKindRaw = nil
                mlxModelID = nil
            case .afmCore:
                modelKindRaw = ModelDescriptor.Kind.afmCore.rawValue
                mlxModelID = nil
            case .afmCoreAdvanced:
                modelKindRaw = ModelDescriptor.Kind.afmCoreAdvanced.rawValue
                mlxModelID = nil
            case .coreAI(let id):
                modelKindRaw = ModelDescriptor.Kind.coreAI.rawValue
                coreAIModelID = id
                mlxModelID = nil
            case .mlx(let repoID):
                modelKindRaw = ModelDescriptor.Kind.mlx.rawValue
                mlxModelID = repoID
            }
        }
    }

    var approvalMode: ApprovalMode? {
        get { approvalModeRaw.flatMap(ApprovalMode.init(rawValue:)) }
        set { approvalModeRaw = newValue?.rawValue }
    }

    /// Most recent sessions first.
    var sessionList: [ChatSession] {
        (sessions ?? []).sorted { $0.lastMessageAt > $1.lastMessageAt }
    }
}
