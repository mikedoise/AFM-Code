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
/// The engine is the presentation-facing half of the AI layer:
/// `ModelCatalog` reports what models exist, the engine uses one.
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

    private(set) var state: State = .idle
    /// Live token text for the in-flight assistant response.
    private(set) var streamingText: String = ""
    /// Tokens currently consumed by the session transcript.
    private(set) var contextTokenCount: Int?
    /// Output tokens of the most recent completed response.
    private(set) var lastResponseTokens: Int?

    private var languageModelSession: LanguageModelSession?
    private var sendTask: Task<Void, Never>?

    init(session: ChatSession, modelContext: ModelContext, catalog: ModelCatalog) {
        self.session = session
        self.modelContext = modelContext
        self.catalog = catalog
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

    // MARK: - Session lifecycle

    /// Lazily create the underlying `LanguageModelSession`, resuming
    /// from the persisted transcript when one exists.
    private func ensureLanguageModelSession() {
        guard languageModelSession == nil else { return }
        let model = SystemLanguageModel.default

        if let data = session.transcriptData,
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            languageModelSession = LanguageModelSession(
                model: model,
                tools: [],
                transcript: transcript
            )
        } else {
            languageModelSession = LanguageModelSession(model: model) {
                AgentInstructions.defaultSystemPrompt
            }
        }
        languageModelSession?.transcriptErrorHandlingPolicy = .revertTranscript
        prewarm()
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
        do {
            let stream = languageModelSession.streamResponse(to: Prompt(prompt))
            for try await snapshot in stream {
                streamingText = snapshot.content
            }
            let response = try await stream.collect()
            finalizeAssistantResponse(response)
            state = .idle
        } catch is CancellationError {
            Self.logger.info("turn cancelled")
            persistPartialAssistantMessage()
            state = .idle
        } catch let error as LanguageModelError {
            Self.logger.error("turn failed: \(error)")
            persistPartialAssistantMessage()
            state = .error(Self.describe(error))
        } catch {
            Self.logger.error("turn failed: \(error.localizedDescription)")
            persistPartialAssistantMessage()
            state = .error(error.localizedDescription)
        }
        streamingText = ""
        await persistTranscript()
        refreshContextUsage()
    }

    // MARK: - Persistence

    private func persistUserMessage(_ text: String) {
        let message = Message(role: .user, content: text)
        modelContext.insert(message)
        session.messages?.append(message)
        session.lastMessageAt = Date()
        session.setInitialTitle(from: text)
        try? modelContext.save()
    }

    private func finalizeAssistantResponse(_ response: LanguageModelSession.Response<String>) {
        let text = response.content
        guard !text.isEmpty else { return }
        let message = Message(role: .assistant, content: text)
        message.tokenCount = response.usage.totalTokenCount
        lastResponseTokens = response.usage.totalTokenCount
        modelContext.insert(message)
        session.messages?.append(message)
    }

    /// Keep whatever partial text the user saw before an interruption,
    /// so the transcript reads the same on resume.
    private func persistPartialAssistantMessage() {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = Message(role: .assistant, content: text)
        modelContext.insert(message)
        session.messages?.append(message)
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
