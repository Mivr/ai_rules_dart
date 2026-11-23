---
status: accepted
unenforceable: "No registered gate metric checks that dart_fix writes back only is_source files or that dart_format stages what the check stages"
---

# 0010. Source rewriting: `dart_fix` and `dart_format` as run targets

Source: `docs/ARCHITECTURE.md`, Design Decision 8.

## Context

Automated fixes and formatting rewrite files in the workspace, which no Bazel
build action may do. They must also agree with the checks the `dart_analyze`
aspect runs (ADR 0009), or a rewritten file still fails the check.

## Decision

- `dart_fix` applies the `dart_analyze` aspect to its `target`; the aspect
  computes the fixes hermetically over the same staged project it analyzes, in
  the `dart_fix_fixes` and `dart_fix_manifest` output groups, and `bazel run`
  copies the result into the workspace.
- Only the target's own files that Bazel records as `is_source` are written
  back.
- `dart_format` is the `bazel run` counterpart of the format check. The build
  stages, with the aspect's own staging code (`stage_config_project`), exactly
  what the check stages around the sources; the runner copies that and each
  file named on the command line into a scratch project, formats there, and
  writes back the files that changed.

## Alternatives ruled out

- Relying on `dart fix`'s own generated-file heuristic, which matches
  `*.g.dart` and no other name.
- Formatting in place in the workspace, where `dart format`'s upward walk
  finds no package config to resolve a `package:` include.

## Consequences

- Codegen output stays resolvable to its importers without being editable.
- Both fix products can be inspected through their output groups without
  running a tool that rewrites sources.
- A change to the format check's staging must reach `dart_format` too, through
  the shared staging code.
