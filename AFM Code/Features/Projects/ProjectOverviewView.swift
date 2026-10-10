import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

/// Detail pane for a selected project: workspace status,
/// session list, and project actions.
struct ProjectOverviewView: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(ChatController.self) private var chat
    @Environment(WorkspaceStore.self) private var workspaces
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        @Bindable var chat = chat
        let workspace = workspaces.workspace(for: project)

        VStack(spacing: 0) {
            header(workspace)

            if workspace.status != .active {
                missingBanner(workspace)
            }

            Divider()

            HStack {
                Text("Sessions")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    createSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(workspace.status != .active)
                .help(workspace.status == .active
                    ? "New session in this project"
                    : "The project folder isn't available")
            }
            .padding(20)

            List {
                settingsSection

                if !(project.commandAllowlist ?? []).isEmpty {
                    allowlistSection
                }

                ForEach(project.sessionList) { session in
                    Button {
                        chat.selection = .session(session.id)
                    } label: {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
            .overlay {
                if project.sessionList.isEmpty {
                    ContentUnavailableView(
                        "No Sessions Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a session to work in \(project.name).")
                    )
                }
            }
        }
        .navigationTitle(project.name)
        .id(project.id)
        .onChange(of: project.modelKindRaw) {
            try? modelContext.save()
        }
        .onChange(of: project.approvalModeRaw) {
            try? modelContext.save()
        }
        .onAppear {
            workspace.refresh()
            project.lastOpenedAt = Date()
            try? modelContext.save()
        }
    }

    // MARK: - Header

    private func header(_ workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.title2.weight(.semibold))
                Text(folderPathText(workspace))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            statusLabel(workspace)
        }
        .padding(20)
    }

    private func folderPathText(_ workspace: Workspace) -> String {
        if let url = workspace.folderURL {
            return url.path
        }
        return "Folder unavailable (was: \(project.folderName))"
    }

    @ViewBuilder
    private func statusLabel(_ workspace: Workspace) -> some View {
        switch workspace.status {
        case .active:
            Label("Folder connected", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .folderMissing:
            Label("Folder missing", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        case .bookmarkInvalid:
            Label("Can't reach folder", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        case .unknown:
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: - Missing-folder recovery

    @ViewBuilder
    private func missingBanner(_ workspace: Workspace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
            Text("The folder for this project can't be found. It may have been moved or deleted.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open in Finder") {
                #if os(macOS)
                if let url = workspace.folderURL {
                    NSWorkspace.shared.open(url)
                }
                #endif
            }
            .disabled(workspace.folderURL == nil)
            Button("Choose New Folder") {
                #if os(macOS)
                if let url = ProjectPicker.run() {
                    project.folderName = url.lastPathComponent
                    project.bookmarkData = try? url.bookmarkData(options: .withSecurityScope)
                    try? modelContext.save()
                    workspace.refresh()
                }
                #endif
            }
        }
        .padding(16)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .bottom], 20)
    }

    // MARK: - Settings

    @ViewBuilder
    private var settingsSection: some View {
        @Bindable var project = project
        Section {
            Picker("Model", selection: $project.modelKind) {
                Text("Best available").tag(ModelDescriptor.Kind?.none)
                ForEach(catalog.descriptors) { descriptor in
                    Text(descriptor.displayName).tag(Optional(descriptor.kind))
                }
            }
            .help("Default model for new sessions in this project.")

            Picker("Approvals", selection: $project.approvalMode) {
                Text(ApprovalMode.ask.label).tag(ApprovalMode?.none)
                ForEach(ApprovalMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(Optional(mode))
                }
            }
            .help("Auto-approve runs file changes and commands without an approval card. Useful for trusted or scratch projects; the command allowlist still applies.")
        } header: {
            Text("Settings")
        }
    }

    // MARK: - Command allowlist

    private var allowlistSection: some View {
        Section {
            ForEach(project.commandAllowlist ?? [], id: \.self) { command in
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button {
                        removeCommand(command)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from the allowlist")
                }
            }
            HStack {
                Text("The agent runs these commands without asking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") {
                    project.commandAllowlist = []
                    try? modelContext.save()
                }
                .font(.caption)
            }
            .padding(.top, 4)
        } header: {
            Text("Allowed Commands (\((project.commandAllowlist ?? []).count))")
        }
    }

    private func removeCommand(_ command: String) {
        project.commandAllowlist = (project.commandAllowlist ?? []).filter { $0 != command }
        try? modelContext.save()
    }

    // MARK: - Actions

    private func createSession() {
        let session = ChatSession.create(in: project, context: modelContext)
        chat.selection = .session(session.id)
    }
}
