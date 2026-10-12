//
//  ThinkingCardView.swift
//  Perspective Intelligence
//
//  Collapsible card that shows the model's chain-of-thought reasoning
//  extracted from <think> blocks in MLX Gemma 4 output.
//

import SwiftUI

struct ThinkingCardView: View {
    let thinkingContent: String
    @State private var isExpanded: Bool = false

    private var preview: String {
        let trimmed = thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(80)) + "..."
    }

    private var lineCount: Int {
        thinkingContent.components(separatedBy: .newlines).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible, tap to toggle
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    Text(isExpanded ? String(localized: "Reasoning") : preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 1)
                    Spacer()
                    if isExpanded {
                        Text("\(lineCount) lines")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)
                ScrollView {
                    Text(thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.purple.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.12), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Model reasoning"))
        .accessibilityValue(thinkingContent)
        .accessibilityHint(isExpanded ? String(localized: "Tap to collapse") : String(localized: "Tap to expand reasoning"))
    }
}
