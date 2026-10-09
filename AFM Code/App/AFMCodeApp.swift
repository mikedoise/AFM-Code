import SwiftUI
import SwiftData

@main
struct AFMCodeApp: App {
    @State private var catalog = ModelCatalog()
    @State private var chat = ChatController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(catalog)
                .environment(chat)
                .modelContainer(ModelContainerProvider.container)
                .frame(minWidth: 860, minHeight: 540)
                .task {
                    await catalog.probe()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            // Single-window app: no "New Window" menu item.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
