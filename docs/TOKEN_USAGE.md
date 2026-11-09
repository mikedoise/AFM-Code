# Local token usage

Settings opens with a Usage section showing recorded total, input and output tokens and a row for each model. Counters are local to this Mac and survive app restarts, model removal, chat deletion and regeneration. The tracking start date is explicit; old messages are not backfilled because their historical counts do not reliably distinguish input, output, tool rounds or model identity.

## Accounting

- Capture `LanguageModelSession.usage` immediately before a request and after successful completion. Add the input/output delta once, keyed to the model that actually received the request.
- The current Foundation Models SDK reports only the final tool-loop step in `response.usage`; session usage includes all steps. The deterministic framework test covers this distinction and repeated turns.
- Include normal replies, regenerations and automatic context summaries. Input includes the conversation and instructions processed again on each generation. Cached input and reasoning output are already part of their respective totals, not extra additions.
- Do not sum streaming snapshots, guess tokens from characters, or use the current context gauge as lifetime usage.
- Failed, cancelled, interrupted and zero-report requests appear as unreported and contribute no fabricated token count. Prewarming is excluded. Totals are recorded usage, not a complete measure of every attempted inference.
- Each backend supplies its own actual tokenizer/runtime counters through the Foundation Models adapter. Automated tests verify orchestration with a synthetic executor; they do not assert fresh live-model inference on every backend.

## Storage and privacy

`TokenUsageStore` keeps an atomic, versioned `token-usage-v1.json` beside the existing app data selected by `DesktopStorage`. It stores aggregate counters, model identity, tracking date and in-flight accounting IDs only. It does not store prompts, replies, tool arguments, paths, secrets or chat/session IDs. There is no upload or telemetry.

A request is registered before inference and settled once. Duplicate completion is ignored. After an interrupted process, pending requests become unreported. A corrupt, unreadable or newer-version file is preserved and tracking pauses with a visible error. Write failures leave the current counters in memory with a visible warning and retry on the next update. No SwiftData schema migration or historical data mutation is involved.

## Verification

Run `python3 scripts/test-token-usage.py`. It compiles production storage code and exercises temporary files only: multiple model IDs, overlapping requests, regeneration, summaries, duplicate callbacks, failures, empty/invalid/overflowed counters, restart/crash recovery, read/write errors, future format preservation, and real Foundation Models tool-loop aggregation with synthetic output. No weights are loaded and no user chats or production preferences are opened.

Build the app with `xcodebuild -project 'AFM Code.xcodeproj' -scheme 'AFM Code' -configuration Debug -destination 'platform=macOS' -jobs 2 -disableAutomaticPackageResolution build`.
