import Foundation
import Observation
import SwiftData

/// What the detail pane shows: a project overview or a session chat.
enum SidebarItem: Hashable, Sendable {
    case project(UUID)
    case session(UUID)
}

/// Owns the detail-pane selection and the live session engines so they
/// survive view rebuilds.
///
/// Engines are cheap to recreate (a session resumes from its persisted
/// transcript), so this dictionary is a cache for the current window.
@MainActor
@Observable
final class ChatController {
    var selection: SidebarItem?

    private var engines: [UUID: SessionEngine] = [:]

    func engine(
        for session: ChatSession,
        modelContext: ModelContext,
        catalog: ModelCatalog,
        workspaces: WorkspaceStore,
        settings: AppSettings
    ) -> SessionEngine {
        if let existing = engines[session.id] {
            return existing
        }
        let engine = SessionEngine(
            session: session,
            modelContext: modelContext,
            catalog: catalog,
            workspaces: workspaces,
            settings: settings
        )
        engines[session.id] = engine
        return engine
    }

    func dropEngine(for sessionID: UUID) {
        engines[sessionID] = nil
    }

    /// Drop every engine belonging to a project (used on project removal).
    func dropEngines(forProjects sessions: [ChatSession]) {
        for session in sessions {
            engines[session.id] = nil
        }
    }
}
