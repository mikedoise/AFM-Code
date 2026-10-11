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

    var body: some View {
        Form {
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

            DisclosureGroup("Add by repository id") {
                HStack(spacing: 8) {
                    TextField("org/model-name", text: $manualRepoID)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                    Button("Add") {
                        mlx.add(repoID: manualRepoID)
                        manualRepoID = ""
                        Task { await catalog.refreshMlxModels() }
                    }
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
                        .help("Already in your library")
                } else {
                    Button("Add") {
                        mlx.add(repoID: repoID, result: result)
                        Task { await catalog.refreshMlxModels() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName ?? model.repoID)
                        .font(.callout.weight(.medium))
                    Text(model.repoID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if state == .downloading, let download {
                    Text("\(Int(download.fractionCompleted * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                controls
            }

            if state == .downloading, let download, download.totalBytes > 0 {
                ProgressView(value: download.fractionCompleted)
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
        case .ready:
            EmptyView()
        default:
            Button(state == .downloadFailed ? "Retry" : "Download") {
                Task { await mlx.download(model) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        Button {
            mlx.remove(model)
            Task { await catalog.refreshMlxModels() }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Remove from the library and delete its downloaded weights.")
    }

    @ViewBuilder
    private var metadata: some View {
        let parts: [String] = [
            model.modelType.map { "type \($0)" } ?? nil,
            model.sizeBytes.map { "\(ModelBadgeView.compact(Int($0 / (1024 * 1024)))) MB" } ?? nil,
            model.maxContextTokens.map { "\(ModelBadgeView.compact($0)) ctx" } ?? nil,
            model.capabilities?.joined(separator: ", ") ?? nil
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
