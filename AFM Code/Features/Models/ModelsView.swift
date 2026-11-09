import HuggingFace
import MLXFoundationModels
import SwiftUI
import SwiftData

/// The MLX model library: search the Hugging Face Hub, add models to
/// the library, download their weights, and remove them.
struct ModelsView: View {
    @Environment(MLXModelManager.self) private var mlx
    @Environment(ModelCatalog.self) private var catalog
    @Query(sort: \MlxModel.addedAt, order: .reverse) private var models: [MlxModel]
    @State private var manualRepoID = ""
    @State private var showsRepositoryField = false

    var body: some View {
        Form {
            CoreAIModelsSection()
            searchSection
            if !mlx.results.isEmpty {
                resultsSection
            }
            librarySection
        }
        .formStyle(.grouped)
    }

    // MARK: - Search

    private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                .accessibilityHidden(true)
                    .foregroundStyle(.secondary)
                TextField(
                    "Search Hugging Face (e.g. qwen3 4bit)",
                    text: Binding(
                        get: { mlx.searchText },
                        set: { mlx.searchText = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .onSubmit {
                    Task { await mlx.search() }
                }
                Button {
                    Task { await mlx.search() }
                } label: {
                    if mlx.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Search")
                    }
                }
                .disabled(
                    mlx.isSearching
                        || mlx.searchText.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }

            if let error = mlx.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Button { showsRepositoryField.toggle() } label: {
                Label("Add by repository ID", systemImage: showsRepositoryField ? "chevron.down" : "chevron.right")
            }
            .accessibilityValue(showsRepositoryField ? "Expanded" : "Collapsed")
            if showsRepositoryField {
                HStack(spacing: 8) {
                    TextField("Repository ID", text: $manualRepoID, prompt: Text("org/model-name"))
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                    Button("Add") {
                        mlx.add(repoID: manualRepoID)
                        manualRepoID = ""
                        Task { await catalog.refreshMlxModels() }
                    }
                    .accessibilityLabel("Add repository \(manualRepoID)")
                    .disabled(manualRepoID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 4)
            }
        } header: {
            Text("Hugging Face")
        } footer: {
            Text("Only repositories with MLX weights can be added. Downloaded weights are stored in AFM Code's own container.")
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        Section("Results") {
            ForEach(mlx.results) { result in
                resultRow(result)
            }
        }
    }

    private func resultRow(_ result: HuggingFace.Model) -> some View {
        let repoID = result.id.description
        let runnable = MLXModelManager.isMLXModel(result)
        let alreadyAdded = mlx.model(forRepoID: repoID) != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(repoID)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if alreadyAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("\(repoID) is already in your library")
                } else {
                    Button("Add") {
                        mlx.add(repoID: repoID, result: result)
                        Task { await catalog.refreshMlxModels() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Add \(repoID) model")
                    .disabled(!runnable)
                    .help(runnable ? "" : "This repository doesn't carry MLX weights.")
                }
            }
            HStack(spacing: 10) {
                if let modelType = MLXModelManager.stringValue(result.config?["model_type"]) {
                    Text(modelType)
                }
                if let downloads = result.downloads, downloads > 0 {
                    Text("\(ModelBadgeView.compact(downloads)) downloads")
                }
                if let likes = result.likes, likes > 0 {
                    Text("\(likes) likes")
                }
                if !runnable && !alreadyAdded {
                    Text("No MLX weights")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Library

    private var librarySection: some View {
        Section("Your Models") {
            if models.isEmpty {
                Text("No MLX models yet. Search above, or paste a repository id.")
                    .foregroundStyle(.secondary)
            }
            ForEach(models) { model in
                LibraryRow(model: model)
            }
        }
    }
}

/// One row of the library: the model, its live readiness, and the
/// download controls.
private struct LibraryRow: View {
    let model: MlxModel

    @Environment(MLXModelManager.self) private var mlx
    @Environment(ModelCatalog.self) private var catalog
    @State private var state: MLXModelManager.ModelState = .unknown

    var body: some View {
        // Reading the shared download progress here makes the row update
        // when a download for this model starts or ends; the task re-runs
        // on that flip to refresh the readiness snapshot.
        let downloadActive = MLXDownloadProgress.shared.activeDownloads.contains {
            $0.modelID == model.repoID
        }
        let download = MLXDownloadProgress.shared.download(forModelID: model.repoID)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusIcon.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName ?? model.repoID)
                        .font(.callout.weight(.medium))
                    Text("Status: " + readinessDescription)
                        .font(.caption)
                        .accessibilityLabel("\(model.displayName ?? model.repoID): \(readinessDescription)")
                    Text(model.repoID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if state == .downloading, let download {
                    Text("\(Int(download.fractionCompleted * 100))%")
                        .accessibilityLabel("\(model.displayName ?? model.repoID): \(Int(download.fractionCompleted * 100)) percent downloaded")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                controls
            }

            if state == .downloading, let download, download.totalBytes > 0 {
                ProgressView(value: download.fractionCompleted)
                    .accessibilityLabel("Download progress for \(model.displayName ?? model.repoID)")
            }

            metadata
        }
        .padding(.vertical, 2)
        .task(id: downloadActive) {
            state = await mlx.state(for: model)
            // The library changed under the catalog (download started
            // or finished, weights appeared): re-derive the MLX
            // descriptors so chat pickers and the context window stay
            // current.
            await catalog.refreshMlxModels()
        }
    }

    private var readinessDescription: String {
        switch state {
        case .ready: "Ready"
        case .downloading: "Downloading"
        case .notDownloaded: "Not downloaded"
        case .downloadFailed: "Download failed"
        case .deviceNotCapable: "Unsupported on this device"
        case .unknown: "Checking availability"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading:
            ProgressView().controlSize(.small)
        case .notDownloaded:
            Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
        case .downloadFailed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .deviceNotCapable:
            Image(systemName: "cpu").foregroundStyle(.orange)
        case .unknown:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .downloading:
            Button("Cancel") {
                Task { await mlx.cancelDownload(model) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Cancel download for \(model.displayName ?? model.repoID)")
        case .ready:
            EmptyView()
        default:
            Button(state == .downloadFailed ? "Retry" : "Download") {
                Task { await mlx.download(model) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("\(state == .downloadFailed ? "Retry download for" : "Download") \(model.displayName ?? model.repoID)")
        }
        Button {
            mlx.remove(model)
            Task { await catalog.refreshMlxModels() }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("Remove \(model.displayName ?? model.repoID) from library and delete downloaded weights")
        .help("Remove from the library and delete its downloaded weights.")
    }

    @ViewBuilder
    private var metadata: some View {
        let parts: [String] = [
            model.modelType.map { "type \($0)" } ?? nil,
            model.sizeBytes.map { "\(ModelBadgeView.compact(Int($0 / (1024 * 1024)))) MB" } ?? nil,
            model.maxContextTokens.map { "Context window: \($0.formatted()) tokens" } ?? nil,
            model.capabilities?.joined(separator: ", ") ?? nil
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
