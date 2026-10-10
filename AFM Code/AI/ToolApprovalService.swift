import Foundation
import Observation
import SwiftData

/// A decision on an approval request.
enum ApprovalDecision: Equatable, Sendable {
    case approve
    case alwaysAllow
    case deny
    /// The turn was stopped; not a user "no" (rendered as cancelled).
    case cancelled
}

/// How strictly a project gates the agent's mutating tools.
enum ApprovalMode: String, Codable, CaseIterable, Sendable {
    /// Every file write/edit and command asks the user first.
    case ask
    /// Trusted project: changes and commands run without an approval card.
    case auto

    var label: String {
        switch self {
        case .ask: return "Always ask"
        case .auto: return "Auto-approve changes"
        }
    }
}

/// Owns the approval lifecycle for tool calls that mutate anything.
///
/// A mutating tool registers its step as pending, then suspends in
/// `wait`. The chat UI presents the approval card and calls `decide`
/// (or the turn's cancellation resolves it). Commands the user picks
/// "Always Allow" for land in the per-project allowlist and run
/// without asking again.
@MainActor
@Observable
final class ToolApprovalService {
    /// Steps currently waiting on a decision (drives the card buttons).
    private(set) var pendingStepIDs: Set<UUID> = []
    private var continuations: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]

    weak var project: Project?

    /// Normalized commands the user has permanently allowed.
    private(set) var commandAllowlist: [String] = []

    init(project: Project?) {
        self.project = project
        self.commandAllowlist = (project?.commandAllowlist ?? []).map(Self.normalize)
    }

    /// Exact-match key for allowlist entries: trimmed, whitespace-collapsed.
    nonisolated static func normalize(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .joined(separator: " ")
    }

    func commandIsAllowed(_ command: String) -> Bool {
        let normalized = Self.normalize(command)
        guard !normalized.isEmpty else { return false }
        return commandAllowlist.contains(normalized)
    }

    func registerPending(_ id: UUID) {
        pendingStepIDs.insert(id)
    }

    /// Suspend until the UI decides or the turn is cancelled.
    ///
    /// Commands already on the allowlist fast-path straight through,
    /// and so does everything else when the project is set to
    /// auto-approve (a trusted project needs no round trip).
    func wait(for id: UUID, command: String? = nil) async -> ApprovalDecision {
        if let command, commandIsAllowed(command) {
            return .alwaysAllow
        }
        if project?.approvalMode == .auto {
            return .approve
        }
        registerPending(id)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
                continuations[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.decide(id, .cancelled)
            }
        }
    }

    /// Called by the UI when the user picks a button.
    func decide(_ id: UUID, _ decision: ApprovalDecision, command: String? = nil) {
        pendingStepIDs.remove(id)
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        if decision == .alwaysAllow, let command {
            rememberCommand(command)
        }
        continuation.resume(returning: decision)
    }

    private func rememberCommand(_ command: String) {
        let normalized = Self.normalize(command)
        guard !normalized.isEmpty, !commandAllowlist.contains(normalized) else { return }
        commandAllowlist.append(normalized)
        project?.commandAllowlist = commandAllowlist
    }

    /// Drop everything left over after a turn ends. Steps are already
    /// persisted on the message by then.
    func reset() {
        for continuation in continuations.values {
            continuation.resume(returning: .cancelled)
        }
        continuations.removeAll()
        pendingStepIDs.removeAll()
    }
}
