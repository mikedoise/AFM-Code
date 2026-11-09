import Foundation

@main struct GitCommandTests {
    static func report(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    @MainActor static func pending(_ approvals: ToolApprovalService) async throws -> UUID {
        for _ in 0..<2000 {
            if let id = approvals.pendingStepIDs.first { return id }
            try await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("Expected a project approval request")
    }
    @MainActor static func command(_ text: String, context: ToolContext, decision: ApprovalDecision = .approve,
                                  beforeDecision: () throws -> Void = {}) async throws -> String {
        report("APPROVAL fixture: " + text)
        context.beginTurn()
        defer { context.endTurn() }
        let task = Task { try await RunCommandTool(context: context).call(arguments: .init(command: text, timeout: 20)) }
        let id = try await pending(context.approvals)
        try beforeDecision()
        precondition(context.turnSteps.last?.command == text, "Approval did not show exact command")
        if decision == .cancelled { task.cancel() }
        else { context.approvals.decide(id, decision) }
        do {
            let result = try await task.value
            precondition(decision != .cancelled)
            return result
        } catch is CancellationError {
            precondition(decision == .cancelled)
            return "cancelled"
        }
    }
    @MainActor static func run(_ text: String, context: ToolContext) async throws -> ToolContext.ProcessRun {
        report("RUN fixture: " + text)
        let result = try await context.runCommand(command: text, timeout: 10)
        report("END fixture: exit \(result.exitCode)")
        return result
    }
    static func args(_ action: String, path: String? = nil, ref: String? = nil, limit: Int? = nil) -> GitTool.Arguments {
        .init(action: action, query: nil, path: path, ref: ref, line: nil, pickaxe: nil, limit: limit)
    }
    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let work = base.appendingPathComponent("work")
        let project = Project()
        let approvals = ToolApprovalService(project: project)
        let context = ToolContext(session: ChatSession(), workspace: Workspace(folderURL: work), approvals: approvals)
        let git = GitTool(context: context)
        let expected = try String(contentsOf: base.appendingPathComponent("expected-head"), encoding: .utf8)
        let initialRun = try await run("git rev-parse HEAD", context: context)
        let initial = initialRun.output.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(initial != expected)

        let path = try await run("command -v git", context: context)
        precondition(path.output.trimmingCharacters(in: .whitespacesAndNewlines) == ProcessInfo.processInfo.environment["AFM_TEST_REAL_GIT"])
        let login = try await ToolContext.runProcess(arguments: ["-lc", "command -v git"], workingDirectory: work, timeout: 5, maxOutputBytes: 1000, environment: ProcessInfo.processInfo.environment)
        precondition(login.output.trimmingCharacters(in: .whitespacesAndNewlines) == "/usr/bin/git")
        report("PASS non-login tool command preserves developer Git; old login path reproduces shim selection")

        for action in ["pull", "fetch", "add", "commit", "push", "switch", "merge"] {
            let before = context.turnSteps.count
            let output = try await git.call(arguments: args(action))
            precondition(output.contains("run_command") && output.contains("approval") && context.turnSteps.count == before)
        }
        report("PASS read-only git rejects changes with approved run_command guidance, no execution")

        for decision in [ApprovalDecision.deny, .cancelled] {
            _ = try await command("git pull --ff-only", context: context, decision: decision) {
                let data = try String(contentsOf: work.appendingPathComponent("sample.txt"), encoding: .utf8)
                precondition(data == "initial\n")
            }
            let head = try await run("git rev-parse HEAD", context: context)
            precondition(head.output.trimmingCharacters(in: .whitespacesAndNewlines) == initial)
        }
        let pulled = try await command("git pull --ff-only", context: context)
        precondition(!pulled.contains("exit code") && context.turnSteps.last?.status == .done)
        let pulledHead = try await run("git rev-parse HEAD", context: context)
        precondition(pulledHead.output.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        report("PASS denied/cancelled pulls do nothing; approved production run_command fast-forwards local fixture")

        let newFile = work.appendingPathComponent("local.txt")
        try Data("local fixture change\n".utf8).write(to: newFile)
        for cmd in ["git add -- local.txt", "git commit -m 'Local fixture change'", "git push origin HEAD:main"] {
            let output = try await command(cmd, context: context)
            precondition(!output.contains("exit code") && context.turnSteps.last?.status == .done, output)
        }
        let pushed = try await run("git rev-parse HEAD", context: context)
        let remote = try await run("git --git-dir=" + ToolContext.shellQuote(base.appendingPathComponent("remote.git").path) + " rev-parse main", context: context)
        precondition(pushed.output == remote.output && pushed.output.trimmingCharacters(in: .whitespacesAndNewlines) != expected)
        report("PASS approved add/commit/push use unchanged approval gate and only temporary local remote")

        let oldShow = try await run("git show --stat --date=short --format=%h %ad %an %s HEAD | head -n 200", context: context)
        precondition(oldShow.exitCode == 0 && oldShow.output.contains("fatal:"))
        let show = try await git.call(arguments: args("show", ref: "HEAD"))
        precondition(context.turnSteps.last?.status == .done && show.contains("Local fixture change") && !show.contains("fatal:"), show)
        report("PASS reproduced old show quoting/masked-failure bug; formatted show now succeeds")

        for action in ["show", "diff", "log"] {
            let result = try await git.call(arguments: args(action, ref: "not-a-real-revision"))
            precondition(result.contains("failed") && context.turnSteps.last?.status == .failed, result)
        }
        let outside = ToolContext(session: ChatSession(), workspace: Workspace(folderURL: base.appendingPathComponent("nonrepo")), approvals: approvals)
        let missing = try await GitTool(context: outside).call(arguments: args("branch"))
        precondition(missing.contains("failed") && outside.turnSteps.last?.status == .failed)
        report("PASS invalid revisions and non-repositories retain failure status")

        let marker = work.appendingPathComponent("must-not-exist")
        for action in ["show", "diff", "log"] {
            let values = args(action, ref: "--output=" + marker.path)
            precondition(GitTool.command(for: action, arguments: values) == nil)
            let result = try await git.call(arguments: values)
            precondition(result.contains("Invalid git ref") && !FileManager.default.fileExists(atPath: marker.path))
        }
        for file in ["-dash.txt", "quote's file.txt"] {
            let output = try await git.call(arguments: args("log", path: file, ref: "HEAD"))
            precondition(context.turnSteps.last?.status == .done && output.contains("Initial fixture"), output)
        }
        let range = try await git.call(arguments: args("log", ref: "HEAD~1..HEAD"))
        precondition(range.contains("Local fixture change"))
        report("PASS option refs rejected; revision ranges and quoted/leading-dash paths work")

        let helper = work.appendingPathComponent(".git/helper.sh")
        try Data(("#!/bin/sh\nprintf invoked >> " + ToolContext.shellQuote(marker.path) + "\n").utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        for setting in ["diff.external", "diff.fixture.textconv", "core.fsmonitor"] {
            let result = try await run("git config " + setting + " " + ToolContext.shellQuote(helper.path), context: context)
            precondition(result.exitCode == 0)
        }
        try Data("*.txt diff=fixture\n".utf8).write(to: work.appendingPathComponent(".gitattributes"))
        try Data((0..<300).map { "changed line \($0)" }.joined(separator: "\n").utf8).write(to: work.appendingPathComponent("sample.txt"))
        for action in ["log", "blame", "show", "diff", "status", "branch"] {
            let output = try await git.call(arguments: args(action, path: action == "blame" ? "local.txt" : nil, limit: 5))
            precondition(context.turnSteps.last?.status == .done, output)
            precondition(!FileManager.default.fileExists(atPath: marker.path), "Configured helper ran for \(action)")
            if action == "diff" { precondition(output.contains("truncated") && output.components(separatedBy: "\n").count <= 6) }
        }
        report("PASS read tools suppress configured helpers; large successful diff caps without SIGPIPE failure")

        let configured = try await run("git config filter.fixture.clean " + ToolContext.shellQuote(helper.path), context: context)
        precondition(configured.exitCode == 0)
        try Data("*.txt filter=fixture\n".utf8).write(to: work.appendingPathComponent(".gitattributes"))
        for action in ["status", "diff", "show"] {
            let output = try await git.call(arguments: args(action))
            precondition(output.contains("filter configuration") && output.contains("run_command") && output.contains("approval"))
            precondition(!FileManager.default.fileExists(atPath: marker.path), "Read tool ran a clean filter")
        }
        let removed = try await run("git config --unset filter.fixture.clean", context: context)
        precondition(removed.exitCode == 0)
        let afterRemoval = try await git.call(arguments: args("status"))
        precondition(!afterRemoval.contains("filter configuration") && context.turnSteps.last?.status == .done)
        report("PASS configured clean filters require approved command; guard refreshes after config changes")
        let prompt = AgentInstructions.prompt(includesTools: true, project: .init(name: "Fixture", rootPath: work.path, structure: nil, readme: nil, isGitRepository: true), contextSize: 4096)
        precondition(prompt.contains("pull") && prompt.contains("fetch") && prompt.contains("run_command") && prompt.contains("approval"))
        report("PASS model-visible routing includes pull/fetch and preserves approvals")
    }
}
