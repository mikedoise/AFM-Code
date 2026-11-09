// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "coreai-models-afm",
    platforms: [.macOS("27.0")],
    products: [.library(name: "CoreAILM", targets: ["CoreAILanguageModels"])],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-jinja.git", from: "2.5.1"),
        .package(url: "https://github.com/mlc-ai/xgrammar", exact: "0.2.2")
    ],
    targets: [
        .target(name: "CoreAILanguageModels", dependencies: [
            "CoreAIShared", "CXGrammar",
            .product(name: "Transformers", package: "swift-transformers"),
            .product(name: "Jinja", package: "swift-jinja")
        ], swiftSettings: [.define("CXGRAMMAR_IMPORT"), .enableUpcomingFeature("MemberImportVisibility"), .enableExperimentalFeature("Lifetimes")], linkerSettings: [.linkedLibrary("c++")]),
        .target(name: "CoreAIShared", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
        .target(name: "CXGrammar", dependencies: [.product(name: "XGrammar", package: "xgrammar")], path: "Sources/lib/CXGrammar", publicHeadersPath: "include")
    ],
    cxxLanguageStandard: .cxx17
)
