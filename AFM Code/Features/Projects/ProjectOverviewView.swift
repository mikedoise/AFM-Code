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
    //
    // These Pickers use guarded bindings on purpose. A Picker re-asserts
    // its selection on every body evaluation; writing that back through
    // the @Model's stored raw value invalidates the view again, looping
    // within a frame ("onChange… tried to update multiple times per
    // frame"). The bindings drop same-value writes, and a not-yet-probed
    // catalog can never mismatch the selection and clobber the saved
    // choice, because the current value is always among the tags. Real
    // changes persist immediately.

    @ViewBuilder
    private var settingsSection: some View {
        Section {
            Picker("Model", selection: modelSelectionBinding) {
                Text("Best available").tag(ModelSelection?.none)
                ForEach(modelSelectionOptions, id: \.self) { selection in
                    Text(selectionLabel(for: selection)).tag(Optional(selection))
                }
            }
            .help("Default model for new sessions in this project.")

            Picker("Approvals", selection: approvalModeBinding) {
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

    private var modelSelectionBinding: Binding<ModelSelection?> {
        Binding(
            get: { project.modelSelection },
            set: { newValue in
                if project.modelSelection != newValue {
                    project.modelSelection = newValue
                    try? modelContext.save()
                }
            }
        )
    }

    private var approvalModeBinding: Binding<ApprovalMode?> {
        Binding(
            get: { project.approvalMode },
            set: { newValue in
                if project.approvalMode != newValue {
                    project.approvalMode = newValue
                    try? modelContext.save()
                }
            }
        )
    }

    /// The catalog's models as picker options, plus the saved choice
    /// if the catalog hasn't seen it yet (a stale probe, or a model
    /// that left the library), so the Picker's tags always include the
    /// current selection.
    private var modelSelectionOptions: [ModelSelection] {
        var options: [ModelSelection] = []
        for descriptor in catalog.descriptors {
            let selection: ModelSelection? = switch descriptor.kind {
            case .afmCore:
                .afmCore
            case .afmCoreAdvanced:
                .afmCoreAdvanced
            case .mlx:
                descriptor.mlxRepoID.map { ModelSelection.mlx(repoID: $0) }
            }
            if let selection, !options.contains(selection) {
                options.append(selection)
            }
        }
        if let current = project.modelSelection, !options.contains(current) {
            options.append(current)
        }
        return options
    }

    private func selectionLabel(for selection: ModelSelection) -> String {
        switch selection {
        case .bestAvailable:
            return "Best available"
        case .afmCore:
            return catalog.descriptor(for: .afmCore)?.displayName ?? "AFM 3 Core"
        case .afmCoreAdvanced:
            return catalog.descriptor(for: .afmCoreAdvanced)?.displayName ?? "AFM 3 Core Advanced"
        case .mlx(let repoID):
            return catalog.descriptor(for: .mlx, mlxRepoID: repoID)?.displayName ?? repoID
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
