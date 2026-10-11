# AFM Code local modifications

This directory is a vendored copy of [`ml-explore/mlx-swift`](https://github.com/ml-explore/mlx-swift),
integrated by AFM Code so the app can build against a locally patched MLX core.

## Upstream provenance

- Package: `mlx-swift`
- Version: `0.32.3`
- Commit: `19601207` ("fix MLXLogger (#493)"), 2026-09-30
- The `Source/Cmlx/mlx` and `Source/Cmlx/mlx-c` trees are the upstream git
  submodules, pinned at:
  - `mlx` @ `1f8e74e3f12f31365464a6867c6579f0e9b29d85` ("Hold GIL in AttachedData destructor (#4391)")
  - `mlx-c` @ `ebc88f10caa1b625e6b581437a8dea6df8a70085` ("Implement missing stream functions (#132)")

  They are inlined in this copy (the git submodule metadata is not included).

## Local modifications

Exactly one local change, in
`Source/Cmlx/mlx/mlx/backend/metal/indexing.cpp`, `Gather::eval_gpu`:

When a gather's index array is 0-dimensional (for example, taking a single
row with a scalar index, as in `tokens[0]` on a `(1, N)` array — which is how
`Gemma4Processor`-style processors build prompt tokens), the C++ code
unconditionally bound the *empty* index-shapes/strides vectors to the compute
encoder, which passes a null pointer to `MTLComputeCommandEncoder
setBytes:length:atIndex:`. The JIT kernel has a compile-time `IDX_NDIM == 0`
specialization and never dereferences those buffers, so release builds are
correct; but the Metal API validator (enabled in Xcode debug sessions) asserts
on the null pointer and the process aborts.

The fix adds placeholder values when `idx_ndim == 0`, mirroring the identical
guard that `Scatter::eval_gpu` already carries in the same file (the MLX team
fixed this hazard class for scatter but not for gather):

```cpp
if (idx_ndim == 0) {
  idx_shapes.push_back(0);
  idx_strides.push_back(0);
  idx_contigs.push_back(false);
}
```

The placeholders are semantically inert: the `IDX_NDIM == 0` kernel
specialization sets `idx_loc = 0` and never reads the shapes/strides/contigs
buffers, so results are bit-identical.

Known upstream quirk (not changed here):

- The `Cmlx` target's `exclude` list contains `"mlx/build"`, but the pinned
  `mlx` submodule commit does not contain a `build/` directory, so SPM emits a
  non-fatal `Invalid Exclude ... File not found` warning at resolve time. It is
  harmless (the build proceeds) and exists identically in the upstream package.

## How to re-upstream

When refreshing this vendored copy from upstream:

1. Replace the tree with the new upstream revision (exclude `.git`, `.gitmodules`, `.swiftpm`, `.github`).
2. Re-apply the single `Gather::eval_gpu` patch above (it is small and
   self-contained; check whether upstream fixed it first — if upstream added
   the same guard, drop the patch).
3. Update the provenance block.
4. `~/Library/org.swift.swiftpm/security/macros.json` is not affected by this
   package (it has no macro targets); macro approvals live for the
   `mlx-swift-lm-afm` package.
