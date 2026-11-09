import Foundation

/// One immutable proposal. Approval authorizes these exact output bytes,
/// not a find/replace operation recomputed against a newer file.
nonisolated struct PreparedFileChange: Sendable {
    static let maximumFileBytes = 8 * 1024 * 1024
    static let maximumFileLines = 100_000

    struct Snapshot: Sendable {
        let url: URL
        let resolvedURL: URL
        let data: Data?

        static func read(at url: URL) throws -> Snapshot {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) {
                    return Snapshot(url: url, resolvedURL: resolved, data: nil)
                }
                throw error
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ChangeError.invalidFile
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while let chunk = try handle.read(upToCount: min(64 * 1024, maximumFileBytes + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumFileBytes else { throw ChangeError.tooLarge }
            }
            try validateSize(data)
            guard String(data: data, encoding: .utf8) != nil else { throw ChangeError.invalidUTF8 }
            return Snapshot(url: url, resolvedURL: resolved, data: data)
        }
    }

    enum ChangeError: LocalizedError {
        case tooLarge, invalidFile, invalidUTF8, missingFile, emptySearch, noMatch, ambiguous(Int), stale
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This change exceeds the review limit (8 MiB or 100,000 lines per file). No change was made; split the work into smaller files."
            case .invalidFile: return "Only regular UTF-8 files can be changed. Directories and symbolic links are not accepted."
            case .invalidUTF8: return "The file is not valid UTF-8. No change was made."
            case .missingFile: return "The file does not exist. Read the correct file before editing."
            case .emptySearch: return "The search text is empty."
            case .noMatch: return "The search text does not appear in the complete file. Re-read it before editing."
            case .ambiguous(let count): return "The search text appears \(count) times in the complete file. Make it unique or explicitly use replaceAll."
            case .stale: return "The file or its location changed after the preview was prepared. Nothing was written. Re-read it and request approval for a new preview."
            }
        }
    }

    let snapshot: Snapshot
    let replacement: Data
    let diff: DiffData
    let summary: String
    var isNoOp: Bool { snapshot.data == replacement }

    static func edit(snapshot: Snapshot, path: String, find: String, replace: String, replaceAll: Bool) throws -> PreparedFileChange {
        guard !find.isEmpty else { throw ChangeError.emptySearch }
        guard let data = snapshot.data else { throw ChangeError.missingFile }
        guard String(data: data, encoding: .utf8) != nil else { throw ChangeError.invalidUTF8 }
        // Foundation's decoding initializer strips a UTF-8 BOM. The standard
        // library decoder preserves it, so unrelated edits preserve all bytes.
        let current = String(decoding: data, as: UTF8.self)
        let count = current.components(separatedBy: find).count - 1
        guard count > 0 else { throw ChangeError.noMatch }
        guard count == 1 || replaceAll else { throw ChangeError.ambiguous(count) }
        let (delta, overflow) = (replace.utf8.count - find.utf8.count).multipliedReportingOverflow(by: count)
        let (estimatedSize, sumOverflow) = current.utf8.count.addingReportingOverflow(delta)
        guard !overflow, !sumOverflow, estimatedSize <= maximumFileBytes else { throw ChangeError.tooLarge }
        let updated = current.replacingOccurrences(of: find, with: replace)
        return try make(snapshot: snapshot, path: path, text: updated,
                        summary: "Edited \(path) (\(count) replacement\(count == 1 ? "" : "s")).")
    }

    static func write(snapshot: Snapshot, path: String, content: String) throws -> PreparedFileChange {
        try make(snapshot: snapshot, path: path, text: content,
                 summary: "Wrote \(content.utf8.count) bytes to \(path).")
    }

    private static func make(snapshot: Snapshot, path: String, text: String, summary: String) throws -> PreparedFileChange {
        let data = Data(text.utf8)
        try validateSize(data)
        let original = snapshot.data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        var diff = LineDiff.compute(path: path,
                                    old: original.isEmpty ? [] : original.components(separatedBy: "\n"),
                                    new: text.isEmpty ? [] : text.components(separatedBy: "\n"),
                                    maxLines: Int.max)
        diff.isNewFile = snapshot.data == nil
        return PreparedFileChange(snapshot: snapshot, replacement: data, diff: diff, summary: summary)
    }

    private static func validateSize(_ data: Data) throws {
        guard data.count <= maximumFileBytes,
              data.reduce(1, { $0 + ($1 == 10 ? 1 : 0) }) <= maximumFileLines else { throw ChangeError.tooLarge }
    }

    /// Coordinates with document editors, checks full bytes immediately before
    /// replacement, and writes the approved bytes atomically. File coordination
    /// cannot lock out unrelated programs that ignore NSFileCoordinator.
    func apply() throws -> String {
        try Task.checkCancellation()
        var coordinationError: NSError?
        var outcome: Result<String, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: snapshot.url, options: .forReplacing, error: &coordinationError) { url in
            outcome = Result {
                try Task.checkCancellation()
                let current = try Snapshot.read(at: url)
                guard current.resolvedURL == snapshot.resolvedURL, current.data == snapshot.data else {
                    throw ChangeError.stale
                }
                if isNoOp { return "No changes needed; the file is unchanged." }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Task.checkCancellation()
                try replacement.write(to: url, options: .atomic)
                return summary
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw ChangeError.stale }
        return try outcome.get()
    }
}
