import Foundation
import Observation
import OSLog

/// The per-session runtime that the coding tools use.
///
/// Tools are plain structs, so their per-session state lives here: the
/// project folder (via `Workspace`), the approval service, and the live
/// tool steps surfaced in the chat. File paths are checked against the
/// project root by the file APIs. Approved shell commands
/// use that root as their working directory; their access is limited by the
/// normal macOS account permissions, not by the working directory alone.
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
        logFileChangeStatus(step)
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
        if status != nil { logFileChangeStatus(steps[index]) }
    }

    // File diagnostics contain only generated IDs, fixed lifecycle labels and
    // error codes. Never log paths, contents, arguments, diffs or descriptions.
    private static let fileLogger = Logger(subsystem: "dev.afmcode", category: "FileChanges")
    enum FileChangePhase: String { case preparation, apply }

    private func logFileChangeStatus(_ step: ToolStep) {
        guard step.kind == .write || step.kind == .edit else { return }
        Self.fileLogger.notice("File change id=\(step.id.uuidString, privacy: .public) kind=\(step.kind.rawValue, privacy: .public) status=\(step.status.rawValue, privacy: .public)")
    }

    func recordFileChangeFailure(_ id: UUID, phase: FileChangePhase, error: any Error) {
        let code = Self.fileChangeFailureCode(error)
        Self.fileLogger.error("File change id=\(id.uuidString, privacy: .public) phase=\(phase.rawValue, privacy: .public) reason=\(code, privacy: .public)")
    }

    static func fileChangeFailureCode(_ error: any Error) -> String {
        if let error = error as? PreparedFileChange.ChangeError {
            switch error {
            case .tooLarge: return "review_limit"
            case .invalidFile: return "invalid_file_type"
            case .invalidUTF8: return "invalid_utf8"
            case .missingFile: return "missing_file"
            case .emptySearch: return "empty_search"
            case .noMatch: return "no_match"
            case .ambiguous: return "ambiguous_match"
            case .stale: return "stale_preview"
            }
        }
        if let error = error as? ToolError {
            switch error {
            case .folderUnavailable: return "folder_unavailable"
            case .pathEscape: return "outside_project"
            case .io: return "path_or_io"
            }
        }
        if error is CancellationError { return "cancelled" }
        let failure = error as NSError
        switch failure.domain {
        case NSCocoaErrorDomain: return "cocoa_\(failure.code)"
        case NSPOSIXErrorDomain: return "posix_\(failure.code)"
        default: return "other"
        }
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
        guard isInsideRoot(resolved) else {
            throw ToolError.pathEscape(path)
        }
        return resolved
    }

    /// True when `url` is the project root or inside it.
    func isInsideRoot(_ url: URL) -> Bool {
        guard let root = rootURL else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
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
        let limit = min(max(0, maxLines ?? 500), maxReadLines)
        guard start <= total, limit > 0 else {
            return ReadResult(output: "", lineCount: 0, truncated: byteTruncated || (limit == 0 && start <= total))
        }
        // Subtract before adding: model-supplied Int.max must not overflow.
        let end = start - 1 + min(limit, total - (start - 1))

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

    /// Whether a file or directory exists at a path inside the project.
    /// `false` when the path is missing or the folder is unavailable.
    func fileExists(_ path: String) -> Bool {
        guard let url = try? resolvePath(path) else { return false }
        return workspace.withAccess { _ in
            FileManager.default.fileExists(atPath: url.path)
        } ?? false
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
        let limit = max(0, maxLines)
        guard lines.count > limit else { return content }
        return lines.prefix(limit).joined(separator: "\n")
    }

    // MARK: - Immutable, full-file change proposals

    private func changeSnapshot(path: String) throws -> PreparedFileChange.Snapshot {
        let url = try resolvePath(path)
        guard let snapshot = try workspace.withAccess({ root in
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            let target = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard target.hasPrefix(canonicalRoot + "/") else { throw ToolError.pathEscape(path) }
            return try PreparedFileChange.Snapshot.read(at: url)
        }) else { throw ToolError.folderUnavailable }
        return snapshot
    }

    func prepareWrite(path: String, content: String) async throws -> PreparedFileChange {
        let snapshot = try changeSnapshot(path: path)
        return try await Task.detached(priority: .userInitiated) {
            try PreparedFileChange.write(snapshot: snapshot, path: path, content: content)
        }.value
    }

    func prepareEdit(path: String, find: String, replace: String, replaceAll: Bool) async throws -> PreparedFileChange {
        let snapshot = try changeSnapshot(path: path)
        return try await Task.detached(priority: .userInitiated) {
            try PreparedFileChange.edit(snapshot: snapshot, path: path, find: find, replace: replace, replaceAll: replaceAll)
        }.value
    }

    func applyChange(_ change: PreparedFileChange) throws -> String {
        try Task.checkCancellation()
        guard let summary = try workspace.withAccess({ root in
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            let target = change.snapshot.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard target.hasPrefix(canonicalRoot + "/") else { throw ToolError.pathEscape(change.diff.path) }
            return try change.apply()
        }) else { throw ToolError.folderUnavailable }
        return summary
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
                root: root.resolvingSymlinksInPath().standardizedFileURL,
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
        root: URL,
        lines: inout [String],
        counter: inout Int
    ) {
        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalPath == root.path || canonicalPath.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { return }
        guard depth < maxDepth, counter < maxListEntries,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
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
            // Display links, but never recursively follow them (including cycles).
            if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                lines.append("\(indent)\(name) → (symbolic link)")
                continue
            }
            if let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                if skippedDirectories.contains(name) { continue }
                lines.append("\(indent)\(name)/")
                walk(entry, depth: depth + 1, maxDepth: maxDepth, root: root, lines: &lines, counter: &counter)
            } else {
                lines.append("\(indent)\(name)")
            }
        }
    }

    // MARK: - Shell
    //
    // Search and run_command execute through a non-login command shell with the
    // already captured/augmented environment and project root as cwd, under
    // the workspace lease, with a hard timeout. A second login initialization
    // would undo PATH augmentation and select sandbox-hostile xcrun shims.
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
            command = "\(rg) --no-config -n --no-heading --max-count 50 -- \(Self.shellQuote(pattern)) \(Self.shellQuote(searchPath))"
        } else {
            command = "grep -rn --binary-files=no-match -- \(Self.shellQuote(pattern)) \(Self.shellQuote(searchPath))"
        }

        let environment = Self.readOnlyEnvironment(ShellEnvironment.inspectionSnapshot().environment)
        let result = try await withLease {
            try await Self.runProcess(
                arguments: ["-f", "-c", command],
                workingDirectory: root,
                timeout: 15,
                maxOutputBytes: 16 * 1024,
                environment: environment
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

    /// Built-in read helpers must not run user startup files or inherit
    /// arbitrary execution hooks from login exports. They use trusted system/
    /// developer command locations; approved run_command retains the host PATH.
    nonisolated static func readOnlyEnvironment(_ base: [String: String]) -> [String: String] {
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL"] {
            if let value = base[key] { env[key] = value }
        }
        if let developer = ShellEnvironment.developerUSRBIN() { env["PATH"] = developer + ":" + env["PATH"]! }
        return env
    }

    func runReadOnlyCommand(command: String, timeout: Double) async throws -> ProcessRun {
        guard let root = rootURL else { throw ToolError.folderUnavailable }
        let environment = Self.readOnlyEnvironment(ShellEnvironment.inspectionSnapshot().environment)
        let result = try await withLease {
            try await Self.runProcess(arguments: ["-f", "-c", command], workingDirectory: root,
                timeout: timeout, maxOutputBytes: 16 * 1024, environment: environment)
        }
        guard let result else { throw ToolError.folderUnavailable }
        return result
    }

    func runCommand(command: String, timeout: Double) async throws -> ProcessRun {
        guard let root = rootURL else { throw ToolError.folderUnavailable }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.io("Empty command.") }
        let environment = Self.commandEnvironment(await ShellEnvironment.resolved() ?? ProcessInfo.processInfo.environment)
        let run = try await withLease {
            try await Self.runProcess(
                arguments: ["-c", trimmed],
                workingDirectory: root,
                timeout: min(max(timeout, 1), 300),
                maxOutputBytes: 16 * 1024,
                environment: environment
            )
        }
        guard let run else { throw ToolError.folderUnavailable }
        return run
    }

    /// Probe the exact displayed executable with the same captured environment
    /// used for discovery. Caller owns approval; raw output is never persisted.
    func runEnvironmentProbe(command: String, environment: [String: String]) async throws -> ProcessRun {
        guard let root = rootURL else { throw ToolError.folderUnavailable }
        var env = Self.commandEnvironment(environment)
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"
        let result = try await withLease {
            try await Self.runProcess(arguments: ["-c", command], workingDirectory: root,
                timeout: 10, maxOutputBytes: 4096, environment: env)
        }
        guard let result else { throw ToolError.folderUnavailable }
        return result
    }

    /// Commands have no interactive input. Respect explicit user settings,
    /// but otherwise let Git report missing terminal credentials promptly.
    nonisolated static func commandEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        if environment["GIT_TERMINAL_PROMPT"] == nil { environment["GIT_TERMINAL_PROMPT"] = "0" }
        return environment
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A bounded pipe sink drained only by the command task.
    nonisolated private final class PipedCapture: @unchecked Sendable {
        private(set) var data = Data()
        private let limit: Int
        private(set) var isFinished = false

        init(limit: Int) { self.limit = max(0, limit) }
        var snapshot: Data { data }

        // Nonblocking, bounded work per poll: neither a quiet descendant nor
        // an endlessly writing command can prevent timeout/cancellation checks.
        func drain(_ descriptor: Int32) {
            guard !isFinished else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(min(count, max(0, limit - data.count))))
                } else if count == 0 {
                    isFinished = true
                    return
                } else if errno != EINTR {
                    if errno != EAGAIN && errno != EWOULDBLOCK { isFinished = true }
                    return
                }
            }
        }
    }

    /// Run in an isolated process group with closed stdin and capped output.
    /// Preserve the captured terminal environment and requested working directory.
    /// Background jobs belong to this invocation, and are stopped when it ends.
    nonisolated static func runProcess(
        arguments: [String],
        workingDirectory: URL,
        timeout: Double,
        maxOutputBytes: Int,
        environment: [String: String]? = nil
    ) async throws -> ProcessRun {
        try Task.checkCancellation()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func checked(_ code: Int32) throws {
            guard code == 0 else {
                throw ToolError.io("Could not start the command: \(String(cString: strerror(code)))")
            }
        }
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // Raw spawn must not expose unrelated app descriptors to commands.
        // The explicit open/dup2 actions below preserve only command stdio.
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        // Group 0 here means the new child's own PID, not our process group.
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        if #available(macOS 26.0, *) {
            try checked(posix_spawn_file_actions_addchdir(&actions, workingDirectory.path))
        } else {
            try checked(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path))
        }
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try checked(posix_spawn_file_actions_adddup2(&actions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
        for fd in [stdoutFD, stderrFD, stdoutPipe.fileHandleForWriting.fileDescriptor, stderrPipe.fileHandleForWriting.fileDescriptor] {
            try checked(posix_spawn_file_actions_addclose(&actions, fd))
        }
        for fd in [stdoutFD, stderrFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw ToolError.io("Could not configure command output pipes.")
            }
        }
        let argv = (["/bin/zsh"] + arguments).map { strdup($0) } + [nil]
        let envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let spawnError = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envBuffer in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argvBuffer.baseAddress!, envBuffer.baseAddress!)
            }
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try checked(spawnError)
        // Keep the leader unreaped until after the final group signal. Its PID
        // therefore cannot be recycled as an unrelated process/group identifier.
        var reaped = false
        defer {
            if !reaped && pid > 0 {
                kill(-pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        let stdoutBox = PipedCapture(limit: maxOutputBytes)
        let stderrBox = PipedCapture(limit: max(maxOutputBytes / 2, 4096))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var timedOut = false
        while true {
            stdoutBox.drain(stdoutFD)
            stderrBox.drain(stderrFD)
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result < 0 && errno != EINTR {
                let error = errno
                // If another reaper removed our child, its PID is no longer
                // reserved. Never signal a potentially recycled group ID.
                if error == ECHILD { reaped = true }
                throw ToolError.io("Could not inspect command status: \(String(cString: strerror(error)))")
            }
            if result == 0 && info.si_pid == pid { break }
            if Task.isCancelled { break }
            if clock.now >= deadline { timedOut = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Stop every ordinary shell/subshell/ssh/git descendant, including ones
        // ignoring TERM or keeping output open after the shell itself exits.
        // Deliberately detached sessions are outside a process group's scope.
        // Termination is not rollback: partial writes and Git lock files may
        // remain. Inspect them before retrying; never remove locks automatically.
        if pid > 0 { kill(-pid, SIGKILL) }
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited < 0 && errno == EINTR
        reaped = true
        guard waited == pid else { throw ToolError.io("Could not collect command exit status.") }
        // Drains never block or outlive this call, even if a detached process
        // inherited a pipe. Preserve buffered diagnostics before returning.
        let drainDeadline = clock.now.advanced(by: .milliseconds(200))
        repeat {
            stdoutBox.drain(stdoutFD)
            stderrBox.drain(stderrFD)
            if stdoutBox.isFinished && stderrBox.isFinished { break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(5))
        } while clock.now < drainDeadline
        try Task.checkCancellation()
        var output = String(decoding: stdoutBox.snapshot, as: UTF8.self)
        let stderr = String(decoding: stderrBox.snapshot, as: UTF8.self)
        if !stderr.isEmpty { output += (output.isEmpty ? "" : "\n") + stderr }
        // Swift cannot import the C function-like WIFEXITED/WEXITSTATUS macros.
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : signal
        return ProcessRun(exitCode: exitCode, output: output, timedOut: timedOut)
    }

    // MARK: - Formatting helpers

    /// One line the model sees when a change or command was denied.
    nonisolated static func denialMessage(detail: String) -> String {
        "The user declined this: \(detail). Do not retry the same change or command. Acknowledge the decline and ask how they'd like to proceed instead."
    }
}
