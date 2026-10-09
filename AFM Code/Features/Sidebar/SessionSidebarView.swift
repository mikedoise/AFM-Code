import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

/// The project sidebar: projects (with their sessions) plus a
/// "General" group for sessions that predate projects.
struct SessionSidebarView: View {
    let projects: [Project]
    let sessions: [ChatSession]
    @Binding var selection: SidebarItem?

    @Environment(\.modelContext) private var modelContext
    @Environment(ModelCatalog.self) private var catalog
    @Environment(WorkspaceStore.self) private var workspaces
    @Environment(ChatController.self) private var chat

    @State private var expandedProjects: Set<UUID> = []
    @State private var renamingProject: Project?
    @State private var removingProject: Project?

    private var generalSessions: [ChatSession] {
        sessions.filter { $0.project == nil }
    }

    var body: some View {
        List(selection: $selection) {
            if !generalSessions.isEmpty {
                Section("General") {
                    ForEach(generalSessions) { session in
                        SessionRow(session: session)
                            .tag(SidebarItem.session(session.id))
                    }
                }
            }

            Section("Projects") {
                ForEach(projects) { project in
                    projectDisclosure(project)
                }
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Add a folder to start working on code.")
                } actions: {
                    Button("Add Project") {
                        addProject()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("AFM Code")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addProject()
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .help("Add a project folder")
            }
        }
        .sheet(item: $renamingProject) { project in
            RenameProjectSheet(project: project) { name in
                project.name = name
                try? modelContext.save()
            }
        }
        .confirmationDialog(
            "Remove \(removingProject?.name ?? "this project")?",
            isPresented: Binding(
                get: { removingProject != nil },
                set: { if !$0 { removingProject = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Project", role: .destructive) {
                if let project = removingProject {
                    removeProject(project)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions in this project are removed from AFM Code. The folder itself is not touched.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ModelBadgeView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.bar)
        }
    }

    // MARK: - Project row

    @ViewBuilder
    private func projectDisclosure(_ project: Project) -> some View {
        let workspace = workspaces.workspace(for: project)
        DisclosureGroup(isExpanded: expansionBinding(for: project)) {
            let projectSessions = project.sessionList
            ForEach(projectSessions) { session in
                SessionRow(session: session)
                    .tag(SidebarItem.session(session.id))
            }
            Button {
                createSession(in: project)
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(!canCreateSession(in: project))
        } label: {
            ProjectRow(
                project: project,
                status: workspace.status,
                sessionCount: project.sessions?.count ?? 0
            )
        }
        .tag(SidebarItem.project(project.id))
        .contextMenu {
            Button("New Session") { createSession(in: project) }
                .disabled(!canCreateSession(in: project))
            Button("Open in Finder") { openInFinder(project) }
            Button("Rename…") { renamingProject = project }
            Divider()
            Button("Remove from AFM Code", role: .destructive) {
                removingProject = project
            }
        }
    }

    private func expansionBinding(for project: Project) -> Binding<Bool> {
        Binding(
            get: { expandedProjects.contains(project.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedProjects.insert(project.id)
                } else {
                    expandedProjects.remove(project.id)
                }
            }
        )
    }

    private func canCreateSession(in project: Project) -> Bool {
        workspaces.workspace(for: project).status == .active
    }

    // MARK: - Actions

    private func addProject() {
        #if os(macOS)
        guard let url = ProjectPicker.run() else { return }
        let project = Project(name: url.lastPathComponent)
        project.folderName = url.lastPathComponent
        project.bookmarkData = try? url.bookmarkData(options: .withSecurityScope)
        modelContext.insert(project)
        try? modelContext.save()
        expandedProjects.insert(project.id)
        selection = .project(project.id)
        workspaces.workspace(for: project).refresh()
        #else
        // iOS project picker lands with the iPad pass.
        #endif
    }

    private func createSession(in project: Project) {
        let session = ChatSession(project: project)
        modelContext.insert(session)
        project.lastOpenedAt = Date()
        try? modelContext.save()
        expandedProjects.insert(project.id)
        selection = .session(session.id)
    }

    private func removeProject(_ project: Project) {
        chat.dropEngines(forProjects: project.sessionList)
        workspaces.drop(project.id)
        expandedProjects.remove(project.id)
        if case .project(let id)? = selection, id == project.id {
            selection = nil
        }
        modelContext.delete(project)
        try? modelContext.save()
    }

    private func openInFinder(_ project: Project) {
        #if os(macOS)
        guard let url = workspaces.workspace(for: project).folderURL else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Rows

private struct ProjectRow: View {
    let project: Project
    let status: Workspace.Status
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(project.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Spacer()
            if sessionCount > 0 {
                Text("\(sessionCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            statusDot
        }
        .help("\(project.name) — \(project.folderName)")
    }

    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .active:
            Circle().fill(.green).frame(width: 6, height: 6)
        case .folderMissing, .bookmarkInvalid:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .unknown:
            EmptyView()
        }
    }
}

struct SessionRow: View {
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(.body)
                .lineLimit(1)
            if let last = session.messageList.last {
                Text(last.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }
}
