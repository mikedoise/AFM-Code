import SwiftUI

/// A model's shared visual identity: the gradient used for its
/// avatar, message bubble (in "Model Colors" style), and the model
/// picker card.
///
/// The gradients and icons are the shared card styles from
/// Perspective Intelligence. On-device AFM variants get fixed
/// identities; MLX models map their repository id to one of the same
/// styles with a stable hash, so a model looks the same everywhere in
/// the app (and across sessions).
struct ModelIdentity: Hashable, Sendable {
    let icon: String
    let gradient: [Color]

    var color: Color {
        gradient.first ?? .accentColor
    }
}

enum ModelIdentityPalette {
    /// The 12 shared gradient styles (port of PI's `promptCardStyles`).
    static let styles: [ModelIdentity] = [
        ModelIdentity(icon: "sparkles", gradient: [Color(red: 0.62, green: 0.32, blue: 0.95), Color(red: 0.36, green: 0.56, blue: 1.00)]),
        ModelIdentity(icon: "bolt.fill", gradient: [Color(red: 1.00, green: 0.71, blue: 0.18), Color(red: 1.00, green: 0.39, blue: 0.23)]),
        ModelIdentity(icon: "globe", gradient: [Color(red: 0.22, green: 0.74, blue: 0.87), Color(red: 0.11, green: 0.46, blue: 0.98)]),
        ModelIdentity(icon: "calendar.badge.clock", gradient: [Color(red: 0.02, green: 0.74, blue: 0.47), Color(red: 0.00, green: 0.53, blue: 0.36)]),
        ModelIdentity(icon: "wand.and.stars", gradient: [Color(red: 0.99, green: 0.29, blue: 0.65), Color(red: 0.63, green: 0.36, blue: 0.95)]),
        ModelIdentity(icon: "brain.head.profile", gradient: [Color(red: 0.99, green: 0.56, blue: 0.20), Color(red: 0.86, green: 0.22, blue: 0.48)]),
        ModelIdentity(icon: "list.bullet.rectangle", gradient: [Color(red: 0.47, green: 0.34, blue: 0.94), Color(red: 0.24, green: 0.73, blue: 0.96)]),
        ModelIdentity(icon: "chart.bar.fill", gradient: [Color(red: 0.16, green: 0.69, blue: 0.38), Color(red: 0.00, green: 0.45, blue: 0.25)]),
        ModelIdentity(icon: "book.closed", gradient: [Color(red: 0.18, green: 0.56, blue: 0.99), Color(red: 0.10, green: 0.21, blue: 0.92)]),
        ModelIdentity(icon: "mic.fill", gradient: [Color(red: 0.99, green: 0.42, blue: 0.33), Color(red: 0.99, green: 0.22, blue: 0.47)]),
        ModelIdentity(icon: "leaf.fill", gradient: [Color(red: 0.11, green: 0.80, blue: 0.60), Color(red: 0.01, green: 0.62, blue: 0.37)]),
        ModelIdentity(icon: "camera.viewfinder", gradient: [Color(red: 0.17, green: 0.44, blue: 0.96), Color(red: 0.52, green: 0.27, blue: 0.94)])
    ]

    static let fallback = styles[0]

    /// The identity for a descriptor, by its stable `id`.
    static func identity(for descriptor: ModelDescriptor) -> ModelIdentity {
        identity(forModelID: descriptor.id)
    }

    /// Fixed identities for the on-device AFM pair.
    static func identity(forKind kind: ModelDescriptor.Kind) -> ModelIdentity {
        switch kind {
        case .afmCore:
            return styles[0] // sparkles, purple to blue — the on-device signature
        case .afmCoreAdvanced:
            return styles[2] // globe, cyan to blue
        case .mlx:
            return styles[6] // generic MLX
        }
    }

    /// The identity stored on a message or derived from a descriptor id.
    /// `nil` (no model recorded, e.g. very old rows) gets the fallback.
    static func identity(forModelID modelID: String?) -> ModelIdentity {
        guard let modelID else { return fallback }
        if let kind = ModelDescriptor.Kind(rawValue: modelID) {
            return identity(forKind: kind)
        }
        if let repoID = modelID.components(separatedBy: ":").last, !repoID.isEmpty {
            return identity(forMLXRepoID: repoID)
        }
        return fallback
    }

    /// Stable for a repository id across launches: a deterministic
    /// fold of the characters, not `hashValue` (which is randomized).
    static func identity(forMLXRepoID repoID: String) -> ModelIdentity {
        let folded = repoID.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
        let index = (folded >= 0 ? folded : -folded) % styles.count
        return styles[index]
    }
}
