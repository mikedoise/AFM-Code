import Foundation
import FoundationModels

/// Runs a shell command in the project folder.
///
/// Mutating: the user approves each command (with Deny / Allow /
/// Always Allow). Commands the user has chosen "Always Allow" for run
/// without asking.
nonisolated struct RunCommandTool: Tool {
    let context: ToolContext

    let name = "run_command"
    let description = "Run a shell command (zsh) in the project folder — builds, tests, linters, git, etc. The command runs with a timeout and its output is returned. Avoid long-running or interactive commands. Destructive commands should be described to the user in your reply."

    @Generable
    struct Arguments {
        @Guide(description: "The full shell command to run, for example \"swift build\" or \"git status\".")
        var command: String

        @Guide(description: "Optional. Timeout in seconds. Defaults to 60; maximum 300.")
        var timeout: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard await context.canOperate else {
            return "The project folder is not available right now, so I can't run commands. Ask the user to re-connect the project folder."
        }

        let command = arguments.command
        let timeout = min(max(arguments.timeout ?? 60, 1), 300)
        let normalized = ToolApprovalService.normalize(command)
        let title = "Run \(Self.ellipsis(command))"

        // Allowlisted commands run straight through; everything else
        // pauses for the user's decision.
        let stepID = await context.beginStep(
            kind: .command,
            toolName: name,
            title: title,
            status: await context.approvals.commandIsAllowed(command) ? .running : .awaiting,
            command: normalized
        )

        let decision = await context.approvals.wait(for: stepID, command: command)

        switch decision {
        case .deny:
            await context.updateStep(stepID, status: .denied, summary: "declined by user")
            return ToolContext.denialMessage(detail: "running `\(command)`")
        case .cancelled:
            await context.updateStep(stepID, status: .cancelled, summary: "stopped")
            throw CancellationError()
        case .approve, .alwaysAllow:
            await context.updateStep(stepID, status: .approved, summary: nil)
            do {
                let run = try await context.runCommand(command: command, timeout: Double(timeout))
                let lineCount = run.output.split(separator: "\n", omittingEmptySubsequences: true).count
                var summary = "exit \(run.exitCode)"
                if lineCount > 0 { summary += " · \(lineCount) lines" }
                if run.timedOut { summary += " · timed out" }
                await context.updateStep(
                    stepID,
                    status: run.exitCode == 0 && !run.timedOut ? .done : .failed,
                    summary: summary,
                    detail: run.output
                )

                var output = run.output
                if output.isEmpty { output = "(no output)" }
                if run.timedOut {
                    output = "Command timed out after \(timeout)s.\n" + output
                }
                if run.exitCode != 0 {
                    output += "\n(exit code \(run.exitCode))"
                }
                return output
            } catch {
                let message = ReadFileTool.message(for: error)
                await context.updateStep(stepID, status: .failed, summary: message)
                return "run_command failed: \(message)"
            }
        }
    }

    static func ellipsis(_ command: String) -> String {
        command.count <= 48 ? command : command.prefix(48) + "…"
    }
}
