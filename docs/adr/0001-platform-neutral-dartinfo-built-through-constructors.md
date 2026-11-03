---
status: accepted
enforced_by: [arch.missing_obligations]
---

# 0001. `DartInfo` is platform-neutral and built only through its constructors

Source: `docs/ARCHITECTURE.md`, Provider Design ("DartInfo contains zero
Flutter concepts" and "Read `DartInfo` directly; build it through
`dart_info()`").

## Context

`DartInfo` is the provider every Dart library publishes, and rule sets outside
rules_dart produce it too: `rules_flutter`'s `flutter_library` and
`rules_dart_proto`'s `dart_proto_library`. Constructing it by hand means
enumerating every field and merging every transitive depset one at a time, so
each added field became a breaking change for every producer, and each had to
work out on its own how the new field merges.

## Decision

- `DartInfo` carries no Flutter, Android, iOS or Apple concept. A rule set
  built on rules_dart wraps or extends it from the outside and never modifies
  it.
- Code reads `DartInfo` directly but builds it only through the constructors
  in `//dart:utils.bzl`: `dart_info()` for a target that contributes a
  package, `dart_info_no_package()` for a target that ships no package of its
  own, and `dart_info_multi()` for a target that owns several packages at once
  (one `dart_library` merged over a pub dependency cycle). Each takes what the
  target contributes itself and merges its dependencies' closures internally.
- The only call to the `DartInfo` constructor is in
  `dart/private/dart_info.bzl`, where those constructors live.

## Alternatives ruled out

- A field per platform on `DartInfo` (a Flutter asset list, an Android or iOS
  setting): it would make the base rule set know about its extensions.
- Hand-built `DartInfo(...)` in a rule, here or downstream: a missing field's
  correct fix (forward the dependencies' values) and its tempting fix (declare
  it `depset()`) look identical in a diff, and the second silently drops every
  dependency's contribution at that boundary.

## Consequences

- A new `DartInfo` field is a change to one function, not to every producer.
- Platform state lives in a provider of the rule set that needs it.
- `//dart/tests:architecture_invariants_test` fails when a `DartInfo` field
  name contains `flutter`, `android`, `ios` or `apple`, or when a production
  `.bzl` outside `dart/private/dart_info.bzl` calls the constructor.
- The same hazard applies to copying a `DartPackageInfo` with a field
  overridden, which is why that goes through one internal
  `derived_package_info()`.
