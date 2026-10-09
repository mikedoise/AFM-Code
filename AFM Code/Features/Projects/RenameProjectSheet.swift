import SwiftUI
import SwiftData

/// Small sheet for renaming a project.
struct RenameProjectSheet: View {
    let project: Project
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Project")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(save)
            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            name = project.name
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        project.name = trimmed
        onSave(trimmed)
        dismiss()
    }
}
