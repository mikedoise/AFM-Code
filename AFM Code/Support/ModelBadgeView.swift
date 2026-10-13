import SwiftUI

/// Compact status pill for the detected on-device model,
/// shown in the sidebar footer, composer, and empty state.
struct ModelBadgeView: View {
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        if let model = catalog.activeDescriptor {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.displayName)
                    .font(.caption.weight(.medium))
                if let contextSize = model.contextSize {
                    Text("· \(Self.compact(contextSize)) ctx")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .help(Self.helpText(for: model))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                model.contextSize.map {
                    "Active model \(model.displayName), \(Self.compact($0)) token context"
                } ?? "Active model \(model.displayName)"
            )
        } else if let detail = catalog.descriptors.first?.availabilityDetail {
            Label(detail, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Model unavailable")
                .accessibilityValue(detail)
        }
    }

    static func helpText(for model: ModelDescriptor) -> String {
        var parts: [String] = []
        if let detail = model.detail { parts.append(detail) }
        if let contextSize = model.contextSize {
            parts.append("\(contextSize) token context window")
        }
        if !model.capabilities.isEmpty {
            parts.append("Capabilities: " + model.capabilities.sorted().joined(separator: ", "))
        }
        return parts.joined(separator: "\n")
    }

    static func compact(_ tokens: Int) -> String {
        if tokens >= 1000 {
            let thousands = Double(tokens) / 1000
            return thousands.formatted(.number.precision(.fractionLength(1))) + "k"
        }
        return "\(tokens)"
    }
}
