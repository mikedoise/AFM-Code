import Foundation
import Darwin
@_silgen_name("sandbox_check")
func sandboxCheck(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32
@main struct DesktopProbe {
    static func main() async throws {
        precondition(sandboxCheck(getpid(), nil, 0) == 0, "Unexpected inherited sandbox")
        print("SIGNED_HARDENED_DESKTOP_NO_APP_SANDBOX")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let environment = await ShellEnvironment.resolved()!
        let candidates = EnvironmentDiagnostics.candidates(names: ["shell", "python3", "gh", "git"], environment: environment, root: root)
        print(EnvironmentDiagnostics.inventory(candidates))
        for candidate in candidates {
            guard let command = EnvironmentDiagnostics.command(for: candidate) else { preconditionFailure("Expected installed fixture tool unavailable: \(candidate.name)") }
            let run = try await ToolContext.runProcess(arguments: ["-c",command], workingDirectory: root, timeout: 8, maxOutputBytes: 4096, environment: environment)
            print(EnvironmentDiagnostics.probeResult(name: candidate.name, exitCode: run.exitCode, output: run.output, timedOut: run.timedOut))
            precondition(run.exitCode == 0 && !run.timedOut && EnvironmentDiagnostics.success(name: candidate.name, output: run.output) != nil)
        }
        let python = candidates.first { $0.name == "python3" }!.executable!
        fflush(nil)
        precondition(python.path == "/opt/homebrew/bin/python3", "Desktop PATH was overridden by Xcode")
        let command = EnvironmentDiagnostics.quote(python.path) + " -I -B -S " + EnvironmentDiagnostics.quote(root.appendingPathComponent("generated script.py").path)
        let run = try await ToolContext.runProcess(arguments: ["-c",command], workingDirectory: root, timeout: 8, maxOutputBytes: 4096, environment: environment)
        precondition(run.exitCode == 0 && run.output.contains("AFM_PYTHON_OK"))
        print("PASS Homebrew Python executes generated script with spaces in its path")
    }
}
