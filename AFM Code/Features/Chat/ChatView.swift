import SwiftUI
import SwiftData

/// The main chat pane for a session: transcript above, composer below.
struct ChatView: View {
    let session: ChatSession

    @Environment(ModelCatalog.self) private var catalog
    @Environment(ChatController.self) private var chat
    @Environment(WorkspaceStore.self) private var workspaces
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
                engine = chat.engine(for: session, modelContext: modelContext, catalog: catalog, workspaces: workspaces)
            }
        }
        .id(session.id)
    }

    /// Per-session model selection. Phase 1 lists the detected
    /// on-device variants (the OS decides which one a machine gets);
    /// PCC joins this menu in Phase 4.
    private var modelPicker: some View {
        Menu {
            ForEach(catalog.descriptors) { descriptor in
                Button {
                    session.modelKind = descriptor.kind
                } label: {
                    let isSelected = (engine?.activeModel ?? catalog.activeDescriptor)?.kind == descriptor.kind
                    if descriptor.isAvailable {
                        Label(descriptor.displayName, systemImage: isSelected ? "checkmark" : "circle")
                    } else if let detail = descriptor.availabilityDetail {
                        Text(detail)
                    } else {
                        Label(descriptor.displayName, systemImage: "xmark")
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
    }
}
