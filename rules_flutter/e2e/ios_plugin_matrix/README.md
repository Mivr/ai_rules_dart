# iOS real-plugin matrix (POD-2, POD-11)

This workspace pins fourteen real Flutter plugins and records what the pinned
rules_flutter checkout does with each one today in both SwiftPM mode (POD-2)
and CocoaPods mode (POD-11). It turns the design's "today" column into a
measurement, so a change that fixes or breaks a real plugin fails a gate
instead of going unnoticed: on Linux the workspace's spec asserts what each
spoke does, on macOS two runners build the spokes that resolve.

`pubspec.yaml` pins the versions; `pubspec.lock` is resolved with the pinned
Flutter toolchain, and every hosted entry carries its sha256. The SwiftPM-mode
`flutter.pub` hub is named `deps`, so its spoke is `@deps__<plugin>`.
The CocoaPods-mode hub is named `deps_pods` (`ios_podfile_lock = "//:Podfile.lock"`),
so its spoke is `@deps_pods__<plugin>`.

## Linux: the workspace's spec

`e2e.yaml` is the Linux half. Run it through the e2e runner, like every other
workspace (`bazel run //tools/e2e_runner -- --workspace=e2e/ios_plugin_matrix
--bazel=bazel` from the `rules_flutter` root; `e2e-linux-nightly` in
`flutter-full.yaml` does this). It runs `bazel test //...` (the lock build test
and the two runners' self-tests), then one command per pinned plugin and hub:

- A spoke whose Apple side resolves is queried (`bazel query
  @deps__<plugin>//:all`) and the query must succeed.
- A spoke the rules refuse is refused where an Apple build reaches it, not at
  fetch: `bazel build @deps__<plugin>//:<plugin>_apple_ios_unbuildable` must
  fail with the refusal's message. In SwiftPM mode seven plugins
  (`firebase_core`, `firebase_auth`, `cloud_firestore`, `firebase_messaging`,
  `google_sign_in_ios`, `sentry_flutter`, and `stripe_ios`) are refused because
  the hub sets no `swift_package_resolved`. In CocoaPods mode eight plugins are
  refused with the unresolved pod and its locked version in the message,
  `sentry_flutter` (which ships no podspec) with the SwiftPM reason, and
  `flutter_inappwebview_ios`, in both modes, because its podspec declares
  resources. Four plugins resolve in CocoaPods mode.
- A spoke has no Android targets (a plugin's Android side is built from the
  app's pinned Gradle model, see `docs/android-model.md`), so none of this
  evaluates an Android side.

When a later item fixes a refusal, edit its command in `e2e.yaml`: that file
holds the expected messages, and nothing else repeats them.

## Build mode (macOS)

### SwiftPM mode (`run_matrix.py`)

```sh
python3 run_matrix.py
python3 run_matrix.py --self-test    # offline; runs as :run_matrix_test
```

`expected.json` maps each pinned plugin to `ok` (its spoke resolves; the
macOS leg builds it) or `refused` (the spec above asserts why; nothing builds
it). The runner reads the plugins recorded as `ok` and builds each
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
python3 run_pods_matrix.py
python3 run_pods_matrix.py --self-test    # offline; runs as :run_pods_matrix_test
```

The runner reads `expected_pods.json` (`ok` or `refused`, as above) and
`build_expected_pods.json`, building each `ok` spoke's iOS device library for
the `ios_arm64` target platform:

```sh
bazel build --platforms=@rules_flutter//flutter/platforms:ios_arm64 @deps_pods__<plugin>//:<plugin>_apple_ios
```

`build_expected_pods.json` gates all four `ok` builds and must not be
empty (the runner exits at once when it is). `image_picker_ios`,
`webview_flutter_wkwebview`, `url_launcher_ios` and `permission_handler_apple`
all map to `ok`, which requires exit 0: all four `ok` plugins build cleanly.

A plugin not listed in the file still prints `RECORD` without failing. Any
build that exits non-zero prints its `bazel build ...` command and the last 30
lines of its output; passing builds print neither.

The runner first reads `pubspec.yaml` and requires `expected_pods.json` to have
a row for every non-SDK package under `dependencies:`. An unreadable
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
archive.
