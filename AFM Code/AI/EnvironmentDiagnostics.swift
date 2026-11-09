import Foundation
import Darwin

/// A deliberately small capability report, never a dump of environment values,
/// shell startup output, authentication state, config files or arbitrary stdout.
nonisolated enum EnvironmentDiagnostics {
    static let names = ["shell", "python3", "python", "gh", "git", "node", "npm", "uv", "rg"]

    struct Candidate: Sendable, Equatable {
        let name: String
        let executable: URL?
        var accessRestricted = false
    }

    static func candidates(names: [String], environment: [String: String], root: URL) -> [Candidate] {
        names.map { name in
            if name == "shell" { return Candidate(name: name, executable: URL(fileURLWithPath: "/bin/zsh")) }
            return scan(name, path: environment["PATH"] ?? "/usr/bin:/bin", root: root)
        }
    }

    static func find(_ name: String, path: String, root: URL) -> URL? {
        scan(name, path: path, root: root).executable
    }

    private static func scan(_ name: String, path: String, root: URL) -> Candidate {
        guard names.contains(name), name != "shell" else { return Candidate(name: name, executable: nil) }
        var restricted = false
        // Empty/relative PATH entries are relative to the command's project cwd.
        for entry in path.components(separatedBy: ":") {
            let directory = entry.hasPrefix("/") ? URL(fileURLWithPath: entry)
                : root.appendingPathComponent(entry.isEmpty ? "." : entry)
            let url = directory.appendingPathComponent(name).standardizedFileURL
            errno = 0
            let accessResult = access(url.path, X_OK)
            let accessError = errno
            if accessResult < 0 && (accessError == EPERM || accessError == EACCES) { restricted = true }
            var isDirectory: ObjCBool = false
            if accessResult == 0, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) {
                return Candidate(name: name, executable: url)
            }
        }
        return Candidate(name: name, executable: nil, accessRestricted: restricted)
    }

    static func command(for candidate: Candidate) -> String? {
        guard let executable = candidate.executable, names.contains(candidate.name) else { return nil }
        let path = quote(executable.path)
        switch candidate.name {
        case "shell": return "\(path) -f -c " + quote("printf AFM_SHELL_OK")
        case "python", "python3":
            return "\(path) -I -B -S -c " + quote("import sys; print('AFM_PYTHON_OK Python %d.%d.%d' % sys.version_info[:3])")
        default: return "\(path) --version"
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func visiblePath(_ url: URL) -> String {
        String(url.path.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : String($0) }.joined().prefix(512))
    }

    static func inventory(_ candidates: [Candidate]) -> String {
        candidates.map { candidate in
            if let executable = candidate.executable {
                return "\(candidate.name): found at \(visiblePath(executable)); execution not tested."
            }
            if candidate.accessRestricted {
                return "\(candidate.name): not discoverable; at least one PATH candidate reports denied access or lacks execute permission. This is not proof it is uninstalled. Execution not tested."
            }
            return "\(candidate.name): not found on the resolved PATH (not proof it is uninstalled; sandbox visibility can also hide tools)."
        }.joined(separator: "\n")
    }

    /// Return only a fixed success marker or a strictly numeric version. An
    /// executable or startup script may print credentials; do not relay that text.
    static func success(name: String, output: String) -> String? {
        if name == "shell" { return output.trimmingCharacters(in: .whitespacesAndNewlines) == "AFM_SHELL_OK" ? "shell probe passed" : nil }
        let prefixes: [String: String] = ["python": "AFM_PYTHON_OK Python ", "python3": "AFM_PYTHON_OK Python ",
            "gh": "gh version ", "git": "git version ", "node": "v", "npm": "", "uv": "uv ", "rg": "ripgrep "]
        guard let prefix = prefixes[name] else { return nil }
        for line in output.components(separatedBy: .newlines) where line.hasPrefix(prefix) {
            let suffix = String(line.dropFirst(prefix.count))
            guard let range = suffix.range(of: #"^[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?(?=$|[\s+\-(])"#, options: .regularExpression) else { continue }
            let version = String(suffix[range])
            guard version.count <= 32 else { continue }
            return "\(name) \(version) probe passed"
        }
        return nil
    }

    static func failureHint(output: String, exitCode: Int32) -> String? {
        let lower = output.lowercased()
        if lower.contains("cannot be used within an app sandbox") {
            return "The output reports an App Sandbox-incompatible developer shim. Use the resolved real tool path from environment_check; this does not grant extra permissions."
        }
        if lower.contains("operation not permitted") || lower.contains("permission denied") {
            return "The output reports denied access. This may be macOS sandbox/privacy access or file permissions. Approval and PATH changes cannot grant that access; do not retry through another route to bypass it."
        }
        if lower.contains("modulenotfounderror") || lower.contains("no module named") {
            return "The selected Python interpreter cannot import a required module. Check its path/version and the project's environment; another installed Python may have different packages. Do not install packages or change access without user approval."
        }
        if exitCode == 127 || lower.contains("command not found") {
            return "Command lookup failed. Use environment_check to distinguish a missing PATH entry from an unavailable executable; do not assume the tool is uninstalled."
        }
        if lower.contains("could not read username") || lower.contains("authentication failed") || lower.contains("terminal prompts disabled") || lower.contains("not logged into") {
            return "Authentication is unavailable to this noninteractive process. Finding or running the executable does not establish account access. Do not print credentials; ask the user to handle authentication."
        }
        return nil
    }

    static func probeResult(name: String, exitCode: Int32, output: String, timedOut: Bool) -> String {
        if timedOut { return "\(name): probe timed out. Execution capability is unconfirmed. Raw output withheld." }
        if exitCode == 0, let result = success(name: name, output: output) {
            return result + ". This does not verify project dependencies, credentials, network access or arbitrary scripts."
        }
        let reason = failureHint(output: output, exitCode: exitCode)
            ?? "The probe did not return its expected success/version result."
        return "\(name): probe failed (exit \(exitCode)). \(reason) Raw output withheld."
    }

    static let limitations = """
    Scope: file tools stay inside the selected project; approved shell commands run with your normal Mac account access, including outside the project. Commands run in noninteractive zsh, without a terminal or stdin, with a 300-second maximum. Aliases/functions are not imported. Approval does not override macOS privacy or filesystem permissions. A discovered path is not proof of execution, and a version probe is not a login or end-to-end capability test. No environment values, credential/config contents, or raw probe output are included.
    """
}
