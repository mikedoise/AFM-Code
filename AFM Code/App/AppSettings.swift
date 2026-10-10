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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.systemPrompt = defaults.string(forKey: Keys.systemPrompt)
    }
}
