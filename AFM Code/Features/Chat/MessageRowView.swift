import AppKit
import SwiftUI

/// One row of the transcript, in the Perspective Intelligence bubble
/// style: user messages sit right in a gradient bubble with the avatar
/// to its right; assistant messages sit left with the model's avatar,
/// a themed (or model-colored) bubble, the thinking card, the steps
/// disclosure card, and a timestamp/copy line beneath.
struct MessageRowView: View {
    let role: Message.Role
    let content: String
    var isStreaming: Bool = false
    /// Chain of thought (reasoning models); renders the thinking card.
    var thinking: String? = nil
    /// Tool activity (assistant turns); renders the steps disclosure.
    var steps: [ToolStep]? = nil
    /// Approval service for live cards; nil for history rows.
    var approvals: ToolApprovalService? = nil
    /// The model that produced this message (assistant) — the bubble's
    /// gradient identity. For the live row, the session's current model.
    var modelID: String? = nil
    /// The live status line ("Model is thinking…"), or nil.
    var statusText: String? = nil
    /// When the status is a suspended approval decision rather than work.
    var statusIsApproval: Bool = false
    /// When the message was recorded (the timestamp line under the bubble).
    var timestamp: Date = .now

    @AppStorage(ChatBubblePreference.key)
    private var bubbleStyleRawValue = ChatBubblePreference.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var showingCopyConfirmation = false

    init(message: Message, modelID: String? = nil) {
        self.role = message.role
        self.content = message.content
        self.thinking = message.thinkingContent
        self.steps = message.toolActivity
        self.modelID = message.modelID ?? modelID
        self.timestamp = message.timestamp
    }

    init(
        role: Message.Role,
        content: String,
        isStreaming: Bool = false,
        thinking: String? = nil,
        steps: [ToolStep]? = nil,
        approvals: ToolApprovalService? = nil,
        modelID: String? = nil,
        statusText: String? = nil,
        statusIsApproval: Bool = false,
        timestamp: Date = .now
    ) {
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.thinking = thinking
        self.steps = steps
        self.approvals = approvals
        self.modelID = modelID
        self.statusText = statusText
        self.statusIsApproval = statusIsApproval
        self.timestamp = timestamp
    }

    private var bubbleStyle: ChatBubbleStyle {
        ChatBubbleStyle(rawValue: bubbleStyleRawValue) ?? ChatBubblePreference.defaultValue
    }

    private var identity: ModelIdentity {
        ModelIdentityPalette.identity(forModelID: modelID)
    }

    private var hasContent: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasThinking: Bool {
        guard let thinking else { return false }
        return !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    var body: some View {
        Group {
            if role == .user {
                userLayout
            } else {
                assistantLayout
            }
        }
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contextMenu {
            if hasContent {
                Button(action: copyMessage) {
                    Label(showingCopyConfirmation ? "Copied" : "Copy Text", systemImage: "doc.on.doc")
                }
            }
        }
    }

    // MARK: - User

    private var userLayout: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 50)
            VStack(alignment: .trailing, spacing: 4) {
                userBubble
                timestampView
            }
            .frame(maxWidth: 520, alignment: .trailing)
            userAvatar
        }
    }

    private var userBubble: some View {
        userText
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                LinearGradient(
                    colors: [
                        Color(red: 0.0, green: 0.48, blue: 1.0),
                        Color(red: 0.0, green: 0.42, blue: 0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedBubbleShape(isFromUser: true))
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
    }

    /// User messages are short — the lightweight inline renderer with
    /// white text, matching PI's user bubble.
    @ViewBuilder
    private var userText: some View {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if let attributed = try? AttributedString(
            markdown: normalized,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            MarkdownTextView(
                attributedString: attributed,
                textColor: .white,
                baseFontSize: 15
            )
        } else {
            Text(content)
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
    }

    private var timestampView: some View {
        Text(timestamp, format: .dateTime.hour().minute())
            .font(.caption2)
            .foregroundStyle(Color.platformTertiaryLabel)
            .padding(.horizontal, 4)
    }

    private var userAvatar: some View {
        Circle()
            .fill(
                LinearGradient(colors: [.green, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: "person.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Assistant

    private var assistantLayout: some View {
        HStack(alignment: .top, spacing: 8) {
            aiAvatar
            VStack(alignment: .leading, spacing: 6) {
                if let statusText {
                    AssistantStatusBadge(
                        text: statusText,
                        presentation: statusIsApproval ? .waitingForApproval : .activeProgress
                    )
                }
                if hasContent || hasThinking {
                    assistantBubble
                } else if let steps, !steps.isEmpty {
                    // No response text yet: keep the steps beside the
                    // status instead of in an otherwise empty bubble.
                    StepsDisclosureCard(
                        steps: steps,
                        approvals: approvals,
                        phase: isStreaming ? .live : .finished
                    )
                }
                if !isStreaming && hasContent {
                    metadataRow
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            Spacer(minLength: 24)
        }
    }

    private var aiAvatar: some View {
        Circle()
            .fill(
                LinearGradient(colors: identity.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: identity.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasThinking, let thinking {
                ThinkingCardView(thinkingContent: thinking)
                    .padding(.bottom, hasContent ? 6 : 0)
            }
            if hasContent {
                StructuredMarkdownView(
                    content: content,
                    textColor: bubbleStyle.textColor(for: colorScheme),
                    isFromUser: false,
                    isStreaming: isStreaming,
                    expandsToFillWidth: false,
                    usesModelGradient: bubbleStyle.usesModelColors
                )
                .equatable()
            }
            if let steps, !steps.isEmpty {
                StepsDisclosureCard(
                    steps: steps,
                    approvals: approvals,
                    phase: isStreaming ? .live : .finished
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            if bubbleStyle.usesModelColors {
                ModelGradientBackground(colors: identity.gradient)
            } else {
                Color.platformControlBackground
            }
        }
        .clipShape(RoundedBubbleShape(isFromUser: false))
        .overlay {
            RoundedBubbleShape(isFromUser: false)
                .stroke(
                    (bubbleStyle.usesModelColors ? Color.white : Color.primary)
                        .opacity(colorSchemeContrast == .increased ? 0.65 : 0.15),
                    lineWidth: colorSchemeContrast == .increased ? 2 : 1
                )
        }
    }

    /// Timestamp plus the inline copy action, under the bubble — the
    /// same placement PI uses for finished assistant replies.
    private var metadataRow: some View {
        HStack(spacing: 8) {
            Text(timestamp, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(Color.platformTertiaryLabel)
            Spacer(minLength: 0)
            Button(action: copyMessage) {
                Image(systemName: showingCopyConfirmation ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(showingCopyConfirmation ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(showingCopyConfirmation ? "Copied" : "Copy message")
        }
    }

    // MARK: - Actions

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            showingCopyConfirmation = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.2)) {
                showingCopyConfirmation = false
            }
        }
    }
}
