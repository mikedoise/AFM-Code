//
//  StreamingMarkdownDocument.swift
//  AFM Code
//
//  Ported from Perspective Intelligence.
//
//  Incremental presentation state for append-only streaming Markdown.
//  Completed source ranges are parsed once and retain stable identity while
//  only the unfinished tail continues to change.
//
//  Streaming boundary behavior is adapted from Nativ's MIT-licensed
//  MarkdownFormatting.swift. See ThirdPartyNotices/Nativ-MarkdownFormatting.LICENSE.
//

import Foundation
import SwiftUI

nonisolated struct StreamingMarkdownDocument: Equatable, Sendable {
    struct Chunk: Identifiable, Equatable, Sendable {
        struct ID: Hashable, Sendable {
            let lowerBoundCharacterOffset: Int
            let upperBoundCharacterOffset: Int
        }

        let id: ID
        let markdown: String
        let blocks: [MarkdownBlock]
    }

    static let defaultChunkTargetLength = 1_200

    private(set) var completedChunks: [Chunk] = []
    private(set) var tail = ""

    private var source = ""
    private var completedCharacterCount = 0
    private let minimumChunkLength: Int

    init(
        markdown: String,
        minimumChunkLength: Int = defaultChunkTargetLength
    ) {
        self.minimumChunkLength = max(1, minimumChunkLength)
        replace(with: markdown)
    }

    /// Incorporates an updated streaming snapshot. The usual append-only path
    /// scans just the mutable tail. If a backend revises earlier text, the
    /// document safely rebuilds from that replacement instead.
    mutating func update(markdown: String) {
        guard markdown != source else { return }

        guard markdown.hasPrefix(source) else {
            replace(with: markdown)
            return
        }

        let appendedText = markdown.dropFirst(source.count)
        source = markdown
        tail.append(contentsOf: appendedText)
        promoteStableChunks()
    }

    var reconstructedMarkdown: String {
        completedChunks.lazy.map(\.markdown).joined() + tail
    }

    private mutating func replace(with markdown: String) {
        source = markdown
        completedChunks = []
        completedCharacterCount = 0
        tail = markdown
        promoteStableChunks()
    }

    private mutating func promoteStableChunks() {
        let boundaries = StreamingMarkdownBoundaryScanner.stableBoundaries(in: tail)
        var chunkStart = tail.startIndex

        for boundary in boundaries {
            guard tail.distance(from: chunkStart, to: boundary) >= minimumChunkLength else {
                continue
            }

            let chunkMarkdown = String(tail[chunkStart..<boundary])
            let lowerBound = completedCharacterCount
            completedCharacterCount += chunkMarkdown.count
            completedChunks.append(
                Chunk(
                    id: .init(
                        lowerBoundCharacterOffset: lowerBound,
                        upperBoundCharacterOffset: completedCharacterCount
                    ),
                    markdown: chunkMarkdown,
                    blocks: MarkdownBlockParser.parse(chunkMarkdown)
                )
            )
            chunkStart = boundary
        }

        guard chunkStart != tail.startIndex else { return }
        tail = String(tail[chunkStart...])
    }
}

/// Locates boundaries that cannot be changed by later append-only content.
/// A blank line is not committed until the next top-level block has started,
/// and open containers remain together until they are known to be complete.
private nonisolated enum StreamingMarkdownBoundaryScanner {
    private struct Line {
        let startIndex: String.Index
        let content: Substring
    }

    private struct CodeFence {
        let marker: Character
        let length: Int
    }

    private enum Container {
        case list(indentation: Int)
        case blockQuote
        case indentedCode
        case other
    }

    private enum MathBlock {
        case dollars
        case brackets
    }

    static func stableBoundaries(in markdown: String) -> [String.Index] {
        var activeFence: CodeFence?
        var activeMathBlock: MathBlock?
        var pendingBlankLine = false
        var precedingContainer = Container.other
        var boundaries: [String.Index] = []

        for line in lines(in: markdown) {
            let content = String(line.content)
            let trimmed = content.trimmingCharacters(in: .whitespaces)

            if let fence = activeFence {
                if isClosingFence(content, for: fence) {
                    activeFence = nil
                    precedingContainer = .other
                }
                continue
            }

            if let mathBlock = activeMathBlock {
                if closes(mathBlock, with: trimmed) {
                    activeMathBlock = nil
                    precedingContainer = .other
                }
                continue
            }

            if trimmed.isEmpty {
                pendingBlankLine = true
                continue
            }

            if pendingBlankLine {
                if !continues(precedingContainer, with: content) {
                    boundaries.append(line.startIndex)
                }
                pendingBlankLine = false
            }

            if let fence = codeFence(in: content) {
                activeFence = fence
                precedingContainer = .other
            } else if let mathBlock = openingMathBlock(in: trimmed) {
                activeMathBlock = mathBlock
                precedingContainer = .other
            } else {
                precedingContainer = container(for: content, continuing: precedingContainer)
            }
        }

        return boundaries
    }

    private static func lines(in markdown: String) -> [Line] {
        var result: [Line] = []
        var lineStart = markdown.startIndex

        while lineStart < markdown.endIndex {
            let newline = markdown[lineStart...].firstIndex(of: "\n")
            let contentEnd = newline ?? markdown.endIndex
            let lineEnd = newline.map { markdown.index(after: $0) } ?? markdown.endIndex
            result.append(
                Line(
                    startIndex: lineStart,
                    content: markdown[lineStart..<contentEnd]
                )
            )
            lineStart = lineEnd
        }

        return result
    }

    private static func container(
        for line: String,
        continuing previous: Container
    ) -> Container {
        if isBlockQuoteLine(line) {
            return .blockQuote
        }
        if let indentation = listMarkerIndentation(in: line) {
            return .list(indentation: indentation)
        }

        let indentation = leadingSpaceCount(in: line)
        switch previous {
        case .list(let listIndentation):
            if indentation > listIndentation || !startsNewTopLevelBlock(line) {
                return previous
            }
        case .blockQuote:
            if !startsNewTopLevelBlock(line) {
                return previous
            }
        case .indentedCode:
            if indentation >= 4 {
                return previous
            }
        case .other:
            break
        }

        return indentation >= 4 ? .indentedCode : .other
    }

    private static func continues(_ container: Container, with line: String) -> Bool {
        switch container {
        case .list(let indentation):
            return listMarkerIndentation(in: line) != nil
                || leadingSpaceCount(in: line) > indentation
        case .blockQuote:
            return isBlockQuoteLine(line)
        case .indentedCode:
            return leadingSpaceCount(in: line) >= 4
        case .other:
            return false
        }
    }

    private static func startsNewTopLevelBlock(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first else { return false }
        return first == "#" || first == ">" || codeFence(in: line) != nil
    }

    private static func listMarkerIndentation(in line: String) -> Int? {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }
        guard indentation <= 3, index < line.endIndex else { return nil }

        if line[index] == "-" || line[index] == "+" || line[index] == "*" {
            let next = line.index(after: index)
            guard next < line.endIndex, line[next].isWhitespace else { return nil }
            return indentation
        }

        var digitCount = 0
        while index < line.endIndex, line[index].isNumber, digitCount < 10 {
            digitCount += 1
            index = line.index(after: index)
        }
        guard (1...9).contains(digitCount),
              index < line.endIndex,
              line[index] == "." || line[index] == ")"
        else {
            return nil
        }

        index = line.index(after: index)
        guard index < line.endIndex, line[index].isWhitespace else { return nil }
        return indentation
    }

    private static func isBlockQuoteLine(_ line: String) -> Bool {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }
        return indentation <= 3 && index < line.endIndex && line[index] == ">"
    }

    private static func leadingSpaceCount(in line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func openingMathBlock(in trimmedLine: String) -> MathBlock? {
        if trimmedLine.hasPrefix("\\[") && !trimmedLine.dropFirst(2).contains("\\]") {
            return .brackets
        }
        if trimmedLine.hasPrefix("$$") && !trimmedLine.dropFirst(2).contains("$$") {
            return .dollars
        }
        return nil
    }

    private static func closes(_ block: MathBlock, with trimmedLine: String) -> Bool {
        switch block {
        case .dollars:
            return trimmedLine.contains("$$")
        case .brackets:
            return trimmedLine.contains("\\]")
        }
    }

    private static func codeFence(in line: String) -> CodeFence? {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }

        guard indentation <= 3,
              index < line.endIndex,
              line[index] == "`" || line[index] == "~"
        else {
            return nil
        }

        let marker = line[index]
        let length = markerRunLength(in: line, from: index, marker: marker)
        guard length >= 3 else { return nil }
        return CodeFence(marker: marker, length: length)
    }

    private static func isClosingFence(_ line: String, for fence: CodeFence) -> Bool {
        guard let candidate = codeFence(in: line),
              candidate.marker == fence.marker,
              candidate.length >= fence.length
        else {
            return false
        }

        var index = line.startIndex
        while index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
        }
        for _ in 0..<candidate.length {
            index = line.index(after: index)
        }
        return line[index...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func markerRunLength(
        in line: String,
        from startIndex: String.Index,
        marker: Character
    ) -> Int {
        var index = startIndex
        var length = 0
        while index < line.endIndex, line[index] == marker {
            length += 1
            index = line.index(after: index)
        }
        return length
    }
}

/// Renders immutable completed chunks without reparsing them as the response
/// grows, while the current tail keeps Perspective's full structured styling
/// and streaming reveal behavior.
struct StreamingStructuredMarkdownView: View {
    let content: String
    let textColor: Color
    let isFromUser: Bool
    let expandsToFillWidth: Bool
    let usesModelGradient: Bool

    @State private var document: StreamingMarkdownDocument

    init(content: String, textColor: Color, isFromUser: Bool, expandsToFillWidth: Bool = true, usesModelGradient: Bool = false) {
        self.content = content
        self.textColor = textColor
        self.isFromUser = isFromUser
        self.expandsToFillWidth = expandsToFillWidth
        self.usesModelGradient = usesModelGradient
        _document = State(initialValue: StreamingMarkdownDocument(markdown: content))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(document.completedChunks) { chunk in
                StructuredMarkdownView(
                    preparedBlocks: chunk.blocks,
                    textColor: textColor,
                    isFromUser: isFromUser,
                    usesLazyLayout: false,
                    expandsToFillWidth: expandsToFillWidth,
                    usesModelGradient: usesModelGradient
                )
                .equatable()
            }

            if !document.tail.isEmpty {
                StructuredMarkdownView(
                    content: document.tail,
                    textColor: textColor,
                    isFromUser: isFromUser,
                    isStreaming: true,
                    expandsToFillWidth: expandsToFillWidth,
                    usesModelGradient: usesModelGradient
                )
                .equatable()
            }
        }
        .frame(maxWidth: expandsToFillWidth ? .infinity : nil, alignment: .leading)
        .onChange(of: content) { _, newContent in
            document.update(markdown: newContent)
        }
    }
}
