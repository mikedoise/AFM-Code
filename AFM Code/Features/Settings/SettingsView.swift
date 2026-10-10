import SwiftUI

/// The Settings window (⌘,): the system prompt editor and a read-only
/// look at the detected on-device model.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        Form {
            promptSection
            modelSection
        }
        .formStyle(.grouped)
        .frame(width: 700, height: 580)
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
            Text("The operating system decides which on-device model this Mac gets; AFM Code reports it but can't change it. Models are selected per session from the chat toolbar.")
        }
    }
}
