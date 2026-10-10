import Foundation
import FoundationModels

/// Makes a targeted change to an existing file via find/replace.
///
/// Mutating: the user approves a diff preview first.
nonisolated struct EditFileTool: Tool {
    let context: ToolContext

    let name = "edit_file"
    let description = "Change part of an existing file. Provide the exact text to find (it must match the file verbatim, including whitespace) and the replacement text. The search text must be unique in the file unless replaceAll is true. The user approves the change before it is applied. Read the file first to get the exact text."

    @Generable
    struct Arguments {
        @Guide(description: "Path of the file to edit, relative to the project root.")
        var path: String

        @Guide(description: "The exact text to find in the file. Must match verbatim, including whitespace and indentation. Include enough surrounding lines to make it unique.")
        var find: String

        @Guide(description: "The text to replace the found text with.")
        var replace: String

        @Guide(description: "Replace every occurrence instead of requiring a unique match. Defaults to false.")
        var replaceAll: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard await context.canOperate else {
            return "The project folder is not available right now, so I can't edit files. Ask the user to re-connect the project folder."
        }

        let path = arguments.path
        let diff = await context.previewDiffForEdit(
            path: path,
            find: arguments.find,
            replace: arguments.replace,
            replaceAll: arguments.replaceAll ?? false
        )

        let stepID = await context.beginStep(
            kind: .edit,
            toolName: name,
            title: "Edit \(path)",
            status: .awaiting,
            diff: diff
        )
        let decision = await context.approvals.wait(for: stepID)

        switch decision {
        case .deny:
            await context.updateStep(stepID, status: .denied, summary: "declined by user")
            return ToolContext.denialMessage(detail: "editing \(path)")
        case .cancelled:
            await context.updateStep(stepID, status: .cancelled, summary: "stopped")
            throw CancellationError()
        case .approve, .alwaysAllow:
            await context.updateStep(stepID, status: .approved, diff: diff)
            do {
                let summary = try await context.editFile(
                    path: path,
                    find: arguments.find,
                    replace: arguments.replace,
                    replaceAll: arguments.replaceAll ?? false
                )
                await context.updateStep(stepID, status: .done, summary: summary, diff: diff)
                return summary
            } catch {
                let message = ReadFileTool.message(for: error)
                await context.updateStep(stepID, status: .failed, summary: message, diff: diff)
                return "edit_file failed: \(message)"
            }
        }
    }
}
