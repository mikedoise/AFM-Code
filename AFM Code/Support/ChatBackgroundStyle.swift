//
//  ChatBackgroundStyle.swift
//  AFM Code
//
//  Ported from Perspective Intelligence.
//

import SwiftUI

enum ChatBackgroundPreference {
    static let key = "chatBackgroundStyle"
    static let defaultValue: ChatBackgroundStyle = .system
}

/// The chat canvas behind the transcript and composer. Applied once at
/// the app root; a dark palette also drives the window's color scheme.
struct ChatWindowBackground: View {
    @AppStorage(ChatBackgroundPreference.key)
    private var selectedStyle = ChatBackgroundPreference.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = ChatBackgroundStyle(rawValue: selectedStyle) ?? ChatBackgroundPreference.defaultValue
        style.color(for: colorScheme)
            .ignoresSafeArea()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

enum ChatBackgroundStyle: String, CaseIterable, Identifiable {
    case system
    case slate
    case sand
    case rose
    case peach
    case mint
    case sky
    case lavender
    case midnight
    case charcoal
    case navy
    case forest
    case plum
    case cocoa

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: "Default")
        case .slate: String(localized: "Slate")
        case .sand: String(localized: "Sand")
        case .rose: String(localized: "Rose")
        case .peach: String(localized: "Peach")
        case .mint: String(localized: "Mint")
        case .sky: String(localized: "Sky")
        case .lavender: String(localized: "Lavender")
        case .midnight: String(localized: "Midnight")
        case .charcoal: String(localized: "Charcoal")
        case .navy: String(localized: "Navy")
        case .forest: String(localized: "Forest")
        case .plum: String(localized: "Plum")
        case .cocoa: String(localized: "Cocoa")
        }
    }

    /// Dark backgrounds keep their depth independently of the app's appearance.
    var isAlwaysDark: Bool {
        switch self {
        case .midnight, .charcoal, .navy, .forest, .plum, .cocoa: true
        default: false
        }
    }

    func contentColorScheme(for colorScheme: ColorScheme) -> ColorScheme {
        isAlwaysDark ? .dark : colorScheme
    }

    /// Opaque colors keep the canvas consistent behind both lists and scroll views.
    /// The original palettes adapt to appearance; deeper palettes stay dark.
    func color(for colorScheme: ColorScheme) -> Color {
        if self == .system { return .platformWindowBackground }

        let components: (Double, Double, Double) = switch (self, colorScheme) {
        case (.slate, .dark): (0.13, 0.16, 0.20)
        case (.slate, _): (0.89, 0.91, 0.94)
        case (.sand, .dark): (0.22, 0.19, 0.14)
        case (.sand, _): (0.96, 0.92, 0.84)
        case (.rose, .dark): (0.24, 0.14, 0.19)
        case (.rose, _): (0.98, 0.89, 0.92)
        case (.peach, .dark): (0.25, 0.17, 0.12)
        case (.peach, _): (1.00, 0.91, 0.84)
        case (.mint, .dark): (0.12, 0.21, 0.17)
        case (.mint, _): (0.86, 0.95, 0.89)
        case (.sky, .dark): (0.11, 0.18, 0.25)
        case (.sky, _): (0.86, 0.93, 0.99)
        case (.lavender, .dark): (0.19, 0.15, 0.25)
        case (.lavender, _): (0.92, 0.89, 0.98)
        case (.midnight, _): (0.04, 0.05, 0.08)
        case (.charcoal, _): (0.12, 0.13, 0.15)
        case (.navy, _): (0.07, 0.13, 0.23)
        case (.forest, _): (0.06, 0.19, 0.14)
        case (.plum, _): (0.22, 0.10, 0.24)
        case (.cocoa, _): (0.22, 0.14, 0.10)
        case (.system, _): (0, 0, 0) // Handled by the system color above.
        }
        return Color(red: components.0, green: components.1, blue: components.2)
    }
}
