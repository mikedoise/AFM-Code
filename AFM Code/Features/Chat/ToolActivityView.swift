import SwiftUI

/// The list of tool steps for one turn (live or from history).
struct ToolStepListView: View {
    let steps: [ToolStep]
    /// Nil for history rows — no approval buttons.
    var approvals: ToolApprovalService? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps) { step in
                ToolStepView(step: step, approvals: approvals)
            }
        }
    }
}

/// One tool step: an approval card while awaiting a decision, a
/// compact (expandable) row once resolved.
struct ToolStepView: View {
    let step: ToolStep
    var approvals: ToolApprovalService? = nil

    @State private var isExpanded = false

    private var isAwaiting: Bool {
        step.status == .awaiting
            && (approvals?.pendingStepIDs.contains(step.id) ?? false)
    }

    var body: some View {
        if isAwaiting {
            awaitingCard
        } else {
            resolvedRow
        }
    }

    // MARK: - Approval card

    private var awaitingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: step.icon)
                    .foregroundStyle(.orange)
                Text(step.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("Awaiting approval")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.15))
                    .clipShape(Capsule())
            }

            if let command = step.command {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let diff = step.diff {
                DiffView(diff: diff)
            }

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    decide(.deny)
                } label: {
                    Label("Deny", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Button {
                    decide(.approve)
                } label: {
                    Label(step.kind == .command ? "Allow" : "Approve", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)

                if step.kind == .command {
                    Button {
                        decide(.alwaysAllow)
                    } label: {
                        Label("Always Allow", systemImage: "hand.raised")
                    }
                    .buttonStyle(.bordered)
                    .help("Run this exact command without asking again in this project")
                }

                Spacer()
            }
        }
        .padding(12)
        .background(.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.35))
        )
    }

    private func decide(_ decision: ApprovalDecision) {
        approvals?.decide(step.id, decision, command: step.command)
    }

    // MARK: - Resolved row

    private var resolvedRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if hasPayload { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: step.statusIcon)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    Image(systemName: step.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(step.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let summary = step.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if hasPayload {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!hasPayload)

            if isExpanded, hasPayload {
                payload
                    .padding(10)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var hasPayload: Bool {
        (step.detail?.isEmpty == false) || (step.diff != nil) || step.command != nil
    }

    @ViewBuilder
    private var payload: some View {
        if let command = step.command, step.kind == .command, step.detail == nil {
            Text(command)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
        if let diff = step.diff {
            DiffView(diff: diff)
            if let detail = step.detail {
                detailText(detail)
            }
        }
        if let detail = step.detail, step.diff == nil {
            detailText(detail)
        }
    }

    private func detailText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 200)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusColor: Color {
        switch step.status {
        case .done: return .green
        case .denied, .failed: return .red
        case .cancelled: return .secondary
        case .running, .approved: return .accentColor
        case .awaiting: return .orange
        }
    }
}
