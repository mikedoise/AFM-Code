import Foundation
import FoundationModels
import Observation
import OSLog
import SwiftData

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
    private let settings: AppSettings
    private(set) var toolContext: ToolContext?

    private(set) var state: State = .idle
    /// Live token text for the in-flight assistant response.
    private(set) var streamingText: String = ""
    /// Tokens currently consumed by the session transcript.
    private(set) var contextTokenCount: Int?
    /// Output tokens of the most recent completed response.
    private(set) var lastResponseTokens: Int?
    /// The context window the model on this Mac actually accepts, as
    /// learned from a failure that reveals it. On some machines the
    /// model refuses input beyond a window smaller than its advertised
    /// `contextSize`; the smallest limit observed so far wins.
    private(set) var effectiveContextSize: Int?

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
        workspaces: WorkspaceStore,
        settings: AppSettings
    ) {
        self.session = session
        self.modelContext = modelContext
        self.catalog = catalog
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
            return catalog.descriptor(for: kind)
        }
        if let kind = session.project?.modelKind {
            return catalog.descriptor(for: kind)
        }
        return catalog.activeDescriptor
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

    /// Lazily create the underlying `LanguageModelSession`, resuming
    /// from the persisted transcript when one exists.
    private func ensureLanguageModelSession() {
        guard languageModelSession == nil else { return }
        let model = SystemLanguageModel.default

        // Tools only when the model variant supports them and this
        // session has a project folder to work in.
        let supportsTools = model.isAvailable && model.capabilities.contains(.toolCalling)
        let tools = (supportsTools && toolContext != nil)
            ? CodingTools(context: toolContext!).tools
            : []
        sessionHasTools = !tools.isEmpty
        sessionTools = tools
        let prompt = AgentInstructions.prompt(
            includesTools: !tools.isEmpty,
            project: Self.makeProjectInfo(toolContext: toolContext),
            basePrompt: settings.systemPrompt,
            contextSize: effectiveContextSize ?? (model.isAvailable ? model.contextSize : nil)
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
            languageModelSession = LanguageModelSession(model: model, tools: tools) {
                prompt
            }
        }
        languageModelSession?.transcriptErrorHandlingPolicy = .revertTranscript
        prewarm()
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

        var options = GenerationOptions()
        if sessionHasTools {
            options.toolCallingMode = .allowed
        }

        do {
            let stream = languageModelSession.streamResponse(to: Prompt(prompt), options: options)
            for try await snapshot in stream {
                streamingText = snapshot.content
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

    /// Measure the transcript against the model's context window.
    private func refreshContextUsage() async {
        guard let languageModelSession else { return }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        do {
            let used = try await model.tokenCount(for: languageModelSession.transcript)
            contextTokenCount = used
            session.lastTokenCount = used
        } catch {
            contextTokenCount = nil
        }
    }

    /// After a turn, keep the transcript well inside the model's
    /// window: at 80% of context, summarize the older half, and if
    /// that still leaves it above 90%, compress everything.
    private func maybeCompact() async {
        guard !isCompacting else { return }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        let size = effectiveContextSize ?? model.contextSize
        guard size > 0 else { return }

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
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return false }

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
        guard let oldTokens = try? await model.tokenCount(for: oldEntries),
              oldTokens >= 1024 else {
            return false
        }

        // A disposable, tool-free session on the same model does the
        // summarizing; it never touches the live transcript.
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
    private func rebuildSession(
        entries: [Transcript.Entry],
        from splitIndex: Int,
        summary: String,
        model: SystemLanguageModel
    ) {
        let prompt = AgentInstructions.prompt(
            includesTools: sessionHasTools,
            project: Self.makeProjectInfo(toolContext: toolContext),
            basePrompt: settings.systemPrompt,
            contextSize: effectiveContextSize ?? (model.isAvailable ? model.contextSize : nil)
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

    /// One transcript entry as plain text the summarizer can read.
    private static func renderEntry(_ entry: Transcript.Entry) -> String? {
        switch entry {
        case .instructions:
            // Stable content; rebuilt on resume and on compaction.
            return nil
        case .prompt(let prompt):
            return "USER: \(Self.segmentText(prompt.segments))"
        case .response(let response):
            return "ASSISTANT: \(Self.segmentText(response.segments))"
        case .reasoning(let reasoning):
            let text = Self.segmentText(reasoning.segments)
            return text.isEmpty ? nil : "AGENT THINKING: \(text)"
        case .toolCalls(let calls):
            let items = calls.map { call in
                "\(call.toolName)(\(Self.summarizeArguments(call.arguments.jsonString)))"
            }
            guard !items.isEmpty else { return nil }
            return String(("TOOL CALLS: " + items.joined(separator: "\n")).prefix(2_000))
        case .toolOutput(let output):
            return "TOOL RESULT (\(output.toolName)): \(Self.segmentText(output.segments, cap: 1_200))"
        @unknown default:
            return nil
        }
    }

    /// Flatten a segment list to text, capped.
    private static func segmentText(_ segments: [Transcript.Segment], cap: Int = 2_000) -> String {
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
        guard trimmed.count > cap else { return trimmed }
        return String(trimmed.prefix(cap)) + " …(truncated)"
    }

    /// Tool-call arguments as JSON, with long string values trimmed so
    /// file contents can't drown the summary while paths stay visible.
    private static func summarizeArguments(_ jsonString: String) -> String {
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
