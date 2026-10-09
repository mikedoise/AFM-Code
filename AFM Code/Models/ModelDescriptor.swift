import Foundation

/// A model AFM Code can prompt, detected at runtime from the
/// Foundation Models framework.
///
/// In the 27 SDK the on-device model comes from `SystemLanguageModel`;
/// the OS decides which variant backs it on a given machine
/// (`core3` = AFM 3 Core, `coreAdvanced3` = AFM 3 Core Advanced).
/// We never assume a tier — we report what the device actually offers.
struct ModelDescriptor: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case afmCore = "afm-core"
        case afmCoreAdvanced = "afm-core-advanced"
    }

    let kind: Kind
    var displayName: String
    var detail: String?
    var isAvailable: Bool
    var availabilityDetail: String?
    var contextSize: Int?
    var capabilities: Set<String>

    var id: String { kind.rawValue }

    init(
        kind: Kind,
        displayName: String,
        detail: String?,
        isAvailable: Bool,
        availabilityDetail: String? = nil,
        contextSize: Int? = nil,
        capabilities: Set<String> = []
    ) {
        self.kind = kind
        self.displayName = displayName
        self.detail = detail
        self.isAvailable = isAvailable
        self.availabilityDetail = availabilityDetail
        self.contextSize = contextSize
        self.capabilities = capabilities
    }
}
