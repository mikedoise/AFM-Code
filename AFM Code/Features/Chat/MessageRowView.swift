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
    /// Phase 9: JPEG image data attached to user messages.
    let imageData: Data?
    /// Phase 9: filename for the attached image.
    let imageFilename: String?
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
        self.imageData = message.imageData
        self.imageFilename = message.imageFilename
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
        self.imageData = nil
        self.imageFilename = nil
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

    /// Phase 9: whether this message has an attached image.
    private var hasImage: Bool {
        imageData != nil && !imageData!.isEmpty
    }

    /// Who spoke, for the bubble's `accessibilityLabel`.
    ///
    /// VoiceOver reads label + value as "You, [message]" / "[model],
    /// [reply]", so the speaker must be a spoken name: the on-device
    /// models get fixed titles; MLX models read their repository name
    /// ("mlx:mlx-community/Qwen3-4B-4bit" → "Qwen3-4B-4bit").
    private var speakerName: String {
        switch role {
        case .user:
            return "You"
        case .assistant:
            guard let modelID else { return "Assistant" }
            switch modelID {
            case "afm-core":
                return "On-device model"
            case "afm-core-advanced":
                return "Advanced on-device model"
            case let id where id.hasPrefix("mlx:"):
                let repoID = String(id.dropFirst("mlx:".count))
                let name = (repoID as NSString).lastPathComponent
                return name.isEmpty ? "Assistant" : name
            default:
                return "Assistant"
            }
        }
    }

    /// The message text as VoiceOver should read it: the raw content
    /// (newlines are fine for `accessibilityValue`).
    private var messageValue: String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "\(isStreaming ? "Still working…" : "Empty message")" : text
    }

    // MARK: - Body

    var body: some View {
        Group {
            if role == .user {
                userLayout
                    // One element per message — the bubble, timestamp,
                    // and avatar collapse so VoiceOver reads "You, [text]"
                    // without extra flick targets.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(speakerName)
                    .accessibilityValue(messageValue)
                    .accessibilityAddTraits(isStreaming ? .updatesFrequently : [])
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

    /// Phase 9: user bubble that may include an attached image.
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Image preview (if any)
            if hasImage, let imageData {
                AttachedImageView(imageData: imageData, filename: imageFilename ?? "image")
                    .frame(maxWidth: 400)
            }
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
                // Collapse the rendered markdown (headers, code blocks,
                // tables) into one element: "[model name], [reply text]".
                // The thinking card and steps disclosure sit outside
                // this element and keep their own accessibility.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(speakerName)
                .accessibilityValue(messageValue)
                .accessibilityAddTraits(isStreaming ? .updatesFrequently : [])
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
                .accessibilityLabel("Message timestamp")
            Spacer(minLength: 0)
            Button(action: copyMessage) {
                Image(systemName: showingCopyConfirmation ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(showingCopyConfirmation ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(showingCopyConfirmation ? "Copied" : "Copy message")
            .accessibilityLabel(showingCopyConfirmation ? "Copied" : "Copy message")
        }
        // Under the bubble: timestamp + copy are the row's only
        // metadata. Hide them from VoiceOver — the bubble element
        // above already carries the full message, and the copy is a
        // custom action on it.
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        VoiceOverAnnouncer.announce("Message copied to clipboard")
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
