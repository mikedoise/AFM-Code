#!/usr/bin/env python3
"""Compile production Core AI residency coordination with a deterministic fake adapter.
No app process is launched, no model weights are read, and no inference runs.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root/'AFM Code/AI/CoreAI/CoreAIModelManager.swift').read_text()
for line in ['import AppKit\n','import CoreAILanguageModels\n','import CoreAIShared\n']:
    source = source.replace(line, '')
start = source.index('    /// The second panel is intentional:')
end = source.index('    func remove(', start)
source = source[:start] + source[end:]  # file-panel UI is tested by the user, not simulated here
with tempfile.TemporaryDirectory(prefix='afm-residency-tests-') as temporary:
    temp = Path(temporary)
    (temp/'Manager.swift').write_text(source)
    (temp/'FakeAdapter.swift').write_text('''import Foundation
import FoundationModels
import Synchronization
struct CoreAILanguageModel: Sendable {
    struct Counters { var created = 0; var loads = 0; var unloads = 0; var active = 0; var maxActive = 0 }
    static let counters = Mutex(Counters())
    enum LoadMode { case lazy }
    let instance = UUID()
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
    init(resourcesAt: URL, mode: LoadMode) async throws { Self.counters.withLock { $0.created += 1 } }
    func load() async throws {
        Self.counters.withLock { $0.loads += 1; $0.active += 1; $0.maxActive = max($0.maxActive, $0.active) }
        defer { Self.counters.withLock { $0.active -= 1 } }
        try await Task.sleep(for: .milliseconds(120))
    }
    func unload() { Self.counters.withLock { $0.unloads += 1 } }
}
''')
    (temp/'Tests.swift').write_text('''import Foundation
@main struct ResidencyTests {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for deterministic state")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "afm-residency-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var records: [ImportedCoreAIModel] = []
        for id in ["A", "B"] {
            let folder = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("model.aimodel"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
            for name in ["tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"] {
                try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
            }
            let metadata: [String: Any] = ["metadata_version": "0.2", "kind": "llm", "name": id, "assets": ["main": "model.aimodel"], "language": ["max_context_length": 4096, "embedded_tokenizer": true]]
            try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent("metadata.json"))
            let bookmark = try folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            records.append(ImportedCoreAIModel(id: id, name: id, bookmark: bookmark, folderPath: folder.path, mainAsset: "model.aimodel", contextSize: 4096))
        }
        defaults.set(try JSONEncoder().encode(records), forKey: "coreAI.importedModels.v1")
        let manager = CoreAIModelManager(defaults: defaults)
        let session = UUID()
        let first = try await manager.prepare(id: "A", sessionID: session)
        manager.finish(sessionID: session, keepResident: true)
        let second = try await manager.prepare(id: "A", sessionID: session)
        precondition(first.instance == second.instance && manager.preparationMetrics?.reusedModel == true)
        precondition(CoreAILanguageModel.counters.withLock { $0.loads } == 1)
        manager.finish(sessionID: session, keepResident: true)
        print("PASS successful turns reuse the same loaded model")

        manager.prewarm(id: "A", sessionID: session)
        precondition(!manager.isBusy)
        print("PASS opening an already warm conversation does not reload")

        manager.prewarm(id: "B", sessionID: session)
        try await wait { CoreAILanguageModel.counters.withLock { $0.loads } == 2 }
        let warmed = try await manager.prepare(id: "B", sessionID: session)
        precondition(warmed.instance != first.instance && manager.loadedModelID == "B")
        precondition(CoreAILanguageModel.counters.withLock { $0.loads } == 2)
        precondition((manager.preparationMetrics?.prewarmWaitSeconds ?? 0) > 0)
        print("PASS sending joins prewarm without duplicate load and records the wait")

        do { _ = try await manager.prepare(id: "A", sessionID: UUID()); fatalError("Concurrent generation admitted") }
        catch { precondition(manager.busySession == session) }
        manager.unloadIdleModel()
        precondition(manager.loadedModelID == "B")
        manager.finish(sessionID: session, keepResident: false)
        precondition(!manager.isBusy && manager.loadedModelID == nil)
        manager.finish(sessionID: UUID(), keepResident: true)
        precondition(!manager.isBusy && manager.loadedModelID == nil)
        print("PASS active use blocks eviction/concurrent sends; failed or cancelled turns release")

        manager.prewarm(id: "A", sessionID: session)
        manager.prewarm(id: "B", sessionID: session)
        try await wait { !manager.isBusy }
        precondition(manager.loadedModelID == "B")
        print("PASS newer conversation supersedes older preparation")

        let oldLoads = CoreAILanguageModel.counters.withLock { $0.loads }
        manager.prewarm(id: "A", sessionID: session)
        try await wait { CoreAILanguageModel.counters.withLock { $0.loads } > oldLoads }
        manager.cancelPrewarm(for: session)
        try await wait { !manager.isBusy }
        precondition(manager.loadedModelID == nil)
        print("PASS closing conversation cancels and drains unfinished preparation")

        manager.prewarm(id: "A", sessionID: session)
        try await wait { manager.busySession == session }
        manager.cancelPrewarm(for: session)
        manager.prewarm(id: "A", sessionID: session)
        try await wait { !manager.isBusy }
        precondition(manager.loadedModelID == "A")
        print("PASS reopening during cancellation starts replacement prewarm")

        _ = try await manager.prepare(id: "A", sessionID: session)
        let otherSession = UUID()
        manager.prewarm(id: "B", sessionID: otherSession)
        precondition(manager.loadedModelID == "A")
        manager.finish(sessionID: session, keepResident: true)
        try await wait { !manager.isBusy }
        precondition(manager.loadedModelID == "B")
        manager.cancelPrewarm(for: otherSession)
        manager.unloadIdleModel()
        print("PASS conversation opened during generation warms after current turn")

        manager.prewarm(id: "B", sessionID: session)
        let claim = Task { try await manager.prepare(id: "B", sessionID: session) }
        claim.cancel()
        do { _ = try await claim.value; fatalError("Cancelled send succeeded") } catch is CancellationError {}
        try await wait { !manager.isBusy }
        precondition(manager.loadedModelID == nil)
        print("PASS cancelled send drains prewarm and releases the generation claim")

        _ = try await manager.prepare(id: "A", sessionID: session)
        manager.finish(sessionID: session, keepResident: true)
        manager.remove("A")
        precondition(manager.loadedModelID == nil)
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("A/model.aimodel").path))
        precondition(CoreAILanguageModel.counters.withLock { $0.maxActive } == 1)
        print("PASS removing a reference unloads its engine, preserves files, and loads never overlap")

        let broken = root.appendingPathComponent("B/model.aimodel")
        try FileManager.default.removeItem(at: broken)
        manager.prewarm(id: "B", sessionID: session)
        precondition(manager.isPreparing(modelID: "B") && !manager.isPreparing(modelID: "A"))
        try await wait { !manager.isBusy }
        precondition(manager.loadErrors["B"] != nil && manager.loadedModelID == nil && !manager.isPreparing(modelID: "B"))
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        manager.prewarm(id: "B", sessionID: session)
        try await wait { !manager.isBusy }
        precondition(manager.loadErrors["B"] == nil && manager.loadedModelID == "B")
        manager.unloadIdleModel()
        print("PASS preparation/error status is model-specific; retry clears load error; unload clears residency")
    }
}
''')
    cmd=['xcrun','swiftc','-parse-as-library','-swift-version','6','-target','arm64-apple-macos27.0',str(temp/'Manager.swift'),str(temp/'FakeAdapter.swift'),str(temp/'Tests.swift'),str(root/'AFM Code/Models/ModelDescriptor.swift'),str(root/'AFM Code/AI/CoreAI/CoreAIBundleValidator.swift'),'-o',str(temp/'tests')]
    subprocess.run(cmd,check=True)
    subprocess.run([str(temp/'tests'),str(temp/'fixtures')],check=True,timeout=20)

root_view=(root/"AFM Code/Features/RootView.swift").read_text()
assert "ChatView(session: session)\n                    .id(session.id)" in root_view
print("PASS source guard: conversation identity owns its engine state (not UI validation)")
