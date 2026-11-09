// AFM Code adaptation of the Apple Core AI stream routing.
// See the BSD-3-Clause license in the package root.

/// Shared, testable text/tool/reasoning routing used by the native executor.
/// Gemma strings contain literal special-token spellings and must reach its
/// tool parser untouched. Native Gemma reasoning channels are not supported.
struct LanguageModelOutputParser {
    enum Event {
        case tool(ToolCallParser.Event)
        case reasoning(String)
    }

    private var thinkParser: ThinkTagParser
    private var toolParser: ToolCallParser?
    private let parseReasoning: Bool

    init(thinkingFormat: ThinkTagParser.Format, supportsReasoning: Bool,
         toolCallDetection: ToolCallDetection?) {
        thinkParser = ThinkTagParser(format: thinkingFormat)
        parseReasoning = supportsReasoning && toolCallDetection?.format != .gemma
        toolParser = toolCallDetection.map {
            ToolCallParser(openMarker: $0.openMarker, closeMarker: $0.closeMarker, format: $0.format)
        }
    }

    var isInsideGemmaString: Bool { toolParser?.isInsideGemmaString == true }

    /// The executor tests the next generated token before decoding it.
    func shouldStop(token: Int32, stopTokens: Set<Int32>) -> Bool {
        stopTokens.contains(token) && !isInsideGemmaString
    }

    mutating func consume(_ delta: String) -> [Event] {
        if parseReasoning { return route(thinkParser.consume(delta)) }
        return route([.text(delta)])
    }

    mutating func flush() -> [Event] {
        var events = parseReasoning ? route(thinkParser.flush()) : []
        if var parser = toolParser {
            events += parser.flush().map(Event.tool)
            toolParser = parser
        }
        return events
    }

    private mutating func route(_ events: [ThinkTagParser.Event]) -> [Event] {
        var output: [Event] = []
        for event in events {
            switch event {
            case .reasoning(let text): output.append(.reasoning(text))
            case .text(let text):
                if var parser = toolParser {
                    output += parser.consume(text).map(Event.tool)
                    toolParser = parser
                } else if !text.isEmpty {
                    output.append(.tool(.text(text)))
                }
            }
        }
        return output
    }
}
