import Foundation

/// The same model-choice rules serve the runtime and every status surface.
struct ModelChoice: Sendable {
    var kind: ModelDescriptor.Kind
    var mlxRepoID: String? = nil
    var coreAIID: String? = nil
}

enum ModelSelectionResolver {
    static func activeModel(selected: ModelDescriptor?, inFlight: ModelDescriptor?) -> ModelDescriptor? {
        inFlight ?? selected
    }

    static func resolve(session: ModelChoice? = nil, project: ModelChoice? = nil,
                        descriptors: [ModelDescriptor]) -> ModelDescriptor? {
        let fallback = descriptors.first(where: \.isAvailable)
        guard let choice = session ?? project else { return fallback }
        switch choice.kind {
        case .coreAI:
            return descriptors.first { $0.kind == .coreAI && $0.coreAIModelID == choice.coreAIID }
                ?? ModelDescriptor(kind: .coreAI, displayName: "Missing Core AI model", detail: nil, isAvailable: false,
                    availabilityDetail: "The selected Core AI export is no longer in the library. Add it again or choose another model.", coreAIModelID: choice.coreAIID)
        case .mlx:
            // Preserve the existing runtime fallback when a removed MLX choice
            // no longer exists. Core AI choices deliberately do not fall back.
            return descriptors.first { $0.kind == .mlx && $0.mlxRepoID == choice.mlxRepoID } ?? fallback
        default:
            return descriptors.first { $0.kind == choice.kind }
        }
    }
}

struct ModelStatus: Equatable, Sendable {
    enum Role: String, Sendable { case selected = "Selected", projectDefault = "Project default", appDefault = "Default" }
    enum State: String, Sendable { case selected = "Selected", preparing = "Preparing", loaded = "Loaded", inUse = "In use", failed = "Error", unavailable = "Unavailable" }
    var model: ModelDescriptor?
    var role: Role
    var state: State
    var detail: String?

    static func resolve(model: ModelDescriptor?, role: Role = .selected,
                        preparing: Bool = false, inUse: Bool = false, loaded: Bool = false,
                        failure: String? = nil) -> ModelStatus {
        let state: State
        let detail: String?
        if preparing { state = .preparing; detail = "Preparing this model. It is not yet confirmed loaded." }
        else if inUse { state = .inUse; detail = "This model is handling the current turn." }
        else if model?.isAvailable != true { state = .unavailable; detail = model?.availabilityDetail ?? "No model is available." }
        else if loaded { state = .loaded; detail = "This model is loaded in memory." }
        else if let failure { state = .failed; detail = failure }
        else { state = .selected; detail = "Chosen for the next request. Availability does not mean the model is loaded." }
        return ModelStatus(model: model, role: role, state: state, detail: detail)
    }

    var label: String { state == .selected ? role.rawValue : state.rawValue }
    var name: String { model?.displayName ?? "No model available" }
    var accessibilityLabel: String { "\(role.rawValue) model: \(name), \(label)" }
}
