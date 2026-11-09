import Foundation
import FoundationModels
@testable import CoreAILanguageModels

/// No inference: real Foundation Models tool dispatch driven by the production
/// Gemma stream parser, with deterministic generated text and a memory-only tool.
struct ScriptedGemmaModel: LanguageModel {
    typealias Executor = ScriptedExecutor
    var body: String
    let instance = UUID()
    var capabilities: LanguageModelCapabilities { .init([.toolCalling]) }
    var executorConfiguration: ScriptedExecutor.Configuration { .init(body: body, instance: instance) }
}
struct ScriptedExecutor: LanguageModelExecutor {
    typealias Model = ScriptedGemmaModel
    struct Configuration: Hashable, Sendable { let body: String; let instance: UUID }
    init(configuration: Configuration) {}
    nonisolated(nonsending) func respond(to request: LanguageModelExecutorGenerationRequest,
        model: ScriptedGemmaModel, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        if request.transcript.contains(where: { if case .toolOutput = $0 { return true }; return false }) {
            await channel.send(.response(action: .appendText("received verified receipt", tokenCount: 4)))
            return
        }
        var parser = LanguageModelOutputParser(thinkingFormat: .tagPair(open: "<think>", close: "</think>"),
            supportsReasoning: false, toolCallDetection: .init(openMarker: "<|tool_call>", closeMarker: "<tool_call|>", format: .gemma))
        let events = parser.consume(model.body) + parser.flush()
        for event in events {
            switch event {
            case .tool(.text(let text)):
                await channel.send(.response(action: .appendText(text, tokenCount: 1)))
            case .tool(.toolCall(let id, let name, let json)):
                await channel.send(.toolCalls(action: .toolCall(id: id, name: name, action: .appendArguments(json, tokenCount: 1))))
            case .reasoning: preconditionFailure("Unexpected Gemma reasoning")
            }
        }
        // An entirely malformed call produces no tool event.
        if events.isEmpty { await channel.send(.response(action: .appendText("No valid call", tokenCount: 3))) }
    }
}
actor ToolReceiptRecorder {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
struct ReceiptTool: Tool {
    let name = "inspectSyntheticToken"
    let description = "Return a receipt for a synthetic token."
    let recorder: ToolReceiptRecorder
    @Generable struct Arguments { var token: String }
    func call(arguments: Arguments) async throws -> String {
        await recorder.record(arguments.token)
        return "verified receipt"
    }
}
@main struct CoreAIToolSessionTests {
    static func main() async throws {
        let raw = "hello<think>literal</think><turn|>\\n"
        let recorder = ToolReceiptRecorder()
        let session = LanguageModelSession(model: ScriptedGemmaModel(body: "<|tool_call>call:inspectSyntheticToken{token:<|\"|>" + raw + "<|\"|>}<tool_call|>"), tools: [ReceiptTool(recorder: recorder)])
        let response = try await session.respond(to: "Inspect the token")
        let values = await recorder.values
        precondition(values == [raw] && response.content.contains("verified receipt"))
        let entries = Array(session.transcript)
        guard let output = entries.lastIndex(where: { if case .toolOutput = $0 { return true }; return false }), output > 0,
              case .toolCalls = entries[output - 1] else { preconditionFailure("Tool continuation lost or separated") }
        print("PASS real Foundation Models dispatch + continuation preserve production-parser raw argument")

        // Gemma's canonical template wraps strings without JSON-escaping them.
        // Check bytes, not merely JSON display spelling: the bridge must encode
        // once and Foundation Models must decode once before the callback.
        let tripleQuote = String(repeating: "\"", count: 3)
        let python = "def example():\n    " + tripleQuote + "A Python docstring." + tripleQuote + "\n"
            + #"    pattern = r"\d+\s+\w+""# + "\n"
            + #"    newline = "\n""# + "\n"
            + #"    quote = "\"""# + "\n"
            + #"    path = "C:\\temp\\file.txt""# + "\n"
        let escapedTripleQuote = String(repeating: "\\\"", count: 3)
        let modelEscaped = python.replacingOccurrences(of: tripleQuote, with: escapedTripleQuote)
        for (label, source) in [("Python docstrings and legitimate escapes", python),
                                ("already-escaped model docstrings remain literal", modelEscaped)] {
            let recorder = ToolReceiptRecorder()
            let body = "<|tool_call>call:inspectSyntheticToken{token:<|\"|>" + source + "<|\"|>}<tool_call|>"
            let session = LanguageModelSession(model: ScriptedGemmaModel(body: body),
                                               tools: [ReceiptTool(recorder: recorder)])
            _ = try await session.respond(to: "Inspect the synthetic Python source")
            let captured = await recorder.values
            precondition(captured.count == 1, "Missing callback: \(label)")
            precondition(Array(captured[0].utf8) == Array(source.utf8), "UTF-8 bytes changed: \(label)")
            print("PASS byte-exact Foundation Models callback: \(label)")
        }

        for (label, body) in [
            ("unknown tool", "<|tool_call>call:unregisteredTool{token:<|\"|>x<|\"|>}<tool_call|>"),
            ("wrong typed argument", "<|tool_call>call:inspectSyntheticToken{token:123}<tool_call|>"),
            ("missing required argument", "<|tool_call>call:inspectSyntheticToken{}<tool_call|>"),
            ("duplicate key", "<|tool_call>call:inspectSyntheticToken{token:<|\"|>x<|\"|>,token:<|\"|>y<|\"|>}<tool_call|>"),
            ("truncated call", "<|tool_call>call:inspectSyntheticToken{token:<|\"|>x<|\"|>}")
        ] {
            let recorder = ToolReceiptRecorder()
            let session = LanguageModelSession(model: ScriptedGemmaModel(body: body), tools: [ReceiptTool(recorder: recorder)])
            do { _ = try await session.respond(to: "Inspect") } catch { /* Typed/unknown calls are rejected by Foundation Models. */ }
            let values = await recorder.values
            precondition(values.isEmpty, "Invalid callback executed: \(label)")
            print("PASS no callback for \(label)")
        }
    }
}
