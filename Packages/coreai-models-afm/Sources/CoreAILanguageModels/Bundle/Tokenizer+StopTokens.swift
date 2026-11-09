// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Tokenizers

extension Tokenizer {
    /// Whether `token` is a genuine entry in the vocabulary, not an unk-token fallback.
    func vocabContains(_ token: String) -> Bool {
        guard let id = convertTokenToId(token) else { return false }
        return convertIdToToken(id) == token
    }

    /// Token IDs that terminate generation: the tokenizer's main EOS (when
    /// present), a base-vocab `<|im_end|>` (when present), and the load-time
    /// `additional` IDs resolved by `LanguageConfig.additionalStopTokenIds`,
    /// plus Gemma 4 turn/handoff markers when its tool dialect is present.
    ///
    /// Both the text and VLM adapters check each generated token against this set.
    /// The `<|im_end|>` fold lives here so it applies whether or not the bundle
    /// ships a tokenizer directory.
    func runtimeStopTokens(additional: Set<Int32>) -> Set<Int32> {
        var stop = additional
        if let eos = eosTokenId { stop.insert(Int32(eos)) }
        if vocabContains("<|im_end|>"), let id = convertTokenToId("<|im_end|>") {
            stop.insert(Int32(id))
        }
        // Gemma 4 hands control back to the caller at <|tool_response>.
        // Do not emit that token as assistant text: it would insert a response
        // between the tool call and output, hiding the output from the template.
        // These markers are not covered by the older end_of_turn patterns, and
        // exported bundles need not retain generation_config.json.
        if vocabContains("<|tool_call>"), vocabContains("<tool_call|>") {
            for token in ["<|tool_response>", "<turn|>"] {
                if vocabContains(token), let id = convertTokenToId(token) {
                    stop.insert(Int32(id))
                }
            }
        }
        return stop
    }
}
