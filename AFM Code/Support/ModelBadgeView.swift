import SwiftUI

/// Explicit per-selection status. Never substitutes the first catalog model.
struct ModelBadgeView: View {
    let status: ModelStatus
    @State private var showsDetails = false

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
        Button { showsDetails.toggle() } label: {
        HStack(spacing: 6) {
            if status.state == .preparing {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            } else {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text("Model: " + status.name).font(.caption.weight(.medium)).truncationMode(.middle)
            Text("· " + status.label).font(.caption).foregroundStyle(.secondary)
        }
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 8) {
                if let model = status.model { Text(model.accessibleDescription) }
                Text(status.detail ?? status.label)
                Button("Done") { showsDetails = false }
            }
            .padding().frame(width: 340)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityLabel)
        .accessibilityHint("Show model details")

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
