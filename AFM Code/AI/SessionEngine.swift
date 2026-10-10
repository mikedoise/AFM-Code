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
    private(set) var toolContext: ToolContext?

    private(set) var state: State = .idle
    /// Live token text for the in-flight assistant response.
    private(set) var streamingText: String = ""
    /// Tokens currently consumed by the session transcript.
    private(set) var contextTokenCount: Int?
    /// Output tokens of the most recent completed response.
    private(set) var lastResponseTokens: Int?

    private var languageModelSession: LanguageModelSession?
    private var sendTask: Task<Void, Never>?
    /// Whether the model session was created with the coding tools.
    private var sessionHasTools = false

    init(
        session: ChatSession,
        modelContext: ModelContext,
        catalog: ModelCatalog,
        workspaces: WorkspaceStore
    ) {
        self.session = session
        self.modelContext = modelContext
        self.catalog = catalog
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

    var contextSize: Int? { activeModel?.contextSize }

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
        let prompt = AgentInstructions.prompt(
            includesTools: !tools.isEmpty,
            project: Self.makeProjectInfo(toolContext: toolContext)
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

    // MARK: - Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

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

        if sessionHasTools {
            toolContext?.beginTurn()
        }

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
        guard let languageModelSession else { return }

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
        } catch {
            handleTurnFailure(error)
        }
        if sessionHasTools {
            toolContext?.endTurn()
        }
        streamingText = ""
        await persistTranscript()
        refreshContextUsage()
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
    private func refreshContextUsage() {
        guard let languageModelSession else { return }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let used = try await model.tokenCount(for: languageModelSession.transcript)
                self.contextTokenCount = used
                self.session.lastTokenCount = used
            } catch {
                self.contextTokenCount = nil
            }
        }
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
