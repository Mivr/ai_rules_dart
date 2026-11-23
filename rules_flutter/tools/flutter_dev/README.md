# flutter_dev

Bazel builds the app; the stock `flutter` tool does everything after that: install, launch, hot
reload, hot restart, DevTools and debugging. `flutter_dev` is the small piece in between. It replaced
the rules' own copy of `flutter run`, `flutter_bazel`; see "Moving from `flutter_bazel`" below.

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
   debugger read these. Like `pub get`'s, the config also holds the `dev_dependencies` of
   `pubspec.yaml` and what they depend on (`flutter_test`, `flutter_lints`), which no application
   depends on: the first run builds them from the pub hub the app's `flutter` comes from (their
   package roots only, nothing compiled) and remembers them until the list changes.
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

The package config holds the `dev_dependencies` as well, so the analyzer resolves
`package:flutter_lints/flutter.yaml` and a test's `package:flutter_test` (`flutter analyze --no-pub`).

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

## Driving the app from a script

Agents and end-to-end tests drive a running app through the stock tool's `--machine` protocol:
`flutter_dev run --machine`, then `app.callServiceExtension` against the debug agent,
`app.restart` for reload and restart, `device.takeScreenshot`, and the `app.log` events. The agent
is a Dart-only plugin the app depends on; its README (`flutter/debug_agent/README.md`) lists every
command. `agent_e2e` (`tool/agent_e2e.dart`) runs all of them against `e2e/stock_dev_loop`, before
and after a hot restart and a hot reload:

```sh
cd e2e/stock_dev_loop
bazel build @rules_flutter//tools/flutter_dev
FLUTTER_DEV=$PWD/$(bazel cquery @rules_flutter//tools/flutter_dev --output=files 2>/dev/null)
bazel run @rules_flutter//tools/flutter_dev:agent_e2e -- --screenshot=/tmp/shot.png -- \
  "$FLUTTER_DEV" run --machine --bazel-target=//:app_x64 -d emulator-5554
```

## Moving from `flutter_bazel`

`flutter_bazel` (`//tools/dev_tool:flutter_bazel`) is gone. Run `flutter_dev` from the Flutter
project directory; options other than `--bazel*` are the stock tool's.

| `flutter_bazel` | Now |
|---|---|
| `run -t //:app` | `run --bazel-target=//:app` |
| `-d macos`, `-d android:emulator-5554`, `-d ios-simulator:<udid>`, `-d chrome` | `-d macos`, `-d emulator-5554`, `-d <udid>`, `-d chrome`: the stock tool's device ids |
| `-c <config>`, `--build-arg <arg>` | `--bazel-arg=--config=<config>`, `--bazel-arg=<arg>` |
| `--dart-define`, `--route`, `--start-paused`, `--no-hot`, `--profile`, `--machine`, `--web-port`, `--web-hostname`, `--web-launch-url`, `--web-header`, `--web-browser-flag` | the same stock flags |
| `--web-run-headless` | `--web-browser-flag=--headless=new` |
| `--no-devtools` | `--no-devtools` (stock) |
| `--wasm` | `--wasm` (stock), which compiles with the stock tool |
| `--single-apk`, `--vm-service-timeout`, `--allow-no-vm-service` | not needed: the stock tool installs the whole APK and waits for the VM service itself |
| `--watch`, `--no-watch` | none: reload with `r` in a terminal, or `app.restart` |
| `--web-viewport` | none; size the browser window with `--web-browser-flag=--window-size=<w>,<h>` |
| `build -t //:app` | `bazel build //:app` |
| `attach --debug-url <uri>` | `attach --bazel-target=//:app --debug-url <uri>` |
| the HTTP control channel (`/command`, `/commands`) | the stock `--machine` protocol on stdin and stdout: `app.callServiceExtension` with `ext.rules_flutter.<command>` (the app depends on the debug agent) |
| `app.tap`, `app.enterText`, `app.getText`, ... | `app.callServiceExtension` with `ext.rules_flutter.tap`, `enterText`, `getText`, ... |
| `app.pressKey` with a Playwright key name | `ext.rules_flutter.pressKey` with the key's DOM `code`, `modifiers` and `text`; not on the web |
| `app.dumpWidgetTree` | `ext.flutter.inspector.getRootWidgetTree` |
| `app.hotReload`, `app.restart` | `app.restart` with `fullRestart` `false` or `true` |
| `app.buildInfo` | none |
| `app.setViewport` (web) | none |
| `/sessions/<appId>/logs` | the `app.log` events |
| `/sessions/<appId>/screenshot/native` | `device.takeScreenshot` (Android and iOS; the stock tool has none for desktop) |
| native hot patching (`flutter_native_library.hot_patch`), relaunch on a native library change | none: a native change needs `flutter_dev run` again, which rebuilds, reinstalls and restarts |
