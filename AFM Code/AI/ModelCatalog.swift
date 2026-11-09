import Foundation
import FoundationModels
import Observation
import SwiftData

/// Detects the models available to this Mac: the on-device Foundation
/// Models the OS provides, plus the MLX models in the user's library.
///
/// The 27 SDK exposes `SystemLanguageModel` with a read-only `variant`
/// (`core3` / `coreAdvanced3`): the OS decides which variant a machine
/// gets, so the catalog *reports* rather than *chooses*. MLX models are
/// user-curated: each one added to the library contributes a descriptor,
/// and its readiness is derived at runtime from the on-disk cache.
@MainActor
@Observable
final class ModelCatalog {
    /// The on-device AFM pair, from `probe()`.
    private(set) var afmDescriptors: [ModelDescriptor] = []
    /// One descriptor per MLX model in the library, from
    /// `refreshMlxModels()`.
    private(set) var mlxDescriptors: [ModelDescriptor] = []
    private(set) var probedAt: Date?

    private let modelContext: SwiftData.ModelContext
    private let mlx: MLXModelManager
    let coreAI = CoreAIModelManager()

    init(modelContext: SwiftData.ModelContext, mlx: MLXModelManager) {
        self.modelContext = modelContext
        self.mlx = mlx
    }

    /// Every model AFM Code can prompt. Pickers iterate this: the
    /// on-device pair first, then the library's MLX models.
    var descriptors: [ModelDescriptor] {
        afmDescriptors + mlxDescriptors + coreAI.descriptors
    }

    /// The best model the app can use right now: the on-device model
    /// when the OS serves one, else the first ready MLX model.
    var activeDescriptor: ModelDescriptor? {
        descriptors.first(where: \.isAvailable)
    }

    func descriptor(for kind: ModelDescriptor.Kind?) -> ModelDescriptor? {
        guard let kind else { return activeDescriptor }
        return descriptors.first { $0.kind == kind }
    }

    /// A specific MLX model from the library, keyed by its repository id.
    func descriptor(for kind: ModelDescriptor.Kind, mlxRepoID: String?) -> ModelDescriptor? {
        guard kind == .mlx, let mlxRepoID else { return nil }
        return descriptors.first { $0.kind == .mlx && $0.mlxRepoID == mlxRepoID }
    }

    func selectedDescriptor(for session: ChatSession) -> ModelDescriptor? {
        let selected = session.modelKind.map { ModelChoice(kind: $0, mlxRepoID: session.mlxModelID, coreAIID: session.coreAIModelID) }
        let inherited = session.project?.modelKind.map { ModelChoice(kind: $0, mlxRepoID: session.project?.mlxModelID, coreAIID: session.project?.coreAIModelID) }
        return ModelSelectionResolver.resolve(session: selected, project: inherited, descriptors: descriptors)
    }

    func selectedDescriptor(for project: Project) -> ModelDescriptor? {
        let inherited = project.modelKind.map { ModelChoice(kind: $0, mlxRepoID: project.mlxModelID, coreAIID: project.coreAIModelID) }
        return ModelSelectionResolver.resolve(project: inherited, descriptors: descriptors)
    }

    func status(for model: ModelDescriptor?, role: ModelStatus.Role = .selected,
                preparing: Bool = false, inUse: Bool = false, failure: String? = nil) -> ModelStatus {
        let id = model?.kind == .coreAI ? model?.coreAIModelID : nil
        var status = ModelStatus.resolve(model: model, role: role,
            preparing: preparing || id.map { coreAI.isPreparing(modelID: $0) } == true,
            inUse: inUse,
            loaded: id.map { coreAI.loadedModelID == $0 } == true,
            failure: failure ?? id.flatMap { coreAI.loadErrors[$0] })
        if model == nil, role == .appDefault, status.state == .unavailable {
            status.detail = descriptors.first?.availabilityDetail ?? status.detail
        }
        return status
    }

    /// Re-read availability, variant, context size, and capabilities of
    /// the on-device model. Cheap: metadata only, no model load or
    /// inference.
    func probe() async {
        let model = SystemLanguageModel.default
        let available = model.isAvailable
        let unavailableReason = available ? nil : Self.unavailableDetail(for: model)

        var core = ModelDescriptor(
            kind: .afmCore,
            displayName: "AFM 3 Core",
            detail: "3B dense · fast everyday coding",
            isAvailable: false,
            availabilityDetail: unavailableReason
        )
        var advanced = ModelDescriptor(
            kind: .afmCoreAdvanced,
            displayName: "AFM 3 Core Advanced",
            detail: "20B sparse · deeper reasoning",
            isAvailable: false,
            availabilityDetail: unavailableReason
        )

        if available {
            let contextSize = model.contextSize
            let capabilities = Self.capabilities(of: model)

            if model.variant == .coreAdvanced3 {
                advanced = ModelDescriptor(
                    kind: .afmCoreAdvanced,
                    displayName: model.variant.displayName,
                    detail: advanced.detail,
                    isAvailable: true,
                    contextSize: contextSize,
                    capabilities: capabilities
                )
                core.availabilityDetail = "This Mac is running the Core Advanced model."
            } else if model.variant == .core3 {
                core = ModelDescriptor(
                    kind: .afmCore,
                    displayName: model.variant.displayName,
                    detail: core.detail,
                    isAvailable: true,
                    contextSize: contextSize,
                    capabilities: capabilities
                )
                advanced.availabilityDetail = "Not available on this Mac."
            } else {
                // Unknown variant: treat whatever the OS serves as the base model.
                core = ModelDescriptor(
                    kind: .afmCore,
                    displayName: model.variant.displayName,
                    detail: "On-device model",
                    isAvailable: true,
                    contextSize: contextSize,
                    capabilities: capabilities
                )
                advanced.availabilityDetail = "Not available on this Mac."
            }
        }

        afmDescriptors = [core, advanced]
        probedAt = Date()
    }

    /// Re-derive the MLX descriptors from the library: one per stored
    /// model, its readiness snapshotted from the adapter without
    /// touching the network. Called at launch, after models are added
    /// or removed, and when a download starts or finishes.
    func refreshMlxModels() async {
        let fetch = FetchDescriptor<MlxModel>(
            sortBy: [SortDescriptor(\MlxModel.addedAt, order: .reverse)]
        )
        let models = (try? modelContext.fetch(fetch)) ?? []
        var refreshed: [ModelDescriptor] = []
        for model in models {
            refreshed.append(Self.descriptor(for: model, state: await mlx.state(for: model)))
        }
        mlxDescriptors = refreshed
    }

    private static func descriptor(
        for model: MlxModel,
        state: MLXModelManager.ModelState
    ) -> ModelDescriptor {
        let (isAvailable, detail): (Bool, String?) = switch state {
        case .ready:
            (true, nil)
        case .downloading:
            (false, "Downloading weights…")
        case .notDownloaded:
            (false, "Not downloaded yet — download it in Settings → MLX Models.")
        case .downloadFailed:
            (false, "The last download failed — retry it in Settings → MLX Models.")
        case .deviceNotCapable:
            (false, "This Mac can't run this model.")
        case .unknown:
            (false, nil)
        }
        return ModelDescriptor(
            kind: .mlx,
            displayName: model.displayName ?? model.repoID,
            detail: model.modelType,
            isAvailable: isAvailable,
            availabilityDetail: detail,
            contextSize: model.maxContextTokens,
            capabilities: Set(model.capabilities ?? []),
            mlxRepoID: model.repoID
        )
    }

    private static func capabilities(of model: SystemLanguageModel) -> Set<String> {
        let set: [String?] = [
            model.capabilities.contains(.toolCalling) ? "toolCalling" : nil,
            model.capabilities.contains(.reasoning) ? "reasoning" : nil,
            model.capabilities.contains(.vision) ? "vision" : nil,
            model.capabilities.contains(.guidedGeneration) ? "guidedGeneration" : nil
        ]
        return Set(set.compactMap { $0 })
    }

    private static func unavailableDetail(for model: SystemLanguageModel) -> String? {
        guard !model.isAvailable else { return nil }
        if case .unavailable(let reason) = model.availability {
            switch reason {
            case .deviceNotEligible:
                return "This Mac can't run Apple Intelligence models."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is off. Enable it in System Settings → Apple Intelligence, then relaunch."
            case .modelNotReady:
                return "The on-device model is still loading. Check back in a moment."
            @unknown default:
                return "The on-device model is currently unavailable."
            }
        }
        return "The on-device model is currently unavailable."
    }
}
