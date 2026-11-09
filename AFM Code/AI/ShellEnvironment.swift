import Foundation
import OSLog

/// Best-effort host zsh exports for approved desktop commands. Discovery uses
/// inspectionSnapshot and never initializes startup files. This app does not
/// adopt App Sandbox; macOS privacy and ordinary file permissions still apply.
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
        var captureSummary = "Not captured yet."
    }

    nonisolated private static let logger = Logger(subsystem: "dev.afmcode", category: "ShellEnvironment")

    nonisolated static var captureSummary: String { state.lock.withLock { state.captureSummary } }

    /// Read-only discovery must never initialize a shell: startup files can
    /// execute arbitrary user code. This snapshot also avoids creating caches.
    nonisolated static func inspectionSnapshot() -> (environment: [String: String], summary: String) {
        let cached = state.lock.withLock { state.cached }
        var environment = cached ?? ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(environment["PATH"], developerBin: developerUSRBIN())
        let summary = cached == nil
            ? "App environment snapshot with conventional fallback paths. No shell startup capture was run; a later approved command may resolve a different environment."
            : "Previously captured exported environment snapshot. No shell startup capture or refresh was run; aliases/functions are not imported."
        return (environment, summary)
    }

    /// The environment for child processes, captured on first need and
    /// TTL-cached. Returns the stale cache when a refresh fails (a
    /// stale PATH beats a minimal one). With no previous capture, use the
    /// augmented app environment; this is not a grant to read shell files.
    nonisolated static func resolved(now: Date = Date()) async -> [String: String]? {
        var snapshot: [String: String]?
        var needsCapture = false
        state.lock.withLock {
            needsCapture = state.cached == nil || now.timeIntervalSince(state.capturedAt) > ttl
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
                state.capturedAt = now
                state.captureSummary = "Exported zsh login environment captured. Aliases/functions are not imported."
            }
            logger.debug("captured \(env.count) environment variables for child processes")
            base = env
        } else {
            logger.warning("shell environment capture failed; using cached or app environment")
            base = snapshot ?? ProcessInfo.processInfo.environment
            state.lock.withLock {
                state.captureSummary = snapshot == nil
                    ? "Shell capture unavailable; using app environment plus conventional tool paths."
                    : "Shell refresh failed; using the previous exported environment."
            }
        }
        return Self.augmented(base)
    }

    /// Match the user's command preference. Do not force Xcode Python/Git or
    /// redirect package caches now that commands run as an ordinary user app.
    nonisolated static func augmented(_ base: [String: String]) -> [String: String] {
        var env = base
        env["PATH"] = augmentedPath(base["PATH"], developerBin: developerUSRBIN())
        return env
    }

    /// Keep the user's order. Add conventional installation directories only
    /// as fallback entries; this neither installs tools nor grants access.
    nonisolated static func augmentedPath(_ original: String?, developerBin: String?) -> String {
        var entries = (original ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .components(separatedBy: ":")
        if let developerBin {
            if !entries.contains(developerBin) { entries.append(developerBin) }
        }
        for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !entries.contains(path) {
            entries.append(path)
        }
        return entries.joined(separator: ":")
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
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = cache.appendingPathComponent("AFMCode/CommandTools", isDirectory: true)
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

    /// Approved command initialization only. Capture zsh exports, delimited by
    /// markers so rc-file noise can't pollute the parse.
    nonisolated static func capture(interactive: Bool) async throws -> [String: String] {
        let marker = "__AFM_CODE_ENV_\(UUID().uuidString)__"
        let script = "printf '\\n\(marker)\\n'; /usr/bin/env; printf '\\n\(marker)\\n'"
        let run = try await ToolContext.runProcess(
            arguments: [interactive ? "-ilc" : "-lc", script],
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            timeout: 10,
            maxOutputBytes: 128 * 1024
        )

        guard !run.timedOut, run.exitCode == 0 else { throw ShellError.noMarker }
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
