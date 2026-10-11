import SwiftUI
import SwiftData

@main
struct AFMCodeApp: App {
    @State private var chat = ChatController()
    @State private var workspaces = WorkspaceStore()
    @State private var settings = AppSettings()
    @State private var mlx: MLXModelManager
    @State private var catalog: ModelCatalog

    // Built here (not in property initializers) because the catalog
    // needs the MLX manager, and a @State property's default value can't
    // reference a sibling property.
    init() {
        let context = ModelContainerProvider.container.mainContext
        let mlxManager = MLXModelManager(modelContext: context)
        _mlx = State(initialValue: mlxManager)
        _catalog = State(initialValue: ModelCatalog(modelContext: context, mlx: mlxManager))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(catalog)
                .environment(chat)
                .environment(workspaces)
                .environment(settings)
                .environment(mlx)
                .modelContainer(ModelContainerProvider.container)
                .frame(minWidth: 860, minHeight: 540)
                .focusedSceneValue(\.afmChat, chat)
                .task {
                    await catalog.probe()
                    await catalog.refreshMlxModels()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            NewSessionCommands()
        }
        Settings {
            SettingsView()
                .environment(catalog)
                .environment(settings)
                .environment(mlx)
        }
    }
}

extension FocusedValues {
    @Entry var afmChat: ChatController?
}

/// ⌘N creates a session in the currently selected project.
struct NewSessionCommands: Commands {
    @FocusedValue(\.afmChat) private var chat: ChatController?

    private var canCreate: Bool {
        guard let chat, case .project = chat.selection else { return false }
        return true
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                createSession()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!canCreate)
        }
    }

    @MainActor
    private func createSession() {
        guard let chat, case .project(let projectID) = chat.selection else { return }
        let context = ModelContainerProvider.container.mainContext
        let predicate = #Predicate<Project> { $0.id == projectID }
        guard let project = try? context.fetch(FetchDescriptor(predicate: predicate)), let project = project.first else { return }
        let session = ChatSession.create(in: project, context: context)
        chat.selection = .session(session.id)
    }
}
