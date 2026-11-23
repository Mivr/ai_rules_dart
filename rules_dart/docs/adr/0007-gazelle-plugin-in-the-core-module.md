---
status: accepted
unenforceable: "No registered gate metric checks that rules_go and gazelle stay non-dev dependencies or that //gazelle/dart loads downstream"
---

# 0007. The Gazelle plugin ships in the core module

Source: `docs/ARCHITECTURE.md`, Design Decision 5;
`ai-docs/performance/decisions.md` ("Leave the Gazelle plugin in the core
module").

## Context

The Gazelle plugin generates Dart BUILD files. Shipping it means depending on
`rules_go` and `gazelle`, which a downstream module only loads if those are
regular, not dev, dependencies.

## Decision

- `rules_go` and `gazelle` are non-dev dependencies, so `//gazelle/dart` is
  loadable from downstream modules. The full rationale is in a comment in
  `MODULE.bazel`.
- The Go SDK is fetched only when a target in `//gazelle/...` is built.
- The plugin supports the `gazelle:resolve` directive for explicit dependency
  overrides.

## Alternatives ruled out

- Moving the plugin to a separate module: it does not affect build
  performance enough to justify a breaking change for Gazelle users.
- Declaring `rules_go` and `gazelle` as dev dependencies, which would make
  the plugin unloadable downstream.

## Consequences

- Consumers resolve `rules_go` and `gazelle` in their module graph even when
  they never run Gazelle.
- Builds that touch no `//gazelle/...` target never fetch the Go SDK.
