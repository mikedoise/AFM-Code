import MLXFoundationModels
import SwiftUI
import SwiftData

/// The "Choose model" popover panel, in the Perspective Intelligence
/// title-picker style: a header with the manage-models shortcut and a
/// card grid where every model wears its gradient identity, the
/// selected one is outlined in white, and unavailable ones show how to
/// make them available.
struct ModelPickerPanel: View {
    let session: ChatSession
    let catalog: ModelCatalog

    @Environment(MLXModelManager.self) private var mlx
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var showModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Choose model")
                    .font(.headline)

                Spacer()

                Button("Manage Models") {
                    showModels = true
                }
                .controlSize(.small)
                .help("Search the Hugging Face Hub and download models to run locally.")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("On-Device")
                    grid {
                        bestAvailableCard
                        ForEach(catalog.afmDescriptors) { descriptor in
                            card(for: descriptor)
                        }
                    }

                    if !catalog.mlxDescriptors.isEmpty {
                        sectionLabel("MLX Library")
                        grid {
                            ForEach(catalog.mlxDescriptors) { descriptor in
                                card(for: descriptor)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .sheet(isPresented: $showModels) {
            ModelsView()
                .frame(width: 680, height: 640)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func grid(@ViewBuilder content: () -> some View) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            content()
        }
    }

    // MARK: - Cards

    private var bestAvailableCard: some View {
        let selected = session.modelKind == nil && session.mlxModelID == nil
        let model = catalog.activeDescriptor
        let available = model?.isAvailable ?? false
        let subtitle = model?.isAvailable == true
            ? "\(model?.displayName ?? "On-device") · best available"
            : (model?.availabilityDetail ?? "No model available on this Mac.")

        let statusIcon: String? = selected
            ? "checkmark.circle.fill"
            : (available ? nil : "exclamationmark.triangle.fill")

        return ModelPickerCard(
            title: "Best available",
            subtitle: subtitle,
            identity: ModelIdentityPalette.fallback,
            isSelected: selected,
            statusIcon: statusIcon,
            isAvailable: available
        ) {
            session.modelKind = nil
            session.mlxModelID = nil
            try? modelContext.save()
        }
    }

    private func card(for descriptor: ModelDescriptor) -> some View {
        let selected = isSelected(descriptor)
        let identity = ModelIdentityPalette.identity(for: descriptor)
        let download = descriptor.kind == .mlx
            ? MLXDownloadProgress.shared.activeDownloads.first { $0.modelID == descriptor.mlxRepoID }
            : nil

        return ModelPickerCard(
            title: descriptor.displayName,
            subtitle: cardSubtitle(for: descriptor),
            identity: identity,
            isSelected: selected,
            statusIcon: statusIcon(isSelected: selected, isAvailable: descriptor.isAvailable),
            isAvailable: descriptor.isAvailable,
            downloadFraction: download?.fractionCompleted
        ) {
            session.modelKind = descriptor.kind
            session.mlxModelID = descriptor.kind == .mlx ? descriptor.mlxRepoID : nil
            try? modelContext.save()
        }
        .disabled(!descriptor.isAvailable)
        .opacity(descriptor.isAvailable ? 1 : 0.68)
    }

    private func isSelected(_ descriptor: ModelDescriptor) -> Bool {
        descriptor.isAvailable && (
            descriptor.kind == .mlx
                ? session.modelKind == .mlx && session.mlxModelID == descriptor.mlxRepoID
                : session.modelKind == descriptor.kind
        )
    }

    private func cardSubtitle(for descriptor: ModelDescriptor) -> String {
        if let detail = descriptor.availabilityDetail, !descriptor.isAvailable {
            return detail
        }
        var parts: [String] = []
        if let contextSize = descriptor.contextSize {
            parts.append("\(ModelBadgeView.compact(contextSize)) ctx")
        }
        if !descriptor.capabilities.isEmpty {
            let order = ["toolCalling", "reasoning", "vision"]
            let labels: [String: String] = [
                "toolCalling": "tools",
                "reasoning": "reasoning",
                "vision": "vision"
            ]
            let shown = order.filter { descriptor.capabilities.contains($0) }.compactMap { labels[$0] }
            if !shown.isEmpty {
                parts.append(shown.joined(separator: " · "))
            }
        }
        if parts.isEmpty, let detail = descriptor.detail {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    private func statusIcon(isSelected: Bool, isAvailable: Bool) -> String? {
        if !isAvailable {
            return "icloud.and.arrow.down"
        }
        if isSelected {
            return "checkmark.circle.fill"
        }
        return nil
    }
}

/// One gradient card in the model picker, in the style of
/// Perspective Intelligence's prompt/model cards.
private struct ModelPickerCard: View {
    let title: String
    let subtitle: String
    let identity: ModelIdentity
    var isSelected: Bool = false
    var statusIcon: String? = nil
    var isAvailable: Bool = true
    var downloadFraction: Double? = nil

    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(title, systemImage: identity.icon)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    if let statusIcon {
                        Image(systemName: statusIcon)
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .accessibilityHidden(true)
                    }
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.93))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let downloadFraction {
                    ProgressView(value: downloadFraction)
                        .tint(.white)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 84, alignment: .topLeading)
            .background {
                ModelGradientBackground(colors: identity.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? Color.white : Color.white.opacity(colorScheme == .dark ? 0.12 : 0.25),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18),
                radius: 10,
                x: 0,
                y: 6
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
