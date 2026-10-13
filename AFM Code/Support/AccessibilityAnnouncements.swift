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

    @MainActor
    func body(content: Content) -> some View {
        content
            .onChange(of: engine?.state) { oldState, newState in
                if oldState == .responding,
                   newState == .idle,
                   settings.announceMessagesWithVoiceOver {
                    VoiceOverAnnouncer.announceImportant("Reply complete")
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
