import Foundation
import SwiftData

/// A model the user added from the Hugging Face Hub, run locally on
/// Apple Silicon via MLX.
///
/// Unlike the on-device AFM model — which the OS provides and the app
/// only reports — MLX models are user-curated: searched on the Hub,
/// downloaded into the app container, and selected per session.
///
/// Download state is not stored here; the `MLXLanguageModel` adapter
/// derives it at runtime (weights present, download in flight, …) from
/// the on-disk cache.
@Model
final class MlxModel {
    var id: UUID
    /// Hugging Face repository identifier, e.g.
    /// "mlx-community/Qwen3-4B-4bit".
    var repoID: String
    /// The git revision to download (usually "main").
    var revision: String
    /// A friendlier display name, when we have one.
    var displayName: String?
    /// The `model_type` from `config.json` (e.g. "qwen3"), captured at
    /// add time for display and capability inference.
    var modelType: String?
    /// The weights' size as reported by the Hub, in bytes, when known.
    var sizeBytes: Int64?
    /// The model's context window in tokens, when known.
    var maxContextTokens: Int?
    /// Comma-separated capability names to declare when loading
    /// ("toolCalling,reasoning,vision"), or `nil` for the adapter's
    /// defaults.
    var capabilitiesRaw: String?
    var addedAt: Date

    init(
        repoID: String,
        revision: String = "main",
        displayName: String? = nil,
        modelType: String? = nil,
        sizeBytes: Int64? = nil,
        maxContextTokens: Int? = nil,
        capabilitiesRaw: String? = nil
    ) {
        self.id = UUID()
        self.repoID = repoID
        self.revision = revision
        self.displayName = displayName
        self.modelType = modelType
        self.sizeBytes = sizeBytes
        self.maxContextTokens = maxContextTokens
        self.capabilitiesRaw = capabilitiesRaw
        self.addedAt = Date()
    }

    /// The declared capability names, or `nil` to use the adapter's
    /// defaults (guided generation).
    var capabilities: [String]? {
        guard let raw = capabilitiesRaw else { return nil }
        let names = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    func setCapabilities(_ names: [String]) {
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        capabilitiesRaw = cleaned.isEmpty ? nil : cleaned.joined(separator: ",")
    }
}
