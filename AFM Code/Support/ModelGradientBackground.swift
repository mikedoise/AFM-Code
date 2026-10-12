import SwiftUI

/// The same deepened model colors support white text in cards and chat bubbles.
struct ModelGradientBackground: View {
    let colors: [Color]
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Color.black.opacity(colorSchemeContrast == .increased ? 0.55 : 0.44)
            }
    }
}
