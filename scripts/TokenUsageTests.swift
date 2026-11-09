import Foundation
import FoundationModels
import Observation
import Synchronization

private struct UsageFixtureModel: LanguageModel {
    typealias Executor = UsageFixtureExecutor
    var toolRound = false
    let instance = UUID()
    var capabilities: LanguageModelCapabilities { .init([.toolCalling]) }
    var executorConfiguration: UsageFixtureExecutor.Configuration { .init(instance: instance) }
}
private struct UsageFixtureExecutor: LanguageModelExecutor {
    typealias Model = UsageFixtureModel
    struct Configuration: Hashable, Sendable { let instance: UUID }
    init(configuration: Configuration) {}
    nonisolated(nonsending) func respond(to request: LanguageModelExecutorGenerationRequest,
        model: UsageFixtureModel, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let continuing: Bool
        if let last = request.transcript.last, case .toolOutput = last { continuing = true }
        else { continuing = false }
        if model.toolRound && !continuing {
            await channel.send(.response(action: .updateUsage(input: .init(totalTokenCount: 10, cachedTokenCount: 2),
                output: .init(totalTokenCount: 3, reasoningTokenCount: 1))))
            await channel.send(.toolCalls(action: .toolCall(id: "fixture", name: "usageFixture", action: .appendArguments("{\"value\":\"test\"}", tokenCount: 0))))
        } else {
            await channel.send(.response(action: .appendText("fixture response", tokenCount: 1)))
            await channel.send(.response(action: .updateUsage(input: .init(totalTokenCount: 20, cachedTokenCount: 4),
                output: .init(totalTokenCount: 5, reasoningTokenCount: 2))))
        }
    }
}
private struct UsageFixtureTool: Tool {
    let name = "usageFixture"
    let description = "Return a synthetic value without external effects."
    @Generable struct Arguments { var value: String }
    func call(arguments: Arguments) async throws -> String { arguments.value }
}

@main struct TokenUsageTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afm-usage-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let started = Date(timeIntervalSince1970: 1000)
        let afm = ModelDescriptor(kind: .afmCore, displayName: "AFM Core", detail: nil, isAvailable: true)
        let mlx = ModelDescriptor(kind: .mlx, displayName: "Test MLX", detail: nil, isAvailable: true, mlxRepoID: "fixture/model")
        let core = ModelDescriptor(kind: .coreAI, displayName: "Test Core AI", detail: nil, isAvailable: true, coreAIModelID: "fixture")
        let store = TokenUsageStore(location: .success(url), now: started)
        precondition(store.totalTokens == 0 && store.trackingStartedAt == started && store.storageError == nil)
        let changed = Mutex(false)
        withObservationTracking { _ = store.totalTokens } onChange: { changed.withLock { $0 = true } }
        let a = store.begin(model: afm, purpose: .response)
        let b = store.begin(model: mlx, purpose: .response)
        precondition(store.pendingRequests == 2)
        store.finish(b, input: 100, output: 20)
        store.finish(a, input: 10, output: 3)
        store.finish(a, input: 10, output: 3)
        store.finishUnreported(a)
        let summary = store.begin(model: core, purpose: .compaction)
        store.finish(summary, input: 50, output: 5)
        precondition(changed.withLock { $0 }, "Settings totals must observe store updates")
        precondition(store.inputTokens == 160 && store.outputTokens == 28 && store.totalTokens == 188)
        precondition(store.completedRequests == 3 && store.unreportedRequests == 0 && store.pendingRequests == 0)
        precondition(store.models.first?.id == mlx.id && store.models.first(where: { $0.id == core.id })?.compactionRequests == 1)
        print("PASS multiple models, overlapping requests, compaction and duplicate completion")

        // Regeneration is another generation, even if its old chat messages are deleted.
        let regenerated = store.begin(model: afm, purpose: .response)
        store.finish(regenerated, input: 10, output: 0)
        let failed = store.begin(model: afm, purpose: .response)
        store.finishUnreported(failed)
        store.finishUnreported(failed)
        let missing = store.begin(model: mlx, purpose: .response)
        store.finish(missing, input: 0, output: 0)
        let invalid = store.begin(model: core, purpose: .response)
        store.finish(invalid, input: -1, output: 50)
        let overflow = store.begin(model: core, purpose: .response)
        store.finish(overflow, input: Int.max, output: 1)
        precondition(store.totalTokens == 198 && store.unreportedRequests == 4 && store.completedRequests == 4)
        _ = store.begin(model: core, purpose: .response)
        let reopened = TokenUsageStore(location: .success(url))
        precondition(reopened.totalTokens == 198 && reopened.trackingStartedAt == started)
        precondition(reopened.pendingRequests == 0 && reopened.unreportedRequests == 5)
        precondition(TokenUsageStore(location: .success(url)).unreportedRequests == 5)
        print("PASS regeneration, empty output, failures, invalid reports, crash recovery and reopen")

        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: corruptURL)
        let corruptStore = TokenUsageStore(location: .success(corruptURL))
        precondition(!corruptStore.isAvailable && corruptStore.storageError != nil)
        precondition(corruptStore.begin(model: afm, purpose: .response) == nil)
        let unchanged = try Data(contentsOf: corruptURL)
        precondition(unchanged == corrupt)
        let futureURL = directory.appendingPathComponent("future.json")
        var future = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        future["version"] = 99
        let futureData = try JSONSerialization.data(withJSONObject: future)
        try futureData.write(to: futureURL)
        precondition(!TokenUsageStore(location: .success(futureURL)).isAvailable)
        let futureAfter = try Data(contentsOf: futureURL)
        precondition(futureAfter == futureData)
        precondition(!TokenUsageStore(location: .failure(CocoaError(.fileReadNoPermission))).isAvailable)
        print("PASS corrupt, future-version and unavailable storage preserve existing data")

        // Fail a write only inside this test's disposable directory.
        let saveDirectory = directory.appendingPathComponent("save-test")
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let saveURL = saveDirectory.appendingPathComponent("usage.json")
        let saveStore = TokenUsageStore(location: .success(saveURL))
        try FileManager.default.removeItem(at: saveDirectory)
        let unsaved = saveStore.begin(model: afm, purpose: .response)
        saveStore.finish(unsaved, input: 7, output: 2)
        precondition(saveStore.totalTokens == 9 && saveStore.storageError != nil)
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let retry = saveStore.begin(model: afm, purpose: .response)
        saveStore.finish(retry, input: 1, output: 1)
        precondition(saveStore.storageError == nil && TokenUsageStore(location: .success(saveURL)).totalTokens == 11)
        print("PASS save failure is visible and later writes recover without losing in-memory usage")

        // Real Foundation Models orchestration, deterministic executor, no weights or user data.
        let runtime = LanguageModelSession(model: UsageFixtureModel(), tools: [])
        for _ in 0..<2 {
            let before = runtime.usage
            let stream = runtime.streamResponse(to: "synthetic input")
            for try await _ in stream { /* Mirrors the app's streaming/collect flow. */ }
            let response = try await stream.collect()
            precondition(response.usage.input.totalTokenCount == 20 && response.usage.output.totalTokenCount == 5,
                "Response usage must be per request, not lifetime cumulative")
            precondition(runtime.usage.input.totalTokenCount - before.input.totalTokenCount == 20)
            precondition(runtime.usage.output.totalTokenCount - before.output.totalTokenCount == 5)
        }
        let toolSession = LanguageModelSession(model: UsageFixtureModel(toolRound: true), tools: [UsageFixtureTool()])
        var options = GenerationOptions()
        options.toolCallingMode = .allowed
        for _ in 0..<2 {
            let before = toolSession.usage
            let toolResponse = try await toolSession.streamResponse(to: "synthetic tool input", options: options).collect()
            precondition(toolResponse.usage.input.totalTokenCount == 20 && toolResponse.usage.output.totalTokenCount == 5,
                "Response usage covers only the final tool-loop step on this SDK")
            let runtimeUsage = reopened.begin(model: afm, purpose: .response)
            reopened.finish(runtimeUsage, inputBefore: before.input.totalTokenCount, outputBefore: before.output.totalTokenCount,
                inputAfter: toolSession.usage.input.totalTokenCount, outputAfter: toolSession.usage.output.totalTokenCount)
        }
        precondition(reopened.totalTokens == 274, "Both tool rounds of both turns must be counted exactly once")
        print("PASS real framework cumulative deltas include every tool round across repeated turns")
        print("PASS no cache/reasoning double count; response-only usage would have undercounted")
    }
}
