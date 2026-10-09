import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Lightweight Markdown rendering for assistant messages.
///
/// Phase 1: fenced code blocks + inline Markdown. Full syntax
/// highlighting lands in the polish phase.
struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = Self.parseBlocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    InlineMarkdownText(text: value)
                        .textSelection(.enabled)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    // MARK: - Block model

    enum Block {
        case text(String)
        case code(language: String?, code: String)
    }

    /// Splits on triple-backtick fences, tracking the optional language tag.
    static func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var buffer = ""
        var inCode = false
        var language: String?

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: language, code: buffer))
                    buffer = ""
                    language = nil
                    inCode = false
                } else {
                    appendTextIfNeeded(blocks: &blocks, buffer: &buffer)
                    inCode = true
                    let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
            } else {
                buffer += line + "\n"
            }
        }

        if inCode {
            // Unclosed fence (mid-stream): treat the rest as a code block.
            blocks.append(.code(language: language, code: buffer))
        } else {
            appendTextIfNeeded(blocks: &blocks, buffer: &buffer)
        }
        return blocks
    }

    private static func appendTextIfNeeded(blocks: inout [Block], buffer: inout String) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            buffer = ""
            return
        }
        blocks.append(.text(buffer))
        buffer = ""
    }
}

/// Inline Markdown (bold, italics, `code`, links, lists) via
/// `AttributedString`'s inline parser, preserving whitespace and line breaks.
struct InlineMarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

/// Monospaced code block with an optional language label and copy action.
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "code")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary)
        )
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
