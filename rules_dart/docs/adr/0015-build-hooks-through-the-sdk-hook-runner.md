---
status: accepted
unenforceable: "No registered gate metric checks build hook execution; the build_hooks e2e workspaces of rules_dart and rules_flutter and the hook analysis tests cover it"
---

# 0015. A package's own build hook runs through the SDK's hook runner

Source: `docs/ARCHITECTURE.md`, Design Decision 13.

## Context

Packages with native code ship `hook/build.dart` (and `hook/link.dart`). A
stock build runs them with `package:hooks_runner` and puts the code assets
they report into the program's native-assets mapping. The rules used to run
none: a hand-written replacement per package (`//dart/ext/sqlite3`,
`//dart/ext/webcrypto`, the registry) stood in for a few, and any other
package with a hook failed the build or was declared away with
`ignore_hooks`.

## Decision

- Each package's build hook runs in one action (`DartBuildHook`) per package
  and target configuration, through `package:hooks_runner` at the version the
  SDK uses, pinned in the runner's own lock. Nothing of the hook protocol is
  re-implemented. The hook's own compile is a separate cached action
  (`DartHookCompile`).
- The action runs sandboxed and offline (`block-network`), with no `HOME` and
  an empty `PATH`, and its inputs are the package's own files, the files named
  in `hook_data`, and the C toolchain Bazel resolved for the target, passed in
  the hook input (small wrappers make a non-NDK toolchain's tools look like
  the `clang`, `ar` and `ld` that `package:native_toolchain_c` recognises).
- A hook gets its own `hooks.user_defines.<package>` slice of the workspace
  pubspec, as JSON, so an edit elsewhere in the pubspec reruns no hook.
- A hook that downloads fails with a message naming the package and the
  remedies. `hook_network` on the lock tag lets that one action use the
  network (`requires-network`).
- An app's or test's manifest (`native_assets.yaml`) and the bundle of its
  libraries come from one `DartNativeAssets` action over the closure's hook
  outputs and `dart_code_asset`s, written with `package:hooks_runner`'s own
  `KernelAssets`.
- Link hooks run through the same runner, where an app links
  (`dart_link_hook`).

## Alternatives ruled out

- Hand-written replacements per package: they cover only the packages someone
  wrote one for, and drift from the package's own hook.
- One action running every hook of the closure: any change would rerun all.
- Giving hooks the network by default.

## Consequences

- Build hooks run with linking disabled, so a code asset is never routed to a
  link hook.
- A package that is a member of a merged pub dependency cycle has no library
  of its own to run its hook in, and a binary reaching it fails.
- Cross-hook assets (`assetsForBuild`) are not passed between hooks.
- A hook that needs a tool the C toolchain does not provide (CMake, cargo)
  fails in its own action, naming what it lacks.
- On macOS and iOS hooks do not run yet, because nothing has run them on
  macOS CI: a hook action there fails, naming the package. `sqlite3`,
  `webcrypto` and `objective_c` keep their Bazel replacements on Apple OSes
  only (`//dart/private:apple_hook_replacements.bzl`, rules_flutter's
  `ext/objective_c`). This goes when build hooks are proven on macOS CI.
