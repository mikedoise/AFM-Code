import Foundation

/// A model AFM Code can prompt, detected at runtime.
///
/// On-device: the OS decides which AFM variant backs
/// `SystemLanguageModel` on a given machine (`core3` = AFM 3 Core,
/// `coreAdvanced3` = AFM 3 Core Advanced); we report rather than choose.
///
/// MLX: user-curated models from the Hugging Face Hub, run locally via
/// the `MLXLanguageModel` adapter. Each gets its own descriptor keyed by
/// repository id.
struct ModelDescriptor: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case afmCore = "afm-core"
        case afmCoreAdvanced = "afm-core-advanced"
        case mlx = "mlx"
    }

    let kind: Kind
    var displayName: String
    var detail: String?
    var isAvailable: Bool
    var availabilityDetail: String?
    var contextSize: Int?
    var capabilities: Set<String>
    /// The Hugging Face repository id, when `kind == .mlx`.
    var mlxRepoID: String? = nil

    /// Unique per model: the kind, plus the repository for MLX models
    /// (two Hub models are different models).
    var id: String {
        kind == .mlx ? "mlx:\(mlxRepoID ?? "?")" : kind.rawValue
    }

    init(
        kind: Kind,
        displayName: String,
        detail: String?,
        isAvailable: Bool,
        availabilityDetail: String? = nil,
        contextSize: Int? = nil,
        capabilities: Set<String> = [],
        mlxRepoID: String? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.detail = detail
        self.isAvailable = isAvailable
        self.availabilityDetail = availabilityDetail
        self.contextSize = contextSize
        self.capabilities = capabilities
        self.mlxRepoID = mlxRepoID
    }
}

/// What a model picker can select: the on-device default, a pinned AFM
/// variant, or a specific MLX model from the library.
enum ModelSelection: Hashable, Sendable {
    case bestAvailable
    case afmCore
    case afmCoreAdvanced
    case mlx(repoID: String)
}
