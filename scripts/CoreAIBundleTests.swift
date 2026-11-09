import Foundation

@main struct CoreAIBundleTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("afm-coreai-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let package = root.appendingPathComponent("test.aimodel")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
        for path in ["tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "test_ple.safetensors"] {
            try Data("{}".utf8).write(to: root.appendingPathComponent(path))
        }
        var metadata: [String: Any] = ["metadata_version": "0.2", "kind": "llm", "name": "Test", "assets": ["main": "test.aimodel"], "language": ["max_context_length": 4096, "embedded_tokenizer": true], "auxiliary_assets": ["per_layer_embeddings": "test_ple.safetensors"]]
        func save() throws { try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("metadata.json")) }
        func rejects(_ name: String, _ test: () throws -> Void) {
            do { try test(); fatalError("Expected rejection: \(name)") }
            catch { print("PASS \(name): \(error.localizedDescription)") }
        }
        try save()
        let info = try CoreAIBundleValidator.inspect(root, selectedModel: package)
        precondition(info.contextSize == 4096 && info.mainAsset == "test.aimodel")
        print("PASS complete folder and matching .aimodel")
        rejects("wrong selected model") { _ = try CoreAIBundleValidator.inspect(root, selectedModel: root.appendingPathComponent("other.aimodel")) }
        metadata["kind"] = "vlm"; try save()
        rejects("unsupported vision bundle") { _ = try CoreAIBundleValidator.inspect(root) }
        metadata["kind"] = "llm"
        metadata["language"] = ["max_context_length": 4096, "embedded_tokenizer": false]; try save()
        rejects("network tokenizer fallback") { _ = try CoreAIBundleValidator.inspect(root) }
        metadata["language"] = ["max_context_length": 4096, "embedded_tokenizer": true]
        metadata["assets"] = ["main": "../test.aimodel"]; try save()
        rejects("asset traversal") { _ = try CoreAIBundleValidator.inspect(root) }
        metadata["assets"] = ["main": "test.aimodel"]; try save()
        try fm.removeItem(at: root.appendingPathComponent("test_ple.safetensors"))
        rejects("missing Gemma PLE") { _ = try CoreAIBundleValidator.inspect(root) }
        try Data().write(to: root.appendingPathComponent("test_ple.safetensors"))
        try fm.createSymbolicLink(atPath: package.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        rejects("nested symlink escape") { _ = try CoreAIBundleValidator.inspect(root) }
        try fm.removeItem(at: package.appendingPathComponent("escape"))
        try fm.removeItem(at: root.appendingPathComponent("tokenizer/tokenizer.json"))
        rejects("missing tokenizer") { _ = try CoreAIBundleValidator.inspect(root) }
        for path in CommandLine.arguments.dropFirst() {
            let info = try CoreAIBundleValidator.inspect(URL(fileURLWithPath: path))
            print("PASS real export metadata: \(info.name), \(info.contextSize) tokens (not inference)")
        }
    }
}
