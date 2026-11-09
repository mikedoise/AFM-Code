import SwiftUI

/// Explicit per-selection status. Never substitutes the first catalog model.
struct ModelBadgeView: View {
    let status: ModelStatus

    private var color: Color {
        switch status.state {
        case .loaded, .inUse: .green
        case .preparing: .accentColor
        case .failed: .red
        case .unavailable: .orange
        case .selected: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if status.state == .preparing {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            } else {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(status.name).font(.caption.weight(.medium)).truncationMode(.middle)
            Text("· " + status.label).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .help([status.name, status.detail, status.model.map(Self.helpText)].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityLabel)
        .accessibilityValue([
            status.detail,
            (status.model?.contextSize).map { "\(Self.compact($0)) token context" }
        ].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(.updatesFrequently)
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
