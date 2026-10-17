import Foundation
import SwiftData

/// A Model Context Protocol server the user has configured.
///
/// MCP servers are global to the app (like the MLX library, not like
/// projects): each one is a local process launched over stdio, and its
/// tools become available to project sessions — namespaced
/// `mcp__<server>__<tool>`, bridged into the model session with the
/// server's own JSON schemas.
///
/// `arguments` and `environment` are stored JSON-encoded so the rows
/// survive without SwiftData collections-of-scalars; the typed
/// accessors keep the rest of the app working with real values.
@Model
final class MCPServer {
    var id: UUID
    /// Display name. Falls back to the executable's file name.
    var name: String
    /// The executable that launches the server (`npx`, `uvx`, a path…).
    var command: String
    /// JSON array of the launch arguments.
    var argumentsRaw: String
    /// JSON object of environment variables to add for the process.
    var environmentRaw: String
    /// Disabled servers stay configured but their processes don't run.
    var isEnabled: Bool
    /// The bundled catalog entry this row was made from; `nil` for
    /// servers the user added from scratch.
    var catalogID: String?
    /// The last connection failure, for the settings UI.
    var lastError: String?
    /// Tool count from the last successful `tools/list`.
    var toolCount: Int?
    var addedAt: Date

    init(
        name: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        isEnabled: Bool = true,
        catalogID: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.command = command
        self.argumentsRaw = Self.encodeArray(arguments)
        self.environmentRaw = Self.encodeObject(environment)
        self.isEnabled = isEnabled
        self.catalogID = catalogID
        self.addedAt = Date()
    }

    // MARK: - Typed accessors

    var arguments: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(argumentsRaw.utf8))) ?? [] }
        set { argumentsRaw = Self.encodeArray(newValue) }
    }

    var environment: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(environmentRaw.utf8))) ?? [:] }
        set { environmentRaw = Self.encodeObject(newValue) }
    }

    /// A stable, comparison-friendly description of the launch
    /// configuration, so the host manager can tell when a change
    /// actually requires a relaunch.
    var launchSignature: String {
        [name, command, argumentsRaw, environmentRaw, isEnabled ? "on" : "off"]
            .joined(separator: "\u{1}")
    }

    static func encodeArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func encodeObject(_ values: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
