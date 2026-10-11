import MLXFoundationModels
import SwiftUI
import SwiftData

/// The main chat pane for a session: transcript above, composer below.
struct ChatView: View {
    let session: ChatSession

    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXModelManager.self) private var mlx
    @Environment(ChatController.self) private var chat
    @Environment(WorkspaceStore.self) private var workspaces
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @State private var engine: SessionEngine?
    @State private var showModelsSheet = false

    var body: some View {
        @Bindable var chat = chat
        // Reading the shared download state registers observation of
        // the observable progress tracker; the task below re-derives
        // the catalog's MLX descriptors whenever the set of active
        // downloads changes — a download starting or finishing.
        let downloadSignature = MLXDownloadProgress.shared.activeDownloads
            .map(\.modelID)
            .sorted()
            .joined(separator: ",")
        VStack(spacing: 0) {
            MessageListView(session: session, engine: engine)
            Divider()
            ComposerView(session: session, engine: engine)
        }
        .navigationTitle(session.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                modelPicker
            }
        }
        .onAppear {
            if engine == nil {
                engine = chat.engine(
                    for: session,
                    modelContext: modelContext,
                    catalog: catalog,
                    mlx: mlx,
                    workspaces: workspaces,
                    settings: settings
                )
            }
            engine?.prewarm()
        }
        .task(id: downloadSignature) {
            await catalog.refreshMlxModels()
        }
        .id(session.id)
    }

    /// Per-session model selection: the on-device AFM pair (the OS
    /// decides which variant a machine gets, and the user can pin
    /// either or back to "best available"), then the MLX models in the
    /// library, and a shortcut to that library.
    private var modelPicker: some View {
        Menu {
            Button {
                session.modelKind = nil
                session.mlxModelID = nil
                try? modelContext.save()
            } label: {
                let isSelected = session.modelKind == nil
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark" : "circle")
                        Text("Best available")
                    }
                    Text("The on-device model, or a ready MLX model")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ForEach(catalog.afmDescriptors) { descriptor in
                modelButton(descriptor)
            }

            if !catalog.mlxDescriptors.isEmpty {
                Divider()
                ForEach(catalog.mlxDescriptors) { descriptor in
                    modelButton(descriptor)
                }
            }

            Divider()

            Button {
                showModelsSheet = true
            } label: {
                Label("Manage MLX Models…", systemImage: "square.stack.3d.up")
            }
            .help("Search the Hugging Face Hub and download models to run locally.")
        } label: {
            if let model = engine?.activeModel ?? catalog.activeDescriptor {
                Label(
                    model.displayName,
                    systemImage: model.isAvailable ? "cpu" : "exclamationmark.triangle.fill"
                )
            } else {
                Label("No Model", systemImage: "questionmark.circle")
            }
        }
        .sheet(isPresented: $showModelsSheet) {
            ModelsView()
                .frame(width: 680, height: 640)
        }
        .help("Model for this session")
    }

    /// One entry of the picker for a specific model. Unavailable
    /// models stay selectable-disabled with a reason: an MLX model
    /// shows how to make it available, an AFM variant why it isn't.
    private func modelButton(_ descriptor: ModelDescriptor) -> some View {
        let isSelected = descriptor.isAvailable && (
            descriptor.kind == .mlx
                ? session.modelKind == .mlx && session.mlxModelID == descriptor.mlxRepoID
                : session.modelKind == descriptor.kind
        )
        let statusIcon = isSelected
            ? "checkmark"
            : descriptor.isAvailable ? "circle" : (descriptor.kind == .mlx ? "tray.and.arrow.down" : "xmark")
        return Button {
            session.modelKind = descriptor.kind
            session.mlxModelID = descriptor.kind == .mlx ? descriptor.mlxRepoID : nil
            try? modelContext.save()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                    Text(descriptor.displayName)
                }
                if descriptor.isAvailable {
                    let meta = [
                        descriptor.contextSize.map { "\(ModelBadgeView.compact($0)) ctx" },
                        Self.capabilitySummary(descriptor)
                    ].compactMap { $0 }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let detail = descriptor.availabilityDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!descriptor.isAvailable)
    }

    /// "tools · reasoning · vision" from the descriptor's capability
    /// set, in a fixed order.
    private static func capabilitySummary(_ descriptor: ModelDescriptor) -> String? {
        let order = ["toolCalling", "reasoning", "vision"]
        let labels: [String: String] = [
            "toolCalling": "tools",
            "reasoning": "reasoning",
            "vision": "vision"
        ]
        let shown = order.filter { descriptor.capabilities.contains($0) }.compactMap { labels[$0] }
        return shown.isEmpty ? nil : shown.joined(separator: " · ")
    }
}
