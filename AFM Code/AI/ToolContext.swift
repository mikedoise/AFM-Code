import Foundation
import Observation

/// The per-session runtime that the coding tools use.
///
/// Tools are plain structs, so their per-session state lives here: the
/// project folder (via `Workspace`), the approval service, and the live
/// tool steps surfaced in the chat. Every file and shell operation is
/// sandboxed to the project root — nothing in here can touch anything
/// outside it.
@MainActor
@Observable
final class ToolContext {
    let session: ChatSession
    let workspace: Workspace
    let approvals: ToolApprovalService

    /// Steps for the in-flight turn, in call order.
    private(set) var steps: [ToolStep] = []
    private var isTurnActive = false

    init(session: ChatSession, workspace: Workspace, approvals: ToolApprovalService) {
        self.session = session
        self.workspace = workspace
        self.approvals = approvals
    }

    // MARK: - Turn lifecycle

    func beginTurn() {
        steps.removeAll()
        isTurnActive = true
        approvals.reset()
    }

    func endTurn() {
        isTurnActive = false
    }

    /// Snapshot of this turn's steps, for persisting on the message.
    var turnSteps: [ToolStep] { steps }

    /// Whether the project folder is reachable right now.
    var canOperate: Bool {
        workspace.status == .active && workspace.folderURL != nil
    }

    // MARK: - Step bookkeeping

    @discardableResult
    func beginStep(
        kind: ToolStep.Kind,
        toolName: String,
        title: String,
        status: ToolStep.Status,
        diff: DiffData? = nil,
        command: String? = nil
    ) -> UUID {
        var step = ToolStep(kind: kind, toolName: toolName, title: title, status: status)
        step.diff = diff
        step.command = command
        steps.append(step)
        return step.id
    }

    func updateStep(
        _ id: UUID,
        status: ToolStep.Status? = nil,
        title: String? = nil,
        summary: String? = nil,
        detail: String? = nil,
        diff: DiffData? = nil,
        command: String? = nil
    ) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        if let status { steps[index].status = status }
        if let title { steps[index].title = title }
        if let summary { steps[index].summary = summary }
        if let detail { steps[index].detail = Self.capped(detail) }
        if let diff { steps[index].diff = diff }
        if let command { steps[index].command = command }
    }

    /// UI detail payloads are capped so persisted history stays light.
    private static func capped(_ text: String, limit: Int = 24_000) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit) + "\n… (truncated)"
    }

    // MARK: - Errors

    enum ToolError: LocalizedError {
        case folderUnavailable
        case pathEscape(String)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .folderUnavailable:
                return "The project folder is not available right now. The user may need to re-connect it in the project pane."
            case .pathEscape(let path):
                return "Refused: that path is outside the project folder (\(path))."
            case .io(let message):
                return message
            }
        }
    }

    // MARK: - Path sandbox

    /// The project root, when the folder is reachable.
    var rootURL: URL? {
        guard canOperate else { return nil }
        return workspace.folderURL
    }

    /// Resolve a model/user-supplied path to a URL, refusing anything
    /// that would escape the project root (collapses `..`, etc.).
    func resolvePath(_ path: String) throws -> URL {
        guard let root = rootURL else { throw ToolError.folderUnavailable }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.io("No path given.") }
        let candidate = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : root.appendingPathComponent(trimmed)
        let resolved = candidate.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            throw ToolError.pathEscape(path)
        }
        return resolved
    }

    /// True when `url` is the project root or inside it.
    func isInsideRoot(_ url: URL) -> Bool {
        guard let root = rootURL else { return false }
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    // MARK: - File operations
    //
    // These run on the main actor under the workspace's security-scoped
    // lease. They throw `ToolError`; tools convert failures into
    // model-readable strings rather than aborting the turn.

    struct ReadResult {
        var output: String
        var lineCount: Int
        var truncated: Bool
    }

    private static let maxReadBytes = 64 * 1024
    private static let maxReadLines = 2000

    func readFile(path: String, startLine: Int?, maxLines: Int?) throws -> ReadResult {
        let url = try resolvePath(path)
        guard let result = try workspace.withAccess({ _ in
            try Self.readCappedText(at: url, startLine: startLine, maxLines: maxLines, displayPath: path)
        }) else {
            throw ToolError.folderUnavailable
        }
        return result
    }

    private static func readCappedText(
        at url: URL,
        startLine: Int?,
        maxLines: Int?,
        displayPath: String
    ) throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.io("No such file: \(displayPath)")
        }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else {
            throw ToolError.io("That path is a directory: \(displayPath)")
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ToolError.io("Could not open \(displayPath).")
        }
        defer { try? handle.close() }

        var data = Data()
        while data.count < maxReadBytes {
            let toRead = min(65_536, maxReadBytes - data.count)
            guard let chunk = try? handle.read(upToCount: toRead), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        let byteTruncated = data.count >= maxReadBytes

        guard var text = String(data: data, encoding: .utf8) else {
            throw ToolError.io("Not a UTF-8 text file: \(displayPath)")
        }
        if byteTruncated { text.removeLast() } // don't split a line at the cap

        let allLines = text.components(separatedBy: "\n")
        let total = allLines.count
        let start = max(1, startLine ?? 1)
        let limit = min(maxLines ?? 500, maxReadLines)
        let end = min(start + limit - 1, total)

        let width = max(4, "\(total)".count)
        let shown = allLines[(start - 1)..<end].enumerated().map { index, line in
            String(format: "%@\t%@", String(format: "%\(width)d", start + index), line)
        }

        return ReadResult(
            output: shown.joined(separator: "\n"),
            lineCount: end - start + 1,
            truncated: byteTruncated || end < total
        )
    }

    /// The file's text content (capped), or `nil` when it doesn't exist.
    func readFileContent(path: String, maxLines: Int = 4000) throws -> String? {
        let url = try resolvePath(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let content = try? workspace.withAccess({ _ -> String in
            try String(contentsOf: url, encoding: .utf8)
        }) else {
            return nil
        }
        let lines = content.components(separatedBy: "\n")
        guard lines.count > maxLines else { return content }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    func writeFile(path: String, content: String) throws -> String {
        let url = try resolvePath(path)
        guard let summary = try workspace.withAccess({ _ in
            try Self.writeText(url: url, content: content, displayPath: path)
        }) else {
            throw ToolError.folderUnavailable
        }
        return summary
    }

    private static func writeText(url: URL, content: String, displayPath: String) throws -> String {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(content.utf8.count) bytes to \(displayPath)."
    }

    func editFile(path: String, find: String, replace: String, replaceAll: Bool) throws -> String {
        let url = try resolvePath(path)
        guard let summary = try workspace.withAccess({ _ in
            try Self.applyEdit(url: url, find: find, replace: replace, replaceAll: replaceAll, displayPath: path)
        }) else {
            throw ToolError.folderUnavailable
        }
        return summary
    }

    private static func applyEdit(
        url: URL,
        find: String,
        replace: String,
        replaceAll: Bool,
        displayPath: String
    ) throws -> String {
        guard !find.isEmpty else {
            throw ToolError.io("The search text is empty.")
        }
        guard let current = try? String(contentsOf: url, encoding: .utf8) else {
            throw ToolError.io("Could not read \(displayPath). Check the path and try again.")
        }
        let count = current.components(separatedBy: find).count - 1
        guard count > 0 else {
            throw ToolError.io("The search text does not appear in \(displayPath). Re-read the file — it may have changed since you last saw it.")
        }
        guard count == 1 || replaceAll else {
            throw ToolError.io("The search text appears \(count) times in \(displayPath). Make it more specific (include surrounding lines) or set replaceAll to true.")
        }
        let updated = current.replacingOccurrences(of: find, with: replace)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        let what = count == 1 ? "1 replacement" : "\(count) replacements"
        return "Edited \(displayPath) (\(what))."
    }

    // MARK: - Diff previews (for pending write/edit steps)

    func previewDiffForWrite(path: String, newContent: String) -> DiffData {
        let relative = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLines = Array(newContent.components(separatedBy: "\n").prefix(4000))
        let oldLines: [String]
        if let existing = try? readFileContent(path: path) {
            let lines = existing.components(separatedBy: "\n")
            oldLines = Array(lines.prefix(4000))
        } else {
            oldLines = []
        }
        return LineDiff.compute(path: relative, old: oldLines, new: newLines)
    }

    func previewDiffForEdit(path: String, find: String, replace: String, replaceAll: Bool) -> DiffData {
        let relative = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldLines: [String]
        if let current = try? readFileContent(path: path) {
            oldLines = Array(current.components(separatedBy: "\n").prefix(4000))
        } else {
            oldLines = []
        }
        let updated = oldLines.joined(separator: "\n").replacingOccurrences(of: find, with: replace)
        let newLines = Array(updated.components(separatedBy: "\n").prefix(4000))
        if oldLines == newLines {
            return DiffData(
                path: relative,
                isNewFile: false,
                lines: [DiffData.Line(kind: .context, text: "(no changes)")],
                truncated: false
            )
        }
        return LineDiff.compute(path: relative, old: oldLines, new: newLines)
    }

    // MARK: - Directory listing

    private static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".gradle", "Pods", ".swiftpm", "build"
    ]

    func listDirectory(path: String, maxDepth: Int) throws -> String {
        guard let root = rootURL else { throw ToolError.folderUnavailable }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: URL
        if trimmed.isEmpty {
            target = root
        } else if let resolved = try? resolvePath(path), isInsideRoot(resolved) {
            target = resolved
        } else {
            throw ToolError.pathEscape(path)
        }

        let depth = min(max(1, maxDepth), 4)
        let output: String? = workspace.withAccess({ _ in
            var lines: [String] = []
            var entries = 0
            Self.walk(
                target, depth: 0, maxDepth: depth,
                lines: &lines, counter: &entries
            )
            if lines.isEmpty {
                return "Empty directory: \(trimmed.isEmpty ? "." : trimmed)"
            }
            if entries >= Self.maxListEntries {
                lines.append("… (listing truncated)")
            }
            return lines.joined(separator: "\n")
        })
        guard let output else { throw ToolError.folderUnavailable }
        return output
    }

    private static let maxListEntries = 200

    private static func walk(
        _ url: URL,
        depth: Int,
        maxDepth: Int,
        lines: inout [String],
        counter: inout Int
    ) {
        guard depth < maxDepth, counter < maxListEntries,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        let indent = String(repeating: "  ", count: depth)
        let sorted = contents.sorted { lhs, rhs in
            let lhsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rhsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if lhsDir != rhsDir { return lhsDir } // directories first
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }

        for entry in sorted {
            guard counter < maxListEntries else {
                counter = maxListEntries
                return
            }
            counter += 1
            let name = entry.lastPathComponent
            if let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                if skippedDirectories.contains(name) { continue }
                lines.append("\(indent)\(name)/")
                walk(entry, depth: depth + 1, maxDepth: maxDepth, lines: &lines, counter: &counter)
            } else {
                lines.append("\(indent)\(name)")
            }
        }
    }

    // MARK: - Shell
    //
    // Search and run_command both execute through a login shell with the
    // project root as cwd, under the workspace lease, with a hard timeout.
    // Output is drained into bounded captures so a chatty (or grandchild-
    // holding) process can never block the turn.

    struct ProcessRun {
        var exitCode: Int32
        var output: String
        var timedOut: Bool
    }

    /// Hold the security-scoped lease for the duration of async work
    /// (a lease is a URL-level permission, so it stays valid across the
    /// await for the child process).
    private func withLease<T>(_ operation: () async throws -> T) async rethrows -> T? {
        guard workspace.acquireLease() else { return nil }
        defer { workspace.releaseLease() }
        return try await operation()
    }

    func search(pattern: String, path: String? = nil) async throws -> String {
        guard let root = rootURL else { throw ToolError.folderUnavailable }
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target: URL
        if !trimmedPath.isEmpty {
            let resolved = try resolvePath(trimmedPath)
            guard isInsideRoot(resolved) else { throw ToolError.pathEscape(trimmedPath) }
            target = resolved
        } else {
            target = root
        }

        let searchPath = target.standardizedFileURL == root.standardizedFileURL ? "." : target.path
        let rg = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let command: String
        if let rg {
            command = "\(rg) -n --no-heading --max-count 50 -- \(Self.shellQuote(pattern)) \(Self.shellQuote(searchPath))"
        } else {
            command = "grep -rn --binary-files=no-match -- \(Self.shellQuote(pattern)) \(Self.shellQuote(searchPath))"
        }

        let result = try await withLease {
            try await Self.runProcess(
                arguments: ["-lc", command],
                workingDirectory: root,
                timeout: 15,
                maxOutputBytes: 16 * 1024
            )
        }
        guard let run = result else { throw ToolError.folderUnavailable }

        let lines = run.output.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            return "No matches for \(pattern) in \(searchPath)."
        }
        let shown = lines.prefix(40).map(String.init).joined(separator: "\n")
        let extra = lines.count - min(lines.count, 40)
        return "Found \(lines.count) matching line\(lines.count == 1 ? "" : "s"):\n\(shown)" + (extra > 0 ? "\n… (\(extra) more matches)" : "")
    }

    func runCommand(command: String, timeout: Double) async throws -> ProcessRun {
        guard let root = rootURL else { throw ToolError.folderUnavailable }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.io("Empty command.") }
        let run = try await withLease {
            try await Self.runProcess(
                arguments: ["-lc", trimmed],
                workingDirectory: root,
                timeout: min(max(timeout, 1), 300),
                maxOutputBytes: 16 * 1024
            )
        }
        guard let run else { throw ToolError.folderUnavailable }
        return run
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A bounded, lock-protected sink for pipe output.
    nonisolated private final class PipedCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int
        private var finished = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            lock.withLock {
                guard data.count < limit else { return }
                data.append(chunk.prefix(limit - data.count))
            }
        }

        var snapshot: Data {
            lock.withLock { data }
        }

        var isFinished: Bool {
            lock.withLock { finished }
        }

        func finish() {
            lock.withLock { finished = true }
        }
    }

    /// Run a shell command with a hard timeout and capped output.
    nonisolated static func runProcess(
        arguments: [String],
        workingDirectory: URL,
        timeout: Double,
        maxOutputBytes: Int
    ) async throws -> ProcessRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ToolError.io("Could not start the command: \(error.localizedDescription)")
        }

        let stdoutBox = PipedCapture(limit: maxOutputBytes)
        let stderrBox = PipedCapture(limit: max(maxOutputBytes / 2, 4096))
        // The drains run on; they finish at pipe EOF. A surviving
        // grandchild may hold the pipe open — harmless: the drain just
        // blocks until that process exits.
        _ = Task.detached { Self.drain(stdoutPipe, into: stdoutBox) }
        _ = Task.detached { Self.drain(stderrPipe, into: stderrBox) }

        var timedOut = false
        do {
            try await Task.sleep(for: .seconds(timeout))
        } catch {
            // The surrounding task was cancelled — clean up and bail.
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        // Give the drains a short grace period, then take what we have.
        // (A surviving grandchild could otherwise hold the pipe open.)
        for _ in 0..<20 {
            if stdoutBox.isFinished && stderrBox.isFinished { break }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break // cancelled — take the snapshot immediately
            }
        }

        var output = String(decoding: stdoutBox.snapshot, as: UTF8.self)
        let stderr = String(decoding: stderrBox.snapshot, as: UTF8.self)
        if !stderr.isEmpty {
            output += (output.isEmpty ? "" : "\n") + stderr
        }

        return ProcessRun(
            exitCode: process.terminationStatus,
            output: output,
            timedOut: timedOut
        )
    }

    /// Read a pipe until EOF, appending into the capture (capped).
    nonisolated private static func drain(_ pipe: Pipe, into box: PipedCapture) {
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            box.append(chunk)
            if chunk.isEmpty { break } // EOF
        }
        box.finish()
    }

    // MARK: - Formatting helpers

    /// One line the model sees when a change or command was denied.
    nonisolated static func denialMessage(detail: String) -> String {
        "The user declined this: \(detail). Do not retry the same change or command. Acknowledge the decline and ask how they'd like to proceed instead."
    }
}
