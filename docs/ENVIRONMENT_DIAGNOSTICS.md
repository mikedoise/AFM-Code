# Desktop command diagnostics

## What changed

`environment_check` is now available alongside the existing coding tools in project conversations whose model supports tools.

- Default: inspect the resolved PATH for `shell`, `python3`, `python`, `gh`, `git`, `node`, `npm`, `uv` and `rg`. It reads cached exported variables, or the app environment with conventional PATH fallbacks when no capture exists. It does not execute discovered programs, initialize a shell, refresh login exports or create cache directories. The report names this snapshot limit; a later approved normal command may capture a different environment.
- It distinguishes a found executable from a missing/hidden path and an access/execute-permission restriction. A found path is explicitly **not execution verified**.
- With a named tool and `verifyExecution: true`, it offers one fixed probe through the existing project approval service. Default approvals still ask, exact allowances still apply, and trusted-project auto approval behaves as before. There is no arbitrary command/path argument.
- Python probes use `-I -B -S` and a fixed arithmetic-free marker/version print, avoiding user site initialization and bytecode writes. Other program probes request only `--version`. Shell checks use a fixed `printf`.
- Only a strictly numeric version, fixed success marker, exit code, timeout, or standardized failure category is retained. Environment values, authentication/config contents and raw probe stdout/stderr are not returned or stored in the activity detail. A program or shell startup script can have side effects, including network activity permitted to the Mac account; a `--version` argument is not network isolation. The tool does not pretend that an arbitrary discovered executable is inherently safe, so execution remains approval-gated.
- Discovery uses the selected-folder access helper, including ordinary desktop and legacy bookmarks, including for project-relative PATH entries or virtual environments. Execution uses that same cached/app snapshot and the exact displayed absolute executable path after approval. The outer command shell can then run its normal startup code; denied/cancelled probes do not launch it.
- Model instructions explain the distinction between discovery, execution, project dependencies and authentication. Command failures now add targeted hints for lookup, access denial, developer shims, Python imports and noninteractive authentication.

Shell environment fixes:

- Conventional `/opt/homebrew/bin` and `/usr/local/bin` paths are appended when missing, without replacing the user's existing ordering. The desktop build preserves the user's PATH order and no longer forces Xcode binaries ahead of it. Developer tools are fallback entries. Read-only built-in helpers separately use controlled system/developer paths.
- Failed refresh now preserves the previously captured exports as the old comment promised. The report identifies capture/fallback state.
- Desktop commands retain the user's cache defaults and explicit overrides. They no longer force UV/pip/npm caches into the old app container.
- Capture documentation now correctly says zsh, not the user's arbitrary configured shell. Actual command execution remains noninteractive zsh. Random capture delimiters and absolute `/usr/bin/env` avoid fixed-marker/startup alias collisions; failed/timed-out captures are not accepted.

The separately confirmed desktop transition removes App Sandbox and enables Hardened Runtime. No macOS security/privacy setting, authentication grant or automatic login was changed. The tool does not request network, installation or authentication operations. Normal command output behavior is unchanged; the stronger output filtering described above is specific to the diagnostic probes.

## Historical sandbox measurement, before the desktop transition

A separate, development-signed headless app was built with AFM's former sandbox entitlements: App Sandbox, user-selected read/write files and outgoing networking. It verified that it was sandboxed, used the production process runner and environment resolution, and ran fixed probes without credentials or user project data. It did not launch or modify the running AFM app.

- zsh: passed.
- Xcode Python: **3.9.6**, passed the isolated interpreter probe and ran a harmless generated `.py` file in the fixture's sandbox temporary directory.
- Xcode Git: **2.54.0**, version probe passed.
- `/opt/homebrew/bin/gh`: installed on the host, but the sandbox fixture's read/execute checks returned **EPERM (1)**. Its fixed version probe failed with denied access.
- `/opt/homebrew/bin/python3`: likewise installed on the host but denied inside the fixture. No alternate permission route was attempted.

This showed that the former sandbox could run generated Python scripts with its accessible interpreter, but did not have ordinary Terminal access to these Homebrew installations. It does **not** prove the user's original Python script works: selected-folder bookmarks, script syntax, Python version, packages, shebang, permissions and any external resources are separate factors. Python 3.9 and the host's newer Python may provide different packages/language features.

The fixture does not share AFM's identity, active bookmarks, credential state or privacy approvals. It verifies the entitlement-level restriction with isolated resources, not a full GUI/real-project end-to-end test. No network requests, GitHub authentication, model inference or actual user-repository commands were tested.

## Current desktop measurement

A separate signed Hardened Runtime fixture verified that it had no App Sandbox. With isolated HOME/startup configuration and the host's normal installed executables, zsh, Homebrew Python **3.14.8**, `gh` **2.102.0**, and Git **2.54.0** passed. Homebrew Python executed a harmless generated script, including a file path with spaces. No credentials, GitHub authentication, network request, user project files or real AFM data were used.

The fixture confirms execution capability, not full interactive Terminal parity. See [desktop access and migration](DESKTOP_ACCESS.md) for first-launch approval/data behavior and remaining limitations.

## Try it in AFM

Build/run the current AFM Code scheme from Xcode when ready. In a project conversation using a tool-capable model, ask:

> Check the command environment. Verify Python 3 execution, and explain whether gh is missing or blocked. Do not change permissions or print credentials.

For direct tool arguments, inventory is `tool: null, verifyExecution: false`; a Python probe is `tool: "python3", verifyExecution: true`. Expand the activity to review the discovered paths/result and approve the fixed execution probe if requested.

A reported access denial should not be worked around by retries or hidden permission changes. The user explicitly approved desktop host access, but macOS privacy controls, file permissions and authentication still apply.

## Validation

- `python3 scripts/test-environment-diagnostics.py`: production diagnostic, approval and runner code with isolated HOME/cache fixtures; inventory never executes candidate programs or shell startup files; approved-startup positive control; denied/cancelled probes do not run startup files; access restrictions; invalid requests; approve/deny/cancel; numeric-only output; Python execution; preserved cache overrides; stale-export recovery.
- `python3 scripts/test-desktop-command-probe.py`: current signed Hardened Runtime/no-sandbox fixture.
- `python3 scripts/test-environment-sandbox.py`: historical sandbox comparison fixture. Requires the existing development signing identity. Creates a distinct test app container and disposable temporary files, not AFM's data store.
- `python3 scripts/test-git-commands.py`: existing production Git/command regressions, disposable local remote only.
- `python3 scripts/audit-smoke.py`: command runner and source accessibility guards.
- Debug Xcode build with package auto-resolution disabled.

No commit or push. GUI, VoiceOver runtime and real-model invocation are left to the user.
