import SwiftUI
import SwiftData

/// The transcript: persisted messages plus the live streaming tail.
struct MessageListView: View {
    let session: ChatSession
    let engine: SessionEngine?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(session.messageList) { message in
                        MessageRowView(message: message)
                            .id(message.id)
                    }

                    if let engine, engine.isBusy {
                        if engine.streamingText.isEmpty {
                            thinkingPlaceholder
                                .id(Self.streamAnchor(session))
                        } else {
                            MessageRowView(
                                role: .assistant,
                                content: engine.streamingText,
                                isStreaming: true
                            )
                            .id(Self.streamAnchor(session))
                        }
                    }

                    if let engine, let error = engine.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: engine?.streamingText) {
                if let engine, engine.isBusy {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(Self.streamAnchor(session), anchor: .bottom)
                    }
                }
            }
            .onChange(of: session.lastMessageAt) {
                withAnimation {
                    if let last = session.messageList.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var thinkingPlaceholder: some View {
        HStack(spacing: 10) {
            avatarPlaceholder
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var avatarPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.14))
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: "curlybraces")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            )
    }

    private static func streamAnchor(_ session: ChatSession) -> String {
        "streaming-\(session.id.uuidString)"
    }
}
