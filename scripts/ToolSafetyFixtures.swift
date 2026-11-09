import Foundation

// Minimal app-state fixtures only. The harness links the production ToolContext,
// approval service, tools, and immutable change implementation unchanged.
// No SwiftData container, bookmarks, preferences, or user workspace is opened.
@MainActor final class Project {
    var commandAllowlist: [String]? = []
    var approvalMode: ApprovalMode = .ask
    var desktopAccessVersion: Int? = 1
}

@MainActor final class ChatSession {}

@MainActor final class Workspace {
    enum Status { case active, folderMissing }
    var status = Status.active
    let folderURL: URL?
    init(folderURL: URL) { self.folderURL = folderURL }
    func withAccess<T>(_ operation: (URL) throws -> T) rethrows -> T? {
        guard let folderURL else { return nil }
        return try operation(folderURL)
    }
    func acquireLease() -> Bool { folderURL != nil }
    func releaseLease() {}
}

enum ShellEnvironment {
    static func inspectionSnapshot() -> (environment: [String: String], summary: String) { (ProcessInfo.processInfo.environment, "Fixture") }
    nonisolated static func developerUSRBIN() -> String? { "/Applications/Xcode.app/Contents/Developer/usr/bin" }
    static func resolved() async -> [String: String]? {
        // Containment tests must fail before reaching any process invocation.
        preconditionFailure("The tool safety harness must not launch a shell")
    }
}

@MainActor final class ToolSafetyFixture {
    let directory: URL
    let root: URL
    let outside: URL
    let project = Project()
    let context: ToolContext
    let approvals: ToolApprovalService

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("afm-tool-safety-\(UUID())")
        root = directory.appendingPathComponent("project")
        outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        approvals = ToolApprovalService(project: project)
        context = ToolContext(session: ChatSession(), workspace: Workspace(folderURL: root), approvals: approvals)
    }

    func cleanup() throws { try FileManager.default.removeItem(at: directory) }
}
