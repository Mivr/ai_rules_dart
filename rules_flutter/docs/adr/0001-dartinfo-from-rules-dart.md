---
status: accepted
unenforceable: "No registered metric counts FlutterInfo constructor call sites."
---

# 0001. Consume DartInfo from rules_dart; keep Flutter metadata in FlutterInfo

## Decision

A Dart library's identity and transitive closure are `DartInfo`, owned by
rules_dart. rules_flutter builds `DartInfo` only through rules_dart's
constructors (`dart_info`, `dart_info_no_package`, `dart_info_multi`,
`dart_analyzable_info_with_package`), as
`flutter/private/flutter_library.bzl:3-4` shows.

Flutter metadata lives in `FlutterInfo`. It is declared in
`flutter/providers.bzl:254` and built only through `flutter_info()`
(`flutter/private/flutter_info.bzl:262`). That function has one constructor
call, at `flutter/private/flutter_info.bzl:319`.

## Alternatives ruled out

- **A Flutter-shaped library provider with its own closure.** Two providers
  describing one library drift apart. `DartAnalyzableInfo` shows how a second
  view is kept honest: `flutter/private/flutter_library.bzl:477` adds
  `sky_engine` to the analyzer's closure and leaves `DartInfo` untouched, so
  compile inputs do not change.
- **Adding fields to `DartInfo` from rules_flutter.** rules_dart owns that
  schema (`ai_rules_dart` `dart/providers.bzl:18`). A local field forks it.
- **Building `FlutterInfo` by hand in each rule.** `flutter/providers.bzl:254`
  notes that a field left unforwarded silently discards every dependency's
  contribution. A single merging constructor prevents that.

## Consequence

A new Flutter channel is a change to the `FlutterInfo` declaration and to
`flutter_info()`. A new field of Dart library identity belongs in rules_dart.
rules_flutter must not add a `DartInfo(` call or a second library provider.
