import SwiftUI

/// A self-rotating arc that keeps spinning while visible, ported from
/// Perspective Intelligence. Plain `ProgressView` spinners can stutter
/// when the containing view re-evaluates on every streamed token; the
/// repeating animation here is independent of that churn.
struct StableChatActivityIndicator: View {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRotating = false

    init(tint: Color = .secondary) {
        self.tint = tint
    }

    var body: some View {
        Circle()
            .trim(from: 0.16, to: 0.88)
            .stroke(
                tint,
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .frame(width: 14, height: 14)
            .fixedSize()
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: 0.85).repeatForever(autoreverses: false),
                value: isRotating
            )
            .onAppear {
                isRotating = !reduceMotion
            }
            .onChange(of: reduceMotion) { _, newValue in
                isRotating = !newValue
            }
            .accessibilityHidden(true)
    }
}
