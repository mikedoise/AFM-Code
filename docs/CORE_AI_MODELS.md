# Core AI models in AFM Code

## Try the exported Gemma model

1. Rebuild/run the **AFM Code** scheme in Xcode. Quit an older running copy first.
2. Open **Choose Model** from the chat title (Shift-Command-M).
3. Choose **Add Core AI Model…** and select the complete export folder:
   `~/Developer/coreai-gemma-benchmark-20261107/exports/gemma4-e2b-4bit-ctx131072`
4. The imported model is selected for that session. Send a short prompt first.

You can instead select its `.aimodel` package. AFM Code then asks for its containing export folder, so the complete metadata, tokenizer and sidecar layout is selected explicitly. Canceling either panel makes no library or selection change. Import failures are shown in the picker and model library.

The 4,096-token export can also be selected, but leaves substantially less room for coding instructions, tool schemas and conversation. Importing a model from Settings adds it to the library without changing the active session. Project defaults also include imported Core AI models.

## The file format

`.aimodel` is the correct model package suffix. Do not rename it to `.coreai`.
The Foundation Models adapter consumes the **export directory**, containing:

- outer `metadata.json` (version 0.2, `kind: llm`);
- the main `.aimodel` named in that metadata;
- the embedded `tokenizer` directory;
- all declared auxiliary files, including Gemma E2B's `_ple.safetensors` sidecar.

An arbitrary `.aimodel` is not necessarily a language model. This initial importer accepts compatible text-language bundles, not vision/diffusion exports. It validates the selected main package, required files, canonical Core AI asset format, and paths before adding the reference. Missing or changed exports fail visibly instead of silently switching to Apple Intelligence.

Models stay where selected. AFM Code persists folder bookmarks and continues to resolve legacy security-scoped bookmarks. Model resources are read, not modified. Removing a library entry does not delete any model files. Keep the whole export together; re-add it if its contents or permissions change.

## Integration

Apple's open-source **CoreAILM** product supplies `CoreAILanguageModels` and `CoreAILanguageModel(resourcesAt:)`, used through the existing Foundation Models `LanguageModelSession`. There is no separate SDK import called CoreAdapter in this implementation. The app-local source snapshot is documented in `Packages/coreai-models-afm/UPSTREAM.md`; it is the same upstream revision used by the Gemma benchmark. Existing MLX dependencies and resolved versions are retained, with XGrammar 0.2.2 added for the Core AI adapter.

- Capabilities come from the loaded adapter, not guessed from the extension.
- Core AI work is serialized across sessions. The read-only folder-access lease stays open for the resident model, including background load, generation and compaction, and closes when it is unloaded.
- One successfully used model stays resident between turns. Opening a conversation prepares it in the background; sending joins that work. Changing models/providers, removing/reimporting a model, errors/cancellation, or **Unload Model** release it. Closing a conversation cancels unfinished background preparation but keeps a completed resident model. First loading/compilation can still take time.
- **Cancel Loading** stops unused background preparation; **Stop** cancels a sent request. Cancellation drains before another model loads. Native compilation may take time to unwind; access remains open until it exits.
- Context counting uses the adapter's actual chat template/tokenizer. Input plus the requested output budget is checked before inference, including tool continuations. Small-window summaries are bounded using the same tokenizer.
- Switching the selected model rebuilds the cached session. An explicitly removed Core AI model is an error, not a fallback to another provider.
- Existing coding-tool approvals still apply. Capability detection does not establish Gemma's tool-use reliability.

## SwiftData picker crash fix

The reported `"MCPServer" is not a valid entity name` exception came from an omitted SwiftData entity: RootView and MCP settings already queried `MCPServer`, but the shared schema listed only four other entities. Returning from a picker can trigger a query/history refresh and expose that mismatch.

The shared schema now includes `MCPServer`, and both the main window and Settings receive the same container. This uses an additive migration at the existing database location. No store deletion, reset, replacement, or history purge is used.

`python3 scripts/test-swiftdata-migration.py` creates a separate legacy fixture, migrates it with the production schema, checks preserved projects/sessions/messages/attachments/bookmarks/transcript/approvals/MLX data, then saves/fetches MCP records and reads persistent history. It reopens the migrated fixture to check persistence. It never opens the user's real store.

## Validation commands

- `xcodebuild -project 'AFM Code.xcodeproj' -scheme 'AFM Code' -configuration Debug -destination 'platform=macOS' build`
- `sh scripts/test-coreai-bundles.sh [export-folder ...]`
- `python3 scripts/test-swiftdata-migration.py`
- `python3 scripts/test-coreai-residency.py`
- `python3 scripts/audit-smoke.py`
- `sh scripts/test-prepared-changes.sh`

A native adapter harness is in `scripts/CoreAINativeSmoke.swift`; `scripts/build-coreai-smoke.py` links it against the exact adapter objects from an existing Debug Xcode build. Pass that DerivedData directory to build it, then pass an export directory to `/tmp/afm-coreai-native-smoke`. It loads real weights and runs synthetic arithmetic plus context-admission checks. Run it only when no other model benchmark is using the Mac. Set `AFM_COREAI_METADATA_ONLY=1` to check only metadata/tokenizer loading.

Import/layout checks and a compiler pass do not prove end-to-end UI behavior, device inference, full 128K context, throughput, or tool reliability. The user is testing the picker on their own device; those results should be recorded separately.

## Results on 2026-11-08

- Final signed Debug macOS build: **passed** after the SwiftData fix and review corrections (`/tmp/afm-coreai-final-build.log`).
- Import regression: **10 passed**, including both 4K and 128K Gemma export folders.
- Legacy disk-store migration, MCP history/save/fetch, reopening and scene-container regression: **passed**.
- Existing command execution/accessibility source checks and prepared file-change regressions: **passed**.
- Exact compiled adapter + offline tokenizer initialization for both Gemma exports: **passed**, without loading model weights.
- Initial adapter check reported **tool calling: false; reasoning: false**. The subsequent Gemma tool-parser integration fixes tool detection for both exports; see `CORE_AI_TOOLS.md` for current checks and limits.
- End-to-end picker retest: **left to the user**, as requested. Real generation in the new AFM integration, sustained performance and full 128K prompts: **not run**. A previous separate benchmark runner answered a short arithmetic prompt, but that is not an AFM integration pass.

Existing uncommitted changes were preserved. No commit/push was made and no user database/model files were deleted, moved or reset.

The user subsequently confirmed that Gemma generates in AFM Code, but reported slow performance. See `CORE_AI_PERFORMANCE.md` for the retention/prewarm follow-up and measured versus unmeasured limits.

Gemma tool calling was subsequently enabled in the app-local adapter. Both real exports now report **tool calling: true; reasoning: false**. Open a project conversation to use coding tools; standalone chats have no project tools. See `CORE_AI_TOOLS.md` for verified parser/approval behavior and live-test limits.
