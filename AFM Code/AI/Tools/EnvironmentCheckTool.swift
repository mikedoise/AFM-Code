import Foundation
import FoundationModels

/// Inventory does not execute discovered programs. Fixed execution probes use
/// the same project approval gate as commands, including per-project settings.
nonisolated struct EnvironmentCheckTool: Tool {
    let context: ToolContext
    let name = "environment_check"
    let description = "Check the current desktop command environment without exposing environment variables or credentials. Reports paths for shell, python3, python, gh, git, node, npm, uv and rg. Finding a tool is separate from running it. Optionally run one fixed, approval-gated version/isolated Python probe. Use this before assuming a terminal tool is missing or after a command lookup/permission error. Does not request installation, login, network access or permission changes."

    @Generable struct Arguments {
        @Guide(description: "Optional tool name: shell, python3, python, gh, git, node, npm, uv or rg. Omit to inspect all paths.")
        var tool: String?
        @Guide(description: "Optional. True runs a fixed execution probe for the named tool through project approval. Defaults to false (path inspection only). One tool must be named for execution.")
        var verifyExecution: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard await context.rootURL != nil else { return "The project folder is unavailable. Reconnect it before checking this project's command environment." }
        let requested = arguments.tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard requested == nil || EnvironmentDiagnostics.names.contains(requested!) else {
            return "Choose one of: \(EnvironmentDiagnostics.names.joined(separator: ", ")). Nothing was executed."
        }
        guard arguments.verifyExecution != true || requested != nil else { return "Name one tool to verify execution. Nothing was executed." }
        let snapshot = ShellEnvironment.inspectionSnapshot()
        let environment = snapshot.environment
        try Task.checkCancellation()
        let candidates = try await context.inspectEnvironment(names: requested.map { [$0] } ?? EnvironmentDiagnostics.names, environment: environment)
        let report = EnvironmentDiagnostics.inventory(candidates) + "\n" + snapshot.summary + "\n" + EnvironmentDiagnostics.limitations
        guard arguments.verifyExecution == true, let candidate = candidates.first,
              let command = EnvironmentDiagnostics.command(for: candidate) else {
            let id = await context.beginStep(kind: .read, toolName: name, title: "Check command environment", status: .running)
            await context.updateStep(id, status: .done, summary: "Paths checked; discovered programs not executed", detail: report)
            return report
        }
        let id = await context.beginStep(kind: .command, toolName: name, title: "Verify \(candidate.name) execution", status: .awaiting, command: command)
        await context.updateStep(id, detail: "Fixed capability probe. It runs the displayed executable with your normal Mac account permissions. No authentication or network test. Only a numeric version or categorized result is retained.")
        switch await context.approvals.wait(for: id, command: command) {
        case .deny:
            await context.updateStep(id, status: .denied, summary: "declined by user")
            return ToolContext.denialMessage(detail: "the \(candidate.name) environment probe")
        case .cancelled:
            await context.updateStep(id, status: .cancelled, summary: "stopped")
            throw CancellationError()
        case .approve, .alwaysAllow:
            await context.updateStep(id, status: .approved)
        }
        do {
            let run = try await context.runEnvironmentProbe(command: command, environment: environment)
            let result = EnvironmentDiagnostics.probeResult(name: candidate.name, exitCode: run.exitCode, output: run.output, timedOut: run.timedOut)
            let success = !run.timedOut && run.exitCode == 0 && EnvironmentDiagnostics.success(name: candidate.name, output: run.output) != nil
            await context.updateStep(id, status: success ? .done : .failed, summary: success ? "Execution verified" : "Probe failed", detail: report + "\n" + result)
            return report + "\n" + result
        } catch {
            if error is CancellationError || Task.isCancelled {
                await context.updateStep(id, status: .cancelled, summary: "stopped")
                throw CancellationError()
            }
            let result = "Probe could not start in this environment. No raw error or environment values were retained. Check the project folder connection and executable access."
            await context.updateStep(id, status: .failed, summary: "Could not start probe", detail: result)
            return report + "\n" + result
        }
    }
}

@MainActor extension ToolContext {
    /// Discovery must retain the selected-folder lease too: PATH may contain a
    /// project-local virtual environment or relative entry.
    func inspectEnvironment(names: [String], environment: [String: String]) throws -> [EnvironmentDiagnostics.Candidate] {
        guard let result = workspace.withAccess({ root in
            EnvironmentDiagnostics.candidates(names: names, environment: environment, root: root)
        }) else { throw ToolError.folderUnavailable }
        return result
    }
}
