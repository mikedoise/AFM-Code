import Foundation
import OSLog

/// The user's real shell environment, captured from their login shell.
///
/// A GUI app starts with a minimal `launchd` environment, and a
/// non-interactive login shell (`zsh -lc`) skips `~/.zshrc` — so tools
/// the user has in their terminal (brew, uv, cargo, nvm, pyenv, …) are
/// invisible to the agent's commands. We capture the environment of the
/// user's actual interactive login shell, cache it with a TTL, and hand
/// it to every child process.
///
/// Child processes *inherit the app's App Sandbox*, so the captured
/// environment isn't enough on its own: the toolchain shims in
/// `/usr/bin` (git, clang, swift) are `xcrun` clones that refuse to run
/// inside a sandbox, and the sandbox denies writes to the user's HOME.
/// `augmented` fixes both: it puts the active developer directory's real
/// binaries ahead of the shims, and redirects tool caches that would
/// target HOME into the app's container.
enum ShellEnvironment {
    /// How long a captured environment stays fresh (the user may
    /// install new tools mid-session).
    nonisolated private static let ttl: TimeInterval = 10 * 60

    /// The shared cache, behind a lock (`NSLock` isn't `Sendable` in
    /// Swift's eyes, so it hides behind `@unchecked`).
    nonisolated private static let state = State()

    nonisolated private final class State: @unchecked Sendable {
        let lock = NSLock()
        var cached: [String: String]?
        var capturedAt: Date = .distantPast
    }

    nonisolated private static let logger = Logger(subsystem: "dev.afmcode", category: "ShellEnvironment")

    /// The environment for child processes, captured on first need and
    /// TTL-cached. Returns the stale cache when a refresh fails (a
    /// stale PATH beats a minimal one), or `nil` when nothing was ever
    /// captured — commands then inherit the app's environment.
    nonisolated static func resolved() async -> [String: String]? {
        var snapshot: [String: String]?
        var needsCapture = false
        state.lock.withLock {
            needsCapture = state.cached == nil || Date().timeIntervalSince(state.capturedAt) > ttl
            snapshot = state.cached
        }
        guard needsCapture else {
            return Self.augmented(snapshot ?? ProcessInfo.processInfo.environment)
        }

        // Interactive first (sees `~/.zshrc`); a login shell as the
        // fallback when an interactive init misbehaves.
        var env = try? await capture(interactive: true)
        if env == nil {
            env = try? await capture(interactive: false)
        }

        var base: [String: String]
        if let env, !env.isEmpty {
            state.lock.withLock {
                state.cached = env
                state.capturedAt = Date()
            }
            logger.debug("captured \(env.count) environment variables for child processes")
            base = env
        } else {
            logger.warning("shell environment capture failed; using the app environment")
            base = ProcessInfo.processInfo.environment
        }
        return Self.augmented(base)
    }

    /// Make the environment safe for a *sandboxed* child process.
    ///
    /// - The toolchain shims in `/usr/bin` (`git`, `clang`, `swift`, …)
    ///   are `xcrun` clones that refuse to run inside an App Sandbox
    ///   ("xcrun: error: cannot be used within an App Sandbox"). The
    ///   real binaries in the active developer directory go ahead of
    ///   them on the PATH.
    /// - The sandbox denies writes outside the user-selected scope, so
    ///   tool caches that default to the user's HOME (uv, pip, npm)
    ///   are redirected into the app's own container.
    nonisolated static func augmented(_ base: [String: String]) -> [String: String] {
        var env = base

        if let devBin = Self.developerUSRBIN() {
            let entries = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
            var path = [devBin]
            path.append(contentsOf: entries.filter { $0 != devBin })
            env["PATH"] = path.joined(separator: ":")
        }

        if let cache = Self.toolCacheDir() {
            env["UV_CACHE_DIR"] = (cache as NSString).appendingPathComponent("uv")
            env["PIP_CACHE_DIR"] = (cache as NSString).appendingPathComponent("pip")
            env["npm_config_cache"] = (cache as NSString).appendingPathComponent("npm")
        }
        return env
    }

    /// `<active developer directory>/usr/bin` — the real git/clang/swift
    /// binaries, as opposed to the sandbox-hostile `xcrun` shims in
    /// `/usr/bin`. Modern macOS records the selection in
    /// `/var/db/xcode_select_link`; older systems use `/Selected`.
    /// `nil` when none of the locations resolve.
    nonisolated static func developerUSRBIN() -> String? {
        let candidates: [String] = {
            var list: [String] = []
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
                list.append(link)
            }
            if let legacy = try? FileManager.default.destinationOfSymbolicLink(atPath: "/Selected") {
                list.append(legacy)
            }
            list.append("/Library/Developer/CommandLineTools")
            return list
        }()
        for candidate in candidates {
            let dir = (candidate as NSString).appendingPathComponent("usr/bin")
            if FileManager.default.fileExists(atPath: dir) {
                return dir
            }
        }
        return nil
    }

    /// A writable cache directory inside the app's sandbox container
    /// (shared across projects), for tool caches that would otherwise
    /// target the user's HOME — which the sandbox denies writes to.
    nonisolated static func toolCacheDir() -> String? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let container = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: bundleID
              ) else {
            return nil
        }
        let url = container.appendingPathComponent("Data/.afm-cache")
        guard (try? url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey]))?.isDirectory != true else {
            return url.path
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        } catch {
            return nil
        }
    }

    /// Run the user's shell and capture its `env` output, delimited by
    /// markers so rc-file noise can't pollute the parse.
    nonisolated static func capture(interactive: Bool) async throws -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            throw ShellError.badShell
        }

        let marker = "__AFM_CODE_ENV__"
        let script = "printf '\\n\(marker)\\n'; env; printf '\\n\(marker)\\n'"
        let run = try await ToolContext.runProcess(
            arguments: [interactive ? "-ilc" : "-lc", script],
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            timeout: 10,
            maxOutputBytes: 128 * 1024
        )

        let lines = run.output.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }),
              let last = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }),
              last > first else {
            throw ShellError.noMarker
        }

        var env: [String: String] = [:]
        for line in lines[(first + 1)..<last] {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            guard key.first.map({ $0.isLetter || $0 == "_" }) == true,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            env[key] = String(line[line.index(after: equals)...])
        }
        // A capture without HOME is useless.
        guard !env.isEmpty, env["HOME"] != nil else {
            throw ShellError.empty
        }
        return env
    }

    enum ShellError: LocalizedError {
        case badShell
        case noMarker
        case empty

        var errorDescription: String? {
            "Couldn't capture the shell environment."
        }
    }
}
