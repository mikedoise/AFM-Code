# Desktop access and first-launch migration

AFM Code is configured as a non-App-Store macOS desktop app. Both Debug and Release disable App Sandbox and enable Hardened Runtime. These are independent protections. This change does not alter macOS privacy settings, Full Disk Access, Gatekeeper, SIP, file ownership, or command-line credentials.

## Command authority and approvals

Approved shell commands and enabled MCP server processes run with the Mac account's normal permissions. They can reach account-accessible files and services outside the selected project. Selecting a project is a working-directory choice for shell commands, not an operating-system boundary. macOS privacy prompts and filesystem restrictions still apply.

Built-in file tools continue to enforce the selected project's canonical root and reject path/symlink escapes. File writes and edits retain the approval flow. Commands and MCP tool calls retain Deny, Allow, and Always Allow controls, unless the user explicitly chooses the project's Auto-approve mode. Always Allow stores the exact command or MCP tool identity, with separate permission namespaces; an MCP allowance cannot authorize a shell command with the same name. A running conversation observes revocation of its stored grants.

At first desktop launch, sandbox-era project approval modes and command/MCP grants are archived in the project, then the active mode becomes Always ask and active grants are cleared. Previously enabled MCP servers are paused, with configuration preserved. Review each server before enabling it again: enabling it starts a process with normal account access, before any individual MCP tool approval. Unmigrated or unknown-version records do not receive automatic execution authority. Raw, untyped previous allowance entries are inactive.

The first approved command may capture the normal login-shell environment, including shell startup scripts. Approved MCP startup does the same. Inventory-only environment diagnostics and built-in read-only Git/search helpers do not capture that login environment or run user startup files. Read-only helpers use a controlled environment and startup-disabled shell. Approved command probes are not a side-effect-free or network-isolated security boundary.

The command runner is noninteractive: it has closed standard input, bounded output, a maximum 300-second timeout, and cancellation/process-group cleanup. Interactive logins, persistent background services, and full terminal applications still need a real terminal. Tool availability is distinct from authentication and project dependencies.

## Existing data stays in place

The desktop app first looks for the original database at `~/Library/Containers/app.techopolis.AFMCode/Data/Library/Application Support/default.store`. When present and accessible, it reuses that location and its support directory, including existing model caches and MCP working directories. It does not copy a live SQLite database or delete/reset the store. Known app preference keys, including imported Core AI model bookmarks, are imported once from the legacy preference file, without replacing preferences already chosen in desktop mode.

Fresh installations use `~/Library/Application Support/AFM Code/default.store`. Inaccessible storage, corrupt legacy preferences, or nonempty legacy support data with a missing expected database cause startup to fail visibly instead of silently opening an empty replacement. An approval-migration save failure also blocks startup. The application checks for another running AFM Code instance before accessing the store; it does not stop that instance.

Ordinary desktop folder bookmarks and legacy security-scoped bookmarks both work. Failure to acquire a security scope does not by itself mean an accessible desktop folder is unavailable. Model files remain in place and are read rather than modified.

## First test on your Mac

1. Save your work and quit the old AFM Code instance yourself. Build and run the updated `AFM Code` scheme in Xcode.
2. Confirm your projects, sessions, messages, settings, and imported model references are present. If startup reports a storage problem, do not remove the old database to get past it.
3. Open a project and confirm its approval mode is Always ask. Test a harmless command or `environment_check` with execution verification, then deny or allow its approval card.
4. Review paused MCP configurations before re-enabling only the servers you trust. Recreate any exact-command allowances you still want under the broader desktop authority.
5. Test generated Python scripts and GitHub CLI commands in a disposable project. Finding/running `gh --version` does not establish GitHub authentication.

## Verification and limits

Disposable fixtures exercise old-schema migration, archived approvals, paused MCP servers, preference import, fail-closed selection, idempotence, independent-process reopen, and a real ordinary bookmark. The tool-safety suite covers exact grants, cross-type grant collisions, revocation, denial, cancellation, immutable file approvals, and root/symlink checks. No tests open the user's actual store.

A separate development-signed Hardened Runtime desktop fixture with an empty app entitlement dictionary ran fixed shell, Python, Git, and GitHub CLI probes. It executed a generated Python script in a temporary directory. The installed versions observed were Homebrew Python 3.14.8, GitHub CLI 2.102.0, and Git 2.54.0. It used an isolated home and explicit Homebrew-first login profile, not the user's startup scripts, credentials, or projects. It verified its own non-sandbox status and signature. It did not test real account authentication, TCC prompts, interactive commands, the AFM GUI, or model inference.

## Distribution

The development build retains the existing Apple Development identity and bundle ID. Hardened Runtime is present, and App Sandbox is absent; the Debug artifact has the usual development `get-task-allow` entitlement. No extra runtime exceptions were added.

Before shipping outside Xcode, archive with Developer ID Application signing, secure timestamp, and Hardened Runtime; verify the shipped app does not contain `get-task-allow`, then notarize and staple according to Apple's guidance. No distribution upload, notarization, or publication has been performed by this change.

- [Apple: Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
