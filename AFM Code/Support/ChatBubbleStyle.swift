import SwiftUI

enum ChatBubblePreference {
    static let key = "chatBubbleStyle"
    static let defaultValue: ChatBubbleStyle = .modelColors
}

enum ChatBubbleStyle: String, CaseIterable, Identifiable {
    case theme
    case modelColors

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .theme: String(localized: "Theme")
        case .modelColors: String(localized: "Model Colors")
        }
    }

    var usesModelColors: Bool { self == .modelColors }

    func textColor(for colorScheme: ColorScheme) -> Color {
        usesModelColors || colorScheme == .dark ? .white : .black
    }
}
