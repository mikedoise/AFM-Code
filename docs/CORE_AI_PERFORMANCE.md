# Core AI performance follow-up

The user confirmed that the exported model works in AFM Code and asked to keep it loaded and prewarm when a conversation opens.

## Confirmed avoidable work

The initial integration called `unload()` after every response, discarded the model, and recreated its tokenizer and engine on the next message. This was conservative about memory, but repeated preparation unnecessarily.

The updated manager keeps at most one successful Core AI model resident. Its read-only folder bookmark remains open while the model is resident. The cached model is replaced when a different model is needed, released for another provider or via **Unload Model**, and discarded after failed/cancelled requests. Model files are never deleted by unloading.

Opening a conversation starts background preparation without disabling typing. Sending joins that preparation instead of creating another load. Background preparation can be cancelled; newer navigation replaces stale work after it drains. Opening another conversation during generation defers its preparation until the current response ends. A cancelled/failed request is not automatically restarted. The view's identity is now tied to its session at the RootView call site, so switching conversations does not reuse another session's stored engine state.

## Existing measured evidence, not a new AFM benchmark

Prior terminal smoke logs for the same arithmetic prompt (23 input tokens, 2 output tokens) reported:

| Export | Model preparation | Prompt processing | Generation | Total |
|---|---:|---:|---:|---:|
| 4,096 tokens | 43.724 s | 0.140 s | 0.017 s | 45.053 s |
| 131,072 tokens | 41.463 s | 3.909 s | 0.059 s | 47.172 s |

Sources: the benchmark checkout's `text-smoke.log` and `text-smoke-ctx131072.log`. These were separate runs on different occasions, not a controlled steady-state 4K-versus-128K comparison. The 128K run emitted ANE compiler warnings but completed; the actual executed hardware path was not established. Do not infer that the context setting alone caused the user's delay.

The earlier 4K warmed benchmark (`benchmark-main.json`) averaged 41.1 generated tokens/s over three trials with 512 input tokens and 256 output tokens. This uses a different workload and cannot predict AFM chat latency. Its cache-hit preparation was 0.059 s and warmup was 7.890 s. A cheap preparation cache hit does not mean recreating and warming an engine is free.

AFM adds its instructions and project context, and a Debug app is not identical to the Release terminal runner. No new real-model timing was run while the user was testing and PI work was competing for the Mac. The running user app was not stopped or relaunched.

## New visible diagnostics

After a Core AI response, the composer shows:

- **Model loaded/reused**;
- **prepare**: demand-time preparation, including waiting for an in-flight prewarm;
- **first text**: time from response request to the first nonempty streamed text;
- **response**: time from request through collection, including prompt processing and generation;
- **output tokens**: Foundation Models' output-only usage count.

The `dev.afmcode` / `SessionEngine` log additionally separates tokenizer initialization, engine load/warmup, prewarm wait and total turn time. Timings contain no prompt text. These wall-clock intervals are not advertised as pure decode throughput.

## Verification

`python3 scripts/test-coreai-residency.py` compiles the production manager's coordination code with a deterministic fake adapter (file-panel UI removed). It checks reuse, no reload for an already warm conversation, joining prewarm, accurate wait accounting, concurrent-send rejection, eviction protection, cancel/drain, navigation replacement, reopening during cancellation, deferred preparation after another generation, stopped-request suppression, removal without deleting files, and at-most-one active load. It also guards RootView's session identity in source. This does not measure Core AI performance or replace native UI/device testing.

The next user test should use the rebuilt app, wait for background preparation to finish, then send a short prompt followed by another. The second should report **Model reused** with near-zero preparation when no switch/error intervened. A remaining first-text or response delay can then be investigated separately with the actual prompt length and controlled, noncompeting model runs.
