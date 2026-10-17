import Foundation

/// A server the app ships with: a known-good launch configuration for
/// a common MCP server, shown in the settings UI's built-in section.
///
/// Defined in code (rather than a bundled resource) so the list stays
/// in the app's source where it can be reviewed — the app has no CI
/// gate to validate a JSON catalog.
struct MCPCatalogEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let command: String
    let arguments: [String]
    let symbol: String
    let sourceURL: URL?

    init(
        id: String,
        name: String,
        summary: String,
        command: String,
        arguments: [String] = [],
        symbol: String = "server.rack",
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.command = command
        self.arguments = arguments
        self.symbol = symbol
        self.sourceURL = sourceURL
    }
}

/// The built-in MCP servers, curated for a coding app.
///
/// These are *suggestions*: the user enables or adds them, and each
/// becomes an ordinary `MCPServer` row (tagged with its catalog id)
/// the moment they're used.
enum MCPServerCatalog {
    static let bundled: [MCPCatalogEntry] = [
        MCPCatalogEntry(
            id: "filesystem",
            name: "Filesystem",
            summary: "Read and write files anywhere on your Mac (the server's own root).",
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", "~/Desktop"],
            symbol: "folder",
            sourceURL: URL(string: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem")
        ),
        MCPCatalogEntry(
            id: "git",
            name: "Git",
            summary: "Read repositories: logs, diffs, branches, and file history.",
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-git"],
            symbol: "arrow.triangle.branch",
            sourceURL: URL(string: "https://github.com/modelcontextprotocol/servers/tree/main/src/git")
        ),
        MCPCatalogEntry(
            id: "fetch",
            name: "Fetch",
            summary: "Fetch a web page and read it as Markdown.",
            command: "uvx",
            arguments: ["mcp-server-fetch"],
            symbol: "network",
            sourceURL: URL(string: "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch")
        ),
        MCPCatalogEntry(
            id: "memory",
            name: "Memory",
            summary: "A persistent knowledge graph the agent can search and grow across sessions.",
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-memory"],
            symbol: "brain",
            sourceURL: URL(string: "https://github.com/modelcontextprotocol/servers/tree/main/src/memory")
        ),
        MCPCatalogEntry(
            id: "sequential-thinking",
            name: "Sequential Thinking",
            summary: "Structured step-by-step reasoning for complex problems.",
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-sequential-thinking"],
            symbol: "list.number",
            sourceURL: URL(string: "https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking")
        ),
    ]

    /// A ready-to-add `MCPServer` row for a catalog entry.
    static func makeServer(for entry: MCPCatalogEntry, isEnabled: Bool = true) -> MCPServer {
        MCPServer(
            name: entry.name,
            command: entry.command,
            arguments: entry.arguments,
            isEnabled: isEnabled,
            catalogID: entry.id
        )
    }
}
