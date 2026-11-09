import AppKit
import CoreAILanguageModels
import CoreAIShared
import Foundation
import FoundationModels
import Observation
import OSLog

struct CoreAIPreparationMetrics: Sendable {
    var reusedModel: Bool
    var totalSeconds: Double
    var tokenizerSeconds: Double
    var engineSeconds: Double
    var prewarmWaitSeconds: Double = 0
}

struct ImportedCoreAIModel: Identifiable, Codable, Sendable {
    var id: String
    var name: String
    var bookmark: Data
    var folderPath: String
    var mainAsset: String
    var contextSize: Int
}

/// References user-selected exports in place. Never moves, duplicates or deletes model files.
@MainActor @Observable
final class CoreAIModelManager {
    private(set) var models: [ImportedCoreAIModel] = []
    private(set) var problems: [String: String] = [:]
    private(set) var capabilities: [String: Set<String>] = [:]
    private(set) var busySession: UUID?
    private(set) var isImporting = false
    var importError: String?
    private let defaults: UserDefaults
    private let storageKey = "coreAI.importedModels.v1"
    private static let logger = Logger(subsystem: "dev.afmcode", category: "CoreAIRuntime")
    private(set) var loadedModelID: String?
    private(set) var loadingModelID: String?
    private(set) var loadErrors: [String: String] = [:]
    private(set) var preparationMetrics: CoreAIPreparationMetrics?
    private var loaded: CoreAILanguageModel?
    private var accessURL: URL?
    private var accessing = false
    private var prewarmTask: Task<Void, Never>?
    private var prewarmID: UUID?
    private var prewarmingModelID: String?
    private var prewarmingSessionID: UUID?
    private var pendingGenerationSession: UUID?
    private var requestedPrewarm: (modelID: String, sessionID: UUID)?

    func isPrewarming(for sessionID: UUID) -> Bool {
        prewarmingSessionID == sessionID && prewarmTask != nil && pendingGenerationSession == nil
    }

    func isPreparing(modelID: String) -> Bool {
        loadingModelID == modelID || (prewarmingModelID == modelID && prewarmTask != nil)
    }

    var isBusy: Bool { busySession != nil || prewarmTask != nil || pendingGenerationSession != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey) {
            models = (try? JSONDecoder().decode([ImportedCoreAIModel].self, from: data)) ?? []
        }
        refresh()
    }

    var descriptors: [ModelDescriptor] {
        models.map { model in
            ModelDescriptor(kind: .coreAI, displayName: model.name,
                detail: capabilities[model.id] == nil ? "Core AI · ready to load; runtime not yet checked" : "Core AI · local text model",
                isAvailable: problems[model.id] == nil, availabilityDetail: problems[model.id],
                contextSize: model.contextSize, capabilities: capabilities[model.id] ?? [], coreAIModelID: model.id)
        }
    }

    func descriptor(id: String?) -> ModelDescriptor? { descriptors.first { $0.coreAIModelID == id } }

    func refresh() {
        guard !isBusy else { return }
        problems = [:]
        for record in models {
            do {
                let url = try resolve(record)
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let info = try CoreAIBundleValidator.inspect(url)
                guard info.mainAsset == record.mainAsset, info.contextSize == record.contextSize else {
                    throw CoreAIImportError.invalid("This export's main model changed. Remove its library entry and add it again.")
                }
            } catch { problems[record.id] = "\(error.localizedDescription) Use Add Core AI Model to select the folder again." }
        }
    }

    private func resolve(_ record: ImportedCoreAIModel) throws -> URL {
        var stale = false
        let scoped = try? URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let url = try scoped ?? URL(resolvingBookmarkData: record.bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if let index = models.firstIndex(where: { $0.id == record.id }) {
                models[index].bookmark = data
                models[index].folderPath = url.path
                try save()
            }
        }
        return url
    }

    /// The second panel is intentional: a .aimodel grant cannot read sibling tokenizer/PLE files.
    func chooseModel() async -> String? {
        guard !isImporting, !isBusy else { return nil }
        isImporting = true
        importError = nil
        defer { isImporting = false }
        let panel = NSOpenPanel()
        panel.title = "Add Core AI Model"
        panel.message = "Choose an .aimodel package or its complete export folder. Required metadata, tokenizer and auxiliary files stay in that folder."
        panel.prompt = "Choose Model"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard await panel.begin() == .OK, let selected = panel.url else { return nil }
        var folder = selected
        let modelURL = selected.pathExtension.lowercased() == "aimodel" ? selected : nil
        if modelURL != nil {
            let accessPanel = NSOpenPanel()
            accessPanel.title = "Allow Access to Model Resources"
            accessPanel.message = "Select the containing export folder so AFM Code can read metadata.json, tokenizer and Gemma's PLE sidecar, as well as the .aimodel."
            accessPanel.prompt = "Use Export Folder"
            accessPanel.directoryURL = selected.deletingLastPathComponent()
            accessPanel.canChooseFiles = false
            accessPanel.canChooseDirectories = true
            accessPanel.allowsMultipleSelection = false
            guard await accessPanel.begin() == .OK, let chosen = accessPanel.url else { return nil }
            folder = chosen
        }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let info = try CoreAIBundleValidator.inspect(folder, selectedModel: modelURL)
            try LanguageModelBundle(at: folder).modelBundle.validateModelAssets() // Canonical Core AI format check, without loading weights.
            let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
            let previous = models
            let id = models.first(where: { $0.folderPath == path })?.id ?? UUID().uuidString
            let record = ImportedCoreAIModel(id: id, name: info.name, bookmark: bookmark, folderPath: path, mainAsset: info.mainAsset, contextSize: info.contextSize)
            models.removeAll { $0.id == id }
            models.append(record)
            do { try save() } catch { models = previous; throw error }
            problems[id] = nil
            loadErrors[id] = nil
            capabilities[id] = nil
            if loadedModelID == id { unloadIdleModel() }
            VoiceOverAnnouncer.announce("Added \(info.name). Select it in Choose Model.")
            return id
        } catch {
            importError = error.localizedDescription
            VoiceOverAnnouncer.announce("Model not added. \(error.localizedDescription)")
            return nil
        }
    }

    func remove(_ id: String) {
        guard !isBusy else { return }
        let previous = models
        models.removeAll { $0.id == id }
        do {
            try save(); problems[id] = nil; loadErrors[id] = nil; capabilities[id] = nil
            if requestedPrewarm?.modelID == id { requestedPrewarm = nil }
            if loadedModelID == id { unloadIdleModel() }
        }
        catch { models = previous; importError = error.localizedDescription }
    }

    private func save() throws { defaults.set(try JSONEncoder().encode(models), forKey: storageKey) }

    /// Nonblocking preparation for the visible conversation. Newer navigation
    /// cancels and drains older preparation before another model can load.
    func prewarm(id: String, sessionID: UUID) {
        requestedPrewarm = (id, sessionID)
        guard pendingGenerationSession == nil,
              busySession == nil || prewarmTask != nil else { return }
        if loadedModelID == id, prewarmTask == nil { return }
        if prewarmingModelID == id, prewarmingSessionID == sessionID, prewarmTask?.isCancelled == false { return }
        let previous = prewarmTask
        previous?.cancel()
        let requestID = UUID()
        prewarmID = requestID
        prewarmingModelID = id
        prewarmingSessionID = sessionID
        prewarmTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if prewarmID == requestID {
                    prewarmTask = nil
                    prewarmID = nil
                    prewarmingModelID = nil
                    prewarmingSessionID = nil
                }
            }
            guard !Task.isCancelled, pendingGenerationSession == nil else { return }
            do {
                _ = try await prepareNow(id: id, sessionID: sessionID)
                endUse(sessionID: sessionID, keepResident: !Task.isCancelled)
            } catch {
                Self.logger.info("Core AI prewarm ended without a resident model: \(error.localizedDescription)")
            }
        }
    }

    func cancelPrewarm(for sessionID: UUID) {
        if requestedPrewarm?.sessionID == sessionID { requestedPrewarm = nil }
        // An explicit send has priority and now owns this preparation.
        guard pendingGenerationSession == nil, prewarmingSessionID == sessionID else { return }
        prewarmTask?.cancel()
    }

    /// Sending joins matching preparation instead of loading a second engine.
    /// A demand claim prevents background navigation from overtaking the send.
    func prepare(id: String, sessionID: UUID) async throws -> CoreAILanguageModel {
        guard pendingGenerationSession == nil, busySession == nil || prewarmTask != nil else {
            throw CoreAIImportError.invalid("Another Core AI response is running. Stop it or wait before starting this session.")
        }
        pendingGenerationSession = sessionID
        if requestedPrewarm?.sessionID == sessionID { requestedPrewarm = (id, sessionID) }
        let demandStarted = ProcessInfo.processInfo.systemUptime
        do {
            if let preparation = prewarmTask {
                if prewarmingModelID != id { preparation.cancel() }
                await withTaskCancellationHandler {
                    await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
            }
            try Task.checkCancellation()
            let waited = ProcessInfo.processInfo.systemUptime - demandStarted
            let model = try await prepareNow(id: id, sessionID: sessionID)
            preparationMetrics?.prewarmWaitSeconds = waited
            preparationMetrics?.totalSeconds += waited
            return model
        } catch {
            pendingGenerationSession = nil
            throw error
        }
    }

    /// One live Core AI use across preparation, generation and compaction.
    private func prepareNow(id: String, sessionID: UUID) async throws -> CoreAILanguageModel {
        guard busySession == nil else {
            throw CoreAIImportError.invalid("Another Core AI response is running. Stop it or wait before starting this session.")
        }
        guard let record = models.first(where: { $0.id == id }) else {
            throw CoreAIImportError.invalid("The selected Core AI model is no longer in the library. Choose a model explicitly.")
        }
        busySession = sessionID
        loadingModelID = id
        loadErrors[id] = nil
        defer { if loadingModelID == id { loadingModelID = nil } }
        preparationMetrics = nil
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try Task.checkCancellation()
            let url = try resolve(record)
            if loadedModelID != id || accessURL != url {
                releaseResidentModel()
                accessURL = url
                accessing = url.startAccessingSecurityScopedResource()
            }
            let info = try CoreAIBundleValidator.inspect(url)
            guard info.mainAsset == record.mainAsset, info.contextSize == record.contextSize else { throw CoreAIImportError.invalid("The export changed. Add it again before loading.") }
            // A completed response leaves one engine resident. Keep its folder
            // access open too; Core AI may read resources again on the next turn.
            if loadedModelID == id, let loaded {
                preparationMetrics = CoreAIPreparationMetrics(reusedModel: true,
                    totalSeconds: ProcessInfo.processInfo.systemUptime - started,
                    tokenizerSeconds: 0, engineSeconds: 0)
                Self.logger.info("Reused resident Core AI model; no tokenizer or engine reload")
                return loaded
            }
            let tokenizerStarted = ProcessInfo.processInfo.systemUptime
            let model = try await CoreAILanguageModel(resourcesAt: url, mode: .lazy)
            let tokenizerSeconds = ProcessInfo.processInfo.systemUptime - tokenizerStarted
            loaded = model
            let engineStarted = ProcessInfo.processInfo.systemUptime
            try Task.checkCancellation()
            // Forward Stop to the adapter's shared load task, but keep the folder
            // lease until load() actually returns. System compilation may not stop instantly.
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await model.load()
            } onCancel: {
                model.unload()
            }
            try Task.checkCancellation()
            let engineSeconds = ProcessInfo.processInfo.systemUptime - engineStarted
            loadedModelID = id
            preparationMetrics = CoreAIPreparationMetrics(reusedModel: false,
                totalSeconds: ProcessInfo.processInfo.systemUptime - started,
                tokenizerSeconds: tokenizerSeconds, engineSeconds: engineSeconds)
            Self.logger.info("Prepared Core AI model: tokenizer \(tokenizerSeconds) seconds, engine load and warmup \(engineSeconds) seconds")
            capabilities[id] = Set([
                model.capabilities.contains(.toolCalling) ? "toolCalling" : nil,
                model.capabilities.contains(.reasoning) ? "reasoning" : nil,
                model.capabilities.contains(.guidedGeneration) ? "guidedGeneration" : nil
            ].compactMap { $0 })
            problems[id] = nil
            return model
        } catch {
            if !(error is CancellationError) && !Task.isCancelled { loadErrors[id] = error.localizedDescription }
            endUse(sessionID: sessionID, keepResident: false)
            throw error
        }
    }

    /// Keep one successfully used model warm. Errors/cancellation discard it;
    /// changing provider/model, removing/reimporting, or Unload also releases it.
    func finish(sessionID: UUID, keepResident: Bool) {
        endUse(sessionID: sessionID, keepResident: keepResident)
        if pendingGenerationSession == sessionID { pendingGenerationSession = nil }
        if !keepResident, requestedPrewarm?.sessionID == sessionID { requestedPrewarm = nil }
        // Honor a conversation opened during another session's generation, but
        // do not restart loading after Stop or a failure in that same session.
        if let requested = requestedPrewarm, requested.sessionID != sessionID || keepResident {
            prewarm(id: requested.modelID, sessionID: requested.sessionID)
        }
    }

    private func endUse(sessionID: UUID, keepResident: Bool) {
        guard busySession == sessionID else { return }
        if !keepResident { releaseResidentModel() }
        busySession = nil
    }

    func unloadIdleModel() {
        guard !isBusy else { return }
        requestedPrewarm = nil
        releaseResidentModel()
    }

    private func releaseResidentModel() {
        loaded?.unload()
        loaded = nil
        loadedModelID = nil
        if accessing { accessURL?.stopAccessingSecurityScopedResource() }
        accessURL = nil
        accessing = false
    }
}
