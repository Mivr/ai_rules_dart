---
status: accepted
unenforceable: "No registered gate metric checks the host or cross-target platform tables; they are pinned by the toolchain unit tests only"
---

# 0004. Five host platforms and two cross-only targets

Source: `docs/ARCHITECTURE.md`, Design Decision 2 and Cross-Compilation.

## Context

rules_dart downloads published Dart SDK releases rather than building the SDK.
A host needs a full SDK archive; a cross target needs only the pair-specific
`gen_snapshot` and `dartaotruntime` artifacts, and some CPUs have no Bazel
release to run a build on.

## Decision

- Five hosts, for which an SDK is downloaded and a build can run: macos-arm64,
  macos-x64, linux-x64, linux-arm64 and windows-x64 (`PLATFORMS` in
  `dart/private/toolchains_repo.bzl`, each with an SDK archive SHA-256 in
  `TOOL_VERSIONS`).
- Two cross-only targets that can be built for but not on: linux-riscv64 and
  linux-arm (armv7), in `TARGET_ONLY_PLATFORMS`. `linux-arm` is selected by
  `@platforms//cpu:armv7`.
- Cross-compilation covers the `exe` and `aot-snapshot` modes, through cross
  toolchains that toolchain resolution picks when `--platforms` is set.

## Alternatives ruled out

- Building the Dart SDK from source.
- Treating linux-riscv64 and linux-arm as hosts: Bazel publishes no release
  for either CPU.
- Selecting armv7 with `@platforms//cpu:arm`, which is an alias for `aarch32`.

## Consequences

- `kernel` and `jit-snapshot` are VM formats and are not cross-compiled;
  `dart_js_binary` and `dart_wasm_binary` output is platform-independent;
  `dart_test` runs on the host.
- Native code assets on the cross-only CPUs need a cc toolchain for that CPU,
  which rules_dart does not ship.
- Adding a platform means a row in the platform table and pinned checksums in
  `dart/private/versions.bzl`.
