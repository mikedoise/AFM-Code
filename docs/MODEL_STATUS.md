# Per-conversation model status

The footer previously ignored the conversation and displayed `ModelCatalog.activeDescriptor`, the first globally available model. That commonly remained AFM Core while the title and runtime used a selected Gemma export.

The composer and sidebar badges now receive an explicit model status. Before an engine exists, the title, composer and sidebar use the same session-override → project-default → Automatic resolver as the runtime. A project overview is labeled Project default; an empty selection is labeled Default, not Active.

The badge distinguishes:

- Selected: chosen for the next request, without claiming loaded residency.
- Preparing: the matching model is being prepared, including queued preparation.
- Loaded: the matching Core AI model is actually resident in memory.
- In use: the model handling the current turn.
- Error or Unavailable: current-model failures or unavailable selections.

AFM/MLX availability is not treated as proof that weights are loaded. Core AI preparation is keyed by model ID, not only session ID. Background load errors are visible, cancellation is not labeled as a load failure, and successful reload clears that failure. A confirmed resident model displays Loaded even when a previous request error remains separately visible in the conversation.

An in-flight turn pins its descriptor through generation, compaction, message attribution and cleanup, so changing a project default or selecting another model elsewhere cannot relabel an existing response. The next turn uses the current selection. Missing Core AI choices remain explicitly unavailable; the existing missing-MLX fallback behavior is preserved.

Status is conveyed in text and VoiceOver labels/values, not only a colored dot. Full names and context size remain accessible even when the compact label is truncated.

## Validation

- `python3 scripts/test-model-status.py`: production resolver/status cases, observed selection changes, overrides/defaults, in-flight identity, missing-model behavior and source wiring guards.
- `python3 scripts/test-coreai-residency.py`: production lifecycle with fake adapter, including model-specific preparation/error state, recovery and unload; no real weights.
- Temporary SwiftData migration and existing command/accessibility-source audit passed.
- Signed Debug Xcode build passed; final log: `/tmp/afm-model-status-final-build.log`.

No app launch/restart, live model inference, or GUI/VoiceOver automation was performed. User data, model files and unrelated edits were preserved. No commit or push.

## User retest

Restart from Xcode when convenient. Switch AFM → Gemma in a conversation and compare the title, composer badge and sidebar footer. Switch to a different conversation/project and confirm its own selection/default appears. Gemma should progress from Preparing to Loaded after successful prewarm; availability alone should not display Loaded.
