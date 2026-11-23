---
status: accepted
unenforceable: "No registered metric counts bundle call sites for tests and apps."
---

# 0004. Tests and apps share one asset, font and shader bundle contract

## Decision

Each asset key is formed once, by the target that lists the asset
(`flutter/private/asset_keys.bzl:1-14`). Each entry is normalized by
`flutter/private/asset_uri.bzl`, and the key travels with the file in
`FlutterInfo`. One bundle step, `flutter_build_assets`
(`flutter/private/common.bzl:1504`), assembles the `flutter_assets` tree for
both tests (`flutter/private/flutter_test.bzl:290`) and apps
(`flutter/private/flutter_application.bzl:491`). Shaders follow the same route
through `flutter_compile_shaders` and the aspects in
`flutter/private/common.bzl`.

## Alternatives ruled out

- **Each rule computing its own keys.** Every platform bundle would have to
  agree by hand. `flutter/private/asset_keys.bzl` says the key is computed once
  so that every bundle, test trees included, agrees.
- **A bundle for tests that differs from the app bundle.** A test could pass
  with keys an app would not produce. Sharing the step keeps the two honest.
- **Raw entry text as the key.** `flutter/private/asset_uri.bzl:17-20` records
  that `a b.png` was bundled under `a b.png` where the engine asks for
  `a%20b.png`.

## Consequence

A new asset or shader feature belongs in the shared contract, not in one rule. A
key error shows up in test bundles as well as in apps, because both use the same
step.
