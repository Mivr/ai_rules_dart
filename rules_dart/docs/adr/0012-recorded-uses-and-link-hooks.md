---
status: accepted
unenforceable: "No registered gate metric checks recorded uses or link hook execution; dart_link_hook unit and e2e tests cover them"
---

# 0012. Recorded uses come from the AOT compile; `dart_link_hook` is the link step

Source: `docs/ARCHITECTURE.md`, Design Decision 10.

## Context

A package's `hook/link.dart` decides what the package ships from how the
program uses it. Only the compiler knows those uses: `@RecordUse` on a `final
class` or a static method makes the AOT compiler record each constant instance
and each call's constant arguments that survive tree-shaking. Bazel names
every output before any action runs.

## Decision

- `dart_binary(record_use = True)` passes `--recorded-uses` to the `dart
compile` action that tree-shakes, in the `exe` and `aot-snapshot` modes, so
  there is no second compile. The `kernel` and `jit-snapshot` modes provide
  the empty `{}` the compiler writes when there is nothing to record (`kind =
"empty"`).
- `dart_link_hook` is a separate rule: it takes the uses from a
  `DartRecordedUsesInfo` or a JSON file and runs every `link_hook` its `deps`
  closure records, one action per package, on the exec toolchain's `dart`.
- The data assets a hook will emit are declared by id in `data_assets`; a hook
  emitting an undeclared asset, or missing a declared one, fails. Assets are
  provided as `DartDataAssetInfo`, without bundling paths.
- A hook whose package declares no assets still runs, as a validation output.
- Each hook runs alone.

## Alternatives ruled out

- A second compile to record uses.
- Failing a `kernel` or `jit-snapshot` binary that asks for recorded uses.
- Discovering hook outputs after the action runs, which Bazel does not allow.
- Passing assets between link hooks, or code assets in link input: the runner
  refuses a hook output that uses them rather than dropping it.

## Consequences

- Where an asset lands in an application is left to the bundler.
- Only a build hook (`hook/build.dart`), which rules_dart cannot run, still
  counts as an unreplaced hook that fails a consuming binary.
- Nothing but `dart_link_hook` runs a link hook, matching `dart run`, where
  only a release build links.
