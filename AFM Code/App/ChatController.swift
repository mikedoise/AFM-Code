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
    /// The detail-pane selection, persisted so the last project or
    /// session is selected again on relaunch.
    var selection: SidebarItem? {
        didSet { Self.saveSelection(selection, to: defaults) }
    }

    private let defaults: UserDefaults
    private var engines: [UUID: SessionEngine] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selection = Self.loadSelection(from: defaults)
    }

    private enum Keys {
        static let selection = "controller.selection"
    }

    private static func saveSelection(_ selection: SidebarItem?, to defaults: UserDefaults) {
        switch selection {
        case .project(let id):
            defaults.set("project:\(id.uuidString)", forKey: Keys.selection)
        case .session(let id):
            defaults.set("session:\(id.uuidString)", forKey: Keys.selection)
        case nil:
            defaults.removeObject(forKey: Keys.selection)
        }
    }

    private static func loadSelection(from defaults: UserDefaults) -> SidebarItem? {
        guard let raw = defaults.string(forKey: Keys.selection),
              let separator = raw.firstIndex(of: ":") else { return nil }
        let kind = String(raw[..<separator])
        let idString = String(raw[raw.index(after: separator)...])
        guard let id = UUID(uuidString: idString) else { return nil }
        switch kind {
        case "project": return .project(id)
        case "session": return .session(id)
        default: return nil
        }
    }

    // MARK: - Command-facing accessors

    /// The selected session, when the detail pane shows one.
    var selectedSessionID: UUID? {
        if case .session(let id)? = selection { return id }
        return nil
    }

    /// True while the session's engine is mid-turn (responding or
    /// compacting) — the ⌘. Stop command's enabled state. A session
    /// whose ChatView has never appeared has no cached engine and so
    /// is not responding.
    func isResponding(forSessionID id: UUID) -> Bool {
        engines[id]?.isBusy == true
    }

    /// ⌘. — cancel the in-flight turn of a session whose engine is
    /// cached in this window.
    func stopResponse(forSessionID id: UUID) {
        engines[id]?.cancel()
    }

    /// ⌘N — create a session in the selected project and select it.
    /// No-ops (and reports `nil`) unless a project is selected.
    @discardableResult
    func createSessionInSelectedProject() -> ChatSession? {
        guard case .project(let projectID) = selection else { return nil }
        let context = ModelContainerProvider.container.mainContext
        let predicate = #Predicate<Project> { $0.id == projectID }
        guard let project = try? context.fetch(FetchDescriptor(predicate: predicate)),
              let project = project.first else { return nil }
        let session = ChatSession.create(in: project, context: context)
        selection = .session(session.id)
        return session
    }

    /// Clear the persisted selection when it no longer matches anything
    /// (the item was removed, or the window's data changed).
    func validateSelection(projects: [Project], sessions: [ChatSession]) {
        guard let current = selection else { return }
        let known: Bool
        switch current {
        case .project(let id):
            known = projects.contains { $0.id == id }
        case .session(let id):
            known = sessions.contains { $0.id == id }
        }
        if !known {
            selection = nil
        }
    }

    func engine(
        for session: ChatSession,
        modelContext: ModelContext,
        catalog: ModelCatalog,
        mlx: MLXModelManager,
        mcp: MCPHostManager,
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
            mlx: mlx,
            mcp: mcp,
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
