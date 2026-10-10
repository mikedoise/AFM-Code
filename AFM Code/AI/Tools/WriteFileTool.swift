import Foundation
import FoundationModels

/// Creates a new file or fully replaces an existing one.
///
/// Mutating: the change is shown to the user as a diff card and only
/// happens after approval.
nonisolated struct WriteFileTool: Tool {
    let context: ToolContext

    let name = "write_file"
    let description = "Create a new file, or completely replace an existing file, with the given content. The user approves the change (with a diff preview) before it is written. Use edit_file for small, targeted changes — reserve this for new files or full rewrites."

    @Generable
    struct Arguments {
        @Guide(description: "Path of the file to write, relative to the project root, for example \"Sources/App.swift\".")
        var path: String

        @Guide(description: "The complete content of the file. Must be the whole file, including any unchanged parts — partial content will lose the rest.")
        var content: String
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard await context.canOperate else {
            return "The project folder is not available right now, so I can't write files. Ask the user to re-connect the project folder."
        }

        let path = arguments.path
        let diff = await context.previewDiffForWrite(path: path, newContent: arguments.content)

        let stepID = await context.beginStep(
            kind: .write,
            toolName: name,
            title: "Write \(path)",
            status: .awaiting,
            diff: diff
        )
        let decision = await context.approvals.wait(for: stepID)

        switch decision {
        case .deny:
            await context.updateStep(stepID, status: .denied, summary: "declined by user")
            return ToolContext.denialMessage(detail: "writing \(path)")
        case .cancelled:
            await context.updateStep(stepID, status: .cancelled, summary: "stopped")
            throw CancellationError()
        case .approve, .alwaysAllow:
            await context.updateStep(stepID, status: .approved, summary: nil, diff: diff)
            do {
                let summary = try await context.writeFile(path: path, content: arguments.content)
                await context.updateStep(stepID, status: .done, summary: summary, diff: diff)
                return summary
            } catch {
                let message = ReadFileTool.message(for: error)
                await context.updateStep(stepID, status: .failed, summary: message, diff: diff)
                return "write_file failed: \(message)"
            }
        }
    }
}
