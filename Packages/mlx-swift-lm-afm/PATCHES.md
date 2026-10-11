# AFM Code local modifications

This directory is a vendored copy of
[`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm),
integrated by AFM Code so the app can consume the MLX language-model stack
(`MLXLMCommon`, `MLXVLM`, `MLXFoundationModels`, `MLXHuggingFace`, and the
other products the app links) from a local package that builds against the
patched `../mlx-swift-afm` MLX core.

## Upstream provenance

- Package: `mlx-swift-lm` (manifest name kept as upstream; the package
  *identity* is the directory name `mlx-swift-lm-afm` because the
  dependency is path-based)
- Version: `3.32.3`
- Commit: `3b339ad6` ("adjustments for running tests on NAX/TF32 hardware (#649)"), 2026-09-30

## Local modifications

No Swift source modifications. The only change is in `Package.swift`:

- The `mlx-swift` dependency was changed from the GitHub URL reference
  (`.upToNextMinor(from: "0.32.3")`) to the local path `../mlx-swift-afm`
  (see that package's `PATCHES.md` for the Metal 0-dim-gather fix that
  motivated the vendoring).
- All `.product(name: ..., package: "mlx-swift")` target references were
  updated to `package: "mlx-swift-afm"` to match the path-based identity.

The `swift-syntax` dependency (used by the `MLXHuggingFaceMacros` macro
target) remains a remote reference.

> Note for Xcode: because the macro target's package identity changed, the
> `MLXHuggingFaceMacros` entry in `~/Library/org.swift.swiftpm/security/macros.json`
> must reference the new identity `mlx-swift-lm-afm` (see the AFM Code
> repository notes). The macro sources are unchanged, so the source
> fingerprint is the same as the upstream `mlx-swift-lm` entry.

## How to re-upstream

When refreshing this vendored copy from upstream:

1. Replace the tree with the new upstream revision (exclude `.git`, `.swiftpm`, `.github`).
2. Re-apply the `Package.swift` dependency repoint (`../mlx-swift-afm` path
   + the 21 `package: "mlx-swift-afm"` product references).
3. Update the provenance block and re-verify the `macros.json` entry.
4. If a new upstream `mlx-swift` version is needed, refresh
   `../mlx-swift-afm` the same way and re-check its patch.
