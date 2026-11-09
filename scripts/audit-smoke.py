#!/usr/bin/env python3
"""Source-only accessibility guards and isolated command-runner regressions.
Does not launch AFM Code, load models, or run VoiceOver.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'AFM Code'
context = (source / 'AI/ToolContext.swift').read_text()
# Compile the production process implementation unchanged in a tiny container.
start = context.index('    nonisolated private final class PipedCapture')
end = context.index('    // MARK: - Formatting helpers', start)
harness = '''import Foundation
import Darwin
struct ToolContext {
    enum ToolError: Error { case io(String) }
    struct ProcessRun: Sendable { var exitCode: Int32; var output: String; var timedOut: Bool }
''' + context[start:end] + '''
}
@main struct Smoke {
    static func main() async throws {
        let directory = URL(fileURLWithPath: "/tmp")
        let clock = ContinuousClock()
        let start = clock.now
        let quick = try await ToolContext.runProcess(arguments: ["-c", "printf ok"], workingDirectory: directory, timeout: 5, maxOutputBytes: 1024)
        precondition(quick.output == "ok" && quick.exitCode == 0 && !quick.timedOut)
        precondition(start.duration(to: clock.now) < .seconds(2), "Quick command waited for timeout")
        print("PASS quick command returns before deadline")
        let failure = try await ToolContext.runProcess(arguments: ["-c", "printf failure >&2; exit 7"], workingDirectory: directory, timeout: 5, maxOutputBytes: 1024)
        precondition(failure.exitCode == 7 && failure.output.contains("failure") && !failure.timedOut)
        print("PASS nonzero exit and stderr")
        let timeout = try await ToolContext.runProcess(arguments: ["-c", "exec /bin/sleep 5"], workingDirectory: directory, timeout: 0.1, maxOutputBytes: 1024)
        precondition(timeout.timedOut && timeout.exitCode != 0)
        print("PASS timeout terminates child")
        let task = Task {
            try await ToolContext.runProcess(arguments: ["-c", "exec /bin/sleep 5"], workingDirectory: directory, timeout: 5, maxOutputBytes: 1024)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation was swallowed") }
        catch is CancellationError { print("PASS cancellation propagates") }
        let capped = try await ToolContext.runProcess(arguments: ["-c", "printf abcdefghijklmnop"], workingDirectory: directory, timeout: 5, maxOutputBytes: 8)
        precondition(capped.output == "abcdefgh")
        print("PASS output cap")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='afm-audit-') as temp:
    path = Path(temp)
    (path / 'Smoke.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', str(path / 'Smoke.swift'), '-o', str(path / 'smoke')], check=True)
    subprocess.run([str(path / 'smoke')], check=True, timeout=20)

checks = {
    'Features/Chat/ComposerView.swift': ['guard canSend, let engine else { return }'],
    'Features/Chat/MessageRowView.swift': ['.accessibilityAction(named: Text("Copy message"), copyMessage)', 'Attached image:'],
    'Features/Chat/DiffView.swift': ['"Added line"', '"Removed line"', '"Review all changes"'],
    'Features/Models/MCPServersView.swift': ['Toggle("Enable \\(server.name)"', 'Toggle("Enable \\(configured.name)"'],
    'Features/Chat/StepsDisclosureCard.swift': ['pendingStep?.id, initial: true', 'newID != oldID'],
    'AI/MCP/MCPTool.swift': ['detail: arguments.jsonString', 'throw CancellationError()'],
}
for name, fragments in checks.items():
    text = (source / name).read_text()
    for fragment in fragments:
        assert fragment in text, (name, fragment)
print('PASS source guards (not runtime accessibility validation)')
