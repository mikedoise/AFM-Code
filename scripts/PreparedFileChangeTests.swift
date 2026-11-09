import Foundation

@main struct PreparedFileChangeTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func rejected(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected rejection: \(label)") }
        catch { print("PASS reject \(label): \(error.localizedDescription)") }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("afm-change-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.txt")
        let original = (0..<6000).map { "line \($0)" }.joined(separator: "\n")
        try Data(original.utf8).write(to: file)
        let snapshot = try PreparedFileChange.Snapshot.read(at: file)
        let late = try PreparedFileChange.edit(snapshot: snapshot, path: "long.txt", find: "line 5500", replace: "late approved change", replaceAll: false)
        expect(late.diff.additions == 1 && late.diff.removals == 1, "Late change must be exact, not whole-file replacement")
        expect(late.diff.lines.contains { $0.kind == .addition && $0.text == "late approved change" }, "Missing late addition")
        expect(!late.diff.truncated, "Complete approval diff was truncated")
        _ = try late.apply()
        expect(tryData(file) == late.replacement, "Applied bytes differ from approved bytes")
        print("PASS edit after line 4000, complete diff, exact approved output")

        let duplicateText = original.replacingOccurrences(of: "line 100\n", with: "duplicate\n").replacingOccurrences(of: "line 5500\n", with: "duplicate\n")
        try Data(duplicateText.utf8).write(to: file)
        let duplicates = try PreparedFileChange.Snapshot.read(at: file)
        rejected("duplicate crossing 4000-line boundary") { _ = try PreparedFileChange.edit(snapshot: duplicates, path: "long.txt", find: "duplicate", replace: "changed", replaceAll: false) }
        let all = try PreparedFileChange.edit(snapshot: duplicates, path: "long.txt", find: "duplicate", replace: "changed", replaceAll: true)
        expect(all.diff.lines.filter { $0.kind == .addition && $0.text == "changed" }.count == 2, "Both replacements must be visible")
        _ = try all.apply()
        expect(tryData(file) == all.replacement, "replaceAll output mismatch")
        print("PASS explicit replaceAll includes every occurrence")

        let current = try PreparedFileChange.Snapshot.read(at: file)
        let stale = try PreparedFileChange.edit(snapshot: current, path: "long.txt", find: "line 5900", replace: "approved", replaceAll: false)
        let external = Data("\(String(data: current.data!, encoding: .utf8)!)\nexternal edit".utf8)
        try external.write(to: file)
        rejected("file changed after preview") { _ = try stale.apply() }
        expect(tryData(file) == external, "Stale approval overwrote external edit")

        let noOpSnapshot = try PreparedFileChange.Snapshot.read(at: file)
        let noop = try PreparedFileChange.edit(snapshot: noOpSnapshot, path: "long.txt", find: "line 5900", replace: "line 5900", replaceAll: false)
        let modification = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        expect(noop.isNoOp && noop.diff.additions == 0 && noop.diff.removals == 0, "No-op must not show changes")
        _ = try noop.apply()
        expect(tryData(file) == external, "No-op changed bytes")
        let afterModification = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        expect(afterModification == modification, "No-op rewrote the file")
        print("PASS no-op leaves bytes and modification time intact")
        rejected("empty search") { _ = try PreparedFileChange.edit(snapshot: noOpSnapshot, path: "long.txt", find: "", replace: "x", replaceAll: false) }
        rejected("missing match") { _ = try PreparedFileChange.edit(snapshot: noOpSnapshot, path: "long.txt", find: "absent target", replace: "x", replaceAll: false) }

        let full = try PreparedFileChange.write(snapshot: noOpSnapshot, path: "long.txt", content: original.replacingOccurrences(of: "line 5999", with: "last-line write"))
        expect(full.diff.lines.contains { $0.kind == .addition && $0.text == "last-line write" }, "Write preview omitted tail")
        _ = try full.apply()
        expect(tryData(file) == full.replacement, "Full write mismatch")
        print("PASS full-file write reviews tail")

        let wide = try PreparedFileChange.write(snapshot: try PreparedFileChange.Snapshot.read(at: file), path: "long.txt", content: (0..<6000).map { "replacement \($0)" }.joined(separator: "\n"))
        expect(wide.diff.additions == 6000 && wide.diff.removals == 6000 && !wide.diff.truncated, "Wide diff must include all changed lines")
        expect(wide.diff.lines.last?.text == "replacement 5999", "Wide diff missing last change")
        print("PASS complete 12000-row diff with bounded comparison work")

        let newURL = root.appendingPathComponent("nested/new.txt")
        let absent = try PreparedFileChange.Snapshot.read(at: newURL)
        rejected("editing nonexistent file") { _ = try PreparedFileChange.edit(snapshot: absent, path: "new.txt", find: "x", replace: "y", replaceAll: false) }
        let creation = try PreparedFileChange.write(snapshot: absent, path: "new.txt", content: "new file")
        _ = try creation.apply()
        expect(creation.diff.isNewFile && tryData(newURL) == creation.replacement, "New-file creation mismatch")
        print("PASS create nested file")
        let missingURL = root.appendingPathComponent("appeared.txt")
        let proposed = try PreparedFileChange.write(snapshot: try PreparedFileChange.Snapshot.read(at: missingURL), path: "appeared.txt", content: "approved")
        try Data("other creator".utf8).write(to: missingURL)
        rejected("new file appeared while awaiting approval") { _ = try proposed.apply() }
        expect(tryData(missingURL) == Data("other creator".utf8), "Overwrote independently created file")
        try FileManager.default.removeItem(at: file)
        rejected("file removed after preview") { _ = try wide.apply() }
        expect(!FileManager.default.fileExists(atPath: file.path), "Recreated deleted file")

        let invalid = root.appendingPathComponent("invalid.txt")
        try Data([0xff, 0xfe]).write(to: invalid)
        rejected("non-UTF8 file") { _ = try PreparedFileChange.Snapshot.read(at: invalid) }
        let capped = root.appendingPathComponent("limit.txt")
        try Data(repeating: 10, count: PreparedFileChange.maximumFileLines).write(to: capped)
        rejected("line-limit overflow instead of partial review") { _ = try PreparedFileChange.Snapshot.read(at: capped) }
        rejected("output byte-limit overflow") { _ = try PreparedFileChange.write(snapshot: absent, path: "large.txt", content: String(repeating: "x", count: PreparedFileChange.maximumFileBytes + 1)) }

        let crlf = root.appendingPathComponent("crlf.txt")
        try Data("first\r\nlast".utf8).write(to: crlf)
        let lineEndings = try PreparedFileChange.edit(snapshot: try PreparedFileChange.Snapshot.read(at: crlf), path: "crlf.txt", find: "last", replace: "updated", replaceAll: false)
        _ = try lineEndings.apply()
        expect(tryData(crlf) == Data("first\r\nupdated".utf8), "Line endings or final newline changed")
        print("PASS preserves CRLF and no trailing newline")
        let unicode = root.appendingPathComponent("unicode.txt")
        try Data("\u{00e9}".utf8).write(to: unicode)
        let normalization = try PreparedFileChange.write(snapshot: try PreparedFileChange.Snapshot.read(at: unicode), path: "unicode.txt", content: "e\u{0301}")
        expect(!normalization.isNoOp && normalization.diff.additions == 1 && normalization.diff.removals == 1, "Unicode normalization must not be hidden as unchanged")
        _ = try normalization.apply()
        expect(tryData(unicode) == Data("e\u{0301}".utf8), "Unicode output mismatch")
        print("PASS byte-distinct Unicode normalization appears in diff")
        let bom = root.appendingPathComponent("bom.txt")
        let bomData = Data([0xef, 0xbb, 0xbf]) + Data("first\nlast".utf8)
        try bomData.write(to: bom)
        let bomChange = try PreparedFileChange.edit(snapshot: try PreparedFileChange.Snapshot.read(at: bom), path: "bom.txt", find: "last", replace: "updated", replaceAll: false)
        _ = try bomChange.apply()
        expect(tryData(bom) == Data([0xef, 0xbb, 0xbf]) + Data("first\nupdated".utf8), "UTF-8 BOM changed implicitly")
        print("PASS UTF-8 BOM preserved during targeted edit")
        rejected("reusing an already-applied proposal") { _ = try bomChange.apply() }
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bom)
        rejected("symbolic-link file") { _ = try PreparedFileChange.Snapshot.read(at: link) }
        rejected("directory as file") { _ = try PreparedFileChange.Snapshot.read(at: root) }
        let cancelledProposal = try PreparedFileChange.write(snapshot: try PreparedFileChange.Snapshot.read(at: crlf), path: "crlf.txt", content: "must not be written")
        let cancelled = Task {
            try? await Task.sleep(for: .seconds(60))
            return try cancelledProposal.apply()
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled change was applied") }
        catch is CancellationError { }
        expect(tryData(crlf) == Data("first\r\nupdated".utf8), "Cancellation wrote file contents")
        print("PASS cancelled proposal cannot write")
        print("ALL PREPARED CHANGE TESTS PASSED")
    }
    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }
}
