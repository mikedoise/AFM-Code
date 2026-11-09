import Foundation
import SwiftData

@MainActor
enum ModelContainerProvider {
    /// Every persisted entity used by @Query must belong to this same schema.
    /// Adding MCPServer is an additive migration; retain the existing store URL
    /// and let SwiftData migrate it. Never delete the store to recover a failure.
    static var schema: Schema {
        Schema([Project.self, ChatSession.self, Message.self, MlxModel.self, MCPServer.self])
    }

    /// Prepared before any settings/controller/host instance. Fail closed on
    /// migration or access errors rather than opening an empty replacement.
    static let containerResult: Result<ModelContainer, Error> = Result {
        let locations = try DesktopStorage.locations
        let configuration = ModelConfiguration(schema: schema, url: locations.store, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        try DesktopApprovalMigration.apply(to: container.mainContext)
        return container
    }
    static var container: ModelContainer { try! containerResult.get() }
}
