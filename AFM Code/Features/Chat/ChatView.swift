import SwiftUI
import SwiftData

/// The main chat pane for a session: transcript above, composer below.
struct ChatView: View {
    let session: ChatSession

    @Environment(ModelCatalog.self) private var catalog
    @Environment(ChatController.self) private var chat
    @Environment(WorkspaceStore.self) private var workspaces
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @State private var engine: SessionEngine?

    var body: some View {
        @Bindable var chat = chat
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
                engine = chat.engine(for: session, modelContext: modelContext, catalog: catalog, workspaces: workspaces, settings: settings)
            }
            engine?.prewarm()
        }
        .id(session.id)
    }

    /// Per-session model selection: the OS decides which on-device
    /// variant a machine gets, and the user can pin one (or back to
    /// "best available").
    private var modelPicker: some View {
        Menu {
            Button {
                session.modelKind = nil
            } label: {
                let isSelected = session.modelKind == nil
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark" : "circle")
                        Text("Best available")
                    }
                    Text("Whichever model this Mac is offered")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ForEach(catalog.descriptors) { descriptor in
                Button {
                    session.modelKind = descriptor.kind
                } label: {
                    let isSelected = session.modelKind == descriptor.kind && descriptor.isAvailable
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: isSelected ? "checkmark" : (descriptor.isAvailable ? "circle" : "xmark"))
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
        .help("Model for this session")
        .onChange(of: session.modelKindRaw) {
            try? modelContext.save()
        }
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
