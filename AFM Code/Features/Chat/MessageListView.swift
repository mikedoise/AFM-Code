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
                        VStack(alignment: .leading, spacing: 12) {
                            if !engine.toolSteps.isEmpty {
                                ToolStepListView(steps: engine.toolSteps, approvals: engine.approvals)
                            }
                            if engine.streamingText.isEmpty {
                                thinkingPlaceholder
                            } else {
                                MessageRowView(
                                    role: .assistant,
                                    content: engine.streamingText,
                                    isStreaming: true
                                )
                            }
                        }
                        .id(Self.streamAnchor(session))
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
            // Stream snapshots can arrive many times per frame, so a
            // plain onChange would fire the scroll repeatedly in one
            // frame. .task(id:) restarts on every change and the sleep
            // coalesces each burst into a single scroll.
            .task(id: engine?.streamingText) {
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(Self.streamAnchor(session), anchor: .bottom)
                }
            }
            .task(id: engine?.toolSteps.count) {
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(Self.streamAnchor(session), anchor: .bottom)
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
