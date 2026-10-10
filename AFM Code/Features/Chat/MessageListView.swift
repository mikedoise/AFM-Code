import SwiftUI
import SwiftData

/// The transcript: persisted messages plus the live streaming tail.
struct MessageListView: View {
    let session: ChatSession
    let engine: SessionEngine?

    /// Whether the viewport sits at (or near) the bottom. Auto-scroll
    /// only follows the stream while this is true, so the user can
    /// read back through history mid-turn without being yanked down.
    @State private var isNearBottom = true

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
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.visibleRect.minY + geometry.visibleRect.height
                return visibleBottom >= geometry.contentSize.height - 80
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            // Stream snapshots can arrive many times per frame, so a
            // plain onChange would fire the scroll repeatedly in one
            // frame. .task(id:) restarts on every change and the sleep
            // coalesces each burst into a single scroll.
            .task(id: engine?.streamingText) {
                try? await Task.sleep(for: .milliseconds(50))
                guard isNearBottom else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(Self.streamAnchor(session), anchor: .bottom)
                }
            }
            .task(id: engine?.toolSteps.count) {
                try? await Task.sleep(for: .milliseconds(50))
                guard isNearBottom else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(Self.streamAnchor(session), anchor: .bottom)
                }
            }
            .onChange(of: session.lastMessageAt) {
                guard isNearBottom else { return }
                withAnimation {
                    if let last = session.messageList.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !isNearBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollToLatest(proxy)
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 16)
                    .help("Scroll to latest")
                }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if engine?.isBusy == true {
            proxy.scrollTo(Self.streamAnchor(session), anchor: .bottom)
        } else if let last = session.messageList.last {
            proxy.scrollTo(last.id, anchor: .bottom)
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
