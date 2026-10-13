import SwiftUI

/// The prompt box in the Perspective Intelligence style: a rounded
/// container holding the native text input and the send/stop button,
/// with the session's model badge, context meter, and status line
/// beneath.
///
/// Key handling: Return sends, Shift-Return inserts a line break
/// (handled inside `ChatInputTextView`).
///
/// Vision support: images pasted into the text view are staged as
/// `PendingImageAttachment` objects and rendered as preview chips
/// above the input.  They are embedded into the sent message and
/// discarded after submission.
struct ComposerView: View {
    let session: ChatSession
    let engine: SessionEngine?

    @Environment(ModelCatalog.self) private var catalog
    @State private var draft = ""
    @State private var pendingImages: [PendingImageAttachment] = []
    @State private var prewarmTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private var model: ModelDescriptor? { engine?.activeModel ?? catalog.activeDescriptor }

    private var isBusy: Bool { engine?.isBusy == true }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model?.isAvailable == true
            && !isBusy
            && engine?.isCompacting != true
    }

    var body: some View {
        VStack(spacing: 0) {
            // Decorative separator; VoiceOver otherwise stops on a
            // blank element.
            Divider().opacity(0.3)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                if let error = engine?.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                // Image preview chips (vision support)
                if !pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingImages) { attachment in
                                ImageAttachmentPreviewCard(
                                    attachment: attachment
                                ) {
                                    pendingImages.removeAll { $0.id == attachment.id }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                }

                messageInputField

                metadataRow
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .onAppear {
            isFocused = true
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                engine?.prewarm()
            }
        }
        .onChange(of: draft) { _, newValue in
            // Prewarm once the user pauses typing, so the first token
            // of the next turn arrives faster.
            prewarmTask?.cancel()
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            prewarmTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled,
                      engine?.isBusy != true,
                      engine?.isCompacting != true else { return }
                engine?.prewarm(draft: newValue)
            }
        }
    }

    // MARK: - Input

    private var messageInputField: some View {
        HStack(spacing: 8) {
            ChatInputTextView(
                text: $draft,
                placeholder: "Ask AFM Code…",
                isDisabled: model?.isAvailable == false,
                accessibilityLabel: "Message AFM Code",
                onSubmit: { _ in submit() },
                onImagePaste: { images in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        pendingImages.append(contentsOf: images)
                    }
                }
            )
            .focused($isFocused)

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.platformTextBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.platformSeparator.opacity(0.5) : Color.platformSeparator.opacity(0.3),
                    lineWidth: 1
                )
        )
    }

    private var sendButton: some View {
        Button {
            if isBusy {
                engine?.cancel()
            } else {
                submit()
            }
        } label: {
            Image(systemName: isBusy ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(sendButtonColor)
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.2), value: isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !isBusy)
        .accessibilityLabel(isBusy ? "Stop generating" : "Send message")
        .help(isBusy ? "Stop generating" : "Send (Return)")
    }

    private var sendButtonColor: Color {
        if isBusy {
            return .red
        }
        return canSend ? Color.accentColor : .secondary.opacity(0.5)
    }

    // MARK: - Metadata row

    private var metadataRow: some View {
        HStack(spacing: 10) {
            ModelBadgeView()
            if let size = engine?.contextSize, size > 0 {
                let used = engine?.contextTokenCount
                let ratio = used.map { min(Double($0) / Double(size), 1.0) } ?? 0
                HStack(spacing: 5) {
                    Image(systemName: "gauge.medium")
                        .foregroundStyle(contextColor(used: used, size: size))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Rectangle()
                                    .fill(contextColor(used: used, size: size))
                                    .frame(width: max(0, proxy.size.width * ratio))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .frame(width: 56, height: 5)
                        .opacity(used == nil ? 0.35 : 1)
                    Text(used.map { "\(ModelBadgeView.compact($0)) / \(ModelBadgeView.compact(size)) tokens" }
                         ?? "\(ModelBadgeView.compact(size)) token window")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .help(used == nil
                      ? "The model's context window. Usage is counted once the transcript is measured."
                      : "Context used by this session against the model's window. Older history compresses automatically as it fills.")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    used.map {
                        "Context: \(ModelBadgeView.compact($0)) of \(ModelBadgeView.compact(size)) tokens used"
                    } ?? "Context window: \(ModelBadgeView.compact(size)) tokens"
                )
            }
            if engine?.isCompacting == true {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Compressing history…")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Compressing history")
                .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
            Text("Return to send · Shift-Return for a new line")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                // Keyboard hint for sighted users; VoiceOver users
                // activate the send button directly.
                .accessibilityHidden(true)
        }
    }

    // MARK: - Actions

    private func submit() {
        let text = draft
        let images = pendingImages
        draft = ""
        pendingImages.removeAll()
        engine?.send(text, images: images.map { ($0.jpegData, $0.suggestedFilename) })
    }

    private func contextColor(used: Int?, size: Int) -> Color {
        let ratio = used.map { Double($0) / Double(size) } ?? 0
        if ratio > 0.9 { return .red }
        if ratio > 0.7 { return .orange }
        return used == nil ? Color.secondary.opacity(0.45) : .secondary
    }
}
