---
status: accepted
unenforceable: "No registered gate metric checks the dart_analyze aspect's scope, output groups or options staging; its e2e workspaces test them"
---

# 0009. Analysis and the format check are an aspect

Source: `docs/ARCHITECTURE.md`, Design Decision 7.

## Context

Analysis and formatting are correctness checks that a developer should not pay
for on every `bazel run`, and Bazel and the IDE must agree on which
`analysis_options.yaml` governs a file.

## Decision

- `dart_analyze` (`//dart:analyze.bzl`) is an aspect applied from `.bazelrc`
  under `bazel test`. The analyzer and `dart format --set-exit-if-changed`
  are separate actions in their own output groups (`dart_analyze`,
  `dart_format`); `no-dart-analyze` and `no-dart-format` opt a target out of
  one each.
- It checks only the targets named on the command line, without propagating
  along `deps`, and only each target's own hand-written files.
- Options come from one `dart_analysis_config`, named by the
  `//dart:analysis_config` label flag, listing every `analysis_options.yaml`;
  all are staged at their workspace paths and the SDK's nearest-file rule picks
  one per file.
- Targets in other repositories are skipped.
- `dart_analysis_test` applies the same aspect through an attribute to targets
  a wildcard cannot name.

## Alternatives ruled out

- Analysis as a build step of every rule, which `bazel run` would pay for.
- Propagating the aspect along `deps`, which re-checks dependencies under the
  dependent's options.
- One options file chosen by rules_dart rather than by the SDK's own lookup.

## Consequences

- A repository chooses the checks it runs by the output groups its `.bazelrc`
  requests.
- A file is checked when its own target is named, so dependencies are checked
  in their own right.
- An options file's own diagnostics fail only targets with files beneath it.
