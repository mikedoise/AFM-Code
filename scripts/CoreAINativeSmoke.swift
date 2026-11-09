import Foundation
import FoundationModels
import CoreAILanguageModels

actor NativeToolRecorder {
    var received: [String] = []
    func record(_ token: String) throws {
        guard received.isEmpty else { throw NSError(domain: "NativeSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Repeated synthetic tool call"]) }
        received.append(token)
    }
}
struct NativeReceiptTool: Tool {
    let name = "inspectSyntheticToken"
    let description = "Inspect a synthetic token and return its verification receipt."
    let recorder: NativeToolRecorder
    @Generable struct Arguments {
        @Guide(description: "The exact synthetic token supplied by the user.") var token: String
    }
    func call(arguments: Arguments) async throws -> String {
        try await recorder.record(arguments.token)
        return "Verified synthetic token. Receipt: violet-842."
    }
}

@main struct CoreAINativeSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass an exported Core AI bundle directory") }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundle = try LanguageModelBundle(at: url)
        let model = try await CoreAILanguageModel(resourcesAt: url)
        defer { model.unload() }
        print("Prepared adapter for \(bundle.name); context \(bundle.maxContextLength); tools \(model.capabilities.contains(.toolCalling)); reasoning \(model.capabilities.contains(.reasoning))")
        if ProcessInfo.processInfo.environment["AFM_COREAI_METADATA_ONLY"] == "1" {
            print("PASS metadata and offline tokenizer; inference not requested")
            return
        }
        try await model.load()
        print("PASS native engine load")
        if ProcessInfo.processInfo.environment["AFM_COREAI_TOOL_SMOKE"] == "1" {
            precondition(model.capabilities.contains(.toolCalling))
            let recorder = NativeToolRecorder()
            let session = LanguageModelSession(model: model, tools: [NativeReceiptTool(recorder: recorder)],
                instructions: "Use inspectSyntheticToken when asked to inspect a token. After the tool returns, report its receipt. Do not invent a receipt.")
            let response = try await session.respond(to: "Inspect synthetic token cobalt-731 using the tool, then tell me the receipt.",
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 256))
            let received = await recorder.received
            precondition(received == ["cobalt-731"] && response.content.contains("violet-842"))
            let entries = Array(session.transcript)
            guard let index = entries.lastIndex(where: { if case .toolOutput = $0 { return true }; return false }), index > 0,
                  case .toolCalls = entries[index - 1] else { preconditionFailure("Tool output lost or separated") }
            print("PASS real Core AI callback and output continuation: \(response.content)")
            print("Synthetic memory-only callback; no file write, command, MCP call or app interaction.")
            return
        }
        let session = LanguageModelSession(model: model, instructions: "Be concise. Follow the user's requested answer format.")
        var options = GenerationOptions()
        options.maximumResponseTokens = 128
        let response = try await session.respond(to: "What is 2 plus 2? Answer with just the number.", options: options)
        let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        print("NATIVE ANSWER: \(answer)")
        guard answer == "4" else { throw NSError(domain: "NativeSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 4, received \(answer)"]) }
        print("PASS Foundation Models response using Core AI adapter")
        let count = model.inputTokenCount(for: Array(session.transcript))
        precondition(count > 0)
        print("PASS transcript token count: \(count)")
        var overBudget = GenerationOptions()
        overBudget.maximumResponseTokens = bundle.maxContextLength
        do {
            _ = try await session.respond(to: "Hello", options: overBudget)
            fatalError("Expected context rejection")
        } catch LanguageModelError.contextSizeExceeded(let error) {
            precondition(error.contextSize == bundle.maxContextLength)
            print("PASS input-plus-output admission rejects overflow")
        }
    }
}
