import Foundation
import Observation

/// Resolves a project's folder from its security-scoped bookmark and
/// tracks whether the folder is still there.
///
/// Phase 2 uses this for status checks only (short leases). Phase 3's
/// tools will route file/shell operations through `withAccess`.
@MainActor
@Observable
final class Workspace {
    enum Status: Equatable, Sendable {
        case unknown
        case active
        case folderMissing
        case bookmarkInvalid
    }

    let project: Project
    private(set) var folderURL: URL?
    private(set) var status: Status = .unknown
    private var isAccessing = false

    init(project: Project) {
        self.project = project
        refresh()
    }

    /// Re-resolve the bookmark and check that the folder exists.
    func refresh() {
        releaseLease()
        folderURL = nil
        status = .unknown

        guard let data = project.bookmarkData else {
            status = .bookmarkInvalid
            return
        }
        var isStale: Bool = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            status = .bookmarkInvalid
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        isAccessing = accessed
        let exists = accessed && FileManager.default.fileExists(atPath: url.path)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        releaseLease()

        folderURL = url
        status = (exists && isDirectory) ? .active : .folderMissing
    }

    /// Run an operation with a temporary security-scoped lease on the
    /// project folder. Returns `nil` when the folder can't be accessed.
    func withAccess<T>(_ operation: (URL) throws -> T) rethrows -> T? {
        guard let url = folderURL else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard accessed else { return nil }
        return try operation(url)
    }

    private func releaseLease() {
        if isAccessing, let url = folderURL {
            url.stopAccessingSecurityScopedResource()
            isAccessing = false
        }
    }
}
