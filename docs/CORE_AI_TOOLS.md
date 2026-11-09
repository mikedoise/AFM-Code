# Gemma tool calling in AFM Code

## What changed

The initial Apple adapter snapshot did not recognize Gemma 4's tool dialect, so AFM correctly withheld coding/MCP tools. AFM's own `CoreAILM` package now contains the isolated Gemma parser fix, with these additional protections:

- Recognizes `<|tool_call>call:NAME{...}<tool_call|>` and converts complete arguments to JSON. It never repairs or executes partial/malformed calls.
- Preserves raw strings, nested values, special-token spellings, source code and large integer spelling. Duplicate keys, invalid numbers, trailing garbage and excessive nesting are rejected.
- Stops generation at Gemma's tool-result handoff so Foundation Models can call the tool and feed its result back into the next prompt.
- Generic `<think>` tags inside file contents are not interpreted as reasoning. Native Gemma reasoning channels are not supported or advertised.
- Advertises tool capability from the actual tokenizer rather than hard-coding model names. Both existing 4K/128K exports report tool calling true, reasoning false.
- Uses AFM's existing coding/MCP registration and project approval gates. No automatic approval was enabled. Unknown tools and invalid typed arguments do not invoke callbacks.
- Keeps the prior residency/prewarm, offline tokenizer, bookmark-based resource access and context-budget protections.

Only the app-local package was changed. Shared Core AI checkouts, model bundles, dependencies and user data remain intact. License and provenance are in `Packages/coreai-models-afm/UPSTREAM.md`.

## Safety fixes while enabling tools

Production tool checks now reject symlinks escaping the selected project, avoid recursive directory-link traversal, and safely handle out-of-range or extreme line numbers. Command approval matching preserves internal whitespace, so quoted tabs cannot match quoted spaces. Existing approval entries are preserved exactly as stored; older normalization already lost any original whitespace, which cannot be recovered. A cancelled caller cannot use an approval fast path.

Write/edit tools still build immutable diffs, wait for the existing approval decision, and reject a stale proposal if the file changes before approval. Default projects ask first. New desktop grants can explicitly enable Auto-approve or exact command/MCP allowances. Sandbox-era automatic grants are archived but inactive after the separately confirmed desktop transition; previously enabled MCP servers are paused for review. See DESKTOP_ACCESS.md.

## Ready-to-test steps

1. Restart the newly built AFM Code scheme from Xcode when convenient. The running app was not stopped or controlled by this work.
2. Open a **project conversation** with a valid project folder, then select the imported Gemma export. No re-export or reimport is needed.
3. After preparation, the model picker shows `tools`; the model library explains that project approval settings apply.
4. For a safe check, use a disposable project and ask it to list the folder or read a small test file.
5. With project approvals set to **Always ask**, ask it to create a small test file. Review the proposed content; denying must leave the file absent, and approving must write exactly the reviewed content.

Use a fresh conversation if the old text-only conversation contains refusals or misleading history. The adapter itself rebuilds tool definitions on the next turn. The 4K export leaves little room for instructions, seven coding schemas, MCP schemas, project context and history; token admission still rejects overflow. A 128K bundle does not guarantee reliable tool choice or correct code.

## Verification

Final signed Debug build passed (`/tmp/afm-coreai-tools-final-build.log`). Residency, temporary SwiftData migration, bundle-import, command/accessibility-source and prepared-file-change regressions also passed.

Passed against the exact Debug Xcode adapter objects:

- Production output pipeline at every character split, including literal/unclosed reasoning tags, Unicode, closing delimiters and EOS/handoff spellings in raw arguments.
- Malformed, incomplete, duplicate-key and overnested calls; recovery to a later valid call; nested values and unchanged integer spelling.
- Tokenizer/capability checks for both real Gemma exports without model inference, including actual handoff/turn token IDs through the executor's shared stop gate.
- Real Foundation Models tool dispatcher with scripted production-parser output: callback receives unchanged arguments, result continuation is retained, and unknown/missing/wrongly typed calls invoke no callback.
- Production ToolContext, ToolApprovalService, WriteFileTool and EditFileTool with a temporary fixture: real writes occur only after simulated approval; denial/cancellation preserve bytes; stale previews fail. No user folder or database is opened.

The isolated source patch previously passed a live Gemma callback/continuation test. **New live 4K/128K model tool tests in AFM's updated adapter are held until a clean user-testing/resource window is confirmed.** No new native tool write, command or MCP operation was run, and the GUI was not automated. Passing parser/dispatch tests is not a claim of model tool-use reliability.

## Reproduce

Use the AFM Code Debug DerivedData directory as `$DD`:

```sh
python3 scripts/build-coreai-smoke.py "$DD" /tmp/afm-coreai-tool-parser-tests scripts/CoreAIToolParserTests.swift
/tmp/afm-coreai-tool-parser-tests /path/to/ctx4096-export /path/to/ctx131072-export
python3 scripts/build-coreai-smoke.py "$DD" /tmp/afm-coreai-tool-session-tests scripts/CoreAIToolSessionTests.swift
/tmp/afm-coreai-tool-session-tests
bash scripts/test-tool-safety.sh
python3 scripts/test-coreai-residency.py
python3 scripts/test-swiftdata-migration.py
sh scripts/test-coreai-bundles.sh
python3 scripts/audit-smoke.py
sh scripts/test-prepared-changes.sh
```

Opt-in native callback smoke, **only after other model work/user generation is idle**:

```sh
python3 scripts/build-coreai-smoke.py "$DD"
AFM_COREAI_TOOL_SMOKE=1 /tmp/afm-coreai-native-smoke /path/to/export
```

This native smoke loads real weights, checks a synthetic memory-only callback and verifies that the final response includes its receipt. It does not write files or launch commands/MCP. Run 4K and 128K sequentially; a short callback does not test full-context reliability or speed.

The subsequent Git/command investigation and related approval/process fixes are documented in `GIT_COMMANDS.md`. Those checks used disposable local Git fixtures, not live Gemma inference or user repositories.

## File-write diagnosis and quote preservation (2026-11-08)

File tools now create their activity step before validation and preview preparation. Missing project access, rejected paths, invalid files and unsuccessful edit searches therefore produce a visible failed step rather than only returning an error to the model. No-op writes/edits also produce a completed step. Cancellation remains terminal, and no mutation or approval request is made for failed preparation.

`dev.afmcode` / `FileChanges` diagnostics record generated step IDs, write/edit kind, lifecycle status, failure phase (`preparation` or `apply`) and fixed error categories/OS error codes. They do not log file paths, content, arguments, diffs or raw error descriptions. No global model verbosity was enabled. These diagnostics only begin after a typed file-tool callback is invoked; they do not identify a model's missing or malformed tool call.

The Python triple-quote report was checked with deterministic byte-level regressions. Gemma's canonical chat template wraps argument strings as raw text, not JSON-escaped source. The production parser correctly JSON-encodes that text once, and Foundation Models decodes it once before invoking the tool. File writing then preserves the decoded content bytes. Raw Python docstrings, Unicode, regex, literal backslashes, escaped string quotes and Windows paths all survive unchanged. Simulated model text containing extra backslashes before triple quotes also survives unchanged. A blanket unescape would corrupt legitimate source and was not added. These tests do not establish what the actual incident's model generated.

New complete-chain check, using adapter objects from an existing Debug build:

```sh
bash scripts/test-coreai-file-write-chain.sh "$DD"
```

This drives scripted Gemma output through the production parser, real Foundation Models typed argument dispatch, production WriteFileTool, immutable preview, ToolApprovalService, and temporary disk files. Four cases passed: canonical and already-escaped Python source, each approved and denied. Files do not exist before approval; denied writes create no file; approved bytes exactly equal the displayed proposal and scripted raw argument.

The expanded `test-tool-safety.sh` reproduces the former invisible preparation failure and now passes eight visible-failure cases, two visible no-ops, quote/backslash write/edit preservation, privacy-safe diagnostic categories and existing approval/cancellation/stale-preview checks. Prepared-change tests, source/command smoke checks and `git diff --check` passed. The changed tools also compiled and passed the fixture suite with Swift 5 and the app's MainActor/default isolation settings.

No live model generation, GUI automation or full app rebuild was performed for this follow-up while the user was testing. The running app was not restarted. Source changes take effect after the user's next rebuild/run. No user project contents, model exports, databases, approval preferences, commits or pushes were changed by these checks.
