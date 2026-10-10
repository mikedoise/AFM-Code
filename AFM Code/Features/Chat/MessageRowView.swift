import SwiftUI

/// One row in the transcript: an avatar plus the message content.
///
/// Assistant messages render as Markdown (code blocks, inline styling);
/// user messages render as plain selectable text.
struct MessageRowView: View {
    let role: Message.Role
    let content: String
    var isStreaming: Bool = false
    /// Tool activity persisted with the message (assistant turns).
    var steps: [ToolStep]? = nil
    /// Approval service for live cards; nil for history rows.
    var approvals: ToolApprovalService? = nil

    init(message: Message) {
        self.role = message.role
        self.content = message.content
        self.isStreaming = false
        self.steps = message.toolActivity
    }

    init(role: Message.Role, content: String, isStreaming: Bool = false, steps: [ToolStep]? = nil, approvals: ToolApprovalService? = nil) {
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.steps = steps
        self.approvals = approvals
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: role == .user ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(role == .user ? "You" : "AFM Code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if isStreaming {
                        Text("· generating")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                }
                if role == .assistant {
                    if let steps, !steps.isEmpty {
                        ToolStepListView(steps: steps, approvals: approvals)
                    }
                    if !content.isEmpty {
                        MarkdownText(text: content)
                    }
                } else {
                    Text(content)
                        .textSelection(.enabled)
                        .frame(maxWidth: 680, alignment: .leading)
                }
            }
            if role == .user {
                Spacer(minLength: 0)
            }
        }
    }

    private var avatar: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14))
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: role == .user ? "person.fill" : "curlybraces")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(role == .user ? Color.accentColor : .secondary)
            )
            .accessibilityHidden(true)
    }
}
