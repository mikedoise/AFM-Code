import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A compact unified-style diff preview, used in approval cards and
/// in expanded tool activity.
struct DiffView: View {
    let diff: DiffData
    var maxHeight: CGFloat = 220
    /// Wrap long lines instead of truncating them (used in the sheet).
    var wrapsLines = false

    @State private var showFull = false

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
            .frame(maxHeight: maxHeight)
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
        .sheet(isPresented: $showFull) {
            DiffSheetView(diff: diff)
        }
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
            if showsFullButton {
                Button {
                    showFull = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("View the full diff")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var showsFullButton: Bool {
        diff.truncated || diff.lines.count > 30
    }

    private func row(_ line: DiffData.Line) -> some View {
        HStack(spacing: 0) {
            Text(symbol(for: line.kind))
                .frame(width: 14, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .lineLimit(wrapsLines ? nil : 8)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
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

/// The whole diff in its own window: tall, line-wrapping, copyable.
struct DiffSheetView: View {
    let diff: DiffData

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(diff.path)
                    .font(.system(.headline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if diff.isNewFile {
                    Text("new file")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if diff.additions > 0 {
                    Text("+\(diff.additions)")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if diff.removals > 0 {
                    Text("−\(diff.removals)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if diff.truncated {
                    Text("preview truncated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
                .padding(10)
            }
        }
        .frame(minWidth: 600, minHeight: 440)
        .onDisappear {
            copied = false
        }
    }

    private func row(_ line: DiffData.Line) -> some View {
        HStack(spacing: 0) {
            Text(symbol(for: line.kind))
                .frame(width: 16, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
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

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diff.unifiedText, forType: .string)
        #endif
        copied = true
    }
}
