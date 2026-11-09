import Foundation
import Observation

/// Local counters only: no prompts, replies, paths, tool arguments or session IDs.
@MainActor
@Observable
final class TokenUsageStore {
    static let shared = TokenUsageStore(location: Result {
        try DesktopStorage.locations.support.appendingPathComponent("token-usage-v1.json")
    })

    enum Purpose: String, Codable, Sendable { case response, compaction }

    struct ModelUsage: Codable, Identifiable, Sendable {
        let id: String
        var name: String
        let backend: String
        var inputTokens = 0
        var outputTokens = 0
        var completedRequests = 0
        var compactionRequests = 0
        var unreportedRequests = 0
        var totalTokens: Int { inputTokens + outputTokens }
    }

    private struct Pending: Codable {
        let modelID: String
        let purpose: Purpose
    }

    private struct Ledger: Codable {
        var version = 1
        let trackingStartedAt: Date
        var models: [String: ModelUsage] = [:]
        var pending: [String: Pending] = [:]
    }

    private var ledger: Ledger?
    private let fileURL: URL?
    private(set) var storageError: String?
    var isAvailable: Bool { ledger != nil }
    var trackingStartedAt: Date? { ledger?.trackingStartedAt }
    var models: [ModelUsage] {
        (ledger?.models.values.map { $0 } ?? []).sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }
    var inputTokens: Int { models.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int { models.reduce(0) { $0 + $1.outputTokens } }
    var totalTokens: Int { inputTokens + outputTokens }
    var completedRequests: Int { models.reduce(0) { $0 + $1.completedRequests } }
    var unreportedRequests: Int { models.reduce(0) { $0 + $1.unreportedRequests } }
    var pendingRequests: Int { ledger?.pending.count ?? 0 }

    init(location: Result<URL, Error>, now: Date = Date()) {
        switch location {
        case .failure:
            fileURL = nil
            storageError = "Usage storage is unavailable. Existing usage has not been replaced."
        case .success(let url):
            fileURL = url
            do {
                let data: Data?
                do { data = try Data(contentsOf: url) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    data = nil
                }
                var loaded = try data.map { try JSONDecoder().decode(Ledger.self, from: $0) }
                    ?? Ledger(trackingStartedAt: now)
                guard Self.isValid(loaded) else { throw CocoaError(.fileReadCorruptFile) }
                // An interrupted process never receives a final usage report.
                for pending in loaded.pending.values {
                    loaded.models[pending.modelID]?.unreportedRequests += 1
                }
                loaded.pending.removeAll()
                ledger = loaded
                persist()
            } catch {
                storageError = "Saved usage could not be read. Tracking is paused to preserve the existing file."
            }
        }
    }

    @discardableResult
    func begin(model: ModelDescriptor?, purpose: Purpose) -> UUID? {
        guard var ledger, let model else { return nil }
        let id = UUID()
        if ledger.models[model.id] == nil {
            ledger.models[model.id] = ModelUsage(id: model.id, name: model.displayName, backend: Self.backend(model.kind))
        } else {
            ledger.models[model.id]?.name = model.displayName
        }
        ledger.pending[id.uuidString] = Pending(modelID: model.id, purpose: purpose)
        self.ledger = ledger
        persist()
        return id
    }

    /// Session usage is cumulative and includes tool rounds; response usage only
    /// describes the final response. Measure a delta around each completed request.
    func finish(_ id: UUID?, inputBefore: Int, outputBefore: Int, inputAfter: Int, outputAfter: Int) {
        let input = inputAfter.subtractingReportingOverflow(inputBefore)
        let output = outputAfter.subtractingReportingOverflow(outputBefore)
        guard inputBefore >= 0, outputBefore >= 0, !input.overflow, !output.overflow else {
            finishUnreported(id)
            return
        }
        finish(id, input: input.partialValue, output: output.partialValue)
    }

    /// Called once with final measured counters, never for stream snapshots.
    /// Cached and reasoning tokens are already included in the input/output totals.
    func finish(_ id: UUID?, input: Int, output: Int) {
        guard let id, var ledger, let pending = ledger.pending[id.uuidString],
              var model = ledger.models[pending.modelID] else { return }
        // Zero-only reports do not establish measured usage. Reject invalid or
        // overflowing counters instead of inventing values or trapping.
        let (total, totalOverflow) = input.addingReportingOverflow(output)
        let (_, aggregateOverflow) = totalTokens.addingReportingOverflow(total)
        guard input >= 0, output >= 0, total > 0, !totalOverflow, !aggregateOverflow else {
            finishUnreported(id)
            return
        }
        model.inputTokens += input
        model.outputTokens += output
        model.completedRequests += 1
        if pending.purpose == .compaction { model.compactionRequests += 1 }
        ledger.models[pending.modelID] = model
        ledger.pending.removeValue(forKey: id.uuidString)
        self.ledger = ledger
        persist()
    }

    /// Errors/cancellation have no authoritative final report; do not estimate.
    /// Also safe in a defer after finish: a completed request cannot be counted twice.
    func finishUnreported(_ id: UUID?) {
        guard let id, var ledger, let pending = ledger.pending.removeValue(forKey: id.uuidString) else { return }
        ledger.models[pending.modelID]?.unreportedRequests += 1
        self.ledger = ledger
        persist()
    }

    private func persist() {
        guard let ledger, let fileURL else { return }
        do {
            try JSONEncoder().encode(ledger).write(to: fileURL, options: .atomic)
            storageError = nil
        } catch {
            storageError = "Recent usage is shown in memory but could not be saved. It may be lost when the app closes."
        }
    }

    private static func isValid(_ ledger: Ledger) -> Bool {
        guard ledger.version == 1 else { return false }
        var total = 0
        var attempts = ledger.pending.count
        for (id, model) in ledger.models {
            guard id == model.id,
                  [model.inputTokens, model.outputTokens, model.completedRequests,
                   model.compactionRequests, model.unreportedRequests].allSatisfy({ $0 >= 0 }),
                  model.compactionRequests <= model.completedRequests else { return false }
            for count in [model.inputTokens, model.outputTokens] {
                let sum = total.addingReportingOverflow(count)
                guard !sum.overflow else { return false }
                total = sum.partialValue
            }
            for count in [model.completedRequests, model.unreportedRequests] {
                let sum = attempts.addingReportingOverflow(count)
                guard !sum.overflow, sum.partialValue < Int.max else { return false }
                attempts = sum.partialValue
            }
        }
        return ledger.pending.values.allSatisfy { ledger.models[$0.modelID] != nil }
    }

    private static func backend(_ kind: ModelDescriptor.Kind) -> String {
        switch kind {
        case .afmCore, .afmCoreAdvanced: "Apple Foundation Models"
        case .mlx: "MLX"
        case .coreAI: "Core AI"
        }
    }
}
