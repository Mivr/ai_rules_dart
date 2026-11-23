# dart_build_runner_builders

One Dart package per builder S10 measures, plus one with all of them
(`combined`), with the sources of `e2e/build_runner` (`go_router_pkg` from
rules_flutter's). `builders.json` is what the pub hubs of those two locks write
(`@<hub>//build_runner:builders.json`), merged; `arguments.txt` passes it with
`-dart_build_runner_facts`.

Each package gets one BUILD file next to its `pubspec.yaml` with a
`dart_build_runner` whose `outs` are the files its sources name by `part`,
`import` or `export` and a builder writes: the same files `e2e/build_runner`
lists by hand and checks against stock `build_runner`. `json_ser`'s
`lib/other/not_generated.dart` has an annotation but no `part`, so nothing is
generated for it, as in a stock build.
