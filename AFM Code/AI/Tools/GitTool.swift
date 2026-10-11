import Foundation
import FoundationModels

/// Queries the project's Git repository (read-only).
///
/// Read-only by construction: every action maps to a git command that
/// neither writes to the repository nor triggers hooks, so — like `search`
/// — it runs without an approval step. Commit *writes* (add/commit/push)
/// deliberately go through `run_command` with its approval flow.
///
/// This is the model's door into commit history: `search` only sees
/// current file contents, and `run_command` asks the user for approval on
/// every new variant, so history questions land here.
nonisolated struct GitTool: Tool {
    let context: ToolContext

    let name = "git"
    let description = """
    Query the project's git repository (read-only; runs without approval). \
    Use this for commit history — search only sees current file contents, never history. \
    Actions: log = find commits (by message text, code pickaxe, or path); \
    blame = who/when a file or line region last changed; \
    show = what a commit changed; diff = uncommitted changes; \
    status = working tree state; branch = branch list.
    """

    @Generable
    struct Arguments {
        @Guide(description: "One of: log, blame, show, diff, status, branch.")
        var action: String

        @Guide(description: "Optional. For log: text to search for — commit messages by default, or code that was added/removed when pickaxe is true.")
        var query: String?

        @Guide(description: "Optional. File path. For blame: required (the file to blame). For log/diff: restrict results to this file.")
        var path: String?

        @Guide(description: "Optional. For show: the commit to inspect — a hash, branch, or tag (default HEAD). For log: a ref or range, e.g. main..feature.")
        var ref: String?

        @Guide(description: "Optional. For blame: first line of the region to blame (default 1).")
        var line: Int?

        @Guide(description: "Optional. For log: true searches the code added/removed by each commit (pickaxe); omitted or false searches commit messages.")
        var pickaxe: Bool?

        @Guide(description: "Optional. Result cap: commits for log (default 25), lines for blame (default 100), diff lines for show/diff (default 200).")
        var limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard await context.canOperate else {
            return "The project folder is not available right now, so I can't query git. Ask the user to re-connect the project folder."
        }

        let action = arguments.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let command = Self.command(for: action, arguments: arguments) else {
            return "Unknown git action \"\(arguments.action)\". Valid actions: log, blame, show, diff, status, branch."
        }
        guard !Self.actionNeedsPath(action) || arguments.path != nil else {
            return "git blame needs a file path — pass the path argument (for example \"src/Main.swift\")."
        }

        let limit = Self.limit(for: action, requested: arguments.limit)
        let title = "Git \(action)" + Self.titleSuffix(arguments)

        let stepID = await context.beginStep(
            kind: .git,
            toolName: name,
            title: title,
            status: .running
        )

        do {
            let run = try await context.runCommand(command: command, timeout: 30)
            let output = Self.present(
                action: action, arguments: arguments, limit: limit, run: run
            )
            let isMatchless = output.hasPrefix("No ")
            await context.updateStep(
                stepID,
                status: run.exitCode == 0 && !run.timedOut ? .done : .failed,
                summary: Self.summary(action: action, arguments: arguments, run: run, matchless: isMatchless),
                detail: output
            )
            if run.exitCode != 0 || run.timedOut {
                return "git \(action) failed" + (run.timedOut ? " (timed out)" : "") + ":\n\(output)"
            }
            return output
        } catch {
            let message = ReadFileTool.message(for: error)
            await context.updateStep(stepID, status: .failed, summary: message)
            return "git \(action) failed: \(message)"
        }
    }

    // MARK: - Command construction

    private static func actionNeedsPath(_ action: String) -> Bool {
        action == "blame"
    }

    private static func limit(for action: String, requested: Int?) -> Int {
        let defaults: [String: Int] = ["log": 25, "blame": 100, "show": 200, "diff": 200]
        let maxes: [String: Int] = ["log": 100, "blame": 500, "show": 1000, "diff": 1000]
        let clamped = min(max(requested ?? defaults[action] ?? 25, 1), maxes[action] ?? 400)
        return action == "status" || action == "branch" ? 100 : clamped
    }

    /// The exact zsh command for one action, or `nil` for an unknown action.
    ///
    /// Every model-supplied value is shell-quoted, and every action is
    /// read-only (no hooks, no writes), so the command is safe to run
    /// without an approval step.
    static func command(for action: String, arguments: Arguments) -> String? {
        let limit = limit(for: action, requested: arguments.limit)
        let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = (query?.isEmpty == false)
        let path = arguments.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPath = (path?.isEmpty == false)
        let ref = arguments.ref?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRef = (ref?.isEmpty == false)
        // Local quote helper: ToolContext.shellQuote is main-actor isolated
        // and this builder is not.
        func q(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        switch action {
        case "log":
            var parts = ["git log"]
            if hasRef { parts.append(q(ref!)) } else { parts.append("--all") }
            parts.append("-n \(limit)")
            parts.append("--date=short")
            parts.append("--pretty=format:%h%x09%ad%x09%an%x09%s")
            if hasQuery {
                if arguments.pickaxe == true {
                    parts.append("-S\(q(query!))")
                } else {
                    parts.append("--grep=\(q(query!)) -i")
                }
            }
            if hasPath { parts.append("-- \(q(path!))") }
            return parts.joined(separator: " ")

        case "blame":
            var parts = ["git blame", "-w"]
            let start = max(arguments.line ?? 1, 1)
            parts.append("-L \(start),+\(limit)")
            if hasPath { parts.append("-- \(q(path!))") }
            return parts.joined(separator: " ")

        case "show":
            var parts = ["git show", "--stat", "--date=short",
                         "--format=%h %ad %an %s",
                         q(hasRef ? ref! : "HEAD")]
            if hasPath { parts.append("-- \(q(path!))") }
            return parts.joined(separator: " ") + " | head -n \(limit)"

        case "diff":
            let scope = hasPath ? " -- \(q(path!))" : ""
            let scopeRef = hasRef ? " \(q(ref!))" : ""
            return "git diff --stat\(scopeRef)\(scope); git diff\(scopeRef)\(scope) | head -n \(limit)"

        case "status":
            return "git status --porcelain=v1 -b"

        case "branch":
            return "git branch -av | head -n \(limit)"

        default:
            return nil
        }
    }

    // MARK: - Presentation

    private static func titleSuffix(_ arguments: Arguments) -> String {
        if let query = arguments.query, !query.isEmpty {
            return " \(Self.ellipsis(query))"
        }
        if let ref = arguments.ref, !ref.isEmpty {
            return " \(Self.ellipsis(ref))"
        }
        if let path = arguments.path, !path.isEmpty {
            return " \(Self.ellipsis(path))"
        }
        return ""
    }

    private static func ellipsis(_ text: String) -> String {
        text.count <= 32 ? text : text.prefix(32) + "…"
    }

    private static func present(
        action: String, arguments: Arguments, limit: Int, run: ToolContext.ProcessRun
    ) -> String {
        var output = run.output
        if output.isEmpty {
            switch action {
            case "log":
                output = "No commits matched" + (arguments.query?.isEmpty == false ? " \"\(arguments.query!)\"" : "") + "."
            case "diff":
                output = "No uncommitted changes" + (arguments.path?.isEmpty == false ? " in \(arguments.path!)" : "") + "."
            default:
                output = "(no output)"
            }
        }
        // `git show`/`git diff` are already line-capped with `head`; cap
        // characters so a wide line can't blow out the context window.
        if output.count > 16_000 {
            output = String(output.prefix(16_000)) + "\n… (truncated)"
        }
        return output
    }

    private static func summary(
        action: String, arguments: Arguments, run: ToolContext.ProcessRun, matchless: Bool
    ) -> String {
        if matchless {
            return "no results"
        }
        let lines = run.output.split(separator: "\n", omittingEmptySubsequences: true).count
        var text = "exit \(run.exitCode) · \(lines) line\(lines == 1 ? "" : "s")"
        if run.timedOut { text += " · timed out" }
        return text
    }
}
