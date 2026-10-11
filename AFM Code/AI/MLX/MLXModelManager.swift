import Foundation
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXLMCommon
import MLXHuggingFace
import OSLog
import Observation
import SwiftData
import Tokenizers

/// The app's MLX model library: searches the Hugging Face Hub, tracks
/// the models the user has added, and builds the `MLXLanguageModel`
/// adapters that run inside the same Foundation Models session
/// machinery as the on-device AFM model.
///
/// Weights live in a known location inside the app container. The
/// package's default cache auto-detects its location (environment
/// variables, home directory, or the container depending on the host);
/// binding the Hub client and every weights location to an explicit
/// container directory keeps downloads and storage deterministic inside
/// the sandbox — the same confinement the project workspaces get.
@MainActor
@Observable
final class MLXModelManager {
    private static let logger = Logger(subsystem: "dev.afmcode", category: "MLXModelManager")

    /// `SwiftData.ModelContext` — qualified because MLXLMCommon declares
    /// its own `ModelContext` (the model + tokenizer container).
    private let modelContext: SwiftData.ModelContext
    private let cache: HubCache
    private let hub: HubClient

    /// Where downloaded weights live: the app container's
    /// Application Support directory, in a `Hub` subfolder.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Hub", isDirectory: true)
    }

    // MARK: - Search state

    var searchText = ""
    private(set) var results: [HuggingFace.Model] = []
    private(set) var isSearching = false
    private(set) var searchError: String?

    init(modelContext: SwiftData.ModelContext) {
        self.modelContext = modelContext
        let cache = HubCache(cacheDirectory: Self.cacheDirectory)
        self.cache = cache
        // No explicit token: public MLX repositories download anonymously.
        // `.environment` follows the HF ecosystem default (HF_TOKEN and
        // friends) when the app is launched with one, and degrades
        // gracefully to no auth in the sandbox.
        self.hub = HubClient(host: HubClient.defaultHost, tokenProvider: .environment, cache: cache)
        try? FileManager.default.createDirectory(
            at: cache.cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Hub search

    /// Search the Hub, most-downloaded first. No library filter is
    /// applied — search terms do the narrowing — but only results that
    /// carry MLX weights can be added (checked at add time).
    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            results = []
            return
        }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            let page = try await hub.listModels(
                search: query,
                sort: "downloads",
                direction: .descending,
                limit: 25,
                fetchConfig: true
            )
            results = page.items
        } catch {
            Self.logger.error("Hub search failed: \(error.localizedDescription)")
            searchError = "Search failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Library

    /// Whether a Hub result carries MLX weights and can be run. The Hub
    /// tags MLX-converted repos with "mlx" (mlx-community, lmstudio, …);
    /// a repo without that is a non-MLX checkpoint the loader can't read.
    static func isMLXModel(_ result: HuggingFace.Model) -> Bool {
        if result.library == "mlx" { return true }
        return result.tags?.contains { $0.caseInsensitiveCompare("mlx") == .orderedSame } ?? false
    }

    /// Add a search result (or a pasted repository id) to the library.
    /// A model already in the library is left untouched.
    @discardableResult
    func add(repoID: String, result: HuggingFace.Model? = nil) -> MlxModel? {
        let trimmed = repoID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let existing = model(forRepoID: trimmed) {
            return existing
        }
        let model = MlxModel(
            repoID: trimmed,
            displayName: result == nil ? trimmed.split(separator: "/").last.map(String.init) : nil
        )
        if let config = result?.config {
            model.modelType = Self.stringValue(config["model_type"])
            model.maxContextTokens = Self.intValue(config["max_position_embeddings"])
            model.setCapabilities(Self.inferCapabilities(
                modelType: model.modelType,
                chatTemplate: Self.stringValue(config["chat_template_jinja"]),
                tags: result?.tags
            ))
        }
        if let size = result?.usedStorage {
            model.sizeBytes = Int64(size)
        }
        modelContext.insert(model)
        try? modelContext.save()
        return model
    }

    /// Remove a model from the library and delete its cached weights.
    func remove(_ model: MlxModel) {
        if let repository = Repo.ID(rawValue: model.repoID) {
            let directory = cache.repoDirectory(repo: repository, kind: .model)
            try? FileManager.default.removeItem(at: directory)
        }
        modelContext.delete(model)
        try? modelContext.save()
    }

    /// A library model by repository id, when present.
    func model(forRepoID repoID: String) -> MlxModel? {
        let predicate = #Predicate<MlxModel> { $0.repoID == repoID }
        let descriptor = FetchDescriptor(predicate: predicate)
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Runtime

    /// The Foundation Models `LanguageModel` adapter for a library model:
    /// weights and tokenizer resolve through the container's Hub cache, so
    /// downloads and storage stay inside the sandbox.
    ///
    /// This mirrors what the `#huggingFaceLanguageModel` macro synthesizes,
    /// except that macro binds `HubCache.default` — outside the sandbox —
    /// so the cache is constructed by hand here.
    func languageModel(for model: MlxModel) -> MLXLanguageModel {
        MLXLanguageModel(
            configuration: ModelConfiguration(
                id: model.repoID,
                revision: model.revision
            ),
            capabilities: Self.capabilities(from: model.capabilities),
            weightsLocation: { id in
                Self.location(forModelID: id, cache: self.cache)
            },
            load: { configuration, progressHandler in
                try await loadModelContainer(
                    from: #hubDownloader(self.hub),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: progressHandler
                )
            }
        )
    }

    /// Resolve a model identifier to its on-disk location inside the
    /// cache — the same scheme the `#huggingFaceLanguageModel` macro
    /// uses, bound to our container cache. Nonisolated: called from
    /// the adapter's sendable `weightsLocation` closure.
    nonisolated private static func location(forModelID id: String, cache: HubCache) -> URL {
        guard let repository = Repo.ID(rawValue: id) else {
            return cache.cacheDirectory
        }
        if let commit = cache.resolveRevision(repo: repository, kind: .model, ref: "main"),
           let snapshot = try? cache.snapshotPath(repo: repository, kind: .model, commitHash: commit) {
            return snapshot
        }
        return cache.repoDirectory(repo: repository, kind: .model)
    }

    /// A model's readiness, collapsed for UI rows.
    enum ModelState: Equatable, Sendable {
        case ready
        case downloading
        case notDownloaded
        case downloadFailed
        case deviceNotCapable
        case unknown
    }

    /// Snapshot a library model's readiness (device, weights, download
    /// state) without contacting the network.
    func state(for model: MlxModel) async -> ModelState {
        let adapter = languageModel(for: model)
        switch await adapter.availability {
        case .available:
            return .ready
        case .downloading:
            return .downloading
        case .unavailable(let reason):
            switch reason {
            case .modelNotDownloaded: return .notDownloaded
            case .downloadFailed: return .downloadFailed
            case .deviceNotCapable: return .deviceNotCapable
            @unknown default: return .unknown
            }
        @unknown default:
            return .unknown
        }
    }

    /// Start (or resume) downloading a model's weights. Download
    /// progress flows into `MLXDownloadProgress.shared`, which the UI
    /// observes. A completed download also backfills the model's context
    /// window from its local `config.json`.
    func download(_ model: MlxModel) async {
        do {
            try await languageModel(for: model).preload()
            await ensureContextSize(for: model)
        } catch is CancellationError {
            Self.logger.info("download of \(model.repoID) cancelled")
        } catch {
            Self.logger.error("download of \(model.repoID) failed: \(error.localizedDescription)")
        }
    }

    /// The directory holding a model's downloaded files (config.json,
    /// tokenizer files, weights) — `nil` until the download is present.
    func weightsDirectory(for model: MlxModel) -> URL? {
        let location = Self.location(forModelID: model.repoID, cache: self.cache)
        let configURL = location.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: configURL.path) ? location : nil
    }

    /// Read the model's context window from its local `config.json` and
    /// store it on the model, so the catalog (and the context gauge)
    /// can use it. The Hub's `?config=true` metadata does not carry
    /// `max_position_embeddings`, so this can only run once the weights
    /// — and their config file — are on disk.
    @discardableResult
    func ensureContextSize(for model: MlxModel) async -> Int? {
        if let known = model.maxContextTokens {
            return known
        }
        guard let directory = weightsDirectory(for: model) else { return nil }
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = FileManager.default.contents(atPath: configURL.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let value: Int?
        if let number = object["max_position_embeddings"] as? Int {
            value = number
        } else if let double = object["max_position_embeddings"] as? Double {
            value = Int(double)
        } else if let string = object["max_position_embeddings"] as? String, let parsed = Int(string) {
            value = parsed
        } else {
            value = nil
        }
        if let value, value > 0 {
            model.maxContextTokens = value
            try? modelContext.save()
            Self.logger.info("noted context window for \(model.repoID): \(value) tokens")
        }
        return model.maxContextTokens
    }

    /// Cancel an in-flight download. Eviction cancels the adapter's load
    /// task; the download's progress clears with it.
    func cancelDownload(_ model: MlxModel) async {
        await languageModel(for: model).evict()
    }

    // MARK: - Capability helpers

    /// The adapter's capability flags for the names stored on a model.
    static func capabilities(from raw: [String]?) -> [LanguageModelCapabilities.Capability] {
        guard let raw else { return [] }
        var capabilities: [LanguageModelCapabilities.Capability] = []
        for name in raw {
            switch name {
            case "toolCalling": capabilities.append(.toolCalling)
            case "reasoning": capabilities.append(.reasoning)
            case "vision": capabilities.append(.vision)
            case "guidedGeneration": capabilities.append(.guidedGeneration)
            default: break
            }
        }
        return capabilities
    }

    /// The capabilities to declare for a Hub model, inferred from its
    /// `config.json` signals. Deliberately conservative: the loader
    /// re-infers formats from the model itself, and an undeclared
    /// capability only withholds a feature — it never breaks a load.
    static func inferCapabilities(
        modelType: String?,
        chatTemplate: String?,
        tags: [String]?
    ) -> [String] {
        var capabilities: [String] = []
        let template = (chatTemplate ?? "").lowercased()
        if template.contains("tool_call") || template.contains("function") {
            capabilities.append("toolCalling")
        }
        if let modelType = modelType?.lowercased(),
           modelType.contains("qwen3")
                || modelType.contains("deepseek")
                || modelType.contains("qwq") {
            capabilities.append("reasoning")
        }
        if let tags, tags.contains(where: {
            let tag = $0.lowercased()
            return tag.contains("vision") || tag.contains("image")
        }) {
            capabilities.append("vision")
        }
        return capabilities
    }

    // MARK: - Config value helpers

    static func stringValue(_ value: HuggingFace.Value?) -> String? {
        if case .some(.string(let string)) = value { return string }
        return nil
    }

    private static func intValue(_ value: HuggingFace.Value?) -> Int? {
        switch value {
        case .some(.int(let int)):
            return int
        case .some(.double(let double)):
            return Int(double)
        default:
            return nil
        }
    }
}
