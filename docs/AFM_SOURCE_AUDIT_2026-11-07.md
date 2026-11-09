# AFM Code source audit, 7 November 2026

## Scope and validation

This is a source audit and focused code improvement pass, not a VoiceOver test or accessibility certification. No app launch, VoiceOver session, model inference, commit, or push was performed. Existing Xcode project and scheme changes were preserved.

Passed: Swift syntax parsing for all application Swift files; `git diff --check`; `python3 scripts/audit-smoke.py`. The smoke script compiles the actual production command-runner implementation in a small Foundation-only harness, then verifies early completion, nonzero exit/stderr, timeout, cancellation, and output limits. Its accessibility assertions are source guards only, not an accessibility-tree test.

Full Debug app build now passed with Xcode 27.1, after correcting a scope error in the new catalog-server toggle label. The first clean build compiled the complete dependency tree and identified that error; the subsequent build compiled the correction and linked/validated the application successfully. Command: `xcodebuild -project "AFM Code.xcodeproj" -scheme "AFM Code" -configuration Debug -derivedDataPath /tmp/afm-audit-build -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -jobs 2 build`. Final log: `/tmp/afm-audit-build-final.log`. The final build reported only the App Intents metadata extraction warning because the app has no AppIntents framework dependency. The isolated regression suite passed again after the fix. No runtime UI validation, VoiceOver testing, signing/distribution validation, or inference accuracy evaluation was performed.

## Existing accessibility strengths

- Native editable NSTextView has explicit accessibility label/help and focus forwarding (`Support/ChatInputTextView.swift`).
- Composer send/stop, context usage, model cards, sidebar projects/sessions, and status badges have meaningful labels/values instead of depending entirely on visual styling.
- App menu commands expose session navigation, composer focus, copy, stop, and regenerate through keyboard shortcuts (`App/AFMCodeApp.swift`).
- Turn announcements and approval announcements exist; settings control ordinary turn announcements (`Support/AccessibilityAnnouncements.swift`, `Features/Chat/StepsDisclosureCard.swift`).
- Structured markdown already contains heading traits, code descriptions, and table-cell labels (`Support/StructuredMarkdownView.swift`).

These are source-supported accessibility mechanisms, not proof that focus order, announcements, or interaction work correctly in the running app.

## Improvements applied

1. Assistant messages no longer discard the markdown renderer's accessible children. Headings, links, and table cells remain exposed in the source hierarchy. Both user and assistant message elements now have explicit Copy message actions. User-message labels mention attached images and filenames (`MessageRowView.swift`).
2. Tool rows expose semantic status and expansion state. Diff rows explicitly identify added, removed, and unchanged lines, independent of color and punctuation. The expand action says preview, since truncated data is still truncated (`ToolActivityView.swift`, `ToolStep.swift`, `DiffView.swift`).
3. Approval disclosure handles an already-pending request when the view appears and announcements when one pending ID changes directly to another (`StepsDisclosureCard.swift`).
4. MCP server enable switches and icon buttons identify their server. Image removal identifies its filename (`MCPServersView.swift`, `ImageAttachmentView.swift`).
5. Return-key submission now observes the same readiness guard as Send, avoiding deletion of an unsent draft when the engine is busy, compacting, missing, or unavailable (`ComposerView.swift`).
6. MCP approval cards now show argument JSON before execution, in the existing capped detail area. MCP cancellation is propagated rather than converted into ordinary failure output (`MCPTool.swift`, `ToolActivityView.swift`).
7. Fixed command latency: `ToolContext.runProcess` previously slept for the entire timeout even when its child finished immediately. It now checks for completion every 50 ms up to the deadline, reaps its child, and propagates cancellation. `RunCommandTool` preserves cancellation as cancellation instead of feeding a failure string back to the model.

## Remaining concerns and limits

- `MessageRowView` still collapses user-message children. Attached-image copy/save context-menu actions are not explicitly surfaced as custom accessibility actions; naming an attachment does not describe its visual content. Multiple images are also not represented by this single-image label.
- `AccessibilityTurnAnnouncements` treats responding-to-idle as “Reply complete”; the engine also uses idle for cancellation. It can therefore announce completion for a stopped reply.
- Source inspection cannot establish focus restoration, exact speech order, announcement timing, keyboard reachability of every context-menu action, or behavior of streaming content under VoiceOver. No VoiceOver test was conducted, as requested.
- `ToolContext.resolvePath` checks standardized lexical paths but does not resolve symlinks. Its “nothing outside the project root” comment is stronger than its checks. Likewise a shell working directory is not confinement. The app sandbox provides a separate, wider boundary. A real project security boundary requires explicit threat-modelled filesystem/process design, not just a path prefix.
- Command cancellation/timeout terminates the direct child, not an entire descendant process tree. Detached pipe drains may remain blocked if grandchildren keep pipes open. The new regression tests use `exec sleep` so they deliberately do not validate arbitrary subprocess trees.
- MCP argument previews use the existing 24,000-character detail cap. Always Allow still authorizes that tool for the project across arguments; this pass does not change that policy.
- MCP schema decoding falls back to unrestricted GeneratedContent when the framework cannot decode a schema (`MCPHostManager.schema`). The “no lossy projection” comment in MCPTool overstates this guarantee.
- Context recovery replays a prompt after rebuilding/reverting a transcript (`SessionEngine.runTurn`, `attemptTurn`). A tool may already have produced external effects before the failure. Replay needs an operation ledger/idempotency policy before being treated as safe for arbitrary writes or MCP actions.

## Lessons for Perspective Intelligence routing

AFM Code is a coding agent with seven built-in tools and optional MCP tools, not an independently evaluated semantic router. Its design is useful; its apparent tool success is not evidence that PI routing accuracy will improve.

Transferable patterns:

- Typed `@Generable` tool arguments and short `@Guide` descriptions, with schema validation at the execution boundary.
- Attach tools only for models with tool-calling capability and a valid per-session workspace/runtime (`SessionEngine.configureSession`).
- Keep tool declarations and current instructions fresh when restoring a saved transcript.
- Share one execution context for approvals, cancellation, tool status, and bounded result output. Persist tool activity separately from the model transcript for clear UI and audit history.
- Prefer observed context limits over advertised limits; measure the actual prompt/schema footprint (`recordRuntimeWindow`, `refreshContextUsage`).
- Keep local decisions, arguments, execution, and outcome distinct. Evaluate selection and arguments separately, including negations, multi-intent requests, abstentions, and destructive actions.

Do not transfer free-form schema fallback, blanket MCP authorization, or automatic replay of side-effecting tools without additional checks. The separate PI benchmark has already found semantic errors despite native schemas; native tool calling does not remove the need for measured routing tests.

## Follow-up: full-file change trustworthiness

The subsequent user-requested full-file edit/approval fix is documented in `TRUSTWORTHY_FILE_CHANGES.md`. Write/edit proposals now validate complete files, retain exact approved output bytes, reject stale snapshots, and offer complete lazy-rendered change review beyond the old 4,000-line boundary. Mutating file tools additionally check canonical project containment; the earlier lexical-path concern still applies to other paths using `resolvePath` alone. The full app build and focused change-plan regressions passed. This does not resolve the separately documented shell/process or model-side replay limitations.
