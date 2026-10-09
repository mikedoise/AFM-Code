import Foundation
import FoundationModels
import Observation

/// Detects the on-device Foundation Models available on this Mac.
///
/// The 27 SDK exposes `SystemLanguageModel` with a read-only `variant`
/// (`core3` / `coreAdvanced3`): the OS decides which variant a machine
/// gets, so the catalog *reports* rather than *chooses*.
@MainActor
@Observable
final class ModelCatalog {
    private(set) var descriptors: [ModelDescriptor] = []
    private(set) var probedAt: Date?

    /// The best model the app can use right now.
    var activeDescriptor: ModelDescriptor? {
        descriptors.first(where: \.isAvailable)
    }

    func descriptor(for kind: ModelDescriptor.Kind?) -> ModelDescriptor? {
        guard let kind else { return activeDescriptor }
        return descriptors.first { $0.kind == kind }
    }

    /// Re-read availability, variant, context size, and capabilities.
    /// Cheap: metadata only, no model load or inference.
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

        descriptors = [core, advanced]
        probedAt = Date()
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
