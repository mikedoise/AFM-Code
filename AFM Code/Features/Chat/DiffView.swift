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
            if diff.lines.count > 400 {
                Text("Showing 400 of \(diff.lines.count) diff rows. Review all changes to inspect the complete proposal.")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<min(diff.lines.count, 400), id: \.self) { index in
                        row(diff.lines[index])
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
                .accessibilityHidden(true)
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
                    .accessibilityLabel("\(diff.additions) \(diff.additions == 1 ? "line" : "lines") added")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
            }
            if diff.removals > 0 {
                Text("−\(diff.removals)")
                    .accessibilityLabel("\(diff.removals) \(diff.removals == 1 ? "line" : "lines") removed")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
            }
            if diff.truncated {
                Text("Saved preview is incomplete")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if showsFullButton {
                Button {
                    showFull = true
                } label: {
                    Label(diff.truncated ? "Expand saved preview" : "Review all changes", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help(diff.truncated ? "Expand saved preview (incomplete)" : "Review all changes")
                .accessibilityLabel(diff.truncated ? "Expand saved preview (incomplete)" : "Review all changes")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var showsFullButton: Bool {
        !diff.lines.isEmpty
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.kind == .addition ? "Added line" : line.kind == .removal ? "Removed line" : "Unchanged line")
        .accessibilityValue(line.text.isEmpty ? "Blank line" : line.text)
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
                    .accessibilityLabel("\(diff.additions) \(diff.additions == 1 ? "line" : "lines") added")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if diff.removals > 0 {
                    Text("−\(diff.removals)")
                    .accessibilityLabel("\(diff.removals) \(diff.removals == 1 ? "line" : "lines") removed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if diff.truncated {
                    Text("Saved preview is incomplete; missing changes cannot be recovered here")
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines.indices, id: \.self) { index in
                        row(diff.lines[index])
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.kind == .addition ? "Added line" : line.kind == .removal ? "Removed line" : "Unchanged line")
        .accessibilityValue(line.text.isEmpty ? "Blank line" : line.text)
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
