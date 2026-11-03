---
status: accepted
unenforceable: "No registered gate metric runs the codegen rules or checks that analysis contexts are not reused across worker requests"
---

# 0008. Bazel-native code generation through per-builder shims

Source: `docs/ARCHITECTURE.md`, Design Decision 6; `docs/ext.md`.

## Context

Dart code generation normally runs under `build_runner`, which owns its own
build graph and output layout. Bazel needs each generated file to be the
declared output of an action, and `source_gen` pins `rootPackageName` per
process.

## Decision

- `dart_codegen` (per file), `dart_aggregate_codegen` (per package) and
  `dart_sqlcodegen` (drift's `.drift` preprocessor) are Bazel-native
  alternatives to `build_runner`.
- Each runs `package:build` `Builder`s through a per-builder AOT shim under
  `dart/ext/*/`.
- A Bazel persistent worker amortises Dart VM startup across requests, but
  the `AnalysisContextCollection` is constructed fresh for every request.

## Alternatives ruled out

- Running `build_runner` inside Bazel actions.
- Reusing one `AnalysisContextCollection` across requests, which would
  silently corrupt `source_gen`'s process-pinned `rootPackageName`.

## Consequences

- Adding a generator means a shim under `dart/ext/`, following the contract in
  `docs/ext.md`.
- The worker saves VM startup, not analysis: each request pays for its own
  analysis context.
