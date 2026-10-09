import Foundation
import Observation
import SwiftData

/// Owns the live session engines so they survive view rebuilds.
///
/// Engines are cheap to recreate (a session resumes from its persisted
/// transcript), so this dictionary can be pruned freely; it is only a
/// cache for the current window.
@MainActor
@Observable
final class ChatController {
    var selectedSessionID: UUID?

    private var engines: [UUID: SessionEngine] = [:]

    func engine(
        for session: ChatSession,
        modelContext: ModelContext,
        catalog: ModelCatalog
    ) -> SessionEngine {
        if let existing = engines[session.id] {
            return existing
        }
        let engine = SessionEngine(session: session, modelContext: modelContext, catalog: catalog)
        engines[session.id] = engine
        return engine
    }

    func dropEngine(for sessionID: UUID) {
        engines[sessionID] = nil
    }
}
