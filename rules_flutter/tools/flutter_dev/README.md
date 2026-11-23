# flutter_dev

Bazel builds the app; the stock `flutter` tool does everything after that: install, launch, hot
reload, hot restart, DevTools and debugging. `flutter_dev` is the small piece in between. It replaces
the rules' own copy of `flutter run` (`//tools/dev_tool:flutter_bazel`), which stays until it is
deleted.

```sh
bazel run @rules_flutter//tools/flutter_dev -- run --bazel-target=//:app -d emulator-5554
bazel run @rules_flutter//tools/flutter_dev -- attach --bazel-target=//:app -d emulator-5554
bazel run @rules_flutter//tools/flutter_dev -- run --bazel-target=//:app_flutter -d chrome
bazel run @rules_flutter//tools/flutter_dev -- ide --bazel-target=//:app
```

Run it from the Flutter project directory (the one with `pubspec.yaml`). Every argument that does
not start with `--bazel` goes to stock `flutter run` or `flutter attach` unchanged, so device
selection (`-d`), `--machine`, `--dart-define`, `--route`, `--start-paused` and the rest work as
there. Its own options:

| Option | What it does |
|---|---|
| `--bazel-target=<label>` | The app to build: an `.apk`, a desktop bundle, an `.app`/`.ipa`/`.zip`. For the web, any target with the `flutter_application` below it. Required. |
| `--bazel=<path>` | The Bazel executable. Default: `$BAZEL`, then `bazel`. |
| `--bazel-arg=<arg>` | An extra `bazel build` argument (`--bazel-arg=--config=android`). Repeatable. |
| `--bazel-flutter=<path>` | The stock `flutter` executable or its SDK root. Default: `$FLUTTER_ROOT`, then `flutter` on `PATH`. |
| `--bazel-allow-version-mismatch` | Run a stock tool whose version differs from the rules' Flutter. |
| `--bazel-no-restart` | No hot restart after the launch (see below). |

## What `run` and `attach` do

1. `bazel build -c dbg <target>` (`-c opt` with `--profile` or `--release`) with the
   `flutter_dev_files` aspect, which brings the application's package config and every generated
   Dart source onto disk. The outputs come from the build event file.
2. Write `.dart_tool/package_config.json` and `.dart_tool/package_graph.json`. Every package root
   is a `file:` URI: workspace packages are the source tree itself, external ones are Bazel's
   repositories, and `sky_engine` comes from the stock SDK. The stock tool, the analyzer and the
   debugger read these.
3. Link each generated Dart source (gen-l10n output, builder output) at its source path, where the
   stock generator would write it, pointing at the output Bazel writes in the top-level
   configuration. Exclude those paths from your BUILD globs and `.gitignore` them.
4. Hand over: `flutter run --no-pub --use-application-binary <the build> ...` or
   `flutter attach ...`. On the web, `flutter run -d chrome` compiles and serves the sources
   itself; Bazel's web output is not used.
5. Once the app has started, ask the stock tool for one hot restart. The app starts with the
   kernel Bazel compiled, whose library URIs no file on disk matches, so breakpoints cannot bind
   to it; after the restart it runs the stock tool's own compile, and breakpoints bind from the
   start (code in `main()` runs again). In `--machine` mode `app.started` is held back until the
   restart is done. The restart costs about one second on an Android emulator.

## After an edit

- Dart, in the app or in any workspace package: hot reload (`r`), as with stock `flutter run`.
- An input of a generator (an `.arb` file, a builder input): run `bazel build -c dbg <generator>`
  (the tool prints the labels), then hot reload. The link already points at that output.
- A project that keeps `l10n.yaml` gets the stock tool's own gen-l10n, which runs at start and
  before every reload and restart and writes `lib/l10n/*.dart` into the source tree (the same
  bytes Bazel writes). `flutter_dev` then does not link those files.
- Kotlin, Swift or any other native code: run `flutter_dev run` again. It rebuilds, and the stock
  tool reinstalls (the APK changed) and relaunches.

## What the stock tool writes into the project

With `--no-pub` (which `run` passes) the stock tool does not regenerate platform tooling, so it
writes only below `.dart_tool/` (`flutter_build/`, the plugin registrant it compiles in) and
`build/` (its compiler state), both ignored by a `flutter create` `.gitignore`. `flutter_dev`
writes `.dart_tool/package_config.json`, `.dart_tool/package_graph.json`, `.dart_tool/flutter_dev/`
and the links of step 3.

## IDEs

`flutter_dev ide --bazel-target=//:app` does the set-up of `run`, copies itself to
`.dart_tool/flutter_dev/flutter_dev`, and writes:

- `.vscode/launch.json` (when there is none; otherwise it prints the configurations): a `launch`
  and an `attach` configuration of the Dart extension with `customTool` set to that copy and the
  `--bazel*` options as `toolArgs`.
- `.run/flutter_dev_<target>.run.xml`, a Flutter run configuration for IntelliJ and Android Studio,
  and an SDK shim in `.dart_tool/flutter_dev/sdk`. The Flutter plugin there always runs
  `<Flutter SDK>/bin/flutter`, so set the project's Flutter SDK path to the shim: its
  `bin/flutter` is `flutter_dev`, which adds the `--bazel*` options it was set up with, and every
  other entry links to the real SDK. Commands other than `run` and `attach` go to the real SDK
  unchanged.

The package config holds the application's dependencies only. Its `dev_dependencies` are not in
it, so the analyzer cannot resolve `package:flutter_lints/flutter.yaml` or a test's
`package:flutter_test` from it.

## Which `flutter`

The stock tool recompiles the app with its own frontend server and `dart:ui`, so it must be the
Flutter version the rules build with; `flutter_dev` checks the version and refuses another. The
rules download the framework's source and the engine artifacts, but not a runnable `flutter`: that
needs `flutter_tools` compiled (from its own locked pub packages) and a `bin/cache` the tool can
write (its lock file, stamps, the artifacts it checks). Until the rules provide one, install the
same Flutter release next to them.

## Platforms

Tested on Linux with an Android emulator (x86_64) and Linux desktop. iOS (`.ipa` or `.app` of an
`ios_application`) and macOS (`.app`, or the `.zip` `rules_apple` writes) are wired the same way
and untested.
