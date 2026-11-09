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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.name).font(.headline)
                        Spacer()
                        Button("Remove from Library", role: .destructive) { catalog.coreAI.remove(model.id) }
                            .disabled(catalog.coreAI.isBusy)
                            .accessibilityLabel("Remove \(model.name) from library")
                            .help("Removes the saved reference only. Model files stay on disk.")
                    }
                    Text("\(model.contextSize.formatted()) tokens · Core AI text model").font(.caption)
                    if catalog.coreAI.loadedModelID == model.id {
                        HStack {
                            Text("Loaded in memory for faster follow-up messages").font(.caption)
                            Button("Unload Model") { catalog.coreAI.unloadIdleModel() }
                                .disabled(catalog.coreAI.isBusy)
                                .accessibilityLabel("Unload \(model.name) from memory")
                        }
                    }
                    if let capabilities = catalog.coreAI.capabilities[model.id] {
                        Text(capabilities.contains("toolCalling")
                             ? "Tool calling available in project conversations. Project approval settings still apply."
                             : "Text chat only: this adapter does not report tool calling for this model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.folderPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let problem = catalog.coreAI.problems[model.id] {
                        Text(problem).foregroundStyle(.orange)
                    } else if catalog.coreAI.capabilities[model.id] == nil {
                        Text("Ready to load. Capabilities and runtime compatibility are checked on the first response.")
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
