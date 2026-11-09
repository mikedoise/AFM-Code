import SwiftUI

struct CoreAIModelsSection: View {
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        Section {
            Button("Add Core AI Model…", systemImage: "doc.badge.plus") {
                Task { _ = await catalog.coreAI.chooseModel() }
            }
            .disabled(catalog.coreAI.isImporting || catalog.coreAI.isBusy)
            .help("Select an .aimodel package or its complete export folder.")
            if catalog.coreAI.isImporting { ProgressView("Adding model…") }
            if let error = catalog.coreAI.importError {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(catalog.coreAI.models) { model in
                let name = ModelDescriptor.readableCoreAIName(model.name, contextSize: model.contextSize)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.headline)
                            Text("Context window: \(model.contextSize.formatted()) tokens. Modalities: text").font(.caption)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(name). Context window: \(model.contextSize.formatted()) tokens. Modalities: text")
                        Spacer()
                        Button("Remove from Library", role: .destructive) { catalog.coreAI.remove(model.id) }
                            .disabled(catalog.coreAI.isBusy)
                            .accessibilityLabel("Remove \(name) from library")
                            .help("Removes the saved reference only. Model files stay on disk.")
                    }
                    Text("Identifier: " + model.name).font(.caption).textSelection(.enabled)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Original model identifier: " + model.name)
                    if catalog.coreAI.loadedModelID == model.id {
                        HStack {
                            Text("Loaded in memory for faster follow-up messages").font(.caption)
                            Button("Unload Model") { catalog.coreAI.unloadIdleModel() }
                                .disabled(catalog.coreAI.isBusy)
                                .accessibilityLabel("Unload \(name) from memory")
                        }
                    }
                    if let capabilities = catalog.coreAI.capabilities[model.id] {
                        Text(capabilities.contains("toolCalling")
                             ? "Tool calling available in project conversations. Project approval settings still apply."
                             : "Text chat only: this adapter does not report tool calling for this model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.folderPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Model files: " + model.folderPath)
                    if let problem = catalog.coreAI.problems[model.id] {
                        Text(problem).foregroundStyle(.orange)
                    } else if catalog.coreAI.capabilities[model.id] == nil {
                        Text("Ready to load. Runtime compatibility not yet checked.")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Ready to load. Runtime compatibility not yet checked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            Button("Refresh Core AI Files") { catalog.coreAI.refresh() }
                .disabled(catalog.coreAI.isBusy)
        } header: {
            Text("Core AI Models")
        } footer: {
            Text("Keep metadata.json, tokenizer and all auxiliary files beside the .aimodel. Gemma E2B also needs its PLE sidecar. Models are used in place, not copied. This importer supports Apple-compatible text-language exports; an arbitrary .aimodel is not necessarily a chat model.")
        }
    }
}
