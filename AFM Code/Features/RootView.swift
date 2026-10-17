import SwiftUI
import SwiftData

/// App root: sidebar (projects + sessions) and a detail pane that
/// shows either a project overview or a session chat.
struct RootView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MCPHostManager.self) private var mcp
    @Environment(ChatController.self) private var chat
    @Environment(WorkspaceStore.self) private var workspaces
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ChatBackgroundPreference.key)
    private var backgroundRawValue = ChatBackgroundPreference.defaultValue.rawValue
    @Query(sort: \Project.lastOpenedAt, order: .reverse)
    private var projects: [Project]
    @Query(sort: \ChatSession.lastMessageAt, order: .reverse)
    private var sessions: [ChatSession]
    @Query(sort: \MCPServer.addedAt)
    private var mcpServers: [MCPServer]

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
        .background {
            ChatWindowBackground()
        }
        .preferredColorScheme(
            (ChatBackgroundStyle(rawValue: backgroundRawValue) ?? ChatBackgroundPreference.defaultValue).isAlwaysDark
                ? .dark
                : nil
        )
        .task {
            workspaces.refreshAll(projects: projects)
            chat.validateSelection(projects: projects, sessions: sessions)
            mcp.reload(servers: mcpServers)
        }
        .onChange(of: projects.map(\.id)) {
            workspaces.refreshAll(projects: projects)
            chat.validateSelection(projects: projects, sessions: sessions)
        }
        .onChange(of: sessions.map(\.id)) {
            chat.validateSelection(projects: projects, sessions: sessions)
        }
        .onChange(of: mcpSignature) {
            mcp.reload(servers: mcpServers)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                workspaces.refreshAll(projects: projects)
                // The on-device model is loaded on demand and its
                // availability can change while backgrounded; re-probe
                // on wake so badges and gauges stay truthful.
                Task { await catalog.probe() }
                // Reconnect any MCP servers released when the app
                // went to the background.
                mcp.reload(servers: mcpServers)
            case .background:
                mcp.shutdown()
            default:
                break
            }
        }
        .focusedSceneValue(\.afmSceneCommands, sceneCommands)
    }

    /// A comparison-friendly snapshot of the MCP configuration, so the
    /// host manager is asked to reconcile only when a server row
    /// actually changed (not on every unrelated re-render).
    private var mcpSignature: String {
        mcpServers
            .map { $0.id.uuidString + "\u{1}" + $0.launchSignature }
            .joined(separator: "\u{2}")
    }

    /// What the keyboard commands need from the window: the ordered
    /// session list (recents and ⌥⌘↑/⌥⌘↓ neighbors), the selection,
    /// the selected session's turn state, and the ⌘N target. Reading
    /// `chat`'s tracked state here is what keeps the menu in step —
    /// selection changes, engine creation, and turn starts all re-render
    /// this value.
    private var sceneCommands: SessionSceneCommands {
        let selectedID = chat.selectedSessionID
        let selectedIndex = selectedID.flatMap { id in
            sessions.firstIndex { $0.id == id }
        }
        return SessionSceneCommands(
            recentSessions: sessions.prefix(10).map {
                .init(id: $0.id, title: $0.title)
            },
            selectedSessionID: selectedID,
            previousSessionID: selectedIndex.flatMap { index in
                index > 0 ? sessions[index - 1].id : nil
            },
            nextSessionID: selectedIndex.flatMap { index in
                index + 1 < sessions.count ? sessions[index + 1].id : nil
            },
            isResponding: selectedID.map { chat.isResponding(forSessionID: $0) } ?? false,
            canCreateSession: {
                if case .project = chat.selection { return true }
                return false
            }(),
            selectSession: { chat.selection = .session($0) },
            stopResponse: {
                if let selectedID {
                    chat.stopResponse(forSessionID: selectedID)
                }
            },
            createSession: { chat.createSessionInSelectedProject() }
        )
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
