# Accessibility build review, November 8, 2026

Candidate fixes are implemented; issues remain open for Taylor's verification. This is not a VoiceOver pass report.

## Implemented

- #7, #20, #26: hide redundant empty-state, project, MCP, search, approval and diff icons while retaining controls and text.
- #8: readable imported Core AI names, original identifier retained separately, explicit context and text modality; model-first accessible descriptions in library, picker and chat header. Context metadata does not establish successful full-window inference.
- #19: concise model-first status with no repeated detail/value; activate the badge for details. Retain timings with explicit seconds, describe resident-model reuse and the first-text wait included in response duration. Replace raw tool-object failures with a readable error.
- #9, #11, #12: remove duplicated project tooltip, distinguish Create Session from saved session titles, use primary text for counts and Projects heading. Contrast still needs measurement in light and dark appearances.
- #10: give saved sessions their own section after project settings.
- #21, #22: name System Prompt, focus its editor by default, and use native Tab/Shift-Tab traversal with Return retained for newlines. Actual traversal with Taylor's settings is pending.
- #23: individually label static Settings values and give announcement switches their purpose names.
- #24, #25: label MCP fields and model/server actions with their targets.
- #27: expose only collapsed/expanded state on the reasoning button; full reasoning is a separate readable element when expanded.
- #28: model-specific readiness text and named download progress.
- #32: replace the repository-ID disclosure with a standard button exposing expanded/collapsed state and a named repository field.
- #34: remove redundant assistant grouping, distinguish read-only message text, skip the composer scroll wrapper, and explicitly navigate on Tab/Shift-Tab. Keep text selection, links and the existing Command-L composer command. This is a candidate fix, not a reproduced live VoiceOver resolution.
- #36: speaker/message headings independent of Markdown headings, keeping structured reply content and tools.
- #37: added/removed line counts with units and singular/plural.
- #15: context used percentage, remaining tokens, unknown-measurement wording, text warnings and threshold/compression announcements.

## Partial older request

#14 now announces short replies as plain text, uses a short notification for long/code replies, and announces tool and compression activity. Existing high-priority approval announcements and user toggles remain. Automatic focus on completed replies and a completion-aware announcement queue are not implemented in this change; they need a deliberate focus/announcement policy and live testing to avoid disrupting editing or reading. Do not close #14 as complete.

## Verification

- Passed: Xcode Debug build for macOS arm64.
- Passed: code signature verification of the built app.
- Passed: production model-selection/status tests, including both imported Gemma name formats, name/context/modality order and concise Loaded status.
- Passed: git diff whitespace checks.
- Not checked yet: updated runtime accessibility tree, actual VoiceOver speech and navigation, Full Keyboard Access, light/dark contrast, populated MLX download/error states, or Dynamic Type presentation. The existing app was actively in use; no restart or interaction was authorized during implementation.

Updated build: `/Users/taylorarndt/Developer/AFM-Code-accessibility-build/Debug/AFM Code.app`.

Xcode removed the old DerivedData product bundle as stale while building to a separate output directory. The existing process remained running; it was not terminated or relaunched. Coordinate the switch before further testing. No generated project files, approval decisions, model library records or chat drafts were deliberately changed.

## Short verification sequence

1. After switching builds, open Settings with Command-comma. Hear System Prompt, edit it, then Tab and Shift-Tab through controls. Verify Usage values and announcement switch names.
2. Open model management. Check model name, Context window, Modalities, readiness and targeted actions. Activate Add by repository ID and verify its field appears and collapses accessibly. Check MCP editor field names without saving a server.
3. In a conversation, navigate by message headings; read links and text, then Tab into and out of Message AFM Code and use Command-L. Expand/collapse reasoning. Verify model details and retained timings. Review added/removed line labels on the next user-authorized change.

## Deferred scope

OpenCode/tool-harness investigation remains outstanding, including the exact arguments behind the EditFileTool generated-content parse failure. No parser bytes, file mutation logic or approval gates were changed. Functional requests #18, #29, #30, #33 and #35 remain separate.
