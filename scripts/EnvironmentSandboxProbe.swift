import Foundation
import Darwin

@_silgen_name("sandbox_check")
func sandboxCheck(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32

@main struct SandboxProbe {
    static func main() async throws {
        precondition(sandboxCheck(getpid(), nil, 0) == 1, "Fixture did not enter a sandbox")
        print("SIGNED_APP_SANDBOX_ACTIVE")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afm-capability-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("generated.py")
        try "print('AFM_PYTHON_OK Python 1.0.0')\n".write(to: script, atomically: true, encoding: .utf8)
        let environment = await ShellEnvironment.resolved() ?? ProcessInfo.processInfo.environment
        print(ShellEnvironment.captureSummary)
        let candidates = EnvironmentDiagnostics.candidates(names: ["shell", "python3", "gh", "git"], environment: environment, root: root)
        print(EnvironmentDiagnostics.inventory(candidates))
        for candidate in candidates {
            guard let command = EnvironmentDiagnostics.command(for: candidate) else { continue }
            do {
                let run = try await ToolContext.runProcess(arguments: ["-c",command], workingDirectory: root, timeout: 10, maxOutputBytes: 4096, environment: environment)
                print(EnvironmentDiagnostics.probeResult(name: candidate.name, exitCode: run.exitCode, output: run.output, timedOut: run.timedOut))
            } catch { print("\(candidate.name): could not start; raw error withheld") }
        }
        for path in ["/opt/homebrew/bin/gh", "/opt/homebrew/bin/python3"] {
            errno = 0
            let readable = access(path, R_OK)
            let readError = errno
            errno = 0
            let executable = access(path, X_OK)
            let executeError = errno
            print("KNOWN_PATH \(path): read=\(readable) errno=\(readError), execute=\(executable) errno=\(executeError)")
            // Classify one fixed version probe at the known installed path;
            // a denial is recorded, never retried via another access route.
            let name = path.hasSuffix("/gh") ? "gh" : "python3"
            let candidate = EnvironmentDiagnostics.Candidate(name: name, executable: URL(fileURLWithPath: path))
            let command = EnvironmentDiagnostics.command(for: candidate)!
            let run = try await ToolContext.runProcess(arguments: ["-c",command], workingDirectory: root, timeout: 10, maxOutputBytes: 4096, environment: environment)
            print("KNOWN_PATH_PROBE " + EnvironmentDiagnostics.probeResult(name: name, exitCode: run.exitCode, output: run.output, timedOut: run.timedOut))
        }
        // Execute one harmless generated script, first with the PATH interpreter,
        // then with Homebrew explicitly if present. All files are fixture-owned.
        let pythonPaths = Set([candidates.first(where: { $0.name == "python3" })?.executable?.path, "/opt/homebrew/bin/python3"].compactMap { $0 })
        for path in pythonPaths.sorted() where FileManager.default.isExecutableFile(atPath: path) {
            let command = EnvironmentDiagnostics.quote(path) + " -I -B -S " + EnvironmentDiagnostics.quote(script.path)
            let run = try await ToolContext.runProcess(arguments: ["-c",command], workingDirectory: root, timeout: 10, maxOutputBytes: 4096, environment: environment)
            print("GENERATED_SCRIPT \(path): " + EnvironmentDiagnostics.probeResult(name: "python3", exitCode: run.exitCode, output: run.output, timedOut: run.timedOut))
        }
    }
}
