//
//  AccessibilityAnnouncements.swift
//  AFM Code
//
//  Posts VoiceOver announcements across the turn lifecycle, mirroring
//  the `AnnouncementModifier` in Perspective Intelligence's chat view.
//
//  - turn starts        → "Sending" (medium priority)
//  - reply finished    → "Reply complete" (high priority)
//  - turn failed       → the error text (high priority)
//
//  Each behavior is gated by the user-facing toggles in
//  `AppSettings` (`announceTypingWithVoiceOver`,
//  `announceMessagesWithVoiceOver`), which default on like PI's.
//

import SwiftUI

/// Attached to a session's chat pane: observes the session engine's
/// state and posts VoiceOver announcements at the moments a blind
/// user needs to know something changed.  Sighted users are
/// unaffected — the announcements are no-ops when VoiceOver is off.
struct AccessibilityTurnAnnouncements: ViewModifier {
    let engine: SessionEngine?
    let settings: AppSettings

    private var contextWarningLevel: Int {
        guard let used = engine?.contextTokenCount, let size = engine?.contextSize, size > 0 else { return 0 }
        let ratio = Double(used) / Double(size)
        return ratio >= 0.9 ? 2 : ratio >= 0.7 ? 1 : 0
    }

    @MainActor
    func body(content: Content) -> some View {
        content
            .onChange(of: contextWarningLevel) { oldLevel, newLevel in
                guard settings.announceTypingWithVoiceOver, newLevel > oldLevel else { return }
                VoiceOverAnnouncer.announce(newLevel == 2 ? "Context window almost full" : "Context window is filling. History may be compressed soon")
            }
            .onChange(of: engine?.isCompacting) { _, compacting in
                guard settings.announceTypingWithVoiceOver else { return }
                VoiceOverAnnouncer.announce(compacting == true ? "Compressing history" : "History compression finished")
            }
            .onChange(of: engine?.toolSteps.last?.title) { _, title in
                guard settings.announceTypingWithVoiceOver, let title else { return }
                VoiceOverAnnouncer.announce(title)
            }
            .onChange(of: engine?.state) { oldState, newState in
                if oldState == .responding,
                   newState == .idle,
                   settings.announceMessagesWithVoiceOver {
                    let reply = engine?.session.messageList.last(where: { $0.role == .assistant })?.content ?? ""
                    if !reply.isEmpty, reply.count <= 600, !reply.contains("```") {
                        let plain = (try? AttributedString(markdown: reply)).map { String($0.characters) } ?? ""
                        VoiceOverAnnouncer.announce(plain.isEmpty ? "Assistant replied" : "Assistant replied. " + plain)
                    } else {
                        VoiceOverAnnouncer.announce("Assistant replied. Use message headings to read the response.")
                    }
                }
                if newState == .responding,
                   settings.announceTypingWithVoiceOver {
                    VoiceOverAnnouncer.announce("Sending")
                }
                if case .error(let message) = newState {
                    VoiceOverAnnouncer.announceImportant("Error: \(message)")
                }
            }
    }
}

extension View {
    /// Turn lifecycle VoiceOver announcements (see
    /// `AccessibilityTurnAnnouncements`).
    func accessibilityTurnAnnouncements(
        engine: SessionEngine?,
        settings: AppSettings
    ) -> some View {
        modifier(
            AccessibilityTurnAnnouncements(engine: engine, settings: settings)
        )
    }
}
