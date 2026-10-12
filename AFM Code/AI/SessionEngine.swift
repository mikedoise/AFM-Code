import Foundation
import FoundationModels
import MLXFoundationModels
import Observation
import OSLog
import SwiftData
import Tokenizers

/// Drives one chat session.
///
/// Owns the Foundation Models `LanguageModelSession`, streams responses
/// into UI state, persists the transcript for resume, and tracks
/// context usage. One engine per `ChatSession`, held by `ChatController`.
///
/// Phase 3: when the session belongs to a project, the engine also owns
/// the tool runtime (`ToolContext` + `ToolApprovalService`). The coding
/// tools ride inside the model session — the framework runs the
/// tool-call loop; the tools do the work; approvals pause it.
///
/// Phase 4: transcripts that approach the model's context window are
/// compacted — a tool-free summarization pass rewrites the older half
/// (or all of it) so long sessions don't die at the window. Turns that
/// fail on a full context are compacted and retried once.
@MainActor
@Observable
final class SessionEngine {
    enum State: Equatable, Sendable {
        case idle
        case responding
        case error(String)
    }

    private static let logger = Logger(subsystem: "dev.afmcode", category: "SessionEngine")

    let session: ChatSession
    private let modelContext: ModelContext
    private let catalog: ModelCatalog
    private let mlx: MLXModelManager
    private let settings: AppSettings
    private(set) var toolContext: ToolContext?

    /// Where this session's prompts actually go: the on-device AFM
    /// model, or the adapter for a model from the user's MLX library.
    private enum ModelSource {
        case afm
        case mlx(MlxModel)
    }

    private(set) var state: State = .idle
    /// Live token text for the in-flight assistant response.
    private(set) var streamingText: String = ""
    /// Live chain-of-thought text from the in-flight response (reasoning
    /// models); the thinking card mirrors it while the turn runs.
    private(set) var streamingReasoning: String = ""
    /// Tokens currently consumed by the session transcript.
    private(set) var contextTokenCount: Int?
    /// Output tokens of the most recent completed response.
    private(set) var lastResponseTokens: Int?
    /// The context window the model on this Mac actually accepts, as
    /// learned from a failure that reveals it. On some machines the
    /// model refuses input beyond a window smaller than its advertised
    /// `contextSize`; the smallest limit observed so far wins.
    private(set) var effectiveContextSize: Int?
    /// The MLX tokenizer for counting context, loaded once per model
    /// from the downloaded weights. `nil` until it has been loaded (or
    /// while the weights aren't on disk yet).
    private var mlxTokenizer: Tokenizers.Tokenizer?
    /// The repository id the cached tokenizer was loaded from.
    private var mlxTokenizerRepoID: String?

    private var languageModelSession: LanguageModelSession?
    private var sendTask: Task<Void, Never>?
    /// Whether the model session was created with the coding tools.
    private var sessionHasTools = false
    /// The tools the session was created with, so the session can be
    /// rebuilt after compaction without changing its behavior.
    private var sessionTools: [any Tool] = []
    /// True while a compaction pass is summarizing history (sends pause).
    private(set) var isCompacting = false

    init(
        session: ChatSession,
        modelContext: ModelContext,
        catalog: ModelCatalog,
        mlx: MLXModelManager,
        workspaces: WorkspaceStore,
        settings: AppSettings
    ) {
        self.session = session
        self.modelContext = modelContext
        self.catalog = catalog
        self.mlx = mlx
        self.settings = settings
        self.toolContext = nil
        if let project = session.project {
            let workspace = workspaces.workspace(for: project)
            let approvals = ToolApprovalService(project: project)
            self.toolContext = ToolContext(session: session, workspace: workspace, approvals: approvals)
        }
        self.contextTokenCount = session.lastTokenCount
    }

    // MARK: - Derived state

    var isBusy: Bool { state == .responding }

    var errorMessage: String? {
        if case .error(let message) = state { return message }
        return nil
    }

    /// The model this session will prompt: the session's explicit
    /// choice, then the project's default, then the best available.
    var activeModel: ModelDescriptor? {
        if let kind = session.modelKind {
            return Self.resolveModelKind(kind, mlxModelID: session.mlxModelID, catalog: catalog)
        }
        if let kind = session.project?.modelKind {
            return Self.resolveModelKind(kind, mlxModelID: session.project?.mlxModelID, catalog: catalog)
        }
        return catalog.activeDescriptor
    }

    /// The session's explicit (or inherited) choice as a descriptor:
    /// the kind always resolves; an MLX choice resolves to the specific
    /// library model, and a choice whose model left the library falls
    /// through to the best available rather than pointing at nothing.
    private static func resolveModelKind(
        _ kind: ModelDescriptor.Kind,
        mlxModelID: String?,
        catalog: ModelCatalog
    ) -> ModelDescriptor? {
        if kind == .mlx {
            if let mlxModelID, let descriptor = catalog.descriptor(for: .mlx, mlxRepoID: mlxModelID) {
                return descriptor
            }
            return catalog.activeDescriptor
        }
        return catalog.descriptor(for: kind)
    }

    /// Where this session's prompts actually go, resolved the same way
    /// as `activeModel` — the two must never disagree.
    private var modelSource: ModelSource {
        guard let descriptor = activeModel, descriptor.kind == .mlx,
              let repoID = descriptor.mlxRepoID,
              let mlxModel = mlx.model(forRepoID: repoID)
        else {
            return .afm
        }
        return .mlx(mlxModel)
    }

    /// The session's real context window: a runtime limit observed
    /// from a failure, else the model's advertised size.
    var contextSize: Int? {
        effectiveContextSize ?? activeModel?.contextSize
    }

    /// Live tool activity for the in-flight turn (drives the UI).
    var toolSteps: [ToolStep] { toolContext?.steps ?? [] }

    var approvals: ToolApprovalService? { toolContext?.approvals }

    // MARK: - Session lifecycle

    /// Lazily create the underlying `LanguageModelSession` on the
    /// session's model, resuming from the persisted transcript when
    /// one exists.
    private func ensureLanguageModelSession() {
        guard languageModelSession == nil else { return }
        switch modelSource {
        case .afm:
            let model = SystemLanguageModel.default
            // Tools only when the model variant supports them and
            // this session has a project folder to work in.
            let supportsTools = model.isAvailable && model.capabilities.contains(.toolCalling)
            configureSession(model: model, supportsTools: supportsTools)
        case .mlx(let mlxModel):
            let model = mlx.languageModel(for: mlxModel)
            // The adapter declares the stored capability names; the
            // MLX model must be downloaded (or downloading) for the
            // adapter to serve a turn.
            let supportsTools = model.capabilities.contains(.toolCalling)
            configureSession(model: model, supportsTools: supportsTools)
            if mlxModel.maxContextTokens == nil {
                // Backfill the context window from the model's local
                // config.json, then let the catalog learn it.
                Task { [weak self] in
                    await self?.mlx.ensureContextSize(for: mlxModel)
                    await self?.catalog.refreshMlxModels()
                }
            }
        }
    }

    /// Shared session construction for both model sources: resolve the
    /// tools the session runs with, refresh the instructions entry so
    /// the model always sees the current prompt, project context, and
    /// tool definitions, and build the session — resuming the saved
    /// transcript when one exists.
    private func configureSession<M: LanguageModel>(model: M, supportsTools: Bool) {
        let tools = (supportsTools && toolContext != nil)
            ? CodingTools(context: toolContext!).tools
            : []
        sessionHasTools = !tools.isEmpty
        sessionTools = tools
        let prompt = AgentInstructions.prompt(
            includesTools: !tools.isEmpty,
            project: Self.makeProjectInfo(toolContext: toolContext),
            basePrompt: settings.systemPrompt,
            contextSize: contextSize
        )

        if let data = session.transcriptData,
           var transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            // Refresh the instructions entry so the model always sees
            // the current prompt, project context, and tool definitions.
            let instructionsEntry = Self.makeInstructionsEntry(prompt: prompt, tools: tools)
            if let first = transcript.first, case .instructions = first {
                transcript[0] = instructionsEntry
            } else {
                transcript.insert(instructionsEntry, at: transcript.startIndex)
            }
            languageModelSession = LanguageModelSession(
                model: model,
                tools: tools,
                transcript: transcript
            )
        } else {
            languageModelSession = LanguageModelSession(
                model: model,
                tools: tools,
                instructions: Instructions(prompt)
            )
        }
        languageModelSession?.transcriptErrorHandlingPolicy = .revertTranscript
        prewarm()

        // Measure the baseline (system prompt, instructions, restored
        // transcript) so the context gauge shows the session's starting
        // usage instead of waiting for the first turn to complete.
        Task { [weak self] in
            await self?.refreshContextUsage()
        }
    }

    /// What the model should know about the project it's working in:
    /// name, folder path, current structure, and a README excerpt.
    /// Best-effort — each piece is skipped if it can't be read.
    private static func makeProjectInfo(toolContext: ToolContext?) -> AgentInstructions.ProjectInfo? {
        guard let toolContext else { return nil }
        let project = toolContext.session.project
        var info = AgentInstructions.ProjectInfo(
            name: project?.name ?? "Untitled Project",
            rootPath: toolContext.rootURL?.path ?? project?.folderName ?? "",
            structure: nil,
            readme: nil
        )
        info.isGitRepository = toolContext.fileExists(".git")
        info.structure = try? toolContext.listDirectory(path: ".", maxDepth: 2)
        for candidate in ["README.md", "README", "README.rst", "readme.md", "README.txt"] {
            if let text = try? toolContext.readFileContent(path: candidate, maxLines: 60) {
                info.readme = text
                break
            }
        }
        return info
    }

    /// Rebuild the instructions transcript entry with the current
    /// prompt and tool definitions.
    private static func makeInstructionsEntry(prompt: String, tools: [any Tool]) -> Transcript.Entry {
        let text = Transcript.TextSegment(content: prompt)
        let definitions = tools.map { Transcript.ToolDefinition(tool: $0) }
        let instructions = Transcript.Instructions(
            id: UUID().uuidString,
            segments: [Transcript.Segment.text(text)],
            toolDefinitions: definitions
        )
        return Transcript.Entry.instructions(instructions)
    }

    /// Ask the framework to load and cache the session ahead of a turn.
    func prewarm() {
        languageModelSession?.prewarm()
    }

    /// Prewarm with the user's draft so the first token of the next
    /// turn arrives faster. Best-effort: the draft is treated as a
    /// prefix of the prompt that will actually be sent.
    func prewarm(draft: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            prewarm()
            return
        }
        languageModelSession?.prewarm(promptPrefix: Prompt(trimmed))
    }

    // MARK: - Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Also while a compaction pass is rebuilding the session — a
        // send mid-rebuild would race the rebuild.
        guard !trimmed.isEmpty, !isBusy, !isCompacting else { return }

        let selectedModel = activeModel
        guard let selectedModel, selectedModel.isAvailable else {
            state = .error(selectedModel?.availabilityDetail ?? "No model is available on this Mac.")
            return
        }

        persistUserMessage(trimmed)
        ensureLanguageModelSession()
        guard languageModelSession != nil else {
            state = .error("Could not start the model session.")
            return
        }

        // Set synchronously so a rapid double-send can't start a second
        // turn; `attemptTurn` re-establishes both on the compaction
        // retry.
        state = .responding
        streamingText = ""
        sendTask = Task { [weak self] in
            await self?.runTurn(prompt: trimmed)
        }
    }

    func cancel() {
        sendTask?.cancel()
    }

    private func runTurn(prompt: String) async {
        guard languageModelSession != nil else { return }

        // Measure against the model's real window before sending, so a
        // transcript that grew since the last turn compacts *before*
        // it overflows, not only after a turn dies on the wall.
        await refreshContextUsage()
        await maybeCompact()

        var attempt = 0
        while true {
            attempt += 1
            let needsCompaction = await attemptTurn(prompt: prompt)
            // The turn died because the transcript is unusable (a
            // full window, or content the model can't read). Compress
            // aggressively, then re-run the same prompt against the
            // rebuilt session — exactly once.
            guard needsCompaction, attempt == 1 else { break }
            guard await compactHistory(keepRecentTurn: false) else { break }
        }

        // A failure whose recovery never ran (nothing left to compact,
        // or the retry also hit the wall) ends the turn still flagged
        // as responding — settle it so the composer isn't stuck busy.
        if state == .responding {
            persistPartialAssistantMessage()
            state = .error(
                "This session's context is full and it couldn't be compressed to fit. "
                + "Start a new session to keep going — the transcript above is preserved."
            )
        }

        if sessionHasTools {
            toolContext?.endTurn()
        }
        streamingText = ""
        streamingReasoning = ""
        // Compact before persisting, so the saved transcript matches
        // what the session actually continues from. Not after a
        // cancellation — the user asked for it to stop.
        if !Task.isCancelled {
            await maybeCompact()
        }
        await persistTranscript()
        await refreshContextUsage()
    }

    /// Runs one model response for `prompt` and reports whether it
    /// failed with a context-size error that a compaction pass could
    /// fix (the caller may then compact and retry).
    private func attemptTurn(prompt: String) async -> Bool {
        guard let languageModelSession else { return false }
        if sessionHasTools {
            toolContext?.beginTurn()
        }
        state = .responding
        streamingText = ""
        streamingReasoning = ""

        var options = GenerationOptions()
        if sessionHasTools {
            options.toolCallingMode = .allowed
        }

        do {
            let stream = languageModelSession.streamResponse(to: Prompt(prompt), options: options)
            for try await snapshot in stream {
                streamingText = snapshot.content
                updateStreamingReasoning(from: snapshot.transcriptEntries)
            }
            let response = try await stream.collect()
            finalizeAssistantResponse(response)
            state = .idle
            return false
        } catch {
            // Two transcript failures we can recover from in place:
            // a full context window, and saved content the current
            // model can't read. Both are fixed the same way — rebuild
            // the transcript (the compactor renders the entries as
            // plain text, so a rebuilt session sidesteps the problem).
            if let modelError = error as? LanguageModelError {
                switch modelError {
                case .contextSizeExceeded(let payload):
                    recordRuntimeWindow(payload.contextSize)
                    Self.logger.info("turn failed: \(modelError); rebuilding the transcript")
                    return true
                case .unsupportedTranscriptContent:
                    Self.logger.info("turn failed: \(modelError); rebuilding the transcript")
                    return true
                default:
                    break
                }
            }
            // The 27 SDK surfaces some window overflows as plain
            // inference failures rather than a typed
            // contextSizeExceeded error — e.g. "Provided 9,610 tokens,
            // but the maximum allowed is 8,192." Detect that shape, note
            // the real window, and recover the same way.
            if let window = Self.contextWindow(from: error) {
                recordRuntimeWindow(window)
                Self.logger.info("turn failed (\(error.localizedDescription)); rebuilding the transcript")
                return true
            }
            handleTurnFailure(error)
            return false
        }
    }

    private func handleTurnFailure(_ error: any Error) {
        let wasCancelled: Bool
        if error is CancellationError {
            wasCancelled = true
        } else if let toolError = error as? LanguageModelSession.ToolCallError {
            // A tool only throws for cancellation in this app.
            wasCancelled = toolError.underlyingError is CancellationError
        } else {
            wasCancelled = false
        }

        if wasCancelled {
            Self.logger.info("turn cancelled")
            persistPartialAssistantMessage()
            state = .idle
        } else if let modelError = error as? LanguageModelError {
            Self.logger.error("turn failed: \(modelError)")
            persistPartialAssistantMessage()
            state = .error(Self.describe(modelError))
        } else {
            Self.logger.error("turn failed: \(error.localizedDescription)")
            persistPartialAssistantMessage()
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Persistence

    /// Link a message to this session on *both* sides of the
    /// relationship and register it. The optional-append form
    /// (`session.messages?.append`) silently no-ops when the
    /// relationship hasn't materialized — we can't afford that.
    private func attach(_ message: Message) {
        modelContext.insert(message)
        message.session = session
        var messages = session.messages ?? []
        if !messages.contains(message) {
            messages.append(message)
        }
        session.messages = messages
        session.lastMessageAt = Date()
    }

    /// Mirror the current turn's reasoning text: the session transcript
    /// accumulates a `Transcript.Reasoning` entry as the model thinks, so
    /// reading it is how the UI gets the chain of thought live.
    private func updateStreamingReasoning(from entries: some Collection<Transcript.Entry>) {
        for entry in entries.reversed() {
            if case .reasoning(let reasoning) = entry {
                streamingReasoning = Self.segmentText(reasoning.segments, cap: nil)
                return
            }
        }
        streamingReasoning = ""
    }

    /// The reasoning text to persist with the assistant message: the
    /// transcript's entry when present, else whatever the stream mirror
    /// holds (covers the roll-back paths, where the transcript no longer
    /// has the current turn).
    private var currentThinkingContent: String? {
        var fromTranscript: String?
        if let transcript = languageModelSession?.transcript {
            for entry in transcript.reversed() {
                if case .reasoning(let reasoning) = entry {
                    fromTranscript = Self.segmentText(reasoning.segments, cap: nil)
                    break
                }
            }
        }
        let text = (fromTranscript ?? streamingReasoning)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func persistUserMessage(_ text: String) {
        let message = Message(role: .user, content: text)
        attach(message)
        session.setInitialTitle(from: text)
        try? modelContext.save()
    }

    private func finalizeAssistantResponse(_ response: LanguageModelSession.Response<String>) {
        let text = response.content
        let steps = toolContext?.turnSteps ?? []
        guard !text.isEmpty || !steps.isEmpty else { return }
        let message = Message(role: .assistant, content: text)
        message.tokenCount = response.usage.totalTokenCount
        lastResponseTokens = response.usage.totalTokenCount
        message.toolActivity = steps.isEmpty ? nil : steps
        message.thinkingContent = currentThinkingContent
        message.modelID = activeModel?.id
        attach(message)
    }

    /// Keep whatever partial text and tool activity the user saw before
    /// an interruption, so the transcript reads the same on resume.
    private func persistPartialAssistantMessage() {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = toolContext?.turnSteps ?? []
        guard !text.isEmpty || !steps.isEmpty else { return }
        let message = Message(role: .assistant, content: text)
        message.toolActivity = steps.isEmpty ? nil : steps
        message.thinkingContent = currentThinkingContent
        message.modelID = activeModel?.id
        attach(message)
    }

    /// Re-encode the framework transcript (which now includes the new
    /// turn, or was rolled back after an error) for future resume.
    private func persistTranscript() async {
        guard let languageModelSession else { return }
        do {
            session.transcriptData = try JSONEncoder().encode(languageModelSession.transcript)
        } catch {
            Self.logger.error("transcript encode failed: \(error)")
        }
        try? modelContext.save()
    }

    // MARK: - Context budgeting

    /// Measure the transcript against the model's context window, the
    /// way that model counts: the framework's own count for the
    /// on-device model, its own tokenizer for MLX models.
    private func refreshContextUsage() async {
        guard let languageModelSession else { return }
        let used: Int?
        switch modelSource {
        case .afm:
            let model = SystemLanguageModel.default
            guard model.isAvailable else { return }
            do {
                used = try await model.tokenCount(for: languageModelSession.transcript)
            } catch {
                used = nil
            }
        case .mlx(let mlxModel):
            guard let tokenizer = await mlxTokenizer(for: mlxModel) else {
                // The gauge hides rather than misreports: without the
                // weights on disk there's no tokenizer to count with.
                contextTokenCount = nil
                return
            }
            let text = Self.renderTranscriptText(languageModelSession.transcript)
            used = tokenizer.encode(text: text).count
        }
        contextTokenCount = used
        if let used {
            session.lastTokenCount = used
        }
    }

    /// Count tokens the way the session's model sees them: the
    /// framework's own count for the on-device model, and the model's
    /// own tokenizer for MLX models. `nil` when the count can't be
    /// made (weights not downloaded yet, …).
    private func tokenCount(for entries: [Transcript.Entry]) async -> Int? {
        switch modelSource {
        case .afm:
            let model = SystemLanguageModel.default
            guard model.isAvailable else { return nil }
            return try? await model.tokenCount(for: entries)
        case .mlx(let mlxModel):
            guard let tokenizer = await mlxTokenizer(for: mlxModel) else { return nil }
            let text = Self.renderTranscriptText(entries)
            return tokenizer.encode(text: text).count
        }
    }

    /// The tokenizer for an MLX model, loaded from its downloaded
    /// weights and cached for the engine's lifetime. Local-only: the
    /// load reads the snapshot directory and never touches the network;
    /// a model without the downloaded tokenizer files simply yields
    /// `nil` and the context gauge hides itself.
    private func mlxTokenizer(for model: MlxModel) async -> Tokenizers.Tokenizer? {
        if let tokenizer = mlxTokenizer, mlxTokenizerRepoID == model.repoID {
            return tokenizer
        }
        guard let directory = mlx.weightsDirectory(for: model) else { return nil }
        do {
            let tokenizer = try await AutoTokenizer.from(modelFolder: directory, strict: false)
            mlxTokenizer = tokenizer
            mlxTokenizerRepoID = model.repoID
            return tokenizer
        } catch {
            Self.logger.info("tokenizer load failed for \(model.repoID): \(error.localizedDescription)")
            return nil
        }
    }

    /// After a turn, keep the transcript well inside the model's
    /// window: at 80% of context, summarize the older half, and if
    /// that still leaves it above 90%, compress everything.
    private func maybeCompact() async {
        guard !isCompacting else { return }
        let size = effectiveContextSize ?? activeModel?.contextSize
        guard let size, size > 0 else { return }

        var used = contextTokenCount
        if used == nil {
            await refreshContextUsage()
            used = contextTokenCount
        }
        guard let used, used >= size * 4 / 5 else { return }

        guard await compactHistory(keepRecentTurn: true) else { return }
        await refreshContextUsage()

        if let used = contextTokenCount, used >= size * 9 / 10 {
            await compactHistory(keepRecentTurn: false)
            await refreshContextUsage()
        }
    }

    /// Summarize the transcript's older half with a fresh tool-free
    /// session and rebuild the model session around the summary. Keeps
    /// the most recent turn verbatim when `keepRecentTurn` is set.
    /// Returns true when the session was rebuilt.
    @discardableResult
    private func compactHistory(keepRecentTurn: Bool) async -> Bool {
        guard let modelSession = languageModelSession, !modelSession.isResponding, !isCompacting else {
            return false
        }

        isCompacting = true
        defer { isCompacting = false }

        let entries = Array(modelSession.transcript)
        guard entries.count > 3 else { return false }

        // Where the summarizable history ends and the kept tail begins:
        // before the most recent user prompt, or never (compress all).
        let splitIndex: Int
        if keepRecentTurn,
           let promptIndex = entries.lastIndex(where: { if case .prompt = $0 { return true }; return false }) {
            splitIndex = promptIndex
        } else {
            splitIndex = entries.count
        }
        let oldEntries = Array(entries[entries.startIndex..<splitIndex])
        guard !oldEntries.isEmpty else { return false }

        // Not enough history to be worth a summarization round trip.
        guard let oldTokens = await tokenCount(for: oldEntries),
              oldTokens >= 1024 else {
            return false
        }

        // A disposable, tool-free session on the session's own model
        // does the summarizing; it never touches the live transcript.
        switch modelSource {
        case .afm:
            return await summarize(
                model: SystemLanguageModel.default,
                entries: entries,
                oldEntries: oldEntries,
                splitIndex: splitIndex
            )
        case .mlx(let mlxModel):
            return await summarize(
                model: mlx.languageModel(for: mlxModel),
                entries: entries,
                oldEntries: oldEntries,
                splitIndex: splitIndex
            )
        }
    }

    /// Summarize `oldEntries` with a disposable, tool-free session on
    /// `model`, then rebuild the live session around the summary. Both
    /// model sources share this: the framework drives the loop the same
    /// way for any `LanguageModel`.
    private func summarize<M: LanguageModel>(
        model: M,
        entries: [Transcript.Entry],
        oldEntries: [Transcript.Entry],
        splitIndex: Int
    ) async -> Bool {
        let instructions = Instructions(Self.compactorInstructions)
        let summarizer = LanguageModelSession(model: model, tools: [], instructions: instructions)
        var options = GenerationOptions()
        options.maximumResponseTokens = 1200

        do {
            let stream = summarizer.streamResponse(
                to: Prompt(Self.renderConversation(oldEntries)),
                options: options
            )
            let response = try await stream.collect()
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return false }
            rebuildSession(entries: entries, from: splitIndex, summary: summary, model: model)
            Self.logger.info("compacted \(entries.count) transcript entries into a summary")
            return true
        } catch {
            Self.logger.error("compaction failed; keeping the full transcript: \(error.localizedDescription)")
            return false
        }
    }

    /// Replace the model session with one whose transcript is
    /// [fresh instructions, compressed summary, kept tail], so the
    /// agent continues from the summary but still sees the current
    /// project context and its most recent turn verbatim.
    private func rebuildSession<M: LanguageModel>(
        entries: [Transcript.Entry],
        from splitIndex: Int,
        summary: String,
        model: M
    ) {
        let prompt = AgentInstructions.prompt(
            includesTools: sessionHasTools,
            project: Self.makeProjectInfo(toolContext: toolContext),
            basePrompt: settings.systemPrompt,
            contextSize: contextSize
        )
        var newEntries: [Transcript.Entry] = [
            Self.makeInstructionsEntry(prompt: prompt, tools: sessionHasTools ? sessionTools : [])
        ]
        let summaryEntry = Transcript.Response(
            assetIDs: [],
            segments: [
                Transcript.Segment.text(
                    Transcript.TextSegment(content: "Earlier conversation (compressed):\n\(summary)")
                )
            ]
        )
        newEntries.append(.response(summaryEntry))
        if splitIndex < entries.count {
            newEntries.append(contentsOf: entries[splitIndex...])
        }

        var transcript = Transcript()
        transcript.append(contentsOf: newEntries)

        let newSession = LanguageModelSession(
            model: model,
            tools: sessionHasTools ? sessionTools : [],
            transcript: transcript
        )
        newSession.transcriptErrorHandlingPolicy = .revertTranscript
        languageModelSession = newSession
        newSession.prewarm()
    }

    /// The summarizer's system prompt: a "memory compressor".
    static let compactorInstructions = """
    You are a memory compressor for a coding-agent conversation.
    Rewrite the earlier conversation below as a compact, self-contained summary that the agent can continue from without seeing the original messages.

    Preserve, in order of the original conversation:
    1. Every user request, with specifics (file paths, names, commands, constraints).
    2. Every file created, modified, or deleted, with its path and what changed.
    3. Every command run, with its outcome (success, key errors, key output).
    4. Approval decisions: which changes or commands the user approved, always-allowed, or denied.
    5. Current state: what is done, what is in progress, what is blocked, and the next step.
    6. User preferences or corrections the agent should keep honoring.

    Rules:
    - Plain prose and bullet points; no file contents, no command output dumps.
    - Under 600 words.
    - Output only the summary.
    """

    // MARK: - Runtime window

    /// The input window a failing turn reveals, when the failure message
    /// carries one. The 27 SDK reports some overflows as plain inference
    /// failures, but the message still names the maximum the model accepts
    /// ("Provided … tokens, but the maximum allowed is N").
    private static func contextWindow(from error: any Error) -> Int? {
        let description = (error as? LanguageModelError)?.localizedDescription
            ?? error.localizedDescription
        guard description.range(of: "provided", options: .caseInsensitive) != nil,
              let range = description.range(of: "maximum allowed is ") else {
            return nil
        }
        var digits = ""
        for character in description[range.upperBound...] {
            if character.isNumber {
                digits.append(character)
            } else if character == "," {
                continue // thousands separator
            } else {
                break
            }
        }
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// Remember the real input window when a failure reveals one. The
    /// advertised `contextSize` is per variant; the model this Mac is
    /// served may accept less. The smallest limit wins, so compaction and
    /// the context gauge stay under what actually works.
    private func recordRuntimeWindow(_ window: Int) {
        guard window > 0 else { return }
        if let current = effectiveContextSize, current <= window { return }
        let advertised = activeModel?.contextSize ?? 0
        effectiveContextSize = window
        Self.logger.info("noted runtime context window: \(window) tokens (advertised \(advertised))")
        if case .mlx(let mlxModel) = modelSource,
           let stored = mlxModel.maxContextTokens, window < stored {
            // Persist the correction — only ever downward — so the next
            // session, the picker badge, and compaction all start from
            // the window that actually works rather than the advertised
            // ceiling the runtime refuses to honor.
            mlxModel.maxContextTokens = window
            try? modelContext.save()
            Self.logger.info("persisted observed window \(window) for \(mlxModel.repoID) (was \(stored))")
            Task { await catalog.refreshMlxModels() }
        }
    }

    // MARK: - Transcript rendering (for the compactor)

    /// Render transcript entries for the compactor, newest first, under
    /// a total character budget so the summary request stays small.
    private static func renderConversation(_ entries: [Transcript.Entry]) -> String {
        var rendered = ""
        var budget = 16_000
        for entry in entries.reversed() {
            guard let piece = renderEntry(entry) else { continue }
            let capped = String(piece.prefix(budget))
            rendered = capped + "\n\n" + rendered
            budget -= capped.count
            guard budget > 0 else { break }
        }
        return rendered
    }

    /// One transcript entry as plain text. Bounded mode (the default)
    /// caps pieces so the compactor's summary request stays small;
    /// unbounded mode renders everything, because the tokenizer counts
    /// what the model actually has to read.
    private static func renderEntry(_ entry: Transcript.Entry, unbounded: Bool = false) -> String? {
        let cap: Int? = unbounded ? nil : 2_000
        switch entry {
        case .instructions(let instructions):
            // Bounded mode skips the instructions entry (it's stable
            // and rebuilt on resume and on compaction, so it doesn't
            // need summarizing); unbounded counting includes it, since
            // the model reads it every turn.
            guard unbounded else { return nil }
            var text = "SYSTEM: " + Self.segmentText(instructions.segments, cap: nil)
            let definitions = instructions.toolDefinitions
                .map { "\($0.name): \($0.description)" }
                .joined(separator: "\n")
            if !definitions.isEmpty {
                text += "\nTOOLS: \(definitions)"
            }
            return text
        case .prompt(let prompt):
            return "USER: \(Self.segmentText(prompt.segments, cap: cap))"
        case .response(let response):
            return "ASSISTANT: \(Self.segmentText(response.segments, cap: cap))"
        case .reasoning(let reasoning):
            let text = Self.segmentText(reasoning.segments, cap: cap)
            return text.isEmpty ? nil : "AGENT THINKING: \(text)"
        case .toolCalls(let calls):
            let items = calls.map { call in
                "\(call.toolName)(\(Self.summarizeArguments(call.arguments.jsonString, unbounded: unbounded)))"
            }
            guard !items.isEmpty else { return nil }
            let text = "TOOL CALLS: " + items.joined(separator: "\n")
            return unbounded ? text : String(text.prefix(2_000))
        case .toolOutput(let output):
            let outputCap: Int? = unbounded ? nil : 1_200
            return "TOOL RESULT (\(output.toolName)): \(Self.segmentText(output.segments, cap: outputCap))"
        @unknown default:
            return nil
        }
    }

    /// The transcript's entries as plain text without any of the
    /// compactor's size caps — for token counting, not summarizing.
    private static func renderTranscriptText(_ entries: some Collection<Transcript.Entry>) -> String {
        var pieces: [String] = []
        for entry in entries {
            if let piece = renderEntry(entry, unbounded: true) {
                pieces.append(piece)
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Flatten a segment list to text. `cap` bounds the result; `nil`
    /// means no bound (token counting needs the full text).
    private static func segmentText(_ segments: [Transcript.Segment], cap: Int? = 2_000) -> String {
        var text = ""
        for segment in segments {
            switch segment {
            case .text(let textSegment):
                text += textSegment.content
            case .structure(let structured):
                text += structured.content.jsonString
            case .attachment(let attachment):
                text += attachment.label ?? "[attachment]"
            @unknown default:
                break
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let cap, trimmed.count > cap else { return trimmed }
        return String(trimmed.prefix(cap)) + " …(truncated)"
    }

    /// Tool-call arguments as JSON, with long string values trimmed so
    /// file contents can't drown the summary while paths stay visible.
    /// Unbounded mode returns the stored arguments as-is: token
    /// counting wants the true size, not a preview.
    private static func summarizeArguments(_ jsonString: String, unbounded: Bool = false) -> String {
        guard !unbounded else { return jsonString }
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(jsonString.prefix(400))
        }
        func render(_ value: Any, depth: Int) -> String {
            guard depth <= 2 else { return "…" }
            switch value {
            case let string as String:
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 200 {
                    return "\(String(trimmed.prefix(120)))…(truncated, \(trimmed.count) chars)"
                }
                return string
            case let dictionary as [String: Any]:
                let pairs = dictionary.sorted { $0.key < $1.key }.map { key, value in
                    "\"\(key)\": \(render(value, depth: depth + 1))"
                }
                return "{" + pairs.joined(separator: ", ") + "}"
            case let array as [Any]:
                let items = array.prefix(5).map { render($0, depth: depth + 1) }
                return "[" + items.joined(separator: ", ") + (array.count > 5 ? ", …" : "") + "]"
            case let number as NSNumber:
                return number.stringValue
            case is NSNull:
                return "null"
            default:
                return "\(value)"
            }
        }
        return String(render(object, depth: 0).prefix(1_500))
    }

    // MARK: - Error description

    private static func describe(_ error: LanguageModelError) -> String {
        switch error {
        case .contextSizeExceeded(_):
            return "This session has grown past the model's context window. Start a new session to keep going — the transcript here is preserved for reference."
        case .rateLimited(_):
            return "The model is rate limited right now. Try again in a little while."
        case .refusal(_):
            return "The model declined to answer that prompt."
        case .timeout(_):
            return "The model timed out before finishing. Try again."
        case .guardrailViolation(_):
            return "The response was blocked by Apple's safety guardrails."
        case .unsupportedCapability(_):
            return "The selected model doesn't support that capability on this machine."
        case .unsupportedTranscriptContent(_):
            return "The saved session history contains content the current model can't read. Start a new session."
        case .unsupportedGenerationGuide(_):
            return "The current model doesn't support this kind of guided generation."
        case .unsupportedLanguageOrLocale(_):
            return "The current model doesn't support this language or region."
        @unknown default:
            return error.localizedDescription
        }
    }
}
