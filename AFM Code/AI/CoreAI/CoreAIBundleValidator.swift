import Foundation

/// Metadata eligibility only. A valid package still needs runtime load and device testing.
struct CoreAIBundleInfo: Sendable {
    var name: String
    var contextSize: Int
    var mainAsset: String
}

enum CoreAIImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

enum CoreAIBundleValidator {
    static func inspect(_ folder: URL, selectedModel: URL? = nil) throws -> CoreAIBundleInfo {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        func asset(_ path: String) throws -> URL {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw CoreAIImportError.invalid("The bundle contains an unsafe asset path: \(path).")
            }
            let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
                throw CoreAIImportError.invalid("The bundle is missing \(path), or it points outside the selected folder. Keep all exported files together.")
            }
            return url
        }
        let metadata = try asset("metadata.json")
        guard let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any],
              raw["metadata_version"] as? String == "0.2",
              raw["kind"] as? String == "llm",
              let assets = raw["assets"] as? [String: String], let main = assets["main"],
              let language = raw["language"] as? [String: Any],
              let context = language["max_context_length"] as? Int, context > 0 else {
            throw CoreAIImportError.invalid("Choose a version 0.2 Core AI text-language bundle with metadata.json. Vision, diffusion and standalone .aimodel packages are not supported by this importer.")
        }
        let mainURL = try asset(main)
        guard mainURL.pathExtension.lowercased() == "aimodel" else {
            throw CoreAIImportError.invalid("metadata.json must name an .aimodel as its main asset.")
        }
        if let selectedModel, selectedModel.standardizedFileURL.resolvingSymlinksInPath() != mainURL {
            throw CoreAIImportError.invalid("The selected .aimodel is not the main model declared by this folder's metadata.json. Choose the matching export folder.")
        }
        for path in assets.values { _ = try asset(path) }
        for path in (raw["auxiliary_assets"] as? [String: String] ?? [:]).values { _ = try asset(path) }
        guard language["embedded_tokenizer"] as? Bool == true else {
            throw CoreAIImportError.invalid("This bundle needs an embedded tokenizer for offline use. Export it with the tokenizer included.")
        }
        _ = try asset("tokenizer/tokenizer.json")
        _ = try asset("tokenizer/tokenizer_config.json")
        // Reject symlinks inside packages/tokenizer too; the bookmark grants only this folder.
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = enumerator?.nextObject() as? URL {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                guard item.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                    throw CoreAIImportError.invalid("The export contains a symbolic link outside its folder: \(item.lastPathComponent).")
                }
            }
        }
        return CoreAIBundleInfo(name: raw["name"] as? String ?? folder.lastPathComponent, contextSize: context, mainAsset: main)
    }
}
