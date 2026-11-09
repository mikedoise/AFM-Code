import Foundation

/// Keep pre-desktop data in place. Never copy a live SQLite store, reset a
/// database, or silently replace an inaccessible legacy store with a new one.
nonisolated enum DesktopStorage {
    struct Locations: Sendable {
        let store: URL
        let support: URL
        let legacyPreferences: URL
        let reusesLegacyStore: Bool
    }
    static let bundleID = "app.techopolis.AFMCode"
    static let prepared: Result<Locations, Error> = Result {
        try prepare(home: FileManager.default.homeDirectoryForCurrentUser, defaults: .standard)
    }
    static var locations: Locations { get throws { try prepared.get() } }

    static func exists(_ url: URL) throws -> Bool {
        do { _ = try url.resourceValues(forKeys: [.isDirectoryKey]); return true }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return false }
            if error.domain == NSPOSIXErrorDomain && error.code == 2 { return false }
            throw error
        }
    }

    static func prepare(home: URL, defaults: UserDefaults) throws -> Locations {
        let fm = FileManager.default
        let legacy = home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library")
        let legacySupport = legacy.appendingPathComponent("Application Support")
        let legacyStore = legacySupport.appendingPathComponent("default.store")
        let preferences = legacy.appendingPathComponent("Preferences/\(bundleID).plist")
        let reuse = try exists(legacyStore)
        if !reuse, try exists(legacySupport) {
            let entries = try fm.contentsOfDirectory(atPath: legacySupport.path).filter { $0 != ".DS_Store" }
            guard entries.isEmpty else {
                throw NSError(domain: "AFMDesktopStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Existing AFM app data was found, but its expected database is missing. No new store was opened. Restore access to the original database before reopening."])
            }
        }
        // An access error above propagates. Only a confirmed missing store may
        // select the new, app-specific location.
        let support = reuse ? legacySupport : home.appendingPathComponent("Library/Application Support/AFM Code")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let result = Locations(store: support.appendingPathComponent("default.store"), support: support,
            legacyPreferences: preferences, reusesLegacyStore: reuse)
        try importPreferences(from: preferences, defaults: defaults)
        return result
    }

    static let ownedPreferenceKeys = [
        "settings.systemPrompt", "settings.announceTypingWithVoiceOver", "settings.announceMessagesWithVoiceOver",
        "coreAI.importedModels.v1", "controller.selection", "sidebar.expandedProjects", "chatBubbleStyle", "chatBackgroundStyle"
    ]
    static func importPreferences(from url: URL, defaults: UserDefaults) throws {
        let marker = "desktop.preferencesImported.v1"
        guard !defaults.bool(forKey: marker) else { return }
        if try exists(url) {
            let data = try Data(contentsOf: url)
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            // Preserve any preferences already chosen in desktop mode. Import
            // only this app's known keys, not Apple/global preference domains.
            for key in ownedPreferenceKeys where defaults.object(forKey: key) == nil {
                if let value = values[key] { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: marker)
    }
}
