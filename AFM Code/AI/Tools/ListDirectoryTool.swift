import Foundation
import FoundationModels

/// Shows the project's folder structure.
///
/// Read-only: runs without approval.
nonisolated struct ListDirectoryTool: Tool {
    let context: ToolContext

    let name = "list_directory"
    let description = "List the folder structure of the project (or a subfolder), showing files and subdirectories. Common build artifacts (.git, node_modules, .build, …) are hidden."

    @Generable
    struct Arguments {
        @Guide(description: "Directory to list, relative to the project root. Use \".\" for the project root.")
        var path: String?

        @Guide(description: "How deep to recurse. Defaults to 2; maximum 4.")
        var maxDepth: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard await context.canOperate else {
            return "The project folder is not available right now, so I can't list it. Ask the user to re-connect the project folder."
        }

        let path = arguments.path ?? "."
        let stepID = await context.beginStep(
            kind: .list,
            toolName: name,
            title: "List \(path)",
            status: .running
        )

        do {
            let output = try await context.listDirectory(
                path: path,
                maxDepth: arguments.maxDepth ?? 2
            )
            let lineCount = output.components(separatedBy: "\n").count
            await context.updateStep(
                stepID,
                status: .done,
                summary: "\(lineCount) entries",
                detail: output
            )
            return output
        } catch {
            let message = ReadFileTool.message(for: error)
            await context.updateStep(stepID, status: .failed, summary: message)
            return "list_directory failed: \(message)"
        }
    }
}
