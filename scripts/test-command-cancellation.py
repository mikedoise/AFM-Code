#!/usr/bin/env python3
"""Compile the unchanged command runner; use disposable markers only.
No model, app, network, repository mutation, or user shell startup files.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
context = (root / 'AFM Code/AI/ToolContext.swift').read_text()
start = context.index('    nonisolated private final class PipedCapture')
end = context.index('    // MARK: - Formatting helpers', start)
harness = '''import Foundation
struct ToolContext {
    enum ToolError: Error { case io(String) }
    struct ProcessRun: Sendable { var exitCode: Int32; var output: String; var timedOut: Bool }
''' + context[start:end] + r'''
}
@main struct Tests {
    static func main() async throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--probe-fd" {
            let descriptor = Int32(CommandLine.arguments[2])!
            let flags = fcntl(descriptor, F_GETFD)
            print(flags == -1 && errno == EBADF ? "descriptor-closed" : "descriptor-leaked")
            return
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let env = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "ZDOTDIR": directory.path,
                   "AFM_RUNNER_PROBE": "preserved"]
        func run(_ command: String, timeout: Double = 5, cap: Int = 1024) async throws -> ToolContext.ProcessRun {
            try await ToolContext.runProcess(arguments: ["-f", "-c", command], workingDirectory: directory,
                                             timeout: timeout, maxOutputBytes: cap, environment: env)
        }
        // Deliberately create an app-owned descriptor without FD_CLOEXEC.
        // Probe in a separately exec'd process, not a shell /dev/fd heuristic.
        let originalFD = open(directory.appendingPathComponent("private-fd-marker").path, O_RDWR | O_CREAT, mode_t(0o600))
        precondition(originalFD >= 0)
        let privateFD = fcntl(originalFD, F_DUPFD, 100)
        close(originalFD)
        precondition(privateFD >= 100 && fcntl(privateFD, F_SETFD, 0) == 0)
        defer { close(privateFD) }
        precondition(fcntl(privateFD, F_GETFD) & FD_CLOEXEC == 0)
        let executable = "'" + CommandLine.arguments[0].replacingOccurrences(of: "'", with: "'\\''") + "'"
        let descriptorProbe = try await run("exec \(executable) --probe-fd \(privateFD)")
        precondition(descriptorProbe.exitCode == 0 && descriptorProbe.output == "descriptor-closed\n",
                     "Command inherited an unrelated app descriptor: \(descriptorProbe.output)")
        precondition(fcntl(privateFD, F_GETFD) >= 0, "Parent descriptor was closed")
        print("PASS unrelated non-CLOEXEC app descriptor is closed in child and retained in parent")
        let clock = ContinuousClock()
        let timeoutStart = clock.now
        let timeout = try await run("(trap '' TERM HUP; /bin/zsh -f -c 'sleep 0.7; printf survived > timeout-marker') & wait", timeout: 0.1)
        precondition(timeout.timedOut && timeout.exitCode != 0)
        precondition(timeoutStart.duration(to: clock.now) < .seconds(1))
        try await Task.sleep(for: .seconds(1))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("timeout-marker").path))
        print("PASS timeout stops nested TERM/HUP-ignoring child")
        let task = Task { try await run("(trap '' TERM HUP; /bin/zsh -f -c 'sleep 0.7; printf survived > cancel-marker') & wait") }
        try await Task.sleep(for: .milliseconds(100))
        let cancelStart = clock.now
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation swallowed") }
        catch is CancellationError {}
        precondition(cancelStart.duration(to: clock.now) < .seconds(1))
        try await Task.sleep(for: .seconds(1))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel-marker").path))
        print("PASS Stop promptly cancels nested child and propagates cancellation")
        let backgroundStart = clock.now
        _ = try await run("(trap '' TERM HUP; sleep 0.7; printf survived > background-marker) & printf foreground")
        precondition(backgroundStart.duration(to: clock.now) < .seconds(1))
        try await Task.sleep(for: .seconds(1))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("background-marker").path))
        print("PASS finished shell does not leave background writers or blocked drains")
        let stdin = try await run("if read answer; then printf unexpected; else printf eof; fi")
        precondition(stdin.output == "eof" && !stdin.timedOut)
        let context = try await run("printf '%s\\n%s' \"$PWD\" \"$AFM_RUNNER_PROBE\"")
        let parts = context.output.components(separatedBy: "\n")
        precondition(parts.count == 2 && parts[1] == "preserved")
        precondition(URL(fileURLWithPath: parts[0]).resolvingSymlinksInPath() == directory.resolvingSymlinksInPath())
        print("PASS noninteractive stdin, working directory, captured environment")
        let failure = try await run("printf out; printf diagnostic >&2; exit 7")
        precondition(failure.exitCode == 7 && failure.output == "out\ndiagnostic" && !failure.timedOut)
        let flood = try await run("while true; do printf abcdefghijklmnopqrstuvwxyz; printf error >&2; done", timeout: 0.15, cap: 8)
        precondition(flood.timedOut && flood.output.utf8.count <= 8 + 1 + 4096)
        let capped = try await run("printf 123456789", cap: 4)
        precondition(capped.output == "1234")
        print("PASS exit status, diagnostics, capped flooding output, responsive timeout")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='afm-command-cancel-') as temporary:
    base = Path(temporary)
    (base / 'Tests.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                    str(base / 'Tests.swift'), '-o', str(base / 'tests')], check=True)
    subprocess.run([str(base / 'tests'), str(base)], check=True, timeout=20)
print('ALL COMMAND CANCELLATION TESTS PASSED')
