import SwiftUI

/// A compact unified-style diff preview, used in approval cards and
/// in expanded tool activity.
struct DiffView: View {
    let diff: DiffData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 220)
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(diff.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if diff.isNewFile {
                Text("new file")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            Spacer()
            if diff.additions > 0 {
                Text("+\(diff.additions)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
            }
            if diff.removals > 0 {
                Text("−\(diff.removals)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
            }
            if diff.truncated {
                Text("truncated")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func row(_ line: DiffData.Line) -> some View {
        HStack(spacing: 0) {
            Text(symbol(for: line.kind))
                .frame(width: 14, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(foreground(for: line.kind))
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(for: line.kind))
    }

    private func symbol(for kind: DiffData.LineKind) -> String {
        switch kind {
        case .context: return " "
        case .addition: return "+"
        case .removal: return "−"
        }
    }

    private func foreground(for kind: DiffData.LineKind) -> Color {
        switch kind {
        case .context: return .secondary
        case .addition: return .primary
        case .removal: return .primary.opacity(0.7)
        }
    }

    private func background(for kind: DiffData.LineKind) -> Color {
        switch kind {
        case .context: return .clear
        case .addition: return .green.opacity(0.14)
        case .removal: return .red.opacity(0.12)
        }
    }
}
