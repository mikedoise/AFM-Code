import SwiftUI

/// The Settings window (⌘,): the system prompt editor and a read-only
/// look at the detected on-device model.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.colorScheme) private var colorScheme
    @State private var showModels = false
    @AppStorage(ChatBubblePreference.key)
    private var bubbleStyleRawValue = ChatBubblePreference.defaultValue.rawValue
    @AppStorage(ChatBackgroundPreference.key)
    private var backgroundRawValue = ChatBackgroundPreference.defaultValue.rawValue

    var body: some View {
        Form {
            promptSection
            modelSection
            mlxSection
            appearanceSection
            accessibilitySection
        }
        .formStyle(.grouped)
        .frame(width: 700, height: 700)
    }

    // MARK: - System prompt

    private var promptSection: some View {
        Section {
            TextEditor(text: Binding(
                get: { settings.systemPrompt ?? "" },
                set: { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    settings.systemPrompt = trimmed.isEmpty ? nil : newValue
                }
            ))
            .font(.system(.callout, design: .monospaced))
            .frame(minHeight: 260)

            LabeledContent("Characters") {
                Text("\(settings.systemPrompt?.count ?? 0)")
                    .foregroundStyle(.secondary)
            }

            if settings.systemPrompt != nil {
                Button("Restore Default Prompt", role: .destructive) {
                    settings.systemPrompt = nil
                }
                .help("Go back to the built-in prompt, which adapts to the model.")
            }
        } header: {
            Text("System Prompt")
        } footer: {
            Text("The base instructions the agent gets in every session. Leave it empty to use the built-in default (full for 32k+ context models, condensed below). The tools and project context are appended automatically. New sessions use it immediately; open sessions pick it up when they resume.")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            if let model = catalog.activeDescriptor {
                LabeledContent("Detected", value: model.displayName)
                if let detail = model.detail {
                    LabeledContent("Notes", value: detail)
                }
                if let size = model.contextSize {
                    LabeledContent("Context window", value: "\(size) tokens")
                }
                if !model.capabilities.isEmpty {
                    LabeledContent("Capabilities", value: model.capabilities.sorted().joined(separator: ", "))
                }
            } else {
                Text(catalog.descriptors.first?.availabilityDetail ?? "No on-device model detected.")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("The operating system decides which on-device model this Mac gets; AFM Code reports it but can't change it. Models are selected per session from the chat title.")
        }
    }

    // MARK: - MLX models

    private var mlxSection: some View {
        Section {
            Button {
                showModels = true
            } label: {
                Label("Manage MLX Models…", systemImage: "square.stack.3d.up")
            }
            .help("Search the Hugging Face Hub and download models to run locally via MLX.")
        } header: {
            Text("MLX Models")
        } footer: {
            Text("Run your own models from the Hugging Face Hub on Apple Silicon. Downloaded weights are stored in AFM Code's container, and models support the same tools, approvals, and context handling as the on-device model.")
        }
        .sheet(isPresented: $showModels) {
            ModelsView()
                .frame(width: 680, height: 640)
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Message bubbles", selection: bubbleStyleBinding) {
                ForEach(ChatBubbleStyle.allCases) { style in
                    Text(style.displayName)
                        .tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .help("Model colors renders assistant replies on the model's gradient; theme uses a neutral surface.")

            VStack(alignment: .leading, spacing: 10) {
                Text("Chat background")
                    .font(.headline)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: 5),
                    spacing: 10
                ) {
                    ForEach(ChatBackgroundStyle.allCases) { style in
                        backgroundSwatch(style)
                    }
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("The palette colors the chat window and, for the deeper palettes, switches it to dark mode. Bubble style applies to assistant replies in every session.")
        }
    }

    private var bubbleStyleBinding: Binding<ChatBubbleStyle> {
        Binding(
            get: { ChatBubbleStyle(rawValue: bubbleStyleRawValue) ?? ChatBubblePreference.defaultValue },
            set: { bubbleStyleRawValue = $0.rawValue }
        )
    }

    // MARK: - Accessibility

    private var accessibilitySection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { settings.announceTypingWithVoiceOver },
                    set: { settings.announceTypingWithVoiceOver = $0 }
                )
            ) {
                LabeledContent("Announce activity") {
                    Text("Medium priority")
                        .foregroundStyle(.secondary)
                }
            }
            .help("Spoken (when VoiceOver is running) when the model starts working, or when a change is waiting for your approval.")

            Toggle(
                isOn: Binding(
                    get: { settings.announceMessagesWithVoiceOver },
                    set: { settings.announceMessagesWithVoiceOver = $0 }
                )
            ) {
                LabeledContent("Announce replies") {
                    Text("High priority")
                        .foregroundStyle(.secondary)
                }
            }
            .help("Spoken (when VoiceOver is running) when a reply finishes, so you know the text is final.")
        } header: {
            Text("VoiceOver")
        } footer: {
            Text("Announcements are only heard when VoiceOver is running; they have no effect for sighted users. The streaming reply itself is always readable in VoiceOver — announcements just mark the start and end of a turn.")
        }
    }

    private func backgroundSwatch(_ style: ChatBackgroundStyle) -> some View {
        let selected = style == (ChatBackgroundStyle(rawValue: backgroundRawValue) ?? ChatBackgroundPreference.defaultValue)
        return Button {
            backgroundRawValue = style.rawValue
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(style.color(for: colorScheme))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Circle().strokeBorder(.quaternary, lineWidth: 1)
                    )
                    .overlay(
                        Circle().strokeBorder(
                            selected ? Color.accentColor : .clear,
                            lineWidth: 2
                        )
                    )
                Text(style.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(style.displayName)
        .accessibilityLabel("Background: \(style.displayName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
