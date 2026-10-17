import Foundation
import OSLog

//
//  MCPClient.swift
//  AFM Code
//
//  A minimal Model Context Protocol client for stdio servers.
//
//  The MCP stdio transport is newline-delimited JSON-RPC 2.0, so the
//  whole protocol surface this app needs — the initialize handshake,
//  tools/list (with cursor pagination), and tools/call — fits in a
//  small self-contained actor. No SDK dependency: the project's
//  package list is user-managed, and everything else about the
//  server (process, environment, lifecycle) mirrors the shell tool.
//

/// One tool reported by a server's `tools/list`.
nonisolated struct MCPToolInfo: Sendable, Equatable {
    /// The server-side tool name, e.g. "read_file".
    let name: String
    let description: String
    /// The server's `inputSchema` (a JSON Schema) as raw JSON, when
    /// one was provided.
    let inputSchema: String?
}

/// A user-presentable connection failure, with optional diagnostic
/// details (redacted, bounded stderr tail).
nonisolated struct MCPConnectionFailure: LocalizedError, Sendable, Equatable {
    let message: String
    let details: String?

    init(message: String, details: String? = nil) {
        self.message = message
        self.details = details
    }

    var errorDescription: String? { message }
}

nonisolated enum MCPClientError: LocalizedError, Sendable {
    case notConnected
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The MCP server is not connected."
        case .invalidResponse:
            return "The MCP server returned an invalid response."
        case .timedOut:
            return "The MCP server did not answer in time."
        }
    }
}

/// A JSON-RPC error returned by the server (`error` object).
nonisolated struct MCPProtocolError: LocalizedError, Sendable {
    let code: Int
    let message: String

    var errorDescription: String? {
        message.isEmpty ? "The MCP server returned an error (\(code))." : message
    }
}

/// A bounded, thread-safe ring buffer of the server's stderr, for
/// diagnostics. Keeps only the tail (a server that spews cannot grow
/// the app's memory). Nonisolated: the pipe's readability handler runs
/// on a background thread and appends directly.
nonisolated private final class MCPStderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var wasTruncated = false
    private let limit: Int

    init(limit: Int = 16_384) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit {
            data.removeFirst(data.count - limit)
            wasTruncated = true
        }
    }

    func snapshot() -> (text: String, wasTruncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self), wasTruncated)
    }
}

/// One connection to one MCP server process.
///
/// JSON-RPC messages arrive on an arbitrary thread (the pipe's
/// readability handler), so all dispatch happens on the actor; the
/// handler only captures `Data` and hops over.
actor MCPClient {
    private static let logger = Logger(subsystem: "dev.afmcode", category: "MCPClient")

    /// Protocol versions this client offers, most preferred first.
    /// The server picks whichever it supports; we accept its answer.
    private static let preferredProtocolVersion = "2025-06-18"

    private struct Connection {
        let id: UUID
        let process: Process
        let inputPipe: Pipe
        let outputPipe: Pipe
        let errorPipe: Pipe
        let stderr: MCPStderrCapture
        var buffer = Data()
        var nextID = 1
        var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
        var isReady = false
    }

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL?
    private let clientName: String
    private let clientVersion: String

    private var connection: Connection?
    private var startupFailure: MCPConnectionFailure?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        clientName: String = "AFM Code",
        clientVersion: String = "1.0"
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    var isConnected: Bool {
        connection != nil && connection?.isReady == true
    }

    // MARK: - Connection lifecycle

    /// Launch the server process and complete the MCP `initialize`
    /// handshake. Throws an `MCPConnectionFailure` with diagnostics.
    func connect() async throws {
        guard connection == nil else { return }
        do {
            try await startConnection()
            connection?.isReady = true
            startupFailure = nil
        } catch {
            let failure = await Self.failureFrom(error, stored: startupFailure, client: self)
            await tearDownConnection(preservingFailure: true)
            throw failure
        }
    }

    /// Connect and list the server's tools under one deadline, so a
    /// server that hangs during startup or the handshake fails fast
    /// instead of blocking the settings UI forever.
    func connectAndListTools(timeout: TimeInterval = 60) async throws -> [MCPToolInfo] {
        guard connection == nil else {
            return try await listTools()
        }

        return try await withTaskCancellationHandler {
            do {
                let tools = try await withThrowingTaskGroup(of: [MCPToolInfo].self) { group in
                    group.addTask {
                        try await self.connect()
                        return try await self.listTools()
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                        let failure = await self.failStartupAfterTimeout(timeout)
                        throw failure
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw MCPConnectionFailure(message: "Failed to connect to the MCP server.")
                    }
                    return result
                }

                guard connection != nil else {
                    throw startupFailure ?? MCPConnectionFailure(message: "Failed to connect to the MCP server.")
                }
                return tools
            } catch {
                if Task.isCancelled {
                    await tearDownConnection(preservingFailure: false)
                    throw CancellationError()
                }
                let failure = await Self.failureFrom(error, stored: startupFailure, client: self)
                await tearDownConnection(preservingFailure: true)
                throw failure
            }
        } onCancel: {
            Task { await self.tearDownConnection(preservingFailure: false) }
        }
    }

    private func startConnection() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let stderr = MCPStderrCapture()
        let process = Process()
        let connectionID = UUID()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory {
            try FileManager.default.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
            process.currentDirectoryURL = workingDirectory
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderr.append(chunk)
            Task { await self?.drainStderrHandle(handle) }
        }
        process.terminationHandler = { [weak self, errorPipe, stderr] process in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            stderr.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            let summary: String
            switch process.terminationReason {
            case .exit:
                summary = "The server process exited with status \(process.terminationStatus)."
            case .uncaughtSignal:
                summary = "The server process ended from signal \(process.terminationStatus)."
            @unknown default:
                summary = "The server process ended with status \(process.terminationStatus)."
            }
            Task {
                await self?.processDidTerminate(
                    connectionID: connectionID,
                    processSummary: summary
                )
            }
        }

        connection = Connection(
            id: connectionID,
            process: process,
            inputPipe: inputPipe,
            outputPipe: outputPipe,
            errorPipe: errorPipe,
            stderr: stderr
        )
        connection?.isReady = false
        startupFailure = nil

        try process.run()

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { await self?.ingest(chunk) }
        }

        // The MCP handshake: initialize (the server chooses a protocol
        // version it supports), then the initialized notification.
        let params: [String: JSONValue] = [
            "protocolVersion": .string(Self.preferredProtocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ]
        let result = try await request("initialize", params: .object(params), timeout: 30)
        if let offered = result["protocolVersion"]?.stringValue {
            let serverName = self.executableURL.lastPathComponent
            Self.logger.debug("MCP server \(serverName) speaks protocol \(offered)")
        }
        try sendNotification("notifications/initialized")
    }

    /// The server exited on its own (crash, or it was a one-shot).
    private func processDidTerminate(connectionID: UUID, processSummary: String) async {
        guard connection?.id == connectionID else { return }
        if let connection, !connection.isReady {
            startupFailure = MCPConnectionFailure(
                message: "The MCP server exited before it connected.",
                details: diagnosticDetails(leading: nil, processSummary: processSummary)
            )
        }
        failPending(with: MCPConnectionFailure(
            message: "The MCP server process ended.",
            details: nil
        ))
        await tearDownConnection(preservingFailure: startupFailure != nil)
    }

    /// Stop the server and release everything.
    func disconnect() async {
        await tearDownConnection(preservingFailure: false)
    }

    private func failPending(with failure: any Error) {
        guard var connection else { return }
        for continuation in connection.pending.values {
            continuation.resume(throwing: failure)
        }
        connection.pending.removeAll()
    }

    private func tearDownConnection(preservingFailure: Bool) async {
        let current = connection
        connection = nil
        current?.process.terminationHandler = nil
        current?.outputPipe.fileHandleForReading.readabilityHandler = nil
        current?.errorPipe.fileHandleForReading.readabilityHandler = nil
        failPendingLocal(current)
        if let process = current?.process, process.isRunning {
            process.terminate()
        }
        try? current?.inputPipe.fileHandleForWriting.close()
        try? current?.outputPipe.fileHandleForReading.close()
        try? current?.errorPipe.fileHandleForReading.close()
        if !preservingFailure {
            startupFailure = nil
        }
    }

    private func failPendingLocal(_ connection: Connection?) {
        guard let connection else { return }
        for continuation in connection.pending.values {
            continuation.resume(throwing: MCPClientError.notConnected)
        }
    }

    private func drainStderrHandle(_ handle: FileHandle) async {
        // The readability handler already drained availableData into the
        // capture; this hop exists only to let the termination path read
        // any final bytes on the actor.
        if !handle.availableData.isEmpty {
            connection?.stderr.append(handle.availableData)
        }
    }

    // MARK: - Protocol

    /// Write a request to the server and wait for its response, racing
    /// the wait against `timeout`.
    private func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        guard let current = connection, current.isReady else {
            throw MCPClientError.notConnected
        }
        let id = current.nextID
        connection?.nextID = id + 1

        var message: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params {
            message["params"] = params
        }
        guard let data = try? JSONEncoder().encode(message) else {
            throw MCPClientError.invalidResponse
        }
        var line = data
        line.append(0x0A)
        current.inputPipe.fileHandleForWriting.write(line)

        return try await Self.withTimeout(timeout) {
            try await self.waitForResponse(id: id)
        }
    }

    /// Block until the response for a request already written to the
    /// pipe. If the enclosing task is cancelled (a timeout, or the
    /// caller's), the pending slot is removed so a late response
    /// cannot leak a continuation.
    private func waitForResponse(id: Int) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                connection?.pending[id] = continuation
            }
        } onCancel: {
            Task { await self.removePending(id) }
        }
    }

    private func removePending(_ id: Int) async {
        if let continuation = connection?.pending.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Send a notification (no response expected).
    private func sendNotification(_ method: String) throws {
        guard let current = connection else { return }
        let message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        guard let data = try? JSONEncoder().encode(message) else { return }
        var line = data
        line.append(0x0A)
        current.inputPipe.fileHandleForWriting.write(line)
    }

    /// Ingest a chunk of the server's stdout, splitting on newlines
    /// and dispatching complete JSON-RPC messages.
    private func ingest(_ chunk: Data) {
        guard connection != nil else { return }
        connection?.buffer.append(chunk)
        while let newline = connection?.buffer.firstIndex(of: 0x0A) {
            guard var connection else { return }
            let lineData = connection.buffer.prefix(upTo: newline)
            connection.buffer.removeSubrange(
                lineData.startIndex...connection.buffer.index(after: newline)
            )
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                dispatch(line)
            }
        }
    }

    private func dispatch(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(RPCMessage.self, from: data)
        else {
            Self.logger.debug("MCP: undecodable line: \(line.prefix(200))")
            return
        }

        if let id = message.id {
            if let continuation = connection?.pending.removeValue(forKey: id) {
                if let error = message.error {
                    continuation.resume(throwing: MCPProtocolError(code: error.code, message: error.message))
                } else if let result = message.result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: MCPClientError.invalidResponse)
                }
            } else if message.method == "ping" {
                // Server-originated pings get an empty object back.
                let reply: [String: JSONValue] = [
                    "jsonrpc": .string("2.0"),
                    "id": .number(Double(id)),
                    "result": .object([:]),
                ]
                if let data = try? JSONEncoder().encode(reply) {
                    var line = data
                    line.append(0x0A)
                    connection?.inputPipe.fileHandleForWriting.write(line)
                }
            }
        } else if message.method == "notifications/tools/list_changed" {
            Self.logger.debug("MCP: tools changed; refresh from settings to pick up the new list")
        }
    }

    // MARK: - MCP methods

    /// `tools/list`, following the server's cursor until exhausted.
    func listTools() async throws -> [MCPToolInfo] {
        guard isConnected else { throw MCPClientError.notConnected }

        var infos: [MCPToolInfo] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor {
                params["cursor"] = .string(cursor)
            }
            let result = try await request("tools/list", params: .object(params), timeout: 30)
            let tools = result["tools"]?.arrayValue ?? []
            for tool in tools {
                let name = tool["name"]?.stringValue ?? ""
                guard !name.isEmpty else { continue }
                let description = tool["description"]?.stringValue ?? ""
                let schema = tool["inputSchema"].flatMap { value -> String? in
                    guard let data = try? JSONEncoder().encode(value) else { return nil }
                    return String(data: data, encoding: .utf8)
                }
                infos.append(MCPToolInfo(name: name, description: description, inputSchema: schema))
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil

        return infos
    }

    /// `tools/call`. Returns the rendered result text; a server-reported
    /// `isError` becomes a thrown `MCPToolFailure`.
    func callTool(name: String, argumentsJSON: String?, timeout: TimeInterval = 120) async throws -> String {
        guard isConnected else { throw MCPClientError.notConnected }

        var params: [String: JSONValue] = ["name": .string(name)]
        if let argumentsJSON, !argumentsJSON.isEmpty,
           let data = argumentsJSON.data(using: .utf8),
           let arguments = try? JSONDecoder().decode(JSONValue.self, from: data) {
            params["arguments"] = arguments
        }
        let requestParams = params

        let result = try await Self.withTimeout(timeout) {
            try await self.request("tools/call", params: .object(requestParams), timeout: timeout)
        }

        let rendered = Self.render(result)
        if result["isError"]?.boolValue == true {
            throw MCPToolFailure(message: rendered)
        }
        return rendered
    }

    /// A tool that ran and reported an error result.
    struct MCPToolFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// MCP content items as model-readable text: text verbatim, images
    /// and resources as placeholders.
    static func render(_ result: JSONValue) -> String {
        let items = result["content"]?.arrayValue ?? []
        return items.compactMap { item -> String? in
            let type = item["type"]?.stringValue
            switch type {
            case "text":
                return item["text"]?.stringValue ?? ""
            case "image":
                return "[image: \(item["mimeType"]?.stringValue ?? "unknown")]"
            case "resource":
                if let embedded = item["resource"]?["text"]?.stringValue, !embedded.isEmpty {
                    return embedded
                }
                return "[resource: \(item["resource"]?["uri"]?.stringValue ?? "unknown")]"
            default:
                return "[unsupported content]"
            }
        }
        .joined(separator: "\n")
    }

    // MARK: - Diagnostics

    private func failStartupAfterTimeout(_ timeout: TimeInterval) async -> MCPConnectionFailure {
        let seconds = max(1, Int(timeout.rounded(.up)))
        let failure = MCPConnectionFailure(
            message: "The MCP server didn't connect within \(seconds) second\(seconds == 1 ? "" : "s").",
            details: diagnosticDetails()
        )
        startupFailure = failure
        await tearDownConnection(preservingFailure: true)
        return failure
    }

    private static func failureFrom(_ error: any Error, stored: MCPConnectionFailure?, client: MCPClient) async -> MCPConnectionFailure {
        if let stored {
            return stored
        }
        if let failure = error as? MCPConnectionFailure {
            return failure
        }
        if error is CancellationError {
            return MCPConnectionFailure(message: "The connection was cancelled.")
        }
        let description = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MCPConnectionFailure(
            message: "Failed to connect to the MCP server.",
            details: await client.diagnosticDetails(leading: description)
        )
    }

    func diagnosticDetails(leading: String? = nil, processSummary: String? = nil) -> String? {
        var sections = [leading, processSummary].compactMap { output -> String? in
            guard let output, !output.isEmpty else { return nil }
            let redacted = Self.redactedDiagnosticOutput(output, arguments: arguments, environment: environment)
            return redacted.isEmpty ? nil : redacted
        }

        if let capture = connection?.stderr {
            let snapshot = capture.snapshot()
            let output = Self.redactedDiagnosticOutput(snapshot.text, arguments: arguments, environment: environment)
            if !output.isEmpty {
                let prefix = snapshot.wasTruncated ? "Earlier server output was truncated.\n" : ""
                sections.append(prefix + output)
            }
        }

        let details = sections.joined(separator: "\n\n")
        return details.isEmpty ? nil : details
    }

    /// Mask values that look like credentials (token-ish env values and
    /// bearer arguments) before any diagnostic text is surfaced.
    static func redactedDiagnosticOutput(
        _ output: String,
        arguments: [String],
        environment: [String: String]
    ) -> String {
        let sensitiveKeyFragments = ["TOKEN", "KEY", "SECRET", "PASSWORD", "AUTH", "CREDENTIAL", "PRIVATE"]
        var secretValues = environment.compactMap { key, value -> String? in
            guard value.count >= 4 else { return nil }
            let normalized = key.uppercased()
            return sensitiveKeyFragments.contains(where: normalized.contains) ? value : nil
        }

        for argument in arguments {
            guard let bearerRange = argument.range(of: "bearer ") else { continue }
            if let value = argument[bearerRange.upperBound...]
                .split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
                .first,
               value.count >= 4 {
                secretValues.append(String(value))
            }
        }

        var result = output
        for secret in Set(secretValues).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }

        // Keep only the tail: the newest lines are the useful ones.
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.suffix(12).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Timeout

    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw MCPClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MCPClientError.timedOut
            }
            return result
        }
    }
}

// MARK: - JSON-RPC wire types

/// A JSON-RPC 2.0 message as received from the server (responses and
/// server-originated requests; notifications have no `id`).
nonisolated private struct RPCMessage: Decodable {
    let id: Int?
    let method: String?
    let result: JSONValue?
    let error: RPCError?
}

nonisolated private struct RPCError: Decodable {
    let code: Int
    let message: String
    let data: JSONValue?
}

/// A dynamic JSON value, for schemas and payloads whose shape is only
/// known at runtime (server capabilities, tool schemas, call results).
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let value) = self { return value[key] }
        return nil
    }
}

extension JSONValue {
    init(_ bool: Bool) { self = .bool(bool) }
    init(_ number: Double) { self = .number(number) }
    init(_ string: String) { self = .string(string) }
    init(_ array: [JSONValue]) { self = .array(array) }
    init(_ object: [String: JSONValue]) { self = .object(object) }
}
