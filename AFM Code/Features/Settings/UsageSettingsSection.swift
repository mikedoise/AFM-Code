import SwiftUI

struct UsageSettingsSection: View {
    var usage: TokenUsageStore = .shared

    var body: some View {
        Section {
            if usage.isAvailable {
                SettingsValueRow("Total recorded tokens", value: usage.totalTokens.formatted())
                    .font(.headline)
                    .accessibilityIdentifier("usage.totalTokens")
                SettingsValueRow("Input tokens", value: usage.inputTokens.formatted())
                SettingsValueRow("Output tokens", value: usage.outputTokens.formatted())
                SettingsValueRow("Completed generations", value: usage.completedRequests.formatted())
                if let started = usage.trackingStartedAt {
                    SettingsValueRow("Tracking since", value: started.formatted(date: .abbreviated, time: .shortened))
                }
                if usage.pendingRequests > 0 {
                    Text("\(usage.pendingRequests.formatted()) \(usage.pendingRequests == 1 ? "generation is" : "generations are") in progress. Totals update when a generation completes.")
                        .foregroundStyle(.secondary)
                }
                if usage.unreportedRequests > 0 {
                    Label("\(usage.unreportedRequests.formatted()) \(usage.unreportedRequests == 1 ? "generation has" : "generations have") no final token report and are excluded from totals.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                if usage.models.isEmpty {
                    Text("No usage recorded yet. Send a message to start tracking usage by model.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(usage.models) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(model.name).font(.headline)
                                Spacer()
                                Text("\(model.totalTokens.formatted()) tokens")
                                    .monospacedDigit()
                            }
                            Text("\(model.backend) · \(model.id)")
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("Input \(model.inputTokens.formatted()) · Output \(model.outputTokens.formatted())")
                            Text("\(model.completedRequests.formatted()) completed · \(model.compactionRequests.formatted()) context summaries · \(model.unreportedRequests.formatted()) unreported")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(model.name), \(model.backend), \(model.id). \(model.totalTokens.formatted()) total tokens. \(model.inputTokens.formatted()) input and \(model.outputTokens.formatted()) output. \(model.completedRequests.formatted()) completed generations, including \(model.compactionRequests.formatted()) context summaries. \(model.unreportedRequests.formatted()) generations without a final token report.")
                    }
                }
            }
            if let error = usage.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Local to this Mac, from the tracking date above. Counts come from the model's final usage report and include conversation history, tool rounds and context summaries. Cached input and reasoning output are already included, not added twice. Earlier chats are not backfilled. Failed, cancelled or interrupted generations and model prewarming are not counted. Only counters and model identity are saved; no message content is stored here.")
        }
    }
}
