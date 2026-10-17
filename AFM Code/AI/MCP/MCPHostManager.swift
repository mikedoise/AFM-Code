import Foundation
import FoundationModels
import OSLog
import Observation
import SwiftData

/// The app's MCP server host: launches and tracks the configured
/// servers, keeps their discovered tool lists, and routes model
/// tool-calls to the right server process.
///
/// The structure follows the proven shape used by Nativ and
/// Perspective Intelligence: one client per server, a per-server
/// state machine surfaced to the settings UI, debounced reloads with
/// a generation guard (a slow server can't strand the reload), and
/// namespaced tool names (`mcp__<server>__<tool>`) so tools from
/// different servers — or a server tool that shadows a built-in name
/// like `read_file` — can never collide.
@MainActor
@Observable
final class MCPHostManager {
    private static let logger = Logger(subsystem: "dev.afmcode", category: "MCPHostManager")

    /// What the settings UI shows for one server.
    enum ServerState: Equatable {
        case disabled
        case connecting
        case connected(toolCount: Int)
        case failed(MCPConnectionFailure)
    }

    private struct Connection {
        let serverID: UUID
        /// The launch configuration the process was started with;
        /// compared on reload to decide whether a restart is needed.
        let launchSignature: String
        let client: MCPClient
        let slug: String
        let tools: [MCPToolInfo]
    }

    /// A comparison-friendly snapshot of a configured server, so a
    /// reload only relaunches when the launch actually changed.
    private struct LaunchSignature: Equatable {
        let id: UUID
        let name: String
        let command: String
        let arguments: [String]
        let environment: [String: String]
        let isEnabled: Bool
    }

    private(set) var states: [UUID: ServerState] = [:]

    private let modelContext: ModelContext
    private var connections: [UUID: Connection] = [:]
    private var appliedSignatures: [LaunchSignature] = []
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Configuration lifecycle

    /// Reconcile the live connections with the configured servers.
    /// Debounced; no-ops when nothing about the launch changed.
    func reload(servers: [MCPServer]) {
        let signatures = servers.map {
            LaunchSignature(
                id: $0.id,
                name: $0.name,
                command: $0.command,
                arguments: $0.arguments,
                environment: $0.environment,
                isEnabled: $0.isEnabled
            )
        }
        guard signatures != appliedSignatures else { return }
        appliedSignatures = signatures
        scheduleReload(servers: servers)
    }

    /// Force a retry for one server (the settings UI's reconnect).
    func reconnect(_ serverID: UUID) {
        if let connection = connections.removeValue(forKey: serverID) {
            states[serverID] = .connecting
            let client = connection.client
            Task { await client.disconnect() }
        }
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.applyReload(generation: generation)
        }
    }

    /// Tear everything down (app backgrounded). Resets the signature
    /// cache so the next `reload` reconnects instead of no-op'ing.
    func shutdown() {
        reloadTask?.cancel()
        let previous = connections
        connections = [:]
        appliedSignatures = []
        states = [:]
        Task {
            for connection in previous.values {
                await connection.client.disconnect()
            }
        }
    }

    private func scheduleReload(servers: [MCPServer]) {
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.applyReload(generation: generation)
        }
    }

    private func applyReload(generation: Int) async {
        let servers = (try? modelContext.fetch(FetchDescriptor<MCPServer>())) ?? []
        guard generation == reloadGeneration else { return }

        let enabled = servers.filter(\.isEnabled)
        let enabledByID = Dictionary(enabled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Drop connections whose launch configuration changed.
        for (id, connection) in connections {
            guard let server = enabledByID[id],
                  server.launchSignature == connection.launchSignature else {
                connections[id] = nil
                await connection.client.disconnect()
                continue
            }
        }
        guard generation == reloadGeneration else { return }

        for server in servers where !server.isEnabled {
            states[server.id] = .disabled
            persist(server, toolCount: nil, error: nil)
        }
        pruneStates(keeping: servers)

        let toConnect = enabled.filter { connections[$0.id] == nil }
        for server in toConnect {
            states[server.id] = .connecting
        }
        guard !toConnect.isEmpty else { return }

        // The user's real shell environment, sandbox-augmented — the
        // same one the shell tool runs with, so `npx`/`uvx`/homebrew
        // resolve exactly like they do in the user's terminal.
        let environment = await ShellEnvironment.resolved()
            ?? ProcessInfo.processInfo.environment
        guard generation == reloadGeneration else { return }

        let pending: [(server: MCPServer, client: MCPClient)] = toConnect.compactMap { server in
            guard let executable = Self.resolveExecutable(server.command, environment: environment) else {
                let failure = MCPConnectionFailure(
                    message: "Couldn't find “\(server.command)”. Check that the tool is installed and on your PATH."
                )
                states[server.id] = .failed(failure)
                persist(server, toolCount: nil, error: failure.message)
                return nil
            }
            let client = MCPClient(
                executableURL: executable,
                arguments: server.arguments,
                environment: Self.childEnvironment(
                    base: environment,
                    overrides: server.environment
                ),
                workingDirectory: Self.workingDirectory(for: server.id.uuidString)
            )
            return (server: server, client: client)
        }

        // Connect concurrently: a hung server must not hold up the rest.
        if !pending.isEmpty {
            await withTaskGroup(of: ConnectOutcome.self) { group in
                for item in pending {
                    group.addTask {
                        do {
                            let tools = try await item.client.connectAndListTools()
                            return ConnectOutcome(serverID: item.server.id, tools: tools, error: nil, client: item.client)
                        } catch {
                            return ConnectOutcome(
                                serverID: item.server.id,
                                tools: nil,
                                error: Self.connectionFailure(from: error),
                                client: item.client
                            )
                        }
                    }
                }
                var usedSlugs = Set(connections.values.map(\.slug))
                for await outcome in group {
                    guard generation == reloadGeneration else {
                        await outcome.client.disconnect()
                        continue
                    }
                    if let tools = outcome.tools,
                       let server = servers.first(where: { $0.id == outcome.serverID }) {
                        let slug = Self.uniqueSlug(for: server, used: &usedSlugs)
                        connections[outcome.serverID] = Connection(
                            serverID: outcome.serverID,
                            launchSignature: server.launchSignature,
                            client: outcome.client,
                            slug: slug,
                            tools: tools
                        )
                        states[outcome.serverID] = .connected(toolCount: tools.count)
                        if let server = servers.first(where: { $0.id == outcome.serverID }) {
                            persist(server, toolCount: tools.count, error: nil)
                        }
                    } else {
                        await outcome.client.disconnect()
                        let failure = outcome.error ?? MCPConnectionFailure(message: "Failed to connect.")
                        states[outcome.serverID] = .failed(failure)
                        if let server = servers.first(where: { $0.id == outcome.serverID }) {
                            persist(server, toolCount: nil, error: failure.message)
                        }
                    }
                }
            }
        }
    }

    private struct ConnectOutcome: Sendable {
        let serverID: UUID
        let tools: [MCPToolInfo]?
        let error: MCPConnectionFailure?
        let client: MCPClient
    }

    private func persist(_ server: MCPServer, toolCount: Int?, error: String?) {
        server.toolCount = toolCount
        server.lastError = error
        try? modelContext.save()
    }

    /// Any connection error as a user-presentable failure. Nonisolated:
    /// called from the task group's child tasks (the settings UI is the
    /// only consumer, but the hop would add nothing).
    nonisolated private static func connectionFailure(from error: any Error) -> MCPConnectionFailure {
        if let failure = error as? MCPConnectionFailure {
            return failure
        }
        if error is CancellationError {
            return MCPConnectionFailure(message: "The connection was cancelled.")
        }
        let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MCPConnectionFailure(message: message)
    }

    private func pruneStates(keeping servers: [MCPServer]) {
        let ids = Set(servers.map(\.id))
        states = states.filter { ids.contains($0.key) }
    }

    // MARK: - Tool bridge

    /// True when any connected server is offering tools.
    var hasConnectedTools: Bool {
        connections.values.contains { !$0.tools.isEmpty }
    }

    /// The MCP tools as Foundation Models `Tool` conformances for one
    /// session: each connected server's tools, namespaced, wired to
    /// the session's approval service.
    func mcpTools(context: ToolContext) -> [any Tool] {
        connections.values.flatMap { connection in
            connection.tools.map { tool in
                MCPTool(
                    namespacedName: Self.toolName(slug: connection.slug, tool: tool.name),
                    displayName: tool.name,
                    description: tool.description,
                    parameters: Self.schema(from: tool.inputSchema),
                    host: self,
                    serverID: connection.serverID,
                    toolName: tool.name,
                    context: context
                )
            }
        }
    }

    /// Route a model tool-call to the owning server. Returns the
    /// rendered result, bounded so a chatty server can't drown the
    /// model's context.
    func callTool(serverID: UUID, toolName: String, argumentsJSON: String?) async throws -> String {
        guard let connection = connections[serverID] else {
            throw MCPClientError.notConnected
        }
        let raw = try await connection.client.callTool(name: toolName, argumentsJSON: argumentsJSON)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no output)" }
        guard trimmed.count > Self.resultCharacterLimit else { return trimmed }
        return String(trimmed.prefix(Self.resultCharacterLimit))
            + "\n… (result truncated; ask the tool for a narrower range)"
    }

    /// Bound a single tool result the way the built-in tools bound
    /// their output (the context gauge, not the server, is the judge).
    static let resultCharacterLimit = 20_000

    // MARK: - Identity and naming

    /// `mcp__<server-slug>__<tool>` — the name the model sees and the
    /// routing key. Slugs are unique per server, so two servers
    /// exposing a same-named tool stay distinct.
    static func toolName(slug: String, tool: String) -> String {
        "mcp__\(slug)__\(tool)"
    }

    static func slug(_ raw: String) -> String {
        let characters = raw.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        let joined = String(characters).lowercased()
        return joined.isEmpty ? "server" : joined
    }

    private static func uniqueSlug(for server: MCPServer, used: inout Set<String>) -> String {
        let baseName = server.name.isEmpty ? server.command : server.name
        let base = slug(baseName)
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    // MARK: - Process resolution

    /// Resolve a launch command to an executable: tilde-expanded,
    /// absolute, or found on the resolved (login-shell) PATH.
    static func resolveExecutable(_ command: String, environment: [String: String]) -> URL? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded)
                ? URL(fileURLWithPath: expanded)
                : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// The environment the server process runs with: the user's real
    /// shell environment (sandbox-augmented) plus the per-server
    /// overrides from its configuration.
    static func childEnvironment(base: [String: String], overrides: [String: String]) -> [String: String] {
        var environment = base
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    /// Each server runs from its own scratch directory in the app
    /// container, so a server that drops files never scatters them.
    static func workingDirectory(for id: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support
            .appendingPathComponent("AFM Code", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent(slug(id), isDirectory: true)
    }

    // MARK: - Schemas

    /// The server's JSON Schema as a Foundation Models `GenerationSchema`.
    ///
    /// `GenerationSchema` is `Codable` in the 27 SDK, so most standard
    /// schemas decode directly. Anything the framework's schema type
    /// can't represent falls back to "any JSON object" — the model then
    /// proposes arguments freely and the server validates.
    static func schema(from rawJSON: String?) -> GenerationSchema {
        if let rawJSON, let data = rawJSON.data(using: .utf8) {
            if let schema = try? JSONDecoder().decode(GenerationSchema.self, from: data) {
                return schema
            }
            Self.logger.debug("MCP: input schema did not decode; using a free-form object schema")
        }
        return GeneratedContent.generationSchema
    }
}
