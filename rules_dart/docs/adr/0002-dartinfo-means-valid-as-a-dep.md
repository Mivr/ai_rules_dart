---
status: accepted
enforced_by: [arch.missing_obligations]
---

# 0002. `DartInfo` means "valid as a dep"; executables publish `DartAnalyzableInfo`

Source: `docs/ARCHITECTURE.md`, Provider Design ("`DartInfo` means \"valid as
a dep\"; `DartAnalyzableInfo` means \"has Dart sources to analyze\"").

## Context

Every `deps` attribute in rules_dart, and in the rule sets built on it, gates
on `providers = [DartInfo]`, so which provider a target publishes decides
whether it can be depended on. Executables still need their entrypoint
analyzed, and their `main` lives outside every package's `lib/`, so no
`DartPackageInfo` can name it.

## Decision

- `dart_library` publishes `DartInfo`.
- `dart_binary`, `dart_test`, `dart_js_binary` and `dart_wasm_binary` publish
  `DartAnalyzableInfo` and no `DartInfo`. `DartAnalyzableInfo` nests a
  `DartInfo` built through the constructors (ADR 0001) rather than restating
  its fields, plus the executable's own entrypoint sources.
- Every label-typed `deps` attribute requires `providers = [DartInfo]`.
- The `dart_analyze` aspect accepts either provider; the `DartInfo` branch is
  permanent, which keeps `dart_proto_library` analyzable without adopting
  anything.

## Alternatives ruled out

- Executables returning `DartInfo`: Bazel has no negative provider constraint,
  so `dart_library(deps = [":some_binary"])` would silently become legal.
- A `deps` attribute without a provider requirement: any target, including a
  `filegroup`, would be accepted and fail later, far from the mistake.

## Consequences

- Naming an executable or any other target without `DartInfo` in `deps` fails
  analysis with Bazel's mandatory-provider error naming `DartInfo`.
- `//dart/tests:architecture_invariants_test` fails when `dart_library` stops
  publishing `DartInfo`, when one of the four executable rules publishes it or
  stops publishing `DartAnalyzableInfo`, when a `dart_library`, `dart_binary`
  or `dart_test` accepts a dependency without `DartInfo`, or when a production
  label `deps` attribute drops `providers = [DartInfo]`.
