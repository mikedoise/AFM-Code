# Git commands and approvals

## Verified defects and fixes

The user's reported pull failure did not include a Git stderr/exit line, so its exact cause is not proven. The investigation nevertheless reproduced these related defects and fixed them:

1. **Command PATH was reset.** The app captures the user's shell environment and prepends Xcode's real developer binaries to avoid sandbox-hostile `/usr/bin` xcrun shims. Running a second login shell (`zsh -lc`) undid that order. On this Mac, an augmented PATH selected `/usr/bin/git` after login startup but `/Applications/Xcode.app/Contents/Developer/usr/bin/git` with `zsh -c`. Command/search execution now uses the non-login shell; environment capture still uses login/interactive startup as before. `.zshenv` can still affect non-login shells.
2. **Git write routing was unclear.** The `git` tool intentionally supports six read-only actions. `run_command` already supported approved Git writes. Tool descriptions, unsupported-action output and agent instructions now explicitly route pull/fetch/add/commit/merge/rebase/switch/checkout/push to the full `run_command` request. Unknown Git actions never silently execute a write.
3. **Read command construction had real bugs.** `git show` split its format string into extra arguments. `head` pipelines hid failures. Option-looking refs could become Git flags even when shell-quoted. The format is now quoted, refs starting with `-` are rejected, exit status is preserved, and successful output is capped in Swift. Failure output keeps its bounded diagnostic tail.
4. **Read commands could invoke configured programs.** The read prefix disables optional index locks, fsmonitor, signature display, external diff and textconv. A fresh effective-config check reads filter key names only; any filter configuration routes the operation to `run_command` approval rather than running it approval-free. Git LFS/global/inactive filter configuration is deliberately handled conservatively. This is not an atomic protection against concurrent external configuration changes.
5. **Approval lifetime needed tightening.** Published pending IDs now already have a registered continuation. Cancellation is checked during registration. Always Allow binds to the actual stored request, not a caller-supplied substitute. Revocations in the project take effect in an already-open conversation, and new grants cannot restore stale entries.
6. **Stop/timeout left descendants running.** A disposable nested child reproduced writing after its shell timed out. Each command now starts its own process group; ordinary descendants are stopped before return, output is drained without lingering tasks, stdin is `/dev/null`, and unrelated app file/socket descriptors are not inherited. The child PID remains reserved until the final group signal, avoiding normal PID reuse hazards.

Commands default `GIT_TERMINAL_PROMPT` to `0` when absent. Explicit settings remain unchanged. Credential helpers, askpass and SSH configuration are not changed; this is not a universal authentication fix.

## Permissions and limitations

- Project approval mode and exact command/MCP allowances remain in effect. No automatic approval, credential permission, bookmark widening, entitlement change or sandbox removal was added.
- A stopped/timed-out command may already have changed files or a remote. SIGKILL is not rollback and may leave Git lock files. Inspect state before retrying; do not delete locks automatically.
- Deliberately detached sessions/new process groups can escape process-group cleanup. Background jobs within the normal command group are stopped when the invocation ends; this runner is not a persistent server launcher.
- Network authentication, credential helpers, signing keys, SSH configuration, and external worktree/common Git directories can require access beyond a selected project. They were not tested against user accounts or repositories.
- The fixture harness exercises production tool/approval/command code but is not the signed app's GUI or security-scoped bookmark flow. Those original sandbox-era checks did not widen access. The current desktop build and preserved approval boundaries are documented in [Desktop access](DESKTOP_ACCESS.md).

## Validation on 2026-11-08

Final signed Debug Xcode build passed: `/tmp/afm-git-final-build.log`.

`python3 scripts/test-git-commands.py` uses only temporary local seed/working repositories and a local bare remote. It blocks non-file Git protocols, isolates HOME/ZDOTDIR/global/system Git configuration/templates, and removes all fixtures afterward. Passed:

- Developer Git PATH survives command startup; old login path reset reproduced.
- Unsupported mutations return explicit approved-command guidance without execution.
- Denied/cancelled pull leaves HEAD unchanged. Approved pull fast-forwards the local fixture.
- Approved add, commit and push operate only on the local disposable remote.
- Old show quoting/masked-failure bug reproduced; fixed show succeeds.
- Invalid revisions and non-repository failures remain failures.
- Leading-hyphen refs rejected; normal ranges and paths containing spaces/apostrophes/leading hyphens still work.
- External diff/textconv/fsmonitor marker helpers do not run in the read path.
- Large diffs cap successfully, without SIGPIPE-based false failure.
- Configured clean filters require the approval path; removing the fixture config is observed on the next call.

`bash scripts/test-tool-safety.sh` passed production approval, file mutation, revocation, exact permission target, 100 rapid-decision, reset/duplicate-decision, range and path tests.

`python3 scripts/test-command-cancellation.py` passed nested TERM/HUP-ignoring child cleanup, Stop, timeout, background child cleanup, environment/cwd/stdin, stderr/exit status, output flooding bounds and unrelated-FD isolation. A negative-control fixture confirmed FD leakage without close-on-exec protection.

Existing audit-smoke, prepared-file-change, Core AI residency and temporary SwiftData migration regressions also passed. No model inference or GUI test was run. No existing user repository was pulled, committed, pushed or changed; no external network Git operation occurred.

## User retest

Restart the newly built AFM Code scheme from Xcode when ready. Open the project conversation and ask for Git status first. For a desired pull or other Git change, AFM should call `run_command` and present the exact command for approval under Always ask. Review it before allowing it.

If a command still fails, the useful evidence is the actual tool name, full command, exit status and stderr from its expanded activity card. A model-reused timing line alone does not identify a Git failure. Do not retry a timed-out write until its outcome is checked.
