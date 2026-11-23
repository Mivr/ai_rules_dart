# iOS real-plugin matrix (POD-2, POD-11)

This workspace pins fourteen real Flutter plugins and records what the pinned
rules_flutter checkout does with each one today in both SwiftPM mode (POD-2)
and CocoaPods mode (POD-11). It turns the design's "today" column into a
measurement, so a change that fixes or breaks a real plugin fails a gate
instead of going unnoticed.

`pubspec.yaml` pins the versions; `pubspec.lock` is resolved with the pinned
Flutter toolchain, and every hosted entry carries its sha256. The SwiftPM-mode
`flutter.pub` hub is named `deps`, so its spoke is `@deps__<plugin>`.
The CocoaPods-mode hub is named `deps_pods` (`ios_podfile_lock = "//:Podfile.lock"`),
so its spoke is `@deps_pods__<plugin>`.

## Fetch mode (Linux)

### SwiftPM mode (`run_matrix.py`)

```sh
bazel --max_idle_secs=60 query @deps__url_launcher_ios//:all
python3 run_matrix.py            # --mode fetch is the default
python3 run_matrix.py --self-test
```

Fetch mode reads `expected.json` and runs `bazel query @deps__<plugin>//:all`
once per pinned plugin. An `ok` entry needs exit 0. A refusal entry needs a
non-zero exit and its substring in the combined output. It prints one
`PASS`/`FAIL` line per plugin and a summary, and exits 1 on any mismatch.
`--self-test` exercises the comparator with fake outcomes and needs no Bazel,
network or workspace.

`expected.json` is the contract's data: when a later item fixes a refusal, edit
its entry there; do not add plugin names to the runner.

Because Android Gradle evaluation is deferred to the lazy Android repository,
the spoke query evaluates only the Apple layer. Seven plugins (`firebase_core`,
`firebase_auth`, `cloud_firestore`, `firebase_messaging`, `google_sign_in_ios`,
`sentry_flutter`, and `stripe_ios`) refuse because the hub sets no
`swift_package_resolved`. The other seven resolve cleanly (`ok`). The deferred
Android Gradle refusal is checked by `check_android_refusal.sh` when building
an Android target (`@deps__google_mlkit_commons//android:lib`).

### CocoaPods mode (`run_pods_matrix.py`)

```sh
bazel query @deps_pods__url_launcher_ios//:all
python3 run_pods_matrix.py               # --mode fetch is the default
python3 run_pods_matrix.py --mode fetch
python3 run_pods_matrix.py --self-test
```

Fetch mode reads `expected_pods.json` and runs
`bazel query @deps_pods__<plugin>//:all` once per pinned plugin. An `ok` entry
needs exit 0. A refusal entry needs a non-zero exit and its case-sensitive
substring in the combined output.

`Podfile.lock` covers the thirteen podspec-shipping plugins in `pubspec.lock`
(excluding `sentry_flutter`, which ships no podspec and falls back to
`darwin/sentry_flutter/Package.swift`). Four engine-only plugins
(`image_picker_ios`, `webview_flutter_wkwebview`, `url_launcher_ios`, and
`permission_handler_apple`) resolve cleanly (`ok`), nine plugins refuse with
Message 11 naming the unresolved pod and locked version (`firebase_auth` fails
on `Firebase/Auth` after resolving sibling `firebase_core`), and
`sentry_flutter` falls back to its SwiftPM manifest and refuses because
`deps_pods` sets no `swift_package_resolved`.

`expected_pods.json` records these measured results. When a later item resolves
a pod dependency, edit its entry in `expected_pods.json`.

`--self-test` exercises fetch and build comparison logic offline (including
refusal matching, case sensitivity, `RECORD` handling for ungated builds, and
passing `--platforms=@rules_flutter//flutter/platforms:ios_arm64`), and runs as
`:run_pods_matrix_test` under `bazel test //...`.

## Build mode (macOS)

### SwiftPM mode (`run_matrix.py`)

```sh
python3 run_matrix.py --mode build
```

Build mode reads the plugins `expected.json` records as `ok` and builds each
spoke's iOS device library, one at a time, for an explicit iOS platform:

```sh
bazel --max_idle_secs=60 build --platforms=@rules_flutter//flutter/platforms:ios_arm64 --ios_multi_cpus=arm64 @deps__<plugin>//:<plugin>_apple_ios
```

The platform and CPU flags live in `run_matrix.py`, so the offline self-test
sees the exact build command; `.bazelrc` and the workflow pass none.

`build_expected.json` names the builds that gate the step today. An entry maps
a plugin to `ok` to require exit 0; any other value is a case-sensitive
substring of a compiler diagnostic such as `<file>:<line>:<col>: error:`,
which requires a non-zero exit and rejects a Bazel `ERROR:` analysis refusal.
The single entry, `image_picker_ios`, maps to `ok`: it requires exit 0 now
that POD-1 builds its `image_picker_ios_objc` target alongside its Swift
target. A failing build prints its command and the last 30 lines of its output.
The other expected-ok plugins are printed as `RECORD` without gating yet; a
later item adds them to `build_expected.json` when their expected result is
known.

### CocoaPods mode (`run_pods_matrix.py`)

```sh
python3 run_pods_matrix.py --mode build
```

Build mode reads `expected_pods.json` and `build_expected_pods.json`, building
each fetch-`ok` spoke's iOS device library for the `ios_arm64` target platform:

```sh
bazel build --platforms=@rules_flutter//flutter/platforms:ios_arm64 @deps_pods__<plugin>//:<plugin>_apple_ios
```

`build_expected_pods.json` gates all four fetch-`ok` builds and must not be
empty (the runner exits at once when it is). `image_picker_ios`,
`webview_flutter_wkwebview`, `url_launcher_ios` and `permission_handler_apple`
all map to `ok`, which requires exit 0: all four fetch-`ok` plugins build
cleanly.

A plugin not listed in the file still prints `RECORD` without failing. Any
build that exits non-zero prints its `bazel build ...` command and the last 30
lines of its output; passing builds print neither.

Both modes first read `pubspec.yaml` and require `expected_pods.json` to have a
row for every non-SDK package under `dependencies:`. An unreadable
`pubspec.yaml`, one without plugins, or a missing row fails with a message
naming each missing plugin. `--self-test` covers the summary exit codes, the
failing-build output, the coverage check and the `file not found` gate offline.

## Regenerating the lock

```sh
bazel --max_idle_secs=60 run @rules_flutter//flutter:pub -- get
```

Never hand-edit `pubspec.lock`; the command above writes it with the pinned
toolchain and the sha256 of every archive.

## Release archive

This workspace is export-ignored in `.gitattributes`
(`/e2e/ios_plugin_matrix/ export-ignore`), so it does not ship in the release
archive. The export-ignore guard
(`//flutter/tests:e2e_export_ignore_guard_test`) finds it through its regular
`MODULE.bazel` and checks that line.
