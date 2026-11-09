import Foundation

@main struct ToolSafetyTests {
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected rejection: \(label)") }
        catch { print("PASS rejected \(label)") }
    }

    @MainActor static func pending(_ approvals: ToolApprovalService) async throws -> UUID {
        for _ in 0..<2000 {
            if let id = approvals.pendingStepIDs.first { return id }
            try await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("Timed out waiting for real approval gate")
    }

    @MainActor static func main() async throws {
        let f = try ToolSafetyFixture()
        defer { try? f.cleanup() }
        let file = f.root.appendingPathComponent("sample.txt")
        try Data("one\ntwo\nthree".utf8).write(to: file)
        try Data("outside sentinel".utf8).write(to: f.outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("escape"), withDestinationURL: f.outside)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("inside"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("cycle"), withDestinationURL: f.root)
        rejects("symlink read") { _ = try f.context.readFile(path: "escape/secret.txt", startLine: nil, maxLines: nil) }
        rejects("symlink content read") { _ = try f.context.readFileContent(path: "escape/secret.txt") }
        rejects("symlink listing target") { _ = try f.context.listDirectory(path: "escape", maxDepth: 4) }
        rejects("parent traversal") { _ = try f.context.resolvePath("../outside/secret.txt") }
        expect(!f.context.isInsideRoot(f.root.appendingPathComponent("escape/secret.txt")), "Symlink containment failed")
        expect(!f.context.fileExists("escape/secret.txt"), "Existence probe escaped")
        do {
            _ = try await f.context.search(pattern: "sentinel", path: "escape/secret.txt")
            preconditionFailure("Search escaped")
        } catch { print("PASS rejected symlink search before shell invocation") }
        let listing = try f.context.listDirectory(path: ".", maxDepth: 4)
        expect(!listing.contains("secret.txt"), "Listing traversed link")
        expect(listing.contains("symbolic link"), "Links should remain visible without traversal")
        let internalRead = try f.context.readFile(path: "inside", startLine: 1, maxLines: 1)
        expect(internalRead.lineCount == 1, "Contained link should remain readable")
        print("PASS canonical containment and link-cycle listing")

        for start in [Int.min, -1, 0, 1, 3, 4, 100, Int.max] {
            for limit in [Int.min, -1, 0, 1, 500, Int.max] {
                let result = try f.context.readFile(path: "sample.txt", startLine: start, maxLines: limit)
                expect((0...3).contains(result.lineCount), "Invalid line count")
                if start > 3 || limit <= 0 { expect(result.output.isEmpty, "Empty range returned data") }
            }
        }
        let tail = try f.context.readFile(path: "sample.txt", startLine: 3, maxLines: Int.max)
        expect(tail.lineCount == 1 && tail.output.contains("three"), "Tail slice wrong")
        let emptyContent = try f.context.readFileContent(path: "sample.txt", maxLines: Int.min)
        expect(emptyContent == "", "Negative content limit must not trap")
        print("PASS 48 extreme range combinations")

        let legacy = "printf '%s' 'a b'"
        f.project.commandAllowlist = [legacy]
        let old = ToolApprovalService(project: f.project)
        expect(old.commandAllowlist == [legacy] && f.project.commandAllowlist == [legacy], "Stored approvals mutated")
        expect(!old.commandIsAllowed(legacy), "Untyped previous grant must not authorize desktop execution")
        expect(!old.commandIsAllowed("printf '%s' 'a\tb'"), "Quoted tab collided with stored space")
        expect(ToolApprovalService.normalize(" echo 'a\tb'\n") == " echo 'a\tb'\n", "Command bytes changed")
        let commandID = UUID()
        let command = "printf '%s' 'new\targument'"
        let approvalTask = Task { await f.approvals.wait(for: commandID, command: command) }
        _ = try await pending(f.approvals)
        f.approvals.decide(commandID, .alwaysAllow, command: command)
        let decision = await approvalTask.value
        expect(decision == .alwaysAllow && f.approvals.commandIsAllowed(command), "Exact approval not remembered")
        expect(!f.approvals.commandIsAllowed(command.replacingOccurrences(of: "\t", with: " ")), "New approval collision")
        print("PASS exact allowlisting and historical entry preservation")

        // An open conversation must honor a revoked project allowance.
        f.project.commandAllowlist = []
        expect(!f.approvals.commandIsAllowed(command), "Revoked command remained authorized")
        let reviewed = "git fetch origin"
        let requestID = UUID()
        let grant = Task { await f.approvals.wait(for: requestID, command: reviewed) }
        _ = try await pending(f.approvals)
        f.approvals.decide(requestID, .alwaysAllow, command: "unreviewed different command")
        _ = await grant.value
        expect(f.approvals.commandIsAllowed(reviewed), "Reviewed command not remembered")
        expect(!f.approvals.commandIsAllowed("unreviewed different command"), "Caller substituted permission target")
        expect(!f.approvals.commandIsAllowed(command), "Remembering a new grant restored revoked entry")
        let sameName = "mcp__fixture__tool"
        let mcpID = UUID()
        let mcpTask = Task { await f.approvals.wait(for: mcpID, command: sameName, scope: .mcp) }
        _ = try await pending(f.approvals)
        f.approvals.decide(mcpID, .alwaysAllow)
        _ = await mcpTask.value
        expect(f.approvals.commandIsAllowed(sameName, scope: .mcp), "MCP grant missing")
        expect(!f.approvals.commandIsAllowed(sameName), "MCP grant authorized a shell command")
        let shellID = UUID()
        let shellTask = Task { await f.approvals.wait(for: shellID, command: sameName) }
        _ = try await pending(f.approvals)
        expect(f.approvals.pendingStepIDs.contains(shellID), "Cross-scope shell command bypassed approval")
        f.approvals.decide(shellID, .deny)
        _ = await shellTask.value
        f.project.commandAllowlist = [ToolApprovalService.permissionKey(sameName)]
        expect(f.approvals.commandIsAllowed(sameName) && !f.approvals.commandIsAllowed(sameName, scope: .mcp), "Shell grant authorized MCP")
        print("PASS shell and MCP grants cannot authorize each other, even with identical names")
        print("PASS live revocation and approval bound to the reviewed command")

        for _ in 0..<100 {
            let id = UUID()
            let waiting = Task { await f.approvals.wait(for: id) }
            _ = try await pending(f.approvals)
            f.approvals.decide(id, .deny)
            let result = await waiting.value
            expect(result == .deny, "Immediate decision was lost")
        }
        print("PASS immediate decisions resolve all 100 published waiters")

        let resetID = UUID()
        let resetWaiter = Task { await f.approvals.wait(for: resetID) }
        _ = try await pending(f.approvals)
        f.approvals.reset()
        f.approvals.decide(resetID, .approve)
        f.approvals.decide(resetID, .alwaysAllow, command: "must not be saved")
        let resetResult = await resetWaiter.value
        expect(resetResult == .cancelled && !f.approvals.commandIsAllowed("must not be saved"), "Late decision survived reset")
        expect(ToolContext.commandEnvironment([:])["GIT_TERMINAL_PROMPT"] == "0", "Noninteractive Git default missing")
        expect(ToolContext.commandEnvironment(["GIT_TERMINAL_PROMPT": "1"])["GIT_TERMINAL_PROMPT"] == "1", "Explicit Git setting changed")
        print("PASS reset/duplicate decisions and noninteractive Git default")

        let write = WriteFileTool(context: f.context)
        let edit = EditFileTool(context: f.context)
        // Preparation failures must reach the user, not just the model.
        @MainActor func failedPreparation(_ label: String, _ call: () async throws -> String) async throws {
            f.context.beginTurn()
            let before = try Data(contentsOf: file)
            let output = try await call()
            expect(f.context.turnSteps.count == 1, "Missing visible step for \(label)")
            expect(f.context.turnSteps.last?.status == .failed, "Preparation failure was not terminal: \(label)")
            expect(f.context.turnSteps.last?.summary?.isEmpty == false, "Missing failure reason: \(label)")
            expect(f.context.turnSteps.last?.diff == nil, "Invalid change offered an approval diff: \(label)")
            expect(f.approvals.pendingStepIDs.isEmpty, "Invalid change requested approval: \(label)")
            expect(output.contains("failed:"), "Failure not returned to model: \(label)")
            let after = try Data(contentsOf: file)
            expect(before == after, "Preparation mutated file: \(label)")
            f.context.endTurn()
            print("PASS visible preparation failure: \(label)")
        }
        try await failedPreparation("write outside project") {
            try await write.call(arguments: .init(path: "../outside/secret.txt", content: "must not write"))
        }
        try await failedPreparation("write directory") {
            try await write.call(arguments: .init(path: ".", content: "must not write"))
        }
        try await failedPreparation("edit missing file") {
            try await edit.call(arguments: .init(path: "missing.txt", find: "x", replace: "y", replaceAll: nil))
        }
        try await failedPreparation("edit missing match") {
            try await edit.call(arguments: .init(path: "sample.txt", find: "not present", replace: "y", replaceAll: nil))
        }
        try await failedPreparation("edit empty search") {
            try await edit.call(arguments: .init(path: "sample.txt", find: "", replace: "y", replaceAll: nil))
        }
        try await failedPreparation("edit ambiguous match") {
            try await edit.call(arguments: .init(path: "sample.txt", find: "o", replace: "y", replaceAll: nil))
        }
        f.context.workspace.status = .folderMissing
        try await failedPreparation("write unavailable project") {
            try await write.call(arguments: .init(path: "sample.txt", content: "must not write"))
        }
        try await failedPreparation("edit unavailable project") {
            try await edit.call(arguments: .init(path: "sample.txt", find: "one", replace: "y", replaceAll: nil))
        }
        f.context.workspace.status = .active

        for tool in ["write", "edit"] {
            f.context.beginTurn()
            let before = try Data(contentsOf: file)
            let unchangedText = String(decoding: before, as: UTF8.self)
            if tool == "write" {
                _ = try await write.call(arguments: .init(path: "sample.txt", content: unchangedText))
            } else {
                _ = try await edit.call(arguments: .init(path: "sample.txt", find: "one", replace: "one", replaceAll: nil))
            }
            expect(f.context.turnSteps.count == 1 && f.context.turnSteps.last?.status == .done, "No-op missing visible completion")
            expect(f.approvals.pendingStepIDs.isEmpty, "No-op requested approval")
            let after = try Data(contentsOf: file)
            expect(before == after, "No-op modified file")
            f.context.endTurn()
            print("PASS visible \(tool) no-op")
        }

        for tool in ["write", "edit"] {
            for choice in [ApprovalDecision.deny, .cancelled, .approve] {
                try Data("original".utf8).write(to: file)
                f.context.beginTurn()
                let task = Task {
                    if tool == "write" {
                        return try await write.call(arguments: .init(path: "sample.txt", content: "replacement"))
                    }
                    return try await edit.call(arguments: .init(path: "sample.txt", find: "original", replace: "replacement", replaceAll: false))
                }
                let stepID = try await pending(f.approvals)
                let before = try Data(contentsOf: file)
                expect(before == Data("original".utf8), "Mutation before approval")
                expect(f.context.turnSteps.last?.diff?.lines.contains(where: { $0.kind == .addition && $0.text == "replacement" }) == true, "Approval missing actual diff")
                if choice == .cancelled { task.cancel() }
                else { f.approvals.decide(stepID, choice) }
                do {
                    _ = try await task.value
                    expect(choice != .cancelled, "Cancelled tool returned success")
                } catch is CancellationError {
                    expect(choice == .cancelled, "Unexpected cancellation")
                }
                let after = try Data(contentsOf: file)
                expect(after == Data((choice == .approve ? "replacement" : "original").utf8), "Approval decision not enforced")
                expect(f.approvals.pendingStepIDs.isEmpty, "Approval leaked")
                f.context.endTurn()
                print("PASS production \(tool) \(choice)")
            }
        }

        // The write tool must not JSON-escape or unescape source text. Both
        // valid Python escapes and a model's erroneous escapes are exact bytes.
        let triple = String(repeating: "\"", count: 3)
        let python = [
            "\(triple)Module docstring.\(triple)",
            #"pattern = r"\d+\s+""#,
            #"text = "a \"quoted\" value""#,
            #"path = "C:\\temp\\file.txt""#,
            #"literal = "\\n""#
        ].joined(separator: "\n") + "\n"
        let alreadyEscaped = #"\"\"\"Model already emitted escaped quotes.\"\"\""#
        let quoteFile = f.root.appendingPathComponent("quote-probe.py")
        for (label, content) in [("Python source", python), ("already escaped source", alreadyEscaped)] {
            f.context.beginTurn()
            let task = Task { try await write.call(arguments: .init(path: "quote-probe.py", content: content)) }
            let id = try await pending(f.approvals)
            expect(f.context.turnSteps.last?.diff?.lines.contains { $0.text.utf8.elementsEqual(content.components(separatedBy: "\n")[0].utf8) } == true, "Preview altered quote bytes")
            f.approvals.decide(id, .approve)
            _ = try await task.value
            let written = try Data(contentsOf: quoteFile)
            expect(written == Data(content.utf8), "Write escaped/unescaped \(label)")
            expect(f.context.turnSteps.last?.status == .done, "Quote write did not finish")
            f.context.endTurn()
            print("PASS exact approved bytes: \(label)")
        }
        // Edit replacements have the same byte-preserving contract.
        f.context.beginTurn()
        let quoteEdit = Task { try await edit.call(arguments: .init(path: "quote-probe.py", find: alreadyEscaped, replace: python, replaceAll: nil)) }
        let quoteEditID = try await pending(f.approvals)
        f.approvals.decide(quoteEditID, .approve)
        _ = try await quoteEdit.value
        let editedPython = try Data(contentsOf: quoteFile)
        expect(editedPython == Data(python.utf8), "Edit altered Python source escapes")
        f.context.endTurn()
        print("PASS exact approved Python edit bytes")

        // Error diagnostics contain only fixed labels/codes, never paths,
        // source, error descriptions or arbitrary third-party error domains.
        expect(ToolContext.fileChangeFailureCode(ToolContext.ToolError.pathEscape("private/source.py")) == "outside_project", "Path escaped into diagnostics")
        expect(ToolContext.fileChangeFailureCode(ToolContext.ToolError.io("private source")) == "path_or_io", "Description escaped into diagnostics")
        expect(ToolContext.fileChangeFailureCode(PreparedFileChange.ChangeError.noMatch) == "no_match", "Missing preparation reason")
        expect(ToolContext.fileChangeFailureCode(PreparedFileChange.ChangeError.stale) == "stale_preview", "Missing apply reason")
        expect(ToolContext.fileChangeFailureCode(NSError(domain: "private source", code: 42, userInfo: [NSLocalizedDescriptionKey: "private source"])) == "other", "Unknown error data escaped into diagnostics")
        expect(ToolContext.fileChangeFailureCode(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)) == "cocoa_\(NSFileWriteNoPermissionError)", "OS error code missing")
        print("PASS content-free failure diagnostic codes")

        // A file changed after the shown preview must not be overwritten by approval.
        try Data("original".utf8).write(to: file)
        f.context.beginTurn()
        let stale = Task { try await write.call(arguments: .init(path: "sample.txt", content: "replacement")) }
        let staleID = try await pending(f.approvals)
        try Data("external update".utf8).write(to: file)
        f.approvals.decide(staleID, .approve)
        _ = try await stale.value
        let unchanged = try Data(contentsOf: file)
        expect(unchanged == Data("external update".utf8), "Stale approval overwrote external edit")
        print("PASS production stale approval rejected")

        // Cancelled callers must not bypass Stop via trusted-project fast paths.
        f.project.approvalMode = .auto
        let cancelled = Task { () -> ApprovalDecision in
            while !Task.isCancelled { await Task.yield() }
            return await f.approvals.wait(for: UUID(), command: command)
        }
        cancelled.cancel()
        let cancelledDecision = await cancelled.value
        expect(cancelledDecision == .cancelled, "Cancelled allowlisted request was approved")
        print("PASS cancelled approval fast path")
        print("ALL TOOL SAFETY TESTS PASSED (no model, no app data, no shell commands)")
    }
}
