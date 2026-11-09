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
        let path = arguments.path
        // Record the attempt before validation/preparation: failures here must
        // be visible to the user as well as returned to the model.
        let stepID = await context.beginStep(
            kind: .write,
            toolName: name,
            title: "Write \(path)",
            status: .running
        )
        let change: PreparedFileChange
        do {
            try Task.checkCancellation()
            guard await context.canOperate else { throw ToolContext.ToolError.folderUnavailable }
            change = try await context.prepareWrite(path: path, content: arguments.content)
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                await context.updateStep(stepID, status: .cancelled, summary: "stopped")
                throw CancellationError()
            }
            let message = ReadFileTool.message(for: error)
            await context.recordFileChangeFailure(stepID, phase: .preparation, error: error)
            await context.updateStep(stepID, status: .failed, summary: message)
            return "write_file failed: \(message)"
        }
        if change.isNoOp {
            let summary = "No changes needed; the file is unchanged."
            await context.updateStep(stepID, status: .done, summary: summary)
            return summary
        }
        let diff = change.diff
        await context.updateStep(stepID, status: .awaiting, diff: diff)
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
                let summary = try await context.applyChange(change)
                await context.updateStep(stepID, status: .done, summary: summary, diff: diff)
                return summary
            } catch {
                if error is CancellationError || Task.isCancelled {
                    await context.updateStep(stepID, status: .cancelled, summary: "stopped")
                    throw CancellationError()
                }
                let message = ReadFileTool.message(for: error)
                await context.recordFileChangeFailure(stepID, phase: .apply, error: error)
                await context.updateStep(stepID, status: .failed, summary: message, diff: diff)
                return "write_file failed: \(message)"
            }
        }
    }
}
