import SwiftUI
import SwiftData

/// App root: sidebar (projects + sessions) and a detail pane that
/// shows either a project overview or a session chat.
struct RootView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(ChatController.self) private var chat
    @Environment(WorkspaceStore.self) private var workspaces
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Project.lastOpenedAt, order: .reverse)
    private var projects: [Project]
    @Query(sort: \ChatSession.lastMessageAt, order: .reverse)
    private var sessions: [ChatSession]

    var body: some View {
        @Bindable var chat = chat
        NavigationSplitView {
            SessionSidebarView(
                projects: projects,
                sessions: sessions,
                selection: $chat.selection
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            detailPane
        }
        .task {
            workspaces.refreshAll(projects: projects)
        }
        .onChange(of: projects.map(\.id)) {
            workspaces.refreshAll(projects: projects)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                workspaces.refreshAll(projects: projects)
                // The on-device model is loaded on demand and its
                // availability can change while backgrounded; re-probe
                // on wake so badges and gauges stay truthful.
                Task { await catalog.probe() }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch chat.selection {
        case .project(let id):
            if let project = projects.first(where: { $0.id == id }) {
                ProjectOverviewView(project: project)
            } else {
                EmptyDetailView(hasProjects: false)
            }
        case .session(let id):
            if let session = sessions.first(where: { $0.id == id }) {
                ChatView(session: session)
            } else {
                EmptyDetailView(hasProjects: projects.isEmpty)
            }
        case nil:
            EmptyDetailView(hasProjects: projects.isEmpty)
        }
    }
}

/// Shown when nothing (or a stale selection) is in the detail pane.
private struct EmptyDetailView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(WorkspaceStore.self) private var workspaces
    let hasProjects: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: hasProjects ? "curlybraces.square" : "folder.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(hasProjects ? "No Selection" : "Welcome to AFM Code")
                .font(.title3.weight(.semibold))
            Text(hasProjects
                ? "Select a project or session to start coding."
                : "Add a folder to work in, and chat with the on-device model about it.")
                .foregroundStyle(.secondary)
            if hasProjects {
                ModelBadgeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
