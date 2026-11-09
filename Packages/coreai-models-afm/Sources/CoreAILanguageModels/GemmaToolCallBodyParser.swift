// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation

/// The grammar emitted by Google's Gemma 4 canonical chat template's
/// `format_argument` and `tool_calls` branch. Reference: google/gemma-4-E2B-it,
/// chat_template.jinja, revision 3e22461f65e89153144f8adb70e3b8c2cc9845a7.
/// Strings are raw text between `<|"|>` tokens: quotes, backslashes and
/// newlines are NOT JSON escapes. Only the resulting JSON is escaped.
/// Parse a complete block atomically; never execute a repaired/partial call.
struct GemmaToolCallBodyParser {
    private var remaining: Substring
    private let quote = "<|\"|>"

    init(_ content: String) { remaining = content[...] }

    mutating func parse() -> (name: String, arguments: String)? {
        skipWhitespace()
        guard take("call:"), let brace = remaining.firstIndex(of: "{") else { return nil }
        let name = remaining[..<brace].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
            name.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) })
        else { return nil }
        remaining = remaining[brace...]
        guard let arguments = object(depth: 0) else { return nil }
        skipWhitespace()
        guard remaining.isEmpty else { return nil }
        return (name, arguments)
    }

    private mutating func skipWhitespace() {
        while remaining.first?.isWhitespace == true { remaining.removeFirst() }
    }

    private mutating func take(_ token: String) -> Bool {
        guard remaining.hasPrefix(token) else { return false }
        remaining = remaining.dropFirst(token.count)
        return true
    }

    private func jsonString(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
            let result = String(data: data, encoding: .utf8)
        else { return nil }
        return result
    }

    private mutating func string() -> String? {
        guard take(quote), let end = remaining.range(of: quote) else { return nil }
        let value = String(remaining[..<end.lowerBound])
        remaining = remaining[end.upperBound...]
        return value
    }

    private mutating func object(depth: Int) -> String? {
        guard depth < 128, take("{") else { return nil }
        skipWhitespace()
        if take("}") { return "{}" }
        var fields: [String] = []
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let key: String
            if remaining.hasPrefix(quote) {
                guard let parsed = string() else { return nil }
                key = parsed
            } else {
                // The canonical call template emits bare keys, including nested
                // mapping keys. Structural punctuation cannot be a bare key.
                let raw = remaining.prefix { !":{},[]<>".contains($0) }
                key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                remaining = remaining.dropFirst(raw.count)
            }
            skipWhitespace()
            guard keys.insert(key).inserted, take(":"), let encodedKey = jsonString(key),
                let value = value(depth: depth + 1)
            else { return nil }
            fields.append(encodedKey + ":" + value)
            skipWhitespace()
            if take("}") { return "{" + fields.joined(separator: ",") + "}" }
            guard take(",") else { return nil }
        }
    }

    private mutating func value(depth: Int) -> String? {
        guard depth < 128 else { return nil }
        skipWhitespace()
        if remaining.hasPrefix(quote) {
            guard let raw = string() else { return nil }
            return jsonString(raw)
        }
        if remaining.hasPrefix("{") { return object(depth: depth) }
        if take("[") {
            skipWhitespace()
            if take("]") { return "[]" }
            var values: [String] = []
            while true {
                guard let item = value(depth: depth + 1) else { return nil }
                values.append(item)
                skipWhitespace()
                if take("]") { return "[" + values.joined(separator: ",") + "]" }
                guard take(",") else { return nil }
            }
        }
        let raw = remaining.prefix { !$0.isWhitespace && !",]}".contains($0) }
        guard !raw.isEmpty else { return nil }
        let scalar = String(raw)
        if scalar != "true" && scalar != "false" && scalar != "null" {
            // JSON validates the numeric grammar, but preserve its spelling so
            // large integers do not round-trip through Double.
            guard scalar.first.map({ $0 == "-" || $0.isNumber }) == true,
                let data = scalar.data(using: .utf8),
                let number = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? NSNumber,
                number.doubleValue.isFinite
            else { return nil }
        }
        remaining = remaining.dropFirst(raw.count)
        return scalar
    }
}
