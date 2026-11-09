import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

@main
struct AFMCodeApp: App {
    @State private var chat: ChatController?
    @State private var workspaces: WorkspaceStore?
    @State private var settings: AppSettings?
    @State private var mlx: MLXModelManager?
    @State private var catalog: ModelCatalog?
    @State private var mcp: MCPHostManager?
    @State private var startupError: String?

    init() {
        do {
            // Never migrate a store while another app instance may be using its
            // old schema or approval settings. Do not terminate that instance.
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: DesktopStorage.bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            guard others.isEmpty else {
                throw NSError(domain: "AFMDesktopStartup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Close the other AFM Code instance, then reopen this build. Your existing data has not been migrated or reset."])
            }
            let context = try ModelContainerProvider.containerResult.get().mainContext
            let mlxManager = MLXModelManager(modelContext: context)
            _chat = State(initialValue: ChatController())
            _workspaces = State(initialValue: WorkspaceStore())
            _settings = State(initialValue: AppSettings())
            _mlx = State(initialValue: mlxManager)
            _catalog = State(initialValue: ModelCatalog(modelContext: context, mlx: mlxManager))
            _mcp = State(initialValue: MCPHostManager(modelContext: context))
        } catch {
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let catalog, let chat, let workspaces, let settings, let mlx, let mcp {
                RootView()
                    .environment(catalog).environment(chat).environment(workspaces)
                    .environment(settings).environment(mlx).environment(mcp)
                    .modelContainer(ModelContainerProvider.container)
                    .frame(minWidth: 860, minHeight: 540)
                    .task {
                        await catalog.probe()
                        await catalog.refreshMlxModels()
                    }
            } else { startupFailure }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { SessionCommands() }
        Settings {
            if let catalog, let settings, let mlx, let mcp {
                SettingsView()
                    .modelContainer(ModelContainerProvider.container)
                    .environment(catalog).environment(settings).environment(mlx).environment(mcp)
            } else { startupFailure }
        }
    }

    private var startupFailure: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("AFM Code could not open its existing data", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(startupError ?? "Storage preparation failed.").textSelection(.enabled)
            Text("No replacement database was opened. Close other AFM Code instances and check access to the existing app data before reopening. Do not delete the store to fix this error.")
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 220)
        .accessibilityElement(children: .combine)
    }

}

/// The keyboard commands, mirroring Perspective Intelligence's
/// ConversationTabCommands: the scene-level ⌘N in the File group and a
/// "Sessions" menu with turn control, copy, the model picker, composer
/// focus, session navigation, deletion, and recent sessions.
struct SessionCommands: Commands {
    @FocusedValue(\.afmSceneCommands) private var scene: SessionSceneCommands?
    @FocusedValue(\.afmDetailCommands) private var detail: SessionDetailCommands?
    @FocusedValue(\.afmListCommands) private var list: SessionListCommands?

    /// ⌘1 through ⌘9, then ⌘0 for the tenth.
    private static let recentSessionKeys: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                scene?.createSession()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(scene?.canCreateSession != true)
        }

        CommandMenu("Sessions") {
            Button("Stop Response") { scene?.stopResponse() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(scene?.isResponding != true)

            Button("Regenerate Response") { detail?.regenerateLastResponse() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(detail?.canRegenerate != true)

            Button("Copy Last Response") { detail?.copyLastResponse() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(detail?.canCopyLastResponse != true)

            Button("Copy Conversation") { detail?.copyTranscript() }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                .disabled(detail?.canCopyTranscript != true)

            Button("Choose Model…") { detail?.showModelPicker() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(detail == nil)

            Button("Go to Message Box") { detail?.focusComposer() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(detail == nil)

            Divider()

            Button("Previous Session") {
                if let id = scene?.previousSessionID { scene?.selectSession(id) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(scene?.previousSessionID == nil)

            Button("Next Session") {
                if let id = scene?.nextSessionID { scene?.selectSession(id) }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(scene?.nextSessionID == nil)

            Button("Delete Session…") { deleteSessionOrEditText() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(list?.canDeleteSelectedSession != true
                          || detail?.isComposerFocused == true)

            Divider()

            if let scene {
                let recent = scene.recentSessions
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, session in
                    Button(session.title) { scene.selectSession(session.id) }
                        .keyboardShortcut(Self.recentSessionKeys[index], modifiers: .command)
                }
            }
        }
    }

    /// ⌘⌫ deletes to the start of the line while typing, so a focused
    /// text view keeps that edit instead of the menu deleting the session.
    private func deleteSessionOrEditText() {
        #if os(macOS)
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable {
            textView.deleteToBeginningOfLine(nil)
            return
        }
        #endif
        list?.deleteSelectedSession()
    }
}
