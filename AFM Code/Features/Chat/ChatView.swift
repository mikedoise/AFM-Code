import MLXFoundationModels
import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

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
    /// The composer's draft, lifted here so the keyboard commands can
    /// guard on it (regeneration refuses to swallow an unsent draft,
    /// the way Perspective Intelligence does).
    @State private var draft = ""
    /// Composer focus, lifted here so ⌘L can drive it and the ⌘⌫
    /// delete guard can read it.
    @FocusState private var composerFocus: Bool

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
            ComposerView(session: session, engine: engine, draft: $draft, focus: $composerFocus)
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
        .focusedSceneValue(\.afmDetailCommands, detailCommands)
    }

    // MARK: - Keyboard commands

    /// What this visible session offers the "Sessions" menu. The flags
    /// read observable state (engine busy-ness, message list, draft,
    /// composer focus), so the menu re-evaluates whenever any of it
    /// changes; the closures read live state when invoked.
    private var detailCommands: SessionDetailCommands {
        let messages = session.messageList
        let busy = engine?.isBusy == true || engine?.isCompacting == true
        let draftEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAssistantResponse = messages.contains {
            $0.role == .assistant
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasContent = messages.contains {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasUserMessage = messages.contains { $0.role == .user }
        return SessionDetailCommands(
            canRegenerate: engine != nil && !busy && draftEmpty && hasUserMessage,
            canCopyLastResponse: hasAssistantResponse,
            canCopyTranscript: hasContent,
            isComposerFocused: composerFocus,
            regenerateLastResponse: { self.regenerateLastResponse() },
            copyLastResponse: { self.copyLastResponse() },
            copyTranscript: { self.copyTranscript() },
            showModelPicker: { self.showModelPicker = true },
            focusComposer: { self.composerFocus = true }
        )
    }

    /// ⌘R — re-run the last user turn in place of its answer. An
    /// unsent draft is never sent along with it.
    private func regenerateLastResponse() {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let engine,
              engine.isBusy != true, engine.isCompacting != true else { return }
        engine.regenerate()
    }

    /// ⇧⌘C — the last non-empty assistant response to the pasteboard.
    private func copyLastResponse() {
        #if os(macOS)
        guard let message = session.messageList.last(where: {
            $0.role == .assistant
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        VoiceOverAnnouncer.announce("Copied the last response")
        #endif
    }

    /// ⌥⇧⌘C — the whole transcript to the pasteboard, in the
    /// Perspective Intelligence shape: the title, then each message
    /// under its speaker.
    private func copyTranscript() {
        #if os(macOS)
        let text = Self.transcriptText(for: session)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        VoiceOverAnnouncer.announce("Copied the conversation")
        #endif
    }

    private static func transcriptText(for session: ChatSession) -> String {
        var sections: [String] = []
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            sections.append(title)
        }
        for message in session.messageList {
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = message.role == .user ? "You" : "Assistant"
            sections.append("\(speaker):\n\(text)")
        }
        return sections.joined(separator: "\n\n")
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
