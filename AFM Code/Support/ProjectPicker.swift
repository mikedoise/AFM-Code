#if os(macOS)
import AppKit
import Foundation

/// Directory picker for adding a project folder.
enum ProjectPicker {
    @MainActor
    static func run() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to work in."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}
#endif
