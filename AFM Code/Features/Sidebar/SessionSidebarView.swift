import SwiftUI
import SwiftData

/// The project sidebar (Phase 1: a flat session list; Projects join in Phase 2).
struct SessionSidebarView: View {
    let sessions: [ChatSession]
    @Binding var selectedSessionID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        List(selection: $selectedSessionID) {
            ForEach(sessions) { session in
                SessionRow(session: session)
                    .tag(session.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            delete(session)
                        }
                    }
            }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Create a session to start coding.")
                )
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New Session")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ModelBadgeView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.bar)
        }
    }

    private func createSession() {
        let session = ChatSession()
        modelContext.insert(session)
        try? modelContext.save()
        selectedSessionID = session.id
    }

    private func delete(_ session: ChatSession) {
        modelContext.delete(session)
        try? modelContext.save()
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
    }
}

private struct SessionRow: View {
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if let last = session.messageList.last {
                Text(last.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }
}
