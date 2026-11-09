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
        case coreAI = "core-ai"
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
    var coreAIModelID: String? = nil

    /// Unique per model: the kind, plus the repository for MLX models
    /// (two Hub models are different models).
    var id: String {
        switch kind {
        case .mlx: "mlx:\(mlxRepoID ?? "?")"
        case .coreAI: "core-ai:\(coreAIModelID ?? "?")"
        default: kind.rawValue
        }
    }

    init(
        kind: Kind,
        displayName: String,
        detail: String?,
        isAvailable: Bool,
        availabilityDetail: String? = nil,
        contextSize: Int? = nil,
        capabilities: Set<String> = [],
        mlxRepoID: String? = nil,
        coreAIModelID: String? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.detail = detail
        self.isAvailable = isAvailable
        self.availabilityDetail = availabilityDetail
        self.contextSize = contextSize
        self.capabilities = capabilities
        self.mlxRepoID = mlxRepoID
        self.coreAIModelID = coreAIModelID
    }
}

/// What a model picker can select: the on-device default, a pinned AFM
/// variant, or a specific MLX model from the library.
enum ModelSelection: Hashable, Sendable {
    case bestAvailable
    case afmCore
    case afmCoreAdvanced
    case mlx(repoID: String)
    case coreAI(id: String)
}

// Presentation only: never change persisted identities or repository paths.
extension ModelDescriptor {
    var readableName: String {
        kind == .coreAI ? Self.readableCoreAIName(displayName, contextSize: contextSize) : displayName
    }

    static func readableCoreAIName(_ name: String, contextSize: Int?) -> String {
        guard name.contains("-") || name.contains("_") else { return name }
        var parts = name.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        parts.removeAll { part in
            let lower = part.lowercased()
            if lower == "coreai" || lower == "text" { return true }
            if let contextSize, lower == "ctx\(contextSize)" { return true }
            if let contextSize, contextSize % 1024 == 0, lower == "\(contextSize / 1024)k" { return true }
            return false
        }
        return parts.map { part in
            if part.lowercased() == "gemma" { return "Gemma" }
            if part.lowercased() == "gemma4" { return "Gemma 4" }
            if part.lowercased() == "e2b" { return "E2B" }
            if part.lowercased() == "it" { return "instruction tuned" }
            if part.lowercased().hasSuffix("bit"), let bits = Int(part.dropLast(3)) { return "\(bits) bit" }
            return part
        }.joined(separator: " ")
    }

    var modalityDescription: String {
        // The Core AI importer accepts only kind=llm text exports.
        if kind == .coreAI { return "Modalities: text" }
        if capabilities.contains("vision") { return "Modalities: text and images" }
        return "Modalities: text; image support not reported"
    }

    var accessibleDescription: String {
        let context = contextSize.map { "Context window: \($0.formatted()) tokens" } ?? "Context window: not reported"
        return "\(readableName). \(context). \(modalityDescription)"
    }
}
