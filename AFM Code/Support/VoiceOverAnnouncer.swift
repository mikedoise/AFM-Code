//
//  VoiceOverAnnouncer.swift
//  AFM Code
//
//  Posts VoiceOver announcements, mirroring the pattern Perspective
//  Intelligence uses in its AnnouncementModifier and views:
//  `NSAccessibility.post(element: NSApp, notification:
//  .announcementRequested)`.  A user with VoiceOver running hears the
//  message even when focus is elsewhere; sighted users are unaffected.
//

import AppKit
import Foundation

enum VoiceOverAnnouncer {
    /// Priority for routine status changes ("Thinking…", "Copied").
    private static let medium: Int = NSAccessibilityPriorityLevel.medium.rawValue
    /// Priority for content that matters ("Your reply is ready").
    private static let high: Int = NSAccessibilityPriorityLevel.high.rawValue

    /// Announce a routine status change.
    static func announce(_ message: String) {
        post(message, priority: medium)
    }

    /// Announce an important event (reply finished, error, decision
    /// needed). High priority preempts lower-priority announcements.
    static func announceImportant(_ message: String) {
        post(message, priority: high)
    }

    private static func post(_ message: String, priority: Int) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: priority
            ]
        )
    }
}
