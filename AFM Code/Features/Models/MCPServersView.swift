import AppKit
import SwiftUI
import SwiftData

/// MCP server management: the sheet behind Settings → MCP.
///
/// Built-in servers from the catalog, the user's own servers, and the
/// live connection state of each (tool count, or the redacted failure
/// details when a launch went wrong).
struct MCPServersView: View {
    @Environment(MCPHostManager.self) private var host
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \MCPServer.addedAt, order: .reverse)
    private var servers: [MCPServer]

    @State private var editing: MCPServer?
    @State private var pendingDelete: MCPServer?

    private let catalog = MCPServerCatalog.bundled

    var body: some View {
        Form {
            Section {
                Button {
                    editing = MCPServer(name: "", command: "")
                } label: {
                    Label("Add MCP Server", systemImage: "plus")
                }
                .help("Add a server you launch yourself: npx, uvx, or any executable.")
            } header: {
                Text("Model Context Protocol")
            } footer: {
                Text("Each server runs as a local process over stdio, and its tools become available to project sessions as mcp__<server>__<tool>. Tool calls still go through the approval flow. Servers run inside the app sandbox: filesystem servers see what the app can see.")
            }

            builtInSection
            yourServersSection
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { server in
            // The editor works on a value draft: the model row is a
            // class, so typing through a direct reference would autosave
            // half-finished edits on Cancel.
            MCPServerEditor(server: server) { draft in
                if servers.contains(where: { $0.id == server.id }) {
                    apply(draft, to: server)
                } else {
                    let newServer = MCPServer(draft)
                    modelContext.insert(newServer)
                }
                try? modelContext.save()
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name.isEmpty == false ? pendingDelete!.name : "this MCP server")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    modelContext.delete(pendingDelete)
                    try? modelContext.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server's configuration is removed from AFM Code. Nothing else is changed.")
        }
    }

    // MARK: - Built-in

    @ViewBuilder
    private var builtInSection: some View {
        Section("Built-in") {
            ForEach(catalog) { entry in
                builtInRow(entry)
            }
        }
    }

    private func builtInRow(_ entry: MCPCatalogEntry) -> some View {
        let configured = servers.first { $0.catalogID == entry.id }
        let state = configured.flatMap { host.states[$0.id] }

        return HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                    statusBadge(state: state ?? .disabled)
                }
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let configured {
                Toggle("", isOn: Binding(
                    get: { configured.isEnabled },
                    set: { _ in
                        configured.isEnabled.toggle()
                        try? modelContext.save()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            } else {
                Button("Add") {
                    let server = MCPServerCatalog.makeServer(for: entry, isEnabled: false)
                    modelContext.insert(server)
                    try? modelContext.save()
                }
                .controlSize(.small)
            }
        }
        .help("“\(entry.command)” \(entry.arguments.joined(separator: " "))")
    }

    // MARK: - User servers

    @ViewBuilder
    private var yourServersSection: some View {
        Section("Your Servers") {
            if servers.isEmpty {
                Text("No servers have been added yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(servers) { server in
                    serverRow(server)
                }
            }
        }
    }

    private func serverRow(_ server: MCPServer) -> some View {
        let state = host.states[server.id]

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusDot(state: state ?? (server.isEnabled ? .connecting : .disabled))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.name.isEmpty ? "Untitled server" : server.name)
                            .font(.body.weight(.medium))
                        statusBadge(state: state)
                    }
                    Text(statusText(state: state, server: server))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if server.isEnabled, let state, case .connected = state {
                    Button {
                        host.reconnect(server.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reconnect")
                }
                Button {
                    editing = server
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Edit")
                Button {
                    pendingDelete = server
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete")
                Toggle("", isOn: Binding(
                    get: { server.isEnabled },
                    set: { _ in
                        server.isEnabled.toggle()
                        try? modelContext.save()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if case .failed(let failure) = state, let details = failure.details, !details.isEmpty {
                failureCallout(details)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Status rendering

    private enum StatusTone {
        case success, warning, danger, neutral
    }

    private func statusDot(state: MCPHostManager.ServerState) -> some View {
        let color: Color
        let pulsing: Bool
        switch state {
        case .connected: color = .green; pulsing = false
        case .connecting: color = .orange; pulsing = true
        case .failed: color = .red; pulsing = false
        case .disabled: color = .secondary; pulsing = false
        }
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 1 : 0.9)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func statusBadge(state: MCPHostManager.ServerState?) -> some View {
        switch state {
        case .connected(let count):
            Text("\(count) tool\(count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.green)
        case .connecting:
            Text("Connecting…")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .failed:
            Text("Failed")
                .font(.caption2)
                .foregroundStyle(.red)
        case .disabled, .none:
            Text("Off")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(state: MCPHostManager.ServerState?, server: MCPServer) -> String {
        switch state {
        case .connected(let count):
            return "\(count) tool\(count == 1 ? "" : "s") available"
        case .connecting:
            return "Connecting…"
        case .failed(let failure):
            return failure.message
        case .disabled:
            return "Disabled"
        case .none:
            return server.isEnabled ? "Not connected" : "Disabled"
        }
    }

    private func failureCallout(_ details: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(details)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Editing

    private func apply(_ draft: MCPServerDraft, to destination: MCPServer) {
        draft.apply(to: destination)
    }
}

/// A value copy of a server's editable fields. The editor mutates the
/// draft, never the model row, so Cancel costs nothing.
struct MCPServerDraft: Equatable {
    var id: UUID
    var name: String
    var command: String
    var arguments: [String]
    var environment: [String: String]
    var isEnabled: Bool

    init(_ server: MCPServer) {
        self.id = server.id
        self.name = server.name
        self.command = server.command
        self.arguments = server.arguments
        self.environment = server.environment
        self.isEnabled = server.isEnabled
    }

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.isEnabled = isEnabled
    }

    func apply(to server: MCPServer) {
        server.name = name
        server.command = command
        server.arguments = arguments
        server.environment = environment
        server.isEnabled = isEnabled
    }

    var isValid: Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension MCPServer {
    convenience init(_ draft: MCPServerDraft) {
        self.init(
            name: draft.name,
            command: draft.command,
            arguments: draft.arguments,
            environment: draft.environment,
            isEnabled: draft.isEnabled
        )
    }
}

// MARK: - Editor

/// The add/edit form for one MCP server.
///
/// Two modes, the way Nativ's editor offers them: a small form (name,
/// launch command, environment), and raw JSON — the standard
/// `mcpServers` object shape, so entries can be pasted straight from
/// existing configurations.
private struct MCPServerEditor: View {
    let onSave: (MCPServerDraft) -> Void
    let onCancel: () -> Void

    @State private var draft: MCPServerDraft
    @State private var launchCommandText: String
    @State private var launchCommandError: String?
    @State private var editingJSON = false
    @State private var jsonText = ""
    @State private var jsonError: String?

    init(server: MCPServer, onSave: @escaping (MCPServerDraft) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: MCPServerDraft(server))
        _launchCommandText = State(
            initialValue: server.command.isEmpty
                ? ""
                : MCPLaunchCommand(executable: server.command, arguments: server.arguments).rendered
        )
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.name.isEmpty && launchCommandText.isEmpty ? "New MCP Server" : "Edit MCP Server")
                    .font(.headline)
                Spacer()
                Toggle("Edit as JSON", isOn: $editingJSON)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: editingJSON) { _, isEditingJSON in
                        switchEditorMode(isEditingJSON: isEditingJSON)
                    }
            }

            if editingJSON {
                TextEditor(text: $jsonText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 240)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .onChange(of: jsonText) { _, _ in
                        validateJSON()
                    }
                if let jsonError {
                    Text(jsonError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                field("Name (optional)") {
                    TextField("Derived from the command if left empty", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                field("Launch command") {
                    TextField(
                        "npx -y @modelcontextprotocol/server-filesystem ~/Documents",
                        text: $launchCommandText
                    )
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    Text("Paste the executable and any arguments on one line. AFM Code launches it directly over stdio, never through a shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let launchCommandError {
                        Text(launchCommandError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                field("Environment (one KEY=VALUE per line)") {
                    TextEditor(text: environmentText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if editingJSON {
                        guard applyJSON() else { return }
                    } else {
                        guard applyLaunchCommand() else { return }
                    }
                    saveDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var environmentText: Binding<String> {
        Binding(
            get: {
                draft.environment.map { "\($0.key)=\($0.value)" }
                    .sorted()
                    .joined(separator: "\n")
            },
            set: { raw in
                var environment: [String: String] = [:]
                for line in raw.split(separator: "\n") {
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty {
                        environment[key] = value
                    }
                }
                draft.environment = environment
            }
        )
    }

    private var canSave: Bool {
        if editingJSON {
            return decodedJSONServer() != nil
        }
        return (try? MCPLaunchCommand(parsing: launchCommandText)) != nil
    }

    private func switchEditorMode(isEditingJSON: Bool) {
        if isEditingJSON {
            _ = applyLaunchCommand()
            jsonText = draft.command.isEmpty ? mcpJSONScaffold : currentJSON()
            validateJSON()
        } else if applyJSON() {
            launchCommandText = MCPLaunchCommand(
                executable: draft.command,
                arguments: draft.arguments
            ).rendered
        }
    }

    @discardableResult
    private func applyLaunchCommand() -> Bool {
        do {
            let launch = try MCPLaunchCommand(parsing: launchCommandText)
            draft.command = launch.executable
            draft.arguments = launch.arguments
            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.name = launch.suggestedName
            }
            launchCommandError = nil
            return true
        } catch {
            launchCommandError = error.localizedDescription
            return false
        }
    }

    /// The standard `mcpServers` entry shape, for the JSON editor's
    /// round-trip. Concrete type: an `any Codable` dictionary can't be
    /// encoded, because the existential doesn't witness `Encodable`.
    private struct JSONForm: Encodable {
        var name: String
        var command: String
        var args: [String]
        var env: [String: String]
    }

    private func currentJSON() -> String {
        let payload = JSONForm(
            name: draft.name,
            command: draft.command,
            args: draft.arguments,
            env: draft.environment
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private func validateJSON() {
        jsonError = decodedJSONServer() == nil
            ? "Enter a valid MCP server JSON object (name, command, args, env)."
            : nil
    }

    @discardableResult
    private func applyJSON() -> Bool {
        guard let decoded = decodedJSONServer() else {
            validateJSON()
            return false
        }
        draft = decoded
        jsonError = nil
        return true
    }

    private func decodedJSONServer() -> MCPServerDraft? {
        guard let data = jsonText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MCPServerJSON.self, from: data),
              !payload.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var server = draft
        server.name = payload.name
        server.command = payload.command
        server.arguments = payload.arguments
        server.environment = payload.environment
        server.isEnabled = payload.isEnabled
        if server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            server.name = MCPLaunchCommand(executable: server.command).suggestedName
        }
        return server
    }

    private func saveDraft() {
        var final = draft
        if final.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            final.name = MCPLaunchCommand(executable: final.command).suggestedName
        }
        onSave(final)
    }
}

/// The standard `mcpServers` entry shape for JSON editing.
private struct MCPServerJSON: Decodable {
    var name: String
    var command: String
    var arguments: [String]
    var environment: [String: String]
    var isEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case command
        case arguments = "args"
        case environment = "env"
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

private let mcpJSONScaffold = """
{
  "name": "filesystem",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/directory"],
  "env": {}
}
"""

// MARK: - Launch command parsing

/// A display-friendly launch command line, resolved into an executable
/// and an argument array. Parsed directly — never run by a shell.
/// Pure value logic, so `nonisolated`: it is passed around as function
/// references (`.map(MCPLaunchCommand.render)`) from any context.
nonisolated struct MCPLaunchCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]

    enum ParseError: LocalizedError {
        case empty
        case unfinishedQuoteOrEscape

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter the command that launches the MCP server."
            case .unfinishedQuoteOrEscape:
                return "The launch command contains an unfinished quote or escape."
            }
        }
    }

    init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    init(parsing source: String) throws {
        let words = try Self.words(in: source)
        guard let executable = words.first else {
            throw ParseError.empty
        }
        self.init(executable: executable, arguments: Array(words.dropFirst()))
    }

    var rendered: String {
        ([executable] + arguments)
            .map(Self.render)
            .joined(separator: " ")
    }

    var suggestedName: String {
        let filename = URL(fileURLWithPath: executable)
            .deletingPathExtension()
            .lastPathComponent
        return filename.isEmpty ? executable : filename
    }

    static func words(in source: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var isEscaping = false
        var hasWord = false

        func finishWord() {
            guard hasWord else { return }
            words.append(word)
            word = ""
            hasWord = false
        }

        for character in source {
            if isEscaping {
                word.append(character)
                hasWord = true
                isEscaping = false
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\" && activeQuote == "\"" {
                    isEscaping = true
                } else {
                    word.append(character)
                    hasWord = true
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                hasWord = true
            case "\\":
                isEscaping = true
                hasWord = true
            default:
                if character.isWhitespace {
                    finishWord()
                } else {
                    word.append(character)
                    hasWord = true
                }
            }
        }

        guard quote == nil, !isEscaping else {
            throw ParseError.unfinishedQuoteOrEscape
        }
        finishWord()
        return words
    }

    static func render(_ word: String) -> String {
        guard !word.isEmpty else { return "\"\"" }
        let needsQuotes = word.contains {
            $0.isWhitespace || $0 == "'" || $0 == "\"" || $0 == "\\"
        }
        guard needsQuotes else { return word }
        let escaped = word
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
