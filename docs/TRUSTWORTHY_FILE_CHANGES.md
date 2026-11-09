# Full-file approval and editing

## What changed

`edit_file` and `write_file` now build an immutable `PreparedFileChange` from a complete UTF-8 snapshot. The tool validates the entire file before asking for approval. It no longer builds a preview from the first 4,000 lines and later recomputes a different operation against the current file.

- A target after line 4,000 is included in the preview.
- Every occurrence is counted across the complete file. Ambiguous targets fail unless `replaceAll` was explicitly requested.
- The preview and the write share exactly the same prepared output bytes. Replacements are not recomputed after approval.
- Immediately before writing, the file's complete bytes and resolved location must still match the snapshot. Changed, removed, or independently created files reject the proposal without overwriting them. A fresh read/proposal and approval are required.
- Writes use NSFileCoordinator for cooperating document editors and an atomic file replacement. This is not a filesystem-level compare-and-swap: programs that ignore file coordination can still race the final check/replacement. Do not claim protection against arbitrary adversarial raw writers.
- No-op requests leave the file untouched. Empty/missing/ambiguous targets, unreadable/non-UTF-8 files, directories, and symbolic-link files are rejected instead of being represented as empty files.
- Targeted edits preserve UTF-8 BOMs, CRLFs, and absence of a final newline. Diff comparisons are byte-exact, including canonically equivalent Unicode with different encodings.

## Complete review without an enormous inline card

The diff trims only identical edge regions before a bounded line comparison. When the central comparison would be too expensive, it shows the complete changed region as a replacement rather than omitting changes. Long unchanged runs are explicitly summarized, while every changed line remains in the proposal.

The inline card displays at most 400 diff rows and has a persistent notice when abbreviated. Its visible **Review all changes** action opens a lazily rendered, uncapped view of all prepared changes, with full wrapping and complete copyable diff text. Addition/removal counts describe the complete proposal. Previously saved truncated history remains explicitly labeled incomplete; it cannot reconstruct changes that were not saved.

For predictable memory/UI use, each source/output file is limited to 8 MiB and 100,000 lines. Larger files fail explicitly before approval; there is no silent partial preview followed by a whole-file write. This is a review limit, not the former 4,000-line truncation bug.

## Verification

Run `bash scripts/test-prepared-changes.sh` for tests compiled against the production change-plan and diff implementation. Coverage includes:

- A targeted edit after line 5,500 in a 6,000-line file and byte-for-byte approved output.
- Duplicate matches on both sides of the former 4,000-line boundary; explicit replace-all shows both changes.
- Changed, deleted, and independently created files while a proposal is pending; replaying an applied proposal.
- No-op preservation of bytes and modification time; empty and missing searches.
- Full-file writes changing the tail, and a complete 12,000-row replacement diff.
- Rejection of invalid UTF-8, symbolic links, directories, and size/line-limit overflow.
- CRLF/no-final-newline preservation, UTF-8 BOM preservation, and byte-distinct Unicode normalization.

Existing command-runner and accessibility source regressions remain in `python3 scripts/audit-smoke.py`. No VoiceOver or model-inference testing is part of these checks.

## Final build result

The complete Debug app build passed with Xcode 27.1, signing disabled and derived data isolated in `/tmp/afm-audit-build`. Log: `/tmp/afm-trustworthy-edit-build.log`. Both regression commands passed after the changes, including cancellation before write. Existing user project/scheme edits were preserved. No commit, push, model run, app interaction, or VoiceOver test was performed.
