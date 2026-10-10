import Foundation
import FoundationModels

/// Reads a text file from the project folder, with line numbers.
///
/// Read-only: runs without approval.
nonisolated struct ReadFileTool: Tool {
    let context: ToolContext

    let name = "read_file"
    let description = "Read a text file from the project folder. Returns the file content with line numbers (\"N\\tcontent\"). Use it to look at file contents before editing them. For large files, use startLine and maxLines to read only the part you need."

    @Generable
    struct Arguments {
        @Guide(description: "Path to the file, relative to the project root, for example \"Sources/App.swift\".")
        var path: String

        @Guide(description: "Optional. The first line to read, 1-based. Defaults to the start of the file.")
        var startLine: Int?

        @Guide(description: "Optional. Maximum number of lines to read. Defaults to 500; the tool never returns more than 2000 lines.")
        var maxLines: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard await context.canOperate else {
            return "The project folder is not available right now, so I can't read files. Ask the user to re-connect the project folder."
        }

        let stepID = await context.beginStep(
            kind: .read,
            toolName: name,
            title: "Read \(arguments.path)",
            status: .running
        )

        do {
            let result = try await context.readFile(
                path: arguments.path,
                startLine: arguments.startLine,
                maxLines: arguments.maxLines
            )
            var summary = "\(result.lineCount) line" + (result.lineCount == 1 ? "" : "s")
            if result.truncated { summary += " (showing part)" }
            await context.updateStep(stepID, status: .done, summary: summary, detail: result.output)
            var output = result.output
            if result.truncated {
                output += "\n… (output truncated; read a narrower line range to see the rest)"
            }
            return output
        } catch {
            let message = Self.message(for: error)
            await context.updateStep(stepID, status: .failed, summary: message)
            return "read_file failed: \(message)"
        }
    }

    static func message(for error: Error) -> String {
        if let toolError = error as? ToolContext.ToolError {
            return toolError.errorDescription ?? "Tool error"
        }
        if error is CancellationError {
            return "Cancelled."
        }
        return error.localizedDescription
    }
}
