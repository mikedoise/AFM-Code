import Foundation
import FoundationModels
@testable import CoreAILanguageModels

/// Deterministic generated text, production parser/dispatch and actual app file
/// tool. Only app state is stubbed; every file lives in ToolSafetyFixture.
@main struct CoreAIFileWriteChainTests {
    @MainActor static func pending(_ approvals: ToolApprovalService) async throws -> UUID {
        for _ in 0..<2000 {
            if let id = approvals.pendingStepIDs.first { return id }
            try await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("Timed out waiting for production approval gate")
    }

    @MainActor static func main() async throws {
        let triple = String(repeating: "\"", count: 3)
        let python = "def example():\n    " + triple + "A café 😀 docstring." + triple + "\n"
            + #"    pattern = r"\d+\s+\w+""# + "\n"
            + #"    newline = "\n""# + "\n"
            + #"    quote = "\"""# + "\n"
            + #"    path = "C:\\temp\\file.txt""# + "\n"
        let escaped = python.replacingOccurrences(of: triple, with: String(repeating: "\\\"", count: 3))
        for (label, content) in [("raw Python source", python), ("already-escaped model source", escaped)] {
            for approve in [true, false] {
                let fixture = try ToolSafetyFixture()
                defer { try? fixture.cleanup() }
                fixture.context.beginTurn()
                defer { fixture.context.endTurn() }
                let file = fixture.root.appendingPathComponent("example.py")
                let body = "<|tool_call>call:write_file{path:<|\"|>example.py<|\"|>,content:<|\"|>" + content + "<|\"|>}<tool_call|>"
                let session = LanguageModelSession(model: ScriptedGemmaModel(body: body),
                    tools: [WriteFileTool(context: fixture.context)])
                let response = Task { try await session.respond(to: "Write the synthetic Python fixture") }
                let id = try await pending(fixture.approvals)
                precondition(!FileManager.default.fileExists(atPath: file.path), "File written before approval")
                guard let step = fixture.context.turnSteps.first(where: { $0.id == id }),
                      step.status == .awaiting, let diff = step.diff else {
                    preconditionFailure("Missing immutable proposal preview")
                }
                let preview = diff.lines.filter { $0.kind == .addition }.map(\.text).joined(separator: "\n")
                precondition(Data(preview.utf8) == Data(content.utf8), "Preview changed source bytes")
                fixture.approvals.decide(id, approve ? .approve : .deny)
                _ = try await response.value
                if approve {
                    let disk = try Data(contentsOf: file)
                    precondition(disk == Data(content.utf8), "On-disk bytes differ from model raw text")
                    precondition(fixture.context.turnSteps.last?.status == .done)
                } else {
                    precondition(!FileManager.default.fileExists(atPath: file.path), "Denied write created file")
                    precondition(fixture.context.turnSteps.last?.status == .denied)
                }
                precondition(fixture.approvals.pendingStepIDs.isEmpty)
                print("PASS full Gemma → typed write_file → preview → \(approve ? "approved exact disk bytes" : "denied no file"): \(label)")
            }
        }
    }
}
