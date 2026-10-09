import Foundation
import Observation

/// Owns the live `Workspace` per project so status survives view rebuilds.
@MainActor
@Observable
final class WorkspaceStore {
    private var workspaces: [UUID: Workspace] = [:]

    func workspace(for project: Project) -> Workspace {
        if let existing = workspaces[project.id] {
            return existing
        }
        let workspace = Workspace(project: project)
        workspaces[project.id] = workspace
        return workspace
    }

    func drop(_ projectID: UUID) {
        workspaces[projectID] = nil
    }

    func refreshAll(projects: [Project]) {
        for project in projects {
            workspace(for: project).refresh()
        }
    }
}
