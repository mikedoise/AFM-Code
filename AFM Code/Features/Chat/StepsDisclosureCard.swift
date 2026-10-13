import SwiftUI

/// A compact, accessible disclosure for live and persisted tool
/// activity, in the style of Perspective Intelligence's processing
/// steps card: one summary row until the user expands it; the assistant
/// status badge carries the live progress.
///
/// AFM adaptation: the expanded list is the existing `ToolStepView`
/// rows (so approval cards keep their full button UI), and the summary
/// line names the step currently in flight. A step waiting on approval
/// opens the card automatically — the decision must stay reachable.
struct StepsDisclosureCard: View {
    let steps: [ToolStep]
    /// Nil for history rows — no approval buttons.
    var approvals: ToolApprovalService? = nil
    var phase: Phase = .finished

    enum Phase: Equatable, Sendable {
        case live
        case finished
    }

    @State private var isExpanded = false
    @Environment(AppSettings.self) private var settings

    private var pendingStep: ToolStep? {
        steps.last { $0.status == .awaiting && (approvals?.pendingStepIDs.contains($0.id) ?? false) }
    }

    private var activeStep: ToolStep? {
        steps.last { $0.status == .running || $0.status == .approved }
    }

    private var hasFailure: Bool {
        steps.contains { $0.status == .failed || $0.status == .cancelled || $0.status == .denied }
    }

    private var title: String {
        if let pendingStep {
            return pendingStep.title
        }
        if let activeStep {
            return activeStep.title
        }
        if let last = steps.last {
            return last.title
        }
        return "Working…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            disclosureButton

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        ToolStepView(step: step, approvals: approvals)
                    }
                }
                .padding(.leading, 30)
                .padding(.trailing, 12)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.platformSeparator.opacity(0.08))
            }
        }
        .onChange(of: pendingStep?.id) { oldID, newID in
            if pendingStep != nil {
                isExpanded = true
            }
            // A new approval request appeared: the decision must be
            // heard, not just seen.  History rows carry no approval
            // service, so this only ever fires on the live row.
            if newID != nil, oldID == nil,
               settings.announceTypingWithVoiceOver {
                let title = pendingStep?.title ?? "A change"
                VoiceOverAnnouncer.announceImportant(
                    "\(title) is waiting for your approval"
                )
            }
        }
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                summaryIcon
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if phase == .live {
                    stepCounter
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(disclosureActionTitle)
        .accessibilityValue(disclosureAccessibilityValue)
        .accessibilityHint(
            isExpanded
                ? "Hides the tool activity"
                : "Shows the tool activity"
        )
        .help(disclosureActionTitle)
    }

    @ViewBuilder
    private var summaryIcon: some View {
        if pendingStep != nil {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        } else if hasFailure {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
                .font(.caption)
        } else if phase == .live {
            StableChatActivityIndicator()
        } else {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var stepCounter: some View {
        let settled = steps.filter { $0.status.isTerminal }.count
        return Text("\(settled)/\(steps.count)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .accessibilityHidden(true)
    }

    private var disclosureAccessibilityValue: String {
        let state = isExpanded ? "Expanded" : "Collapsed"
        let settled = steps.filter { $0.status.isTerminal }.count
        return "\(settled) of \(steps.count) steps. \(state)."
    }

    private var disclosureActionTitle: String {
        isExpanded ? "Collapse tool activity" : "Expand tool activity"
    }
}
