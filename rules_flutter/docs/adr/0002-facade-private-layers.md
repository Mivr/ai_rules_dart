---
status: accepted
enforced_by: [bzl.layer.violations]
---

# 0002. Public facades load private code; private code never loads a facade

## Decision

The public surface is the 15 `.bzl` files directly under `flutter/`. Consumers
load only those. Facades load files under `flutter/private/`. Private files load
each other and `flutter/providers.bzl`, which is a leaf. Nothing in
`flutter/private/` should load a facade. Two existing exceptions are listed in
`docs/ARCHITECTURE.md` section 1. The Dart rule set is consumed through
`@rules_dart` and is never copied into this tree or loaded by a private path.
The evidence is in `docs/ARCHITECTURE.md` section 1.

## Alternatives ruled out

- **One flat `flutter/` directory with no private split.** Every helper becomes
  public, and every rename becomes a breaking change for consumers.
- **Private files loading facades for shared constants.** It is the shortcut
  that produced the two current exceptions:
  `flutter/private/flutter_integration_android_app.bzl:7` and
  `flutter/private/flutter_integration_test.bzl:65` load `//flutter:android.bzl`
  for two constants. Shared constants belong in `flutter/private/constants.bzl`.

## Consequence

A constant that a private file needs goes in `flutter/private/constants.bzl`,
not in a facade. The two exceptions stay listed in `docs/ARCHITECTURE.md`
section 1 until they are removed; a change must not add a third. The
`bzl.layer.violations` metric measures the layer assignment, which is the facade
and implementation split. It does not measure the rules_dart boundary, which ADR
0001 records.
