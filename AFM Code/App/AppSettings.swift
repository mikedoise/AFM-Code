import Foundation
import Observation

/// App-wide settings, persisted in `UserDefaults`.
///
/// Small and UI-facing. This deliberately avoids SwiftData: a new
/// setting is just a new key — no model attribute, no schema
/// migration, no backfill rules.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let systemPrompt = "settings.systemPrompt"
        static let announceTypingWithVoiceOver = "settings.announceTypingWithVoiceOver"
        static let announceMessagesWithVoiceOver = "settings.announceMessagesWithVoiceOver"
    }

    /// The user's custom base system prompt. `nil` means the built-in
    /// default, which adapts to the model's context window size.
    var systemPrompt: String? {
        didSet {
            if let systemPrompt,
               systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.removeObject(forKey: Keys.systemPrompt)
            } else {
                defaults.set(systemPrompt, forKey: Keys.systemPrompt)
            }
        }
    }

    /// Whether to post VoiceOver announcements when the model starts
    /// working ("Thinking…", "Running a command…", waiting on
    /// approval).  Defaults on, matching Perspective Intelligence.
    var announceTypingWithVoiceOver: Bool {
        get {
            // Unset (legacy state) reads as true — the behavior has
            // always been on for new installs.
            defaults.object(forKey: Keys.announceTypingWithVoiceOver) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Keys.announceTypingWithVoiceOver) }
    }

    /// Whether to announce the model's reply when a turn finishes.
    /// Defaults on, matching Perspective Intelligence.
    var announceMessagesWithVoiceOver: Bool {
        get {
            defaults.object(forKey: Keys.announceMessagesWithVoiceOver) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Keys.announceMessagesWithVoiceOver) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.systemPrompt = defaults.string(forKey: Keys.systemPrompt)
    }
}
