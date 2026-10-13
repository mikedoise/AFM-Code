import MLXFoundationModels
import SwiftUI
import SwiftData

/// The main chat pane for a session: bubbles above, composer below.
///
/// The navigation title doubles as the model picker (the Perspective
/// Intelligence flow): the title and the current model's name sit in
/// the title bar, and tapping them opens the "Choose model" popover.
struct ChatView: View {
    let session: ChatSession

    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXModelManager.self) private var mlx
    @Environment(ChatController.self) private var chat
    @Environment(WorkspaceStore.self) private var workspaces
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @State private var engine: SessionEngine?
    @State private var showModelPicker = false

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
            ComposerView(session: session, engine: engine)
        }
        .background {
            ChatWindowBackground()
        }
        .accessibilityTurnAnnouncements(engine: engine, settings: settings)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                titleModelPickerButton
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

    // MARK: - Title model picker

    /// The title + model name as one spoken phrase: "Fix login bug, On-
    /// device model. Double-tap to choose the model."
    private var accessibilityTitle: String {
        let title = session.title.isEmpty ? "Chat" : session.title
        let model = (engine?.activeModel ?? catalog.activeDescriptor)?.displayName
        return model.map { "\(title), \($0)" } ?? title
    }

    private var titleModelPickerButton: some View {
        Button {
            showModelPicker.toggle()
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.title)
                        .font(.body)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: showModelPicker ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                }

                if let model = engine?.activeModel ?? catalog.activeDescriptor {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: ModelIdentityPalette.identity(for: model).gradient,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 7, height: 7)
                        Text(model.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .help("Choose the model for this session")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("Shows the model picker")
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityAction(.default) {
            showModelPicker.toggle()
        }
        .popover(isPresented: $showModelPicker, arrowEdge: .top) {
            ModelPickerPanel(session: session, catalog: catalog)
                .frame(
                    minWidth: 360, idealWidth: 480, maxWidth: 560,
                    minHeight: 300, idealHeight: 440, maxHeight: 560
                )
                .padding(12)
                .presentationBackground {
                    ChatWindowBackground()
                }
        }
    }
}
