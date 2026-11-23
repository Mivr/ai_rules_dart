---
status: accepted
unenforceable: "No registered gate metric reads the supported Bazel versions; MODULE.bazel bazel_compatibility makes Bazel itself refuse older releases"
---

# 0003. Bazel 9.x only, bzlmod required

Source: `docs/ARCHITECTURE.md`, Design Decision 1.

## Context

rules_dart is consumed as a Bazel module and is designed to be extended by
`rules_flutter`. Supporting several Bazel major versions and the legacy
`WORKSPACE` setup would multiply the matrix every rule and repository rule has
to work under.

## Decision

rules_dart supports Bazel 9.x only and requires bzlmod. `MODULE.bazel`
declares `bazel_compatibility = [">=9.0.0"]`, and the repository ships no
`WORKSPACE` setup.

## Alternatives ruled out

- Supporting Bazel 8 or earlier alongside 9.x.
- A `WORKSPACE` (non-bzlmod) installation path with `*_dependencies()` macros.

## Consequences

- Rules and module extensions may use Bazel 9 APIs without fallbacks.
- A consumer on an older Bazel is refused at module resolution rather than
  failing later in analysis.
- CI and the BCR presubmit test Bazel 9.x only.
