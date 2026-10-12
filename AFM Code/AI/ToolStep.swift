import Foundation

/// One unit of tool activity during a turn: a single tool call and
/// what it did.
///
/// Live steps live on `ToolContext` while a turn runs; at turn end the
/// engine persists them JSON-encoded on the assistant `Message` so a
/// resumed session renders the same history. The Foundation Models
/// transcript remains the model-side source of truth — this is the
/// UI-facing mirror (the same pattern Perspective Intelligence uses).
struct ToolStep: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case read, write, edit, list, search, git, command
    }

    enum Status: String, Codable, Sendable {
        /// In flight, no approval needed (reads, searches, allowlisted commands).
        case running
        /// Waiting for the user's decision.
        case awaiting
        /// Approved and executing.
        case approved
        case denied
        case done
        case failed
        /// The turn was stopped while this step was in flight.
        case cancelled

        /// Whether the step will not change state again on its own.
        var isTerminal: Bool {
            switch self {
            case .denied, .done, .failed, .cancelled: true
            default: false
            }
        }
    }

    let id: UUID
    let kind: Kind
    /// The Foundation Models tool name (`read_file`, `run_command`, …).
    let toolName: String
    /// One-line header, e.g. "Read Sources/Auth.swift".
    var title: String
    var status: Status
    /// Short result line, e.g. "87 lines" or "exit 0 · 24 lines".
    var summary: String?
    /// Expandable body: file content, command output, search results.
    var detail: String?
    /// Diff preview for write/edit steps.
    var diff: DiffData?
    /// The exact command, for the "Always Allow" affordance.
    var command: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        toolName: String,
        title: String,
        status: Status
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.title = title
        self.status = status
    }

    var icon: String {
        switch kind {
        case .read: return "doc.text.magnifyingglass"
        case .write: return "doc.badge.plus"
        case .edit: return "pencil"
        case .list: return "folder"
        case .search: return "text.magnifyingglass"
        case .git: return "clock.arrow.circlepath"
        case .command: return "terminal"
        }
    }

    var statusIcon: String {
        switch status {
        case .running, .approved: return "clock"
        case .awaiting: return "exclamationmark.bubble"
        case .denied: return "xmark.octagon"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "stop.circle"
        }
    }

    var statusColor: String {
        switch status {
        case .done: return "green"
        case .denied, .failed: return "red"
        case .cancelled: return "secondary"
        default: return "accent"
        }
    }
}

/// A line-oriented diff preview attached to write/edit steps.
///
/// `nonisolated` so the diff can be computed off the main actor.
nonisolated struct DiffData: Codable, Equatable, Sendable {
    enum LineKind: String, Codable, Sendable {
        case context, addition, removal
    }

    struct Line: Codable, Equatable, Sendable {
        var kind: LineKind
        var text: String
    }

    var path: String
    var isNewFile: Bool
    var lines: [Line]
    /// True when the preview was cut to stay readable.
    var truncated: Bool

    var additions: Int { lines.lazy.filter { $0.kind == .addition }.count }
    var removals: Int { lines.lazy.filter { $0.kind == .removal }.count }

    /// The diff as unified-style text, for the copy button.
    var unifiedText: String {
        lines.map { line in
            let prefix: String = switch line.kind {
            case .context: " "
            case .addition: "+"
            case .removal: "-"
            }
            return prefix + line.text
        }
        .joined(separator: "\n")
    }
}

/// A small LCS line-diff, sized for Phase 3 previews.
///
/// For files whose line product is large we bail out to a whole-file
/// "replace" preview instead of spending time on a full LCS.
///
/// `nonisolated` so the (potentially heavy) computation can run off
/// the main actor while an approval card is being prepared.
nonisolated enum LineDiff {
    static func compute(
        path: String,
        old: [String],
        new: [String],
        maxLines: Int = 400
    ) -> DiffData {
        let isNewFile = old.isEmpty

        guard Double(old.count) * Double(new.count) < 16_000_000 else {
            return wholeReplace(path: path, old: old, new: new, isNewFile: isNewFile, maxLines: maxLines)
        }

        let m = old.count
        let n = new.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                dp[i][j] = old[i] == new[j]
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        var lines: [DiffData.Line] = []
        lines.reserveCapacity(m + n)
        var i = 0
        var j = 0
        while i < m && j < n {
            if old[i] == new[j] {
                lines.append(DiffData.Line(kind: .context, text: old[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                lines.append(DiffData.Line(kind: .removal, text: old[i]))
                i += 1
            } else {
                lines.append(DiffData.Line(kind: .addition, text: new[j]))
                j += 1
            }
        }
        while i < m { lines.append(DiffData.Line(kind: .removal, text: old[i])); i += 1 }
        while j < n { lines.append(DiffData.Line(kind: .addition, text: new[j])); j += 1 }

        return finish(path: path, isNewFile: isNewFile, raw: lines, maxLines: maxLines)
    }

    private static func wholeReplace(
        path: String,
        old: [String],
        new: [String],
        isNewFile: Bool,
        maxLines: Int
    ) -> DiffData {
        var lines: [DiffData.Line] = old.map { DiffData.Line(kind: .removal, text: $0) }
        lines.append(contentsOf: new.map { DiffData.Line(kind: .addition, text: $0) })
        return finish(path: path, isNewFile: isNewFile, raw: lines, maxLines: maxLines)
    }

    /// Collapse long context runs, then cap the total preview.
    private static func finish(
        path: String,
        isNewFile: Bool,
        raw: [DiffData.Line],
        maxLines: Int
    ) -> DiffData {
        var condensed: [DiffData.Line] = []
        var run: [DiffData.Line] = []
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard run.count > 7 else {
                condensed.append(contentsOf: run)
                return
            }
            condensed.append(contentsOf: run.prefix(2))
            condensed.append(DiffData.Line(kind: .context, text: "⋯ \(run.count - 4) unchanged lines"))
            condensed.append(contentsOf: run.suffix(2))
        }

        for line in raw {
            if line.kind == .context {
                run.append(line)
            } else {
                flush()
                condensed.append(line)
            }
        }
        flush()

        var truncated = false
        if condensed.count > maxLines {
            condensed = Array(condensed.prefix(maxLines - 1))
            condensed.append(DiffData.Line(kind: .context, text: "⋯ diff truncated (\(condensed.count + 1) lines shown)"))
            truncated = true
        }

        return DiffData(path: path, isNewFile: isNewFile, lines: condensed, truncated: truncated)
    }
}
