import SwiftUI

/// The prompt box: an expanding text field, send/stop control,
/// model badge, and context meter.
///
/// Key handling: Return sends, Shift-Return inserts a line break.
struct ComposerView: View {
    let session: ChatSession
    let engine: SessionEngine?

    @Environment(ModelCatalog.self) private var catalog
    @State private var draft = ""
    @State private var prewarmTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private var model: ModelDescriptor? { engine?.activeModel ?? catalog.activeDescriptor }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model?.isAvailable == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = engine?.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $draft)
                    .font(.body)
                    .autocorrectionDisabled()
                    .frame(minHeight: 44, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.quaternary)
                            .opacity(0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isFocused ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.35))
                    )
                    .focused($isFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            return .ignored
                        }
                        submit()
                        return .handled
                    }

                if engine?.isBusy == true {
                    Button {
                        engine?.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send (Return)")
                }
            }

            HStack(spacing: 10) {
                ModelBadgeView()
                if let used = engine?.contextTokenCount, let size = engine?.contextSize, size > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.medium")
                            .foregroundStyle(contextColor(used: used, size: size))
                        Text("\(ModelBadgeView.compact(used)) / \(ModelBadgeView.compact(size)) tokens")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
                if engine?.isCompacting == true {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Compressing history…")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Return to send · Shift-Return for a new line")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.bar)
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

    private func submit() {
        let text = draft
        draft = ""
        engine?.send(text)
    }

    private func contextColor(used: Int, size: Int) -> Color {
        let ratio = Double(used) / Double(size)
        if ratio > 0.9 { return .red }
        if ratio > 0.7 { return .orange }
        return .secondary
    }
}
