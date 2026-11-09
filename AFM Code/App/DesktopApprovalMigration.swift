import Foundation
import SwiftData

/// Sandbox-era automatic authority is not approval for host access. Keep the
/// previous settings as inactive history, then require fresh desktop grants.
@MainActor enum DesktopApprovalMigration {
    static func apply(to context: ModelContext) throws {
        let projects = try context.fetch(FetchDescriptor<Project>())
        let servers = try context.fetch(FetchDescriptor<MCPServer>())
        guard projects.allSatisfy({ $0.desktopAccessVersion == nil || $0.desktopAccessVersion == 1 }),
              servers.allSatisfy({ $0.desktopAccessVersion == nil || $0.desktopAccessVersion == 1 }) else {
            throw NSError(domain: "AFMDesktopApprovalMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: "This data uses a newer approval format. Open it with the newer AFM Code build; no grants were changed."])
        }
        do {
            for project in projects where project.desktopAccessVersion != 1 {
                project.sandboxCommandAllowlist = project.commandAllowlist
                project.sandboxApprovalModeRaw = project.approvalModeRaw
                project.commandAllowlist = []
                project.approvalMode = .ask
                project.desktopAccessVersion = 1
            }
            for server in servers where server.desktopAccessVersion != 1 {
                server.wasEnabledInSandbox = server.isEnabled
                server.isEnabled = false
                server.desktopAccessVersion = 1
                server.lastError = nil
                server.toolCount = nil
            }
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            throw error // Do not expose engines or launch servers on failure.
        }
    }
}
