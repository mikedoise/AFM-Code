import SwiftUI
import SwiftData

/// The transcript: persisted messages plus the live streaming tail,
/// all rendered as bubbles in the Perspective Intelligence style.
struct MessageListView: View {
    let session: ChatSession
    let engine: SessionEngine?

    @Environment(ModelCatalog.self) private var catalog

    /// Whether the viewport sits at (or near) the bottom. Auto-scroll
    /// only follows the stream while this is true, so the user can
    /// read back through history mid-turn without being yanked down.
    @State private var isNearBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.messageList) { message in
                        MessageRowView(message: message)
                            .id(message.id)
                    }

                    if let engine, engine.isBusy {
                        MessageRowView(
                            role: .assistant,
                            content: engine.streamingText,
                            isStreaming: true,
                            thinking: engine.streamingReasoning,
                            steps: engine.toolSteps.isEmpty ? nil : engine.toolSteps,
                            approvals: engine.approvals,
                            modelID: engine.activeModel?.id,
                            statusText: liveStatusText,
                            statusIsApproval: liveStatusIsApproval
                        )
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
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Error")
                            .accessibilityValue(error)
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
            .task(id: engine?.streamingReasoning) {
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
                    .accessibilityLabel("Scroll to latest message")
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

    // MARK: - Live status

    /// The badge above the in-flight assistant row: the model's name
    /// while it thinks or responds, or the working title of the current
    /// tool, the way Perspective Intelligence prefixes its statuses.
    private var liveStatusText: String? {
        guard engine?.isBusy == true else { return nil }
        let name = (engine?.activeModel ?? catalog.activeDescriptor)?.displayName ?? "Assistant"
        let steps = engine?.toolSteps ?? []
        if steps.contains(where: { $0.status == .awaiting }) {
            if let step = steps.last(where: { $0.status == .awaiting }) {
                return "\(name) · \(step.title)…"
            }
            return "\(name) is waiting for your approval…"
        }
        if let step = steps.last(where: { $0.status == .running || $0.status == .approved }) {
            return "\(step.title)…"
        }
        if (engine?.streamingText ?? "").isEmpty {
            return "\(name) is thinking…"
        }
        return "\(name) is responding…"
    }

    private var liveStatusIsApproval: Bool {
        let steps = engine?.toolSteps ?? []
        return steps.contains { $0.status == .awaiting && (engine?.approvals?.pendingStepIDs.contains($0.id) ?? false) }
    }

    private static func streamAnchor(_ session: ChatSession) -> String {
        "streaming-\(session.id.uuidString)"
    }
}
