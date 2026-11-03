---
status: accepted
enforced_by: [perf.test_runfiles.files, perf.test_runfiles.bytes]
---

# 0014. Test runfiles carry an SDK subset, not the whole SDK

Source: `ai-docs/performance/decisions.md` ("Trim the SDK from test
runfiles", "SDK subsets fall back to the whole SDK").

## Context

Every `dart_test` ships its runfiles tree to the test sandbox. No test in this
repository runs `dart format` or `dart compile` itself, so the whole Dart SDK
in every test's runfiles is cost without use.

## Decision

- `dart_test` runfiles carry the toolchain's `runtime_files` subset: the SDK
  files a test needs at run time to run its compiled kernel.
- A test that runs SDK commands itself declares `@rules_dart//dart` in `data`,
  which brings the whole SDK.
- `compile_files` and `runtime_files` are optional on `dart_toolchain`; a
  toolchain naming neither, as rules_flutter's own may, gets `tool_files`.

## Alternatives ruled out

- The whole SDK in every test's runfiles.
- Making the subsets mandatory, which would break toolchains defined by other
  rule sets.

## Consequences

- A change that puts the whole SDK, or other unused compile-time artifacts,
  back into test runfiles raises the runfiles file and byte counts.
- A test needing an SDK command must ask for it in `data`.
