# Apple Core AI language adapter for AFM Code

Source: https://github.com/apple/coreai-models, commit b712e4e96df6665f90a1f3cb49cc91d3660d43b9.
Copied from the local benchmark checkout on 2026-11-08. Includes only CoreAILanguageModels, CoreAIShared and the CXGrammar bridge, plus the original BSD-3-Clause license. No weights or benchmark edits are included.

The manifest exposes CoreAILM only and retains the upstream Transformers, Jinja and XGrammar dependencies. MLX uses its existing namespaced MLXCXGrammar, avoiding symbol collisions.

AFM patch: expose the adapter's own transcript tokenizer count and reject input plus requested output beyond bundle context before inference (including tool continuations). See CoreAILanguageModel.swift. Model weights and export metadata are unchanged.

AFM lifecycle patch: ModelResources.engine forwards caller cancellation to its captured load task and drains it before returning. AFM Code serializes Core AI loads/turns, retains one successful model and prewarms on conversation open. Native compiler work may remain briefly non-interruptible.

Gemma tool-calling patch (2026-11-08): selectively ported ToolCallParser, GemmaToolCallBodyParser and Tokenizer+StopTokens from the isolated `~/Developer/coreai-gemma-tools-20261107` checkout at the same upstream revision. That checkout's native synthetic callback/continuation test passed previously. Its LICENSE matches this package's BSD-3-Clause license byte-for-byte; no new dependency or weight is added. Local changes recognize Gemma 4 asymmetric tool markers, atomically parse its raw argument grammar, and stop at native handoff/turn boundaries except inside a raw argument.

AFM additionally routes the native executor through LanguageModelOutputParser, which preserves raw Gemma arguments containing generic reasoning tags. Native Gemma reasoning channels remain unsupported and are not advertised. Context admission, offline tokenizer requirements and cancellation draining are retained. Tool arguments are no longer written into adapter diagnostic logs. Foundation Models dispatches only registered, typed tools; AFM project approval settings remain the authority for side effects.
