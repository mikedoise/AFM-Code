import AppKit
import SwiftUI

/// Semantic platform colors shared by the chat chrome. Mirrors the
/// helper from Perspective Intelligence so the chrome reads the same
/// in both apps.
extension Color {
    static var platformWindowBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var platformTextBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var platformControlBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var platformSeparator: Color {
        Color(nsColor: .separatorColor)
    }

    static var platformTertiaryLabel: Color {
        Color(nsColor: .tertiaryLabelColor)
    }
}
