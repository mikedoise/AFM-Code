import SwiftUI

/// The assistant's live status while a turn is in flight:
/// "Model is thinking…" above the bubble, or the working title of the
/// current tool. Ported from Perspective Intelligence.
///
/// Approval is a suspended user-decision state, not indeterminate
/// background work — it shows a static icon instead of a spinner.
enum AssistantStatusPresentation: Equatable, Sendable {
    case activeProgress
    case waitingForApproval

    var showsIndeterminateProgress: Bool {
        self == .activeProgress
    }

    var staticSystemImageName: String? {
        switch self {
        case .activeProgress:
            return nil
        case .waitingForApproval:
            return "hand.raised.fill"
        }
    }

    var addsFrequentUpdatesAccessibilityTrait: Bool {
        self == .activeProgress
    }
}

struct AssistantStatusBadge: View {
    let text: String
    var presentation: AssistantStatusPresentation = .activeProgress

    var body: some View {
        HStack(spacing: 6) {
            if presentation.showsIndeterminateProgress {
                StableChatActivityIndicator()
                    .accessibilityHidden(true)
            } else if let systemImageName = presentation.staticSystemImageName {
                Image(systemName: systemImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.platformSeparator.opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant status: \(text.replacingOccurrences(of: "…", with: ""))")
        .accessibilityAddTraits(
            presentation.addsFrequentUpdatesAccessibilityTrait
                ? .updatesFrequently
                : []
        )
    }
}
