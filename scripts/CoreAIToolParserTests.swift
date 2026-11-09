import Foundation
@testable import CoreAILanguageModels

@main struct CoreAIToolParserTests {
    static let detection = ToolCallDetection(openMarker: "<|tool_call>", closeMarker: "<tool_call|>", format: .gemma)
    static func parser() -> LanguageModelOutputParser {
        // Even a tokenizer that advertises generic think tokens must not
        // strip them from Gemma's raw tool arguments.
        LanguageModelOutputParser(thinkingFormat: .tagPair(open: "<think>", close: "</think>"),
                                  supportsReasoning: true, toolCallDetection: detection)
    }
    static func calls(_ events: [LanguageModelOutputParser.Event]) -> [(String, String)] {
        events.compactMap {
            if case .tool(.toolCall(_, let name, let json)) = $0 { return (name, json) }
            return nil
        }
    }
    static func arguments(_ call: (String, String)) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(call.1.utf8)) as! [String: Any]
    }
    static func text(_ events: [LanguageModelOutputParser.Event]) -> String {
        events.compactMap { if case .tool(.text(let text)) = $0 { return text }; return nil }.joined()
    }
    static func main() async throws {
        let raw = "a<think>b</think>c unclosed <think> quote: \" slash: \\n café 😀\n<tool_call|><|tool_response><turn|><eos>"
        let input = "before<|tool_call>call:write_file{path:<|\"|>fixture.txt<|\"|>,content:<|\"|>" + raw + "<|\"|>}<tool_call|><|tool_call>call:ping{}<tool_call|>after"
        let chars = Array(input)
        for split in 0...chars.count {
            var p = parser()
            let result = p.consume(String(chars[..<split])) + p.consume(String(chars[split...])) + p.flush()
            let found = calls(result)
            precondition(found.map { $0.0 } == ["write_file", "ping"])
            let args = try arguments(found[0])
            precondition(args["content"] as? String == raw, "Raw argument changed at split \(split)")
            precondition(text(result) == "beforeafter")
            precondition(!result.contains { if case .reasoning = $0 { return true }; return false })
        }
        var p = parser()
        var events: [LanguageModelOutputParser.Event] = []
        for char in chars { events += p.consume(String(char)) }
        events += p.flush()
        let charArgs = try arguments(calls(events)[0])
        precondition(charArgs["content"] as? String == raw)
        print("PASS production pipeline preserves raw arguments at every split and character, without reasoning leakage")

        var quoting = parser()
        _ = quoting.consume("<|tool_call>call:echo{text:<|\"|>")
        precondition(quoting.isInsideGemmaString)
        _ = quoting.consume("<|tool_response><turn|><eos>")
        precondition(quoting.isInsideGemmaString)
        _ = quoting.consume("<|\"|>")
        precondition(!quoting.isInsideGemmaString)
        precondition(calls(quoting.consume("}<tool_call|>")).count == 1)
        print("PASS EOS suppression is confined to an open raw Gemma string")

        let malformed = ["call:ping{", "call:ping{x:true,}", "call:ping{x:[1,]}",
            "call:ping{x:unknown}", "call:ping{x:NaN}", "call:ping{x:01}",
            "call:ping{x:1,x:2}", "call:ping{} garbage", "call:{}",
            "call:ping{x:<|\"|>unfinished}", "call:ping{x:{a:1}",
            "call:ping{x:\"not a Gemma string\"}", "call:ping{x:1e9999}",
            "call:ping{x:" + String(repeating: "[", count: 130) + "0" + String(repeating: "]", count: 130) + "}"]
        for body in malformed {
            var p = parser()
            precondition(calls(p.consume("<|tool_call>" + body + "<tool_call|>") + p.flush()).isEmpty, body)
        }
        var incomplete = parser()
        precondition(calls(incomplete.consume("<|tool_call>call:ping{}") + incomplete.flush()).isEmpty)
        var recovery = parser()
        precondition(calls(recovery.consume("<|tool_call>call:bad{x:unknown}<tool_call|><|tool_call>call:ping{}<tool_call|>")).map { $0.0 } == ["ping"])
        print("PASS malformed, truncated, duplicate-key and overnested blocks emit no call; subsequent valid block recovers")

        var nested = parser()
        let found = calls(nested.consume(#"<|tool_call>call:inspect{data:{items:[true,false,null,-12,1.25,1e-4,{}],<|"|>quoted key<|"|>:[]},n:9007199254740993}<tool_call|>"#))
        let args = try arguments(found[0])
        precondition(found[0].1.contains("9007199254740993"))
        let data = args["data"] as! [String: Any]
        let items = data["items"] as! [Any]
        precondition(items.count == 7 && items[2] is NSNull && items[3] as? Int == -12)
        print("PASS nested values, quoted keys and exact integer spelling")

        var json = LanguageModelOutputParser(thinkingFormat: .tagPair(open: "<think>", close: "</think>"), supportsReasoning: true,
            toolCallDetection: ToolCallDetection(openMarker: "<tool_call>", closeMarker: "</tool_call>", format: .json))
        let legacy = json.consume(#"<think>reason</think>visible<tool_call>{"name":"ping","arguments":{}}</tool_call>"#) + json.flush()
        precondition(calls(legacy).map { $0.0 } == ["ping"] && text(legacy) == "visible")
        precondition(legacy.contains { if case .reasoning("reason") = $0 { return true }; return false })
        var plain = LanguageModelOutputParser(thinkingFormat: .tagPair(open: "<think>", close: "</think>"), supportsReasoning: false, toolCallDetection: nil)
        precondition(text(plain.consume("literal <think>text") + plain.flush()) == "literal <think>text")
        print("PASS existing JSON/reasoning route and non-reasoning literal text")

        for path in CommandLine.arguments.dropFirst() {
            let bundle = try LanguageModelBundle(at: URL(fileURLWithPath: path))
            let tokenizer = try await bundle.loadTokenizer()
            precondition(detectToolCallFormat(using: tokenizer)?.format == .gemma)
            let stops = tokenizer.runtimeStopTokens(additional: [])
            for name in ["<|tool_response>", "<turn|>"] {
                precondition(stops.contains(Int32(tokenizer.convertTokenToId(name)!)))
            }
            for name in ["<|tool_call>", "<tool_call|>"] {
                precondition(!stops.contains(Int32(tokenizer.convertTokenToId(name)!)))
            }
            // Exercise the exact gate called by the executor using the real
            // export's special-token IDs before and after a Unicode raw string.
            let handoff = Int32(tokenizer.convertTokenToId("<|tool_response>")!)
            let turn = Int32(tokenizer.convertTokenToId("<turn|>")!)
            var gate = parser()
            precondition(gate.shouldStop(token: handoff, stopTokens: stops))
            _ = gate.consume("<|tool_call>call:echo{text:<|\"|>café 😀")
            precondition(!gate.shouldStop(token: handoff, stopTokens: stops))
            _ = gate.consume("<|tool_response>")
            precondition(!gate.shouldStop(token: turn, stopTokens: stops))
            _ = gate.consume("<turn|><|\"|>")
            precondition(gate.shouldStop(token: handoff, stopTokens: stops))
            _ = gate.consume("}<tool_call|>")
            precondition(gate.shouldStop(token: turn, stopTokens: stops))
            let model = try await CoreAILanguageModel(resourcesAt: URL(fileURLWithPath: path))
            precondition(model.capabilities.contains(.toolCalling) && !model.capabilities.contains(.reasoning))
            model.unload()
            print("PASS actual offline tokenizer/capabilities/handoff markers: \(bundle.name) (no inference)")
        }
    }
}
