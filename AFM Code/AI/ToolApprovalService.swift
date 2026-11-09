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
    enum PermissionScope: String, Sendable { case command, mcp }
    private struct PendingPermission { let value: String; let scope: PermissionScope }
    private var pendingCommands: [UUID: PendingPermission] = [:]

    weak var project: Project?

    /// Exact commands the user has permanently allowed.
    private var transientCommandAllowlist: [String] = []
    var commandAllowlist: [String] {
        guard let project else { return transientCommandAllowlist }
        guard project.desktopAccessVersion == 1 else { return [] }
        return project.commandAllowlist ?? []
    }

    init(project: Project?) {
        self.project = project
    }

    /// Preserve shell syntax, including whitespace inside quotes. Historical
    /// entries remain unchanged: whitespace lost by older versions cannot be
    /// recovered. Untyped previous grants are preserved but are not honored.
    nonisolated static func normalize(_ command: String) -> String {
        command
    }

    nonisolated static func permissionKey(_ value: String, scope: PermissionScope = .command) -> String {
        scope.rawValue + ":" + value
    }

    nonisolated static func displayPermission(_ value: String) -> String {
        if value.hasPrefix("command:") { return String(value.dropFirst(8)) }
        if value.hasPrefix("mcp:") { return "MCP tool: " + value.dropFirst(4) }
        return "Inactive previous grant: " + value
    }

    func commandIsAllowed(_ command: String, scope: PermissionScope = .command) -> Bool {
        let normalized = Self.normalize(command)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return commandAllowlist.contains(Self.permissionKey(normalized, scope: scope))
    }

    /// Suspend until the UI decides or the turn is cancelled.
    ///
    /// Commands already on the allowlist fast-path straight through,
    /// and so does everything else when the project is set to
    /// auto-approve (a trusted project needs no round trip).
    func wait(for id: UUID, command: String? = nil, scope: PermissionScope = .command) async -> ApprovalDecision {
        guard !Task.isCancelled else { return .cancelled }
        if let command, commandIsAllowed(command, scope: scope) {
            return .alwaysAllow
        }
        if project?.desktopAccessVersion == 1 && project?.approvalMode == .auto {
            return .approve
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                // Publish only after the continuation exists. A quick button
                // press or Stop must never lose the decision and leave a waiter.
                continuations[id] = continuation
                pendingCommands[id] = command.map { PendingPermission(value: $0, scope: scope) }
                pendingStepIDs.insert(id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.decide(id, .cancelled)
            }
        }
    }

    /// Called by the UI when the user picks a button.
    func decide(_ id: UUID, _ decision: ApprovalDecision, command _: String? = nil) {
        pendingStepIDs.remove(id)
        let command = pendingCommands.removeValue(forKey: id)
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        if decision == .alwaysAllow, let command {
            rememberCommand(command.value, scope: command.scope)
        }
        continuation.resume(returning: decision)
    }

    private func rememberCommand(_ command: String, scope: PermissionScope) {
        let normalized = Self.normalize(command)
        let permission = Self.permissionKey(normalized, scope: scope)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !commandAllowlist.contains(permission) else { return }
        // Read the live project list so revocations in Settings apply to an
        // already-open conversation, and new grants do not restore old ones.
        var updated = commandAllowlist
        updated.append(permission)
        if let project { project.commandAllowlist = updated }
        else { transientCommandAllowlist = updated }
    }

    /// Drop everything left over after a turn ends. Steps are already
    /// persisted on the message by then.
    func reset() {
        for continuation in continuations.values {
            continuation.resume(returning: .cancelled)
        }
        continuations.removeAll()
        pendingCommands.removeAll()
        pendingStepIDs.removeAll()
    }
}
