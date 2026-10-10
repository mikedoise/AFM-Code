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
        guard needsCapture else { return snapshot }

        // Interactive first (sees `~/.zshrc`); a login shell as the
        // fallback when an interactive init misbehaves.
        var env = try? await capture(interactive: true)
        if env == nil {
            env = try? await capture(interactive: false)
        }

        if let env, !env.isEmpty {
            state.lock.withLock {
                state.cached = env
                state.capturedAt = Date()
            }
            logger.debug("captured \(env.count) environment variables for child processes")
            return env
        }
        logger.warning("shell environment capture failed; using the app environment")
        return snapshot
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
