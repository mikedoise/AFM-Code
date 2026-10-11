import Foundation
import FoundationModels

/// Searches file contents across the project.
///
/// Read-only: runs without approval.
nonisolated struct SearchTool: Tool {
    let context: ToolContext

    let name = "search"
    let description = "Search file contents across the project for a text pattern (substring, or regular expression when ripgrep is available). Returns matching lines as \"path:line:content\". Use it to find where something is defined or used. It sees current file contents only — use the git tool for commit history."

    @Generable
    struct Arguments {
        @Guide(description: "Text or regular expression to search for.")
        var pattern: String

        @Guide(description: "Optional. Restrict the search to this directory or file, relative to the project root. Defaults to the whole project.")
        var path: String?
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard await context.canOperate else {
            return "The project folder is not available right now, so I can't search it. Ask the user to re-connect the project folder."
        }

        let stepID = await context.beginStep(
            kind: .search,
            toolName: name,
            title: "Search \"\(Self.ellipsis(arguments.pattern))\"",
            status: .running
        )

        do {
            let result = try await context.search(
                pattern: arguments.pattern,
                path: arguments.path
            )
            let isMatchless = result.hasPrefix("No matches")
            await context.updateStep(
                stepID,
                status: .done,
                summary: isMatchless ? "no matches" : Self.summary(for: result),
                detail: result
            )
            return result
        } catch {
            let message = ReadFileTool.message(for: error)
            await context.updateStep(stepID, status: .failed, summary: message)
            return "search failed: \(message)"
        }
    }

    static func ellipsis(_ text: String) -> String {
        text.count <= 32 ? text : text.prefix(32) + "…"
    }

    static func summary(for result: String) -> String {
        if result.hasPrefix("No matches") {
            return "no matches"
        }
        let firstLine = result.components(separatedBy: "\n").first ?? ""
        if let range = firstLine.range(of: "\\d+", options: .regularExpression),
           let number = Int(firstLine[range]) {
            return "\(number) match\(number == 1 ? "" : "es")"
        }
        return "done"
    }
}
