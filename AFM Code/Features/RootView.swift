import SwiftUI
import SwiftData

/// App root: sessions sidebar + chat detail.
struct RootView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(ChatController.self) private var chat
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.lastMessageAt, order: .reverse)
    private var sessions: [ChatSession]

    var body: some View {
        @Bindable var chat = chat
        NavigationSplitView {
            SessionSidebarView(
                sessions: sessions,
                selectedSessionID: $chat.selectedSessionID
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            if let selectedID = chat.selectedSessionID,
               let session = sessions.first(where: { $0.id == selectedID }) {
                ChatView(session: session)
            } else {
                EmptyWorkspaceView()
            }
        }
    }
}

/// Shown when no session is selected.
private struct EmptyWorkspaceView: View {
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "curlybraces.square")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No Session Selected")
                .font(.title3.weight(.semibold))
            Text("Select a session, or create one to start coding.")
                .foregroundStyle(.secondary)
            ModelBadgeView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
