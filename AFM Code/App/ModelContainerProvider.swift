import Foundation
import SwiftData

enum ModelContainerProvider {
    /// The app's SwiftData container. Created once at launch.
    static let container: ModelContainer = {
        let schema = Schema([Project.self, ChatSession.self, Message.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Failed to initialize the AFM Code model container: \(error)")
        }
    }()
}
