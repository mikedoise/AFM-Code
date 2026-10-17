import Foundation
import FoundationModels

/// One discovered MCP tool, bridged into the model session.
///
/// The 27 Foundation Models `Tool` protocol takes a `GenerationSchema`,
/// so the server's own `inputSchema` (JSON Schema, decoded straight into
/// the framework type) is what the model sees — no lossy projection.
/// Arguments arrive as `GeneratedContent`; the model's JSON is handed to
/// the server verbatim.
///
/// Safety follows the built-in mutating tools: every call registers a
/// step, and — like `run_command` — waits on the approval service
/// (Deny / Allow / Always Allow). The allowlist unit is the namespaced
/// tool name, so "Always Allow" grants that tool for the project
/// without enumerating its arguments. A project set to auto-approve
/// runs MCP tools without a card, same as commands.
nonisolated struct MCPTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    /// The namespaced name the model sees: `mcp__<server>__<tool>`.
    let name: String
    let description: String
    /// The server's `inputSchema` as the framework's schema type.
    let parameters: GenerationSchema

    private let host: MCPHostManager
    private let serverID: UUID
    /// The server-side tool name (without the namespace).
    private let toolName: String
    private let context: ToolContext

    init(
        namespacedName: String,
        displayName: String,
        description: String,
        parameters: GenerationSchema,
        host: MCPHostManager,
        serverID: UUID,
        toolName: String,
        context: ToolContext
    ) {
        self.name = namespacedName
        var text = description
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = "Tool “\(displayName)” provided by an external MCP server."
        } else {
            text += " (Provided by an external MCP server; results come from that server.)"
        }
        self.description = text
        self.parameters = parameters
        self.host = host
        self.serverID = serverID
        self.toolName = toolName
        self.context = context
    }

    @concurrent
    func call(arguments: GeneratedContent) async throws -> String {
        try Task.checkCancellation()

        let allowlistKey = ToolApprovalService.normalize(name)
        let stepID = await context.beginStep(
            kind: .mcp,
            toolName: name,
            title: name,
            status: await context.approvals.commandIsAllowed(allowlistKey) ? .running : .awaiting,
            command: allowlistKey
        )

        let decision = await context.approvals.wait(for: stepID, command: name)

        switch decision {
        case .deny:
            await context.updateStep(stepID, status: .denied, summary: "declined by user")
            return ToolContext.denialMessage(detail: "the MCP tool \(name)")
        case .cancelled:
            await context.updateStep(stepID, status: .cancelled, summary: "stopped")
            throw CancellationError()
        case .approve, .alwaysAllow:
            await context.updateStep(stepID, status: .approved, summary: nil)
            do {
                let output = try await host.callTool(
                    serverID: serverID,
                    toolName: toolName,
                    argumentsJSON: arguments.jsonString
                )
                await context.updateStep(
                    stepID,
                    status: .done,
                    summary: Self.summary(for: output),
                    detail: output
                )
                return output
            } catch {
                let message = Self.message(for: error)
                await context.updateStep(stepID, status: .failed, summary: message)
                return "\(name) failed: \(message)"
            }
        }
    }

    private static func summary(for output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = trimmed.split(separator: "\n", omittingEmptySubsequences: true).count
        var summary = "\(lineCount) line" + (lineCount == 1 ? "" : "s")
        if trimmed.count > 200 {
            summary += " · \(trimmed.count) chars"
        }
        return summary
    }

    private static func message(for error: any Error) -> String {
        if error is CancellationError {
            return "Cancelled."
        }
        if let failure = error as? MCPClient.MCPToolFailure {
            return failure.message
        }
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
