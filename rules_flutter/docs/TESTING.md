# Testing Guide

Complete instructions for testing rules_flutter changes. Run **all applicable sections** before considering work done.

> **Never run `bazel clean`** — it destroys the cache and causes long rebuilds.

> **Capture the whole run to a file, then read the file.** Anything long — `bazel
> test //...`, the e2e suite, a manual `flutter_dev run` — goes to a log that is
> inspected afterwards. Never watch one through a `tail`/`grep`/`head` filter on
> the live pipe: the filter has to be chosen before you know what went wrong, it
> keeps only the lines you already thought to ask for, and the output is gone once
> it has scrolled past. The failure is routinely somewhere other than the line you
> matched on.
>
> Redirect rather than pipe, so the exit status survives as well — a shell reports
> the *tail* of a pipeline, so `… | tee log` leaves `$?` at 0 no matter how the
> command exited:
>
> ```sh
> bazel test //... > /tmp/root-tests.log 2>&1; echo "exit=$?"
> grep -n 'FAILED\|ERROR' /tmp/root-tests.log   # afterwards, against the file
> ```
>
> If you must watch a run as it happens, `tee` to the file and read *that*
> afterwards — `cmd 2>&1 | tee log` — and take the status from `$pipestatus[1]`
> (zsh, this repo's shell) or `${PIPESTATUS[0]}` (bash), never from `$?`. The two
> are not interchangeable: zsh arrays are 1-indexed, so `${PIPESTATUS[0]}` there
> expands to the empty string rather than to a status, and a test for it being
> non-zero silently passes.

## 1. Root workspace

```sh
bazel test //...
```

### Proving analysis covers a file

`bazel test` runs `dart analyze` and the `dart format` check as rules_dart's
`dart_analyze` aspect (`.bazelrc`), over each target's own hand-written files:
a library's sources, and an executable's `[main] + srcs`. A clean run proves
nothing about a file until you have seen it go red. Nothing checks that the
target you believe owns a file actually carries it, so a file no checked target
owns passes exactly as quietly as a clean one. The aspect also never visits a
`manual` target, or one incompatible with the host, since `//...` does not
expand to either. Prove coverage by making a deliberate diagnostic appear — a
transient file whose only content is an unused import — and confirming the
build fails **at that file's own path**, then restoring and confirming green.

Which probe discriminates depends on the owning target's shape:

* **Target carries `srcs`** → drop the probe in as a new, *unimported* file.
  Unimported is what makes it proof: an imported one is reached through `main`'s
  own closure, so the target goes red whether or not `srcs` carries it.
* **Target is `main`-only** — a `main` and no `srcs`
  (`//tools/update_flutter_version`) →
  transiently repoint `main` at the probe; restoring must return it to green.
  The dropped-file form cannot discriminate here: a probe added to a `srcs` the
  committed target does not have goes red even if the `main` slot is never
  analyzed at all.

Place the probe at the full extent the coverage claims, not at its shallowest
point. A flat glob (`test/e2e/*.dart`) with a probe dropped at the top of
`test/e2e/` passes over the gap; only a probe in a *subdirectory* catches it —
a depth where a test `dart test` would discover and run can sit with nothing
analyzing it. A probe answers only for the depth and shape it was placed at.

The principle under all three: **the probe must exercise the same staging path
the committed target uses.** One that produces a diagnostic by some other route
proves the analyzer works, not that this target covers anything. This is not
specific to analysis — any probe meant to prove a check *can* fail has to fail
through the path the committed check actually takes.

### Never apply `dart fix` unreviewed

There is deliberately no `dart_fix` target in this repo. If one is ever added,
**the reviewed diff is the deliverable, not a green build** — never `bazel run`
it and take the result.

The reason: `avoid_redundant_argument_values` deletes `sourceRepository:` from
`Runfiles.create` call sites. That argument is a
`String.fromEnvironment('RUNFILES_SOURCE_REPO')` const supplied by the BUILD
file's `defines`, and **the analyzer receives no `-D` defines**, so it sees the
empty-string `defaultValue` and calls the argument redundant. The result
compiles and every unit test passes; it breaks runfiles resolution only for
downstream consumers, where nothing in this repo would notice.

**Any lint that reasons about a constant's value misfires the same way**, since
the analyzer never sees the build's defines. That is the general case, not one
bad rule.

### Language versions: unset, with pubspecs at the pinned SDK

No target in this repo states `language_version`, and none should without a
reason that requires it. Unset, a target is compiled, analyzed and
format-checked at the SDK's newest language version, and an entrypoint inside
a package takes that package's version.

That default is right only while every `pubspec.yaml` states the SDK this repo
pins as its `sdk:` lower bound (`^3.13.0` today). `dart format` run by hand or
by an IDE takes its version from that lower bound, through the
`.dart_tool/package_config.json` pub writes, while the format check (rules_dart's
`dart_analyze` aspect) formats at the SDK's newest. When the two differ, as
they did at Dart 3.13, which rewraps a long `typedef`, each reformats the
other's output.

So bumping the pinned Flutter/Dart SDK means raising every `pubspec.yaml`'s
`sdk:` lower bound, and the `sdks:` floor of its `pubspec.lock`, to the new
version in the same change, then reformatting whatever the new style moves.
The one exception is `flutter/private/gen_l10n/pubspec.yaml`, which matches
upstream `flutter_tools` exactly.

## 2. The dev loop

`flutter_dev` (`tools/flutter_dev`) builds with Bazel and hands the app to the stock `flutter`
tool. Its unit tests run with fake `bazel` and `flutter` executables and need no device:

```sh
bazel test //tools/flutter_dev/...
```

The end-to-end check needs a device and the stock tool of the rules' Flutter release
(`flutter_dev` refuses another). `agent_e2e` starts `e2e/stock_dev_loop` with
`flutter_dev run --machine` and drives it the way an agent does: every
`ext.rules_flutter.*` command of the debug agent through `app.callServiceExtension`, the widget
tree, the example's own plugin extension, and `device.takeScreenshot` where the device has one;
then a hot restart and a hot reload, and all of it again. It prints a JSON report and exits 1 when
a check failed.

```sh
cd e2e/stock_dev_loop   # Android also needs .bazelrc.user with the SDK and NDK
bazel build @rules_flutter//tools/flutter_dev
FLUTTER_DEV=$PWD/$(bazel cquery @rules_flutter//tools/flutter_dev --output=files 2>/dev/null)
bazel run @rules_flutter//tools/flutter_dev:agent_e2e -- --screenshot=/tmp/shot.png -- \
  "$FLUTTER_DEV" run --machine --bazel-target=//:app_x64 -d emulator-5554
xvfb-run -a bazel run @rules_flutter//tools/flutter_dev:agent_e2e -- -- \
  "$FLUTTER_DEV" run --machine --bazel-target=//:app_linux -d linux
```

## 3. E2E workspaces (automated)

Run `bazel test //...` in each workspace. All non-manual tests run automatically.

```sh
cd e2e/smoke && bazel test //...
cd e2e/dual_hub && bazel test //...
cd e2e/hello_world && bazel test //...
cd e2e/codegen && bazel test //...
cd e2e/ffi_example && bazel test //...
cd e2e/ffi_plugin_example && bazel test //...
cd e2e/plugin_example && bazel test //...
cd e2e/macos_example && bazel test //...
cd e2e/ios_example && bazel test //...
cd e2e/multi_window_example && bazel test //...
cd e2e/android_example && bazel test //...
cd e2e/web_example && bazel test //...
cd e2e/integration_web && bazel test //...  # Linux-only (hermetic chrome-headless-shell)
cd e2e/integration_linux && bazel test //...  # Linux-only (hermetic Xvfb + GTK3/Mesa runtime)
cd e2e/integration_android && bazel test //...  # Linux-only with /dev/kvm (hermetic headless Android emulator)
cd e2e/integration_ios && bazel test //...  # macOS-only (iOS simulator); Linux runs the portable Dart-side build and analysis tests only
cd e2e/linux_example && bazel test //...    # Linux-only (target_compatible_with)
cd e2e/cross_compile_example && bazel test //...    # Linux-only (target_compatible_with)
cd e2e/windows_example && bazel test //...  # Windows-only (target_compatible_with)
```

**Platform notes:**
- macOS-only targets (macos bundle tests, ios_example) are skipped on other platforms via `target_compatible_with`.
- Linux-only targets (linux bundle tests, linux_example) are skipped on macOS/Windows.
- Windows-only targets (windows_example) are skipped on macOS/Linux.
- `android_example` and `hello_world` (Android targets) require `ANDROID_HOME` to be set to the Android SDK path (e.g. `export ANDROID_HOME=$HOME/Library/Android/sdk` on macOS) and `ANDROID_NDK_HOME` to the NDK path (e.g. `export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/<version>`, the versioned directory, not its `ndk/` parent). Any workspace that registers the host NDK toolchain needs both even for non-Android targets, because toolchain resolution fetches the repository. In a `.bazelrc` these need `--repo_env`, not `--action_env` — repository rules never see `--action_env`. `e2e/min_versions` is the exception: it downloads its Android SDK and NDK from pinned, checksummed Google archives, so it needs neither variable. Its Android leg is Linux-only (`target_compatible_with`), so macOS skips that leg and runs the Apple legs without an NDK.
- A plugin's or AAR's `<uses-permission>` (e.g. `record_android`'s RECORD_AUDIO) reaches the APK without `--merge_android_manifest_permissions`: `flutter_android_app` lifts library permissions into the app's manifest itself, and no e2e workspace sets the flag, so the suite shows it is not needed. `plugin_example`'s `verify_android_apk_test` and `glass_app:verify_glass_apk_test` check it.
- `flutter_android_app` merges `android/app/src/debug/AndroidManifest.xml` (where `flutter create` declares `android.permission.INTERNET`) into `-c dbg` APKs only, mirroring Gradle's variant merge. Debug APKs therefore host the Dart VM service out of the box; release APKs stay permission-free. `plugin_example`'s and `hello_world`'s flutter-create manifests are kept pristine to cover this path; `android_example` declares INTERNET in its hand-written `src/main` manifest and has no variant manifests, covering the no-op path. `verify_android_apk_test` in `plugin_example` is mode-aware: it asserts INTERNET present + `kernel_blob.bin` under `-c dbg`, and INTERNET absent + `libapp.so` in default (release) builds.
- Android builds need no platform flags: `flutter_android_bundle` transitions the application to the Android platform matching its `android_abi`, and packaging hard-fails on any non-ELF native library. `verify_android_apk_test` in `e2e/android_example` asserts every packaged `.so` is ELF with the ABI's machine type, and that every androidx class the engine needs at runtime (including the profileinstaller → concurrent-futures → listenablefuture chain) is defined in the APK's dex — so a missing runtime dep fails in CI without an emulator.
- If Xcode beta causes `local_config_xcode` errors, add `--repo_env=DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **After an Xcode upgrade**, a workspace that has not built since can fail with
  `Running '…/xcode-locator <old version>' failed with code 1 … indicates that
  Xcode version <old> is not available` while `xcode-locator`'s own output in the
  same message lists the new one. Each workspace caches its own
  `local_config_xcode`, so this hits whichever ones are stale and not the rest.
  `bazel fetch --configure` refreshes `apple_support`'s copy but not
  `bazel_tools`'s, which is the one in the error; invalidate that repo (never
  `bazel clean`) and rebuild:
  ```sh
  ob=$(bazel info output_base)
  rm -rf "$ob/external/bazel_tools+xcode_configure_extension+local_config_xcode" \
         "$ob/external/@bazel_tools+xcode_configure_extension+local_config_xcode.marker"
  ```
- **After a Dart SDK upgrade**, `dart run` inside a workspace whose packages
  have native-asset build hooks fails outright:
  ```
  Can't load Kernel binary: Invalid kernel binary format version (expected 130, found 127).
    Building assets for package:objective_c failed.
  Running build hooks...Error: Running build hooks failed.
  ```
  The hook is compiled once to
  `<workspace>/.dart_tool/hooks_runner/<pkg>/<hash>/hook.dill` and that cache is
  not keyed by SDK version, so the newer VM is handed the older kernel. Only
  `e2e/plugin_example` has such a package today (`objective_c`, via the darwin
  plugins). Delete the cache — it is gitignored and regenerated:
  ```sh
  rm -rf e2e/plugin_example/.dart_tool/hooks_runner
  ```
  A `dart run` launch with `workingDirectory` set to an e2e workspace makes the
  SDK build *that workspace's* hooks before the tool's `main` runs at all, so
  the process dies before `daemon.connected`. The hook's actual error is in
  `<workspace>/.dart_tool/hooks_runner/<pkg>/<hash>/stderr.txt`.
- `cross_compile_example`'s only test target is `cross_linux_build_test`, a
  `build_test` over `:cross_linux` with `target_compatible_with` Linux: Linux
  CI executes the cross-compiled bundle build with `bazel test //...`, while
  on macOS the test skips itself (there is no Linux test toolchain on that
  host) and the cross-compile flow stays `bazel build :cross_linux`. Its
  `.bazelrc` pins `--platforms=linux_x64` for every command. The analysis and
  format checks are an aspect, not tests, and that workspace enables it under
  `build`, so one command covers the cross-compiled bundle and the checks:
  ```sh
  cd e2e/cross_compile_example
  bazel build //...
  ```

### What the automated e2e tests cover

| Workspace | Key tests |
|-----------|-----------|
| smoke | Toolchain resolution for all platforms; custom-release (`3.47.70`) toolchain with checksum-verified fetch; offline (`local_path`) toolchain from the checked-in `fake_sdk` tree |
| hello_world | Kernel, AOT, application, and per-platform bundle builds; flutter_test |
| codegen | Per-file and aggregate custom generators (`dart_binary` + `run_binary`), generated code in dependency packages, hot-reload-with-codegen |
| build_runner | `dart_build_runner` over a Flutter package (go_router_builder) with a `sky_engine` SDK summary; each generated file diffed against stock `build_runner` output |
| ffi_example | Both FFI mechanisms — Native Assets (`add_plugin`, `@Native` asset-id bind) and `native_deps` (`mul_plugin`, conventional-path open) — bundle structure on macOS/Linux plus manual runtime proof on iOS simulator and macOS |
| ffi_plugin_example | FFI plugin build + macOS/Linux bundle structure with `libmultiply.dylib`/`.so` |
| plugin_example | Real pub.dev plugins (`path_provider`, `url_launcher`, `package_info_plus`) plus the hand-written `:greeting_plugin` regression case; per-platform bundle builds; web plugin assertions via the e2e suite; macOS runtime verifier asserting the four plugin-result strings. See **Plugin verification matrix** below. |
| macos_example | Full macOS app build + bundle structure verification (Info.plist, ObjC symbols, framework linkage, AOT dylib, flutter_assets, and a native library built in a subdirectory of its package landing flat at `Contents/Frameworks/libsub.dylib`) |
| ios_example | iOS app build (requires Xcode) |
| web_example | Web app builds (dart2wasm + dart2js) from the project's `web/` directory, and its templating (`custom_boot:verify_templating_test`) |
| integration_web | End-to-end web `flutter_integration_test` running a real counter + asset app in hermetic `chrome-headless-shell` |
| integration_linux | End-to-end Linux desktop `flutter_integration_test` running a counter + asset app and a native C++ method-channel plugin under hermetic `Xvfb` + GTK3/Mesa `llvmpipe` |
| integration_android | End-to-end Android `flutter_integration_test` running a counter + asset app and a Kotlin method-channel plugin in a hermetic headless Android emulator with KVM |
| integration_ios | End-to-end iOS simulator `flutter_integration_test` running a counter + asset app and a Swift method-channel plugin on a booted simulator (macOS-only targets skip elsewhere; the Dart-side build and analysis tests run everywhere). Each test gets a distinct bundle id (`com.example.<package path>.<name>.<label hash>`), a per-run harness token, and the `exclusive` tag, so simulator runs cannot collide |
| multi_window_example | Multi-window macOS + multi-scene iOS builds with FlutterEngineGroup; macOS bundle verification |
| android_example | Android APK build (3 approaches: flutter_android_app, Bazel-generated manifest, custom manifest) + APK content verification + web build |
| linux_example | Linux desktop app (2 approaches: flutter_linux_app, Bazel-generated runner) + bundle structure verification |
| windows_example | Windows desktop app (3 approaches: flutter_windows_app, Bazel-generated runner, custom cc_binary) + bundle structure verification |

### Plugin verification matrix

`e2e/plugin_example` exercises real pub.dev plugins — `path_provider` (federated, SwiftPM Apple, **jnigen Android** — path_provider_android ≥ 2.3 calls Java through `package:jni`, whose C support library `libdartjni.so` is built from source by the bundled `ext/jni` overlay and packaged at `lib/<abi>/` — pure-Dart Linux/Windows), `url_launcher` (federated, SwiftPM Apple, Kotlin Android, real C++ Linux/Windows, web Dart), `package_info_plus` (monolithic, every platform including web), `audio_session` (curated `ext/` overlay), and `record_android` 1.5.1 (Android-only federated implementation used without its umbrella — regression case for a plugin that ships `android/src/main/res/` resources referenced as `R.drawable.ic_mic` and declares **no** Gradle dependencies, compiling purely against the embedding's exported androidx classpath) — plus the hand-written `:greeting_plugin` (regression case for pure-Bazel-deps plugins). `lib/main.dart` resolves a string from each plugin and renders + emits them on a single `plugin_example_results …` log line. Each platform's e2e check asserts the line is correct; empty/null/error content fails loudly.

| Assertion | Source | Expected |
|---|---|---|
| `appName=…` | `PackageInfo.fromPlatform()` | `Plugin Example` on macOS/iOS (from `CFBundleName` in the generated Info.plist), `plugin_example` on web (from the auto-generated `version.json`'s `app_name`). Failure means the `package_info_plus` registrant didn't fire on that platform. |
| `documentsPath=…` | `getApplicationDocumentsDirectory().path` (`kIsWeb`-guarded) | `/Users/…` on macOS, `/var/…` on iOS, `/home/…` on Linux, `C:\Users\…` on Windows, `/data/user/0/…` on Android, `web: not supported` on web. |
| `tempPath=…` | `getTemporaryDirectory().path` (`kIsWeb`-guarded) | Absolute path with the platform-appropriate prefix; web shows `web: not supported`. |
| `launchOk=launch ok` | `canLaunchUrl(Uri.parse('https://flutter.dev'))` | Exact `launch ok` on macOS/iOS/Linux/Windows/web. On Android the correct value is `launch denied`: `canLaunchUrl` is subject to package visibility and the app declares no `<queries>` for https VIEW intents (flutter create output ships untouched). Either way the channel responded — an `error:` value means the `url_launcher` registrant didn't fire. |
| `greeting=Hello from GreetingPlugin!` | `//greeting_plugin:greeting_plugin` (regression case) | Exact match. |
| `recordHasPermission=…` | `MethodChannel('com.llfbandit.record/messages')` `create` + `hasPermission(request: false)` | `has=true` on Android (`verify_android_app_test` grants RECORD_AUDIO via `adb shell pm grant` first, which itself fails if the plugin's manifest didn't merge); `not supported` everywhere else. An `error:` value means the `record_android` registrant didn't fire or its resources failed to compile. |

| Platform | Where the assertion runs |
|---|---|
| macOS | `:verify_macos_app_test` (manual stdout check). |
| iOS Simulator | Manual: `flutter_dev run` on a booted simulator, and read the `plugin_example_results` line. |
| Android | `:android_bundle_build_test` (build), `:verify_android_apk_test` (APK content: `libdartjni.so` present + ELF/ABI-valid, jni support classes in dex — runs in `bazel test //...`), `:verify_android_app_test` (manual: install on emulator/device, RESUMED + crash-buffer fail-fast, asserts the `plugin_example_results` logcat line reports a real `/data/user/0/…` path from path_provider — proves jnigen plugin registration end to end). |
| Linux | `:linux_bundle_build_test` (build only). Visual verification on the GCP VM is manual (see § Linux visual verification). |
| Windows | `:windows_bundle_build_test` (build only). Visual verification on the GCP VM is manual (see § Windows visual verification). |

A run is the dispositive end-to-end check per platform: if Native Assets are broken the app crashes before drawing, and if plugin auto-wiring is broken a `MissingPluginException` replaces the results line.

### Android plugin native source builds (externalNativeBuild)

Some pub packages compile C/C++ for Android via Gradle's
`externalNativeBuild` (CMake/ndk-build) — e.g. `package:jni`, whose
`libdartjni.so` every jnigen-based plugin loads with
`System.loadLibrary("dartjni")`. rules_flutter has no generic translation
for arbitrary Gradle native builds; instead:

1. A curated overlay reproduces the build with `cc_library` +
   `cc_shared_library` (compiled by the registered NDK toolchain via the
   Android bundle's platform transition) and ships the `.so` through
   `flutter_plugin.native_deps` behind a
   `select({"@platforms//os:android": …})`. The library flows through the
   existing transitive native-libs pathway into the bundle's
   `native_libs.jar` at `lib/<abi>/`, subject to the same ELF/ABI machine
   validation as every other packaged library. `ext/jni/1/` is the
   canonical example (note `shared_lib_name` must yield the exact filename
   `System.loadLibrary` resolves).
2. Packages declaring `externalNativeBuild` that no overlay handles fail
   the Android build at load time with a message pointing at
   `flutter.plugin_overlays` — never a silently incomplete APK.
   Non-Android platforms are unaffected (the check lives in the spoke's
   `android/` sub-package, loaded only via the hub's Android aggregator).

### Curated code assets (no authoring needed)

A pub package shipping a build hook is first checked against rules_dart's curated registry (`@rules_dart//dart/ext:registry.bzl`). Where rules_dart provides a Bazel replacement — `sqlite3` today — `flutter.pub()` attaches it to that package automatically, so an app depending on `drift` gets `libsqlite3` without naming it and without an overlay. `e2e/ffi_example` covers this end to end; its `verify_*_runtime_test` targets assert the library actually loaded.

A package with a hook that *nothing* replaces is recorded, and `flutter_application` fails when it reaches one — the alternative is a clean build whose `*.native_assets.json` is one entry short and which dies at runtime on an unresolved `@Native` symbol. Two ways out: write an overlay (below), or declare the hook irrelevant with `flutter.pub(ignore_hooks = ["<pkg>"])` when the package's native code is genuinely unused in this build.

### Native Assets overlay authoring

Pub packages that ship a `hooks/build.dart` Dart-Native-Assets build hook (e.g. `package:objective_c`) and have no curated entry get translated to Bazel-native equivalents under `ext/<pkg>/<major>/BUILD.bazel.tpl`. The template is loaded by `flutter_pub_package` for any spoke whose package name + major version matches.

Template substitutions: `{HUB_NAME}` (the user's `flutter.pub(name = ...)`), `{PKG}` (the package name), `{VERSION}` (the resolved version), `{LANGUAGE_VERSION}` (derived from the package's own `environment.sdk`), and `{DEPS}` (the package's dependencies, as spoke labels, intersected with the lock).

A hub consults the root module's `flutter.plugin_overlays` roots first, then its own module's roots: an overlay a dependency registers never replaces the BUILD files of the root's packages (or another module's hubs). Put an app-local fix in the root module.

Substitution rewrites comment text too, so a comment that names a placeholder gets rewritten along with the code — write `HUB_NAME`, not `{HUB_NAME}`, in prose.

Two of those are mandatory, and the repo rule fails the fetch if a template writes the value out by hand instead:

* `{LANGUAGE_VERSION}` — the package's `environment.sdk` is the only place its language version is declared.
* `{DEPS}` — the package's pubspec is the only place its dependencies are declared, and deriving them is also what keeps a template from naming a repo the hub never created.

Both exist because a template directory serves a whole version range, so a hand-written copy drifts on the package's next release with no build error to catch it. `objective_c` 9.5.0 is the worked example: its hook stopped using `native_toolchain_c`, so the package dropped it from `dependencies`, the lock stopped carrying it, the hub stopped creating the spoke — and `ext/objective_c/9/`, which serves all of 9.x, was still asking for `@<hub>__native_toolchain_c`. Consumers got an unknown-repo error naming neither `objective_c` nor the overlay.

For the same reason, prefer a `glob()` over a named source file when the file's existence varies across the range the directory serves — `test/util.c` in the `objective_c` overlay, which 9.5.0 deleted.

Procedure:

1. Locate the package's hook source under `~/Library/Caches/bazel/_bazel_<user>/.../external/<hub>__<pkg>/hook/build.dart`. Read what it builds (file glob, link mode, target platforms, copts).
2. Reproduce the build with `cc_shared_library` + `objc_library` (Apple) / `cc_library` (other platforms). Set `shared_lib_name` to something *different* from the bundle filename — `flutter_native_asset` symlinks the cc output to `<bundle_filename>` in its own package, and matching names collide.
3. Wrap the output in `flutter_native_asset(name = "<pkg>_native_asset", asset_id = "package:<pkg>/<basename>", link_mode = "dynamic_loading_bundle", library = ":_<pkg>_dylib", bundle_filename = "<basename>")`, constrained to the supported platforms with `target_compatible_with`. Platforms that need a different `bundle_filename` (`lib<x>.so`, `<x>.dll`) get their own target; platforms that agree on every attribute share one.
4. Hang a `flutter_plugin(name = "<pkg>", platforms = [], native_assets = select({...}))` over them. Even though the package is "pure Dart" from pub's perspective, the empty-`platforms` plugin shape is what carries the native-assets entry into `FlutterInfo` for the application's manifest. The `select()` is what decides which asset targets an application sees: list exactly the ones that belong to the platform being built, and `//conditions:default: []` for the rest. Two targets claiming the same `asset_id` in one build fail analysis.
5. Drop the template at `ext/<pkg>/<major>/BUILD.bazel.tpl`. The next `bazel run @rules_flutter//flutter:pub -- get` + Bazel build picks it up automatically.

If the build fails at runtime with `Couldn't resolve native function "<symbol>"`, the most common cause is the `cc_shared_library`'s `install_name` not matching the asset id's basename — set `user_link_flags = ["-Wl,-install_name,@rpath/<basename>"]` on Apple targets. See `ext/objective_c/9/BUILD.bazel.tpl` for the canonical example.

## 4. Manual tests

These require a GUI environment and are skipped by `bazel test //...`.

### macOS runtime smoke test

Launches the app, polls for a window, and verifies dimensions > 100x100. Catches window sizing bugs (e.g. the 1x32 collapsed-window bug).

It also reads the app's stdout for `macos_example_native sum=7 difference=3`, which `main()` prints only after calling into both bundled native libraries: `libadd.dylib` (built at its package root) and `libsub.dylib` (built at `vendor/lib/` in its package). The window check cannot see this on its own — a library that fails to load throws in `main()` before `runApp`, and the runner still opens its 800x632 window (measured with the library renamed out of reach).

```sh
cd e2e/macos_example
bazel test :verify_macos_app_test --test_tag_filters= --strategy=TestRunner=standalone
```

**When to run:** After any change to macOS runner code (`flutter/private/runners/macos/`) or to what the macOS bundle carries (`flutter_macos_application.bzl`).

**`System Events reports no windows for any process` can be the Bazel server, not your grant.** The test reads windows through System Events, which answers only a client macOS trusts with Accessibility. Measured 2026-09-18: in a workspace whose Bazel server had first been started by another program (the old dev tool), the test failed this way while `osascript -e 'tell application "System Events" to count processes'` answered from the same terminal. After `bazel shutdown` and a rerun from the terminal it passed. So check the `osascript` line first: if it answers, restart the server; if it does not, grant the terminal Accessibility.

### FFI runtime tests (iOS simulator, macOS, Linux, Windows)

Behavioral verification that both native-library mechanisms work at runtime:
`add()` binds via `@Native` asset-id resolution (`flutter_native_asset` →
`--native-assets` kernel manifest), `mul()` raw-opens its conventional path
(`native_deps`). The app writes
`ffi_example_result add(3,4)=7 mul(3,4)=12` to its temp dir; the tests read
it back (via `simctl get_app_container` on iOS).

```sh
cd e2e/ffi_example
bazel test :verify_ios_simulator_test --test_tag_filters= --strategy=TestRunner=standalone
bazel test :verify_macos_runtime_test --test_tag_filters= --strategy=TestRunner=standalone
# Linux (headless boxes need Xvfb; XAUTHORITY must pass through):
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 \
  bazel test :verify_linux_runtime_test --test_tag_filters= \
    --strategy=TestRunner=standalone \
    --test_env=DISPLAY --test_env=XAUTHORITY --test_env=LIBGL_ALWAYS_SOFTWARE
# Windows (needs a display adapter — on GCP create the VM with --enable-display-device):
bazel test :verify_windows_runtime_test --test_tag_filters= --strategy=TestRunner=standalone
```

**When to run:** After any change to native-assets manifest emission
(`flutter_native_assets.bzl`, `flutter_native_asset.bzl`), native-library
bundling (`flutter_ios_native_frameworks`, `flutter_macos_native_libs`), or
kernel compilation flags.

### macOS visual verification

Launches the app binary directly, captures stdout/stderr, takes a screenshot, and prints structured JSON output. The screenshot file can be opened for visual verification.

```sh
cd e2e/macos_example && bazel build :app
# Extract the app
mkdir -p /tmp/macos_app && unzip -oq bazel-bin/app.zip -d /tmp/macos_app
# Run the diagnostic
dart run ../../e2e/_macos_test/verify_macos_app.dart /tmp/macos_app/app.app "Flutter App"
```

**Over ssh, launch with `open`.** Running the app binary directly in an ssh
session, with no window-server session of its own, gives a 134x129 window off
the left edge of the screen, and `lifecycleState` stays null: the main window
never appears. `open -n /tmp/macos_app/app.app --args ...` gives a proper one.
(Found on a MacBook Air by the amorphous_ui session; not reproduced on a
machine with a logged-in desktop.)

### Hot reload / hot restart (manual)

Reload and restart are the stock tool's; what the rules decide is what it runs on (the APK or
bundle, the package config, the links to generated sources). After a change to those, run the
app with `flutter_dev run` and check by eye that an edit in the app, in another workspace package
and in a generated source (an `.arb` file, then `bazel build -c dbg <generator>`) shows after
`r`, and that `R` shows an edit inside `main()`. `agent_e2e` (§ 2) checks the agent commands
after a restart.

### Stale staged sources (a poisoned action cache)

An app package that mixes hand-written and generated sources is assembled into a
`*.pkgsrcs` tree artifact (rules_dart's `assemble_source_dir`, via bazel-lib's
`copy_to_directory`) so the Dart toolchain sees one real `rootUri`. That staged
tree can keep content from a superseded build **while the source tree is clean**,
and bazel will go on replaying it. It reads exactly like a broken checkout; it
is not one.

**Signature.** Two entry points, one cause:

- *Loud* — a compile error citing a path under
  `bazel-out/<config>/bin/<target>.<package>.pkgsrcs/…` quoting code that is not in
  the source file, with `git status` clean.
- *Quiet* — the staged content is stale but still valid, so the build is green, the
  reload reports success, and the app renders the old code. Nothing names a file.

Neither responds to `touch` (bazel invalidates on content digest, not mtime, so
rewriting identical bytes is a no-op) or to `bazel shutdown` (the action cache is on
disk, not in the server). Only the configurations you actually built are affected — a
`-c dbg` session leaves the `fastbuild` tree clean. But a package is staged once per
configuration, and the macOS runner adds min-OS-transitioned `*-ST-*` configs, so a
single session can leave several copies behind: check every one rather than assuming
plain `-c dbg`.

**Diagnose — diff the staged copy against its source.** For the loud variant the
error names the staged path; for the quiet variant, diff the file you just edited.
The build-emitted `app.package_config.json` carries each package's staged
`*.pkgsrcs` root; the package's source root is its directory in the workspace.

```sh
cd e2e/codegen

# Loud variant — the error names the exact staged path; diff that one file.
diff dep_part/lib/settings.dart \
  bazel-out/darwin_arm64-dbg/bin/app.dep_part.pkgsrcs/lib/settings.dart

# Quiet variant — nothing names a configuration, so check every staged copy.
for t in bazel-out/*/bin/app.dep_part.pkgsrcs; do
  diff -q dep_part/lib/settings.dart "$t/lib/settings.dart"
done
```

Any difference while `git status` is clean is this bug. Confirm with `--explain`:
in the poisoned state the copy action does not appear in the log at all, because it
is an action-cache hit — only the downstream compile re-runs, and fails identically
every time.

```sh
bazel build :app -c dbg --explain=/tmp/explain.log --verbose_explanations
grep pkgsrcs /tmp/explain.log   # poisoned: no output
```

**Fix — delete that one tree and rebuild.**

```sh
TREE=bazel-out/darwin_arm64-dbg/bin/app.dep_part.pkgsrcs   # the one the diff flagged
chmod -R u+w "$TREE" && rm -rf "$TREE"
bazel build :app -c dbg
```

`--explain` then reports `Executing action 'Copying files to directory
app.dep_part.pkgsrcs': action changed since cached execution.` **Do not reach for
`bazel clean`** (forbidden — see CLAUDE.md): removing one output directory forces
one action to re-run, where `bazel clean` discards the whole cache to repair a
single entry.

**Cause.** Bazel digests a source file when Skyframe evaluates its file state, but a
local action reads that file from disk when it *executes* — the macOS sandbox stages
symlinks to the live file, so `--spawn_strategy=sandboxed` does not close the gap.
Change the file in between and bazel records the action as `{inputs: pre-edit digest,
outputs: post-edit content}`. Restore the source to its pre-edit state and the
recorded inputs match *and* the recorded outputs match the stale tree on disk, so the
action is a cache hit from then on. The downstream compile failure is not cached, so
it re-runs against the stale tree and reproduces the same error forever.

Bazel names this hazard itself, in the help for `--guard_against_concurrent_changes`
(default `lite`): *"the cache may be polluted when a source file is changed while an
action that takes it as an input is executing."* That guard only checks inputs before
**remote-cache uploads**; this repo configures no remote or disk cache, so the local
action cache is unguarded.

This is not a rules_flutter, rules_dart, or bazel-lib bug, and not a property of
`copy_to_directory` or of tree artifacts — bazel does detect a tree artifact mutated
behind its back, warm server or cold, and re-runs the copy. The mechanism is a
per-action input-digest race and so is input-agnostic: no kind of input, generator
script or plain library source, is immune.

**Prevention — know the danger window.** Reload handling itself runs a build:
`refreshGenerated` invokes `bazel build` inside `app.hotReload`/`app.restart` for
codegen apps, and watch mode fires a debounced build on every on-disk edit. Never
revert a fixture edit until the build it triggered has finished. In `--machine` mode
the `app.hotReload`/`app.restart` **response** is that signal — the pipeline awaits
`refreshGenerated` before answering. Under `--watch`, wait for the reload-completed
event after each edit. Never revert on a timer.

**Upstream asks:**

1. *Bazel* — extend `--guard_against_concurrent_changes` to local action-cache
   writes, not only remote-cache uploads. The check that would have prevented this
   is already implemented; it just is not applied to the local cache.
2. *rules_dart* — add a staleness validation action inside `assemble_source_dir`, or
   expose a labelled handle to the assembled tree. The `.pkgsrcs` tree is an
   unlabelled sub-artifact of a helper function, so no consumer can write a bazel
   test that looks at it. A validation action taking both the staged tree and the
   source files as declared inputs would be sound by cache semantics — a poisoned
   copy leaves it with an input combination it has never cached, so it re-executes
   and fails loudly.

An on-disk sweep outside bazel is *not* a substitute: diffing every `*.pkgsrcs` tree
against its source root flags every target you simply have not rebuilt yet, which is
legitimate staleness rather than this bug.

### Linux visual verification (GCP VM)

Cross-compile a Linux debug bundle from macOS, deploy to a GCP VM, and verify the Flutter UI renders.

```sh
# 1. Cross-compile (requires LLVM toolchain — use cross_compile_example)
cd e2e/cross_compile_example && bazel build :cross_linux

# 2. Create a Linux VM
dart run tools/vm/create_linux_vm.dart flutter-linux-test

# 3. Deploy and verify
dart run tools/vm/deploy_bundle.dart flutter-linux-test e2e/cross_compile_example/bazel-bin/cross_linux

# 4. Clean up
gcloud compute instances delete flutter-linux-test --quiet
```

**When to run:** After any change to Linux runner code, engine selection, or bundle assembly.

**What the check actually asserts:** that a window titled with the bundle's
name (the built-in runner's default title; pass `--title` for another) appears
(not merely that some window exists — the Xvfb root window always does), and
that a capture of it differs from the blank display measured before launch. It
fails loudly if the runner dies on a missing library, or maps a window and
paints nothing.

**Three things the VM needs, all handled by `create_linux_vm.dart` and
`verify_linux_app.dart`** — each fails silently when missing:
- `libgtk-3-0` is **not** in the Ubuntu cloud image; without it the runner exits
  with `libgtk-3.so.0: cannot open shared object file`.
- Flutter's GTK embedder renders through EGL, which ignores
  `LIBGL_ALWAYS_SOFTWARE` and tries DRI3 — unavailable under Xvfb.
  `GALLIUM_DRIVER=llvmpipe` is what actually selects software rendering; without
  it the window appears and stays empty.
- `scrot` refuses to replace an existing file unless given `--overwrite`, so a
  polled screenshot silently keeps reporting the first frame it ever captured.

### Windows visual verification (GCP VM)

Build natively on a Windows VM, take a DXGI screenshot — fully automated over SSH (no RDP needed).

The create script sets up auto-logon via sysprep specialize, so an interactive console session exists at boot. PsExec launches apps in that session and `dxcam` captures DXGI screenshots.

```sh
# 1. Create a Windows VM (auto-logon, MSVC, Python, dxcam, PsExec)
dart run tools/vm/create_windows_vm.dart flutter-windows-test

# 2. Deploy bundle and verify (automated — screenshot downloads locally)
dart run tools/vm/deploy_bundle.dart flutter-windows-test <bundle_path> --windows

# 3. Clean up
gcloud compute instances delete flutter-windows-test --quiet
```

**Key details:**
- `--enable-display-device` is mandatory — provides virtual GPU for D3D
- GDI `CopyFromScreen` captures D3D/Flutter surfaces as **black** — must use DXGI (`dxcam`)
- Console resolution is 800x600
- Files are written to `C:\temp\` (shared), not user profile dirs

**When to run:** After any change to Windows runner code, engine selection, or bundle assembly.

## 5. Web rendering verification

There is no browser-test toolchain in this repo and no `npx` step. The built bytes are checked by
the web workspaces' own tests:

| Check | Where | What it proves |
|-------|-------|----------------|
| Templating / defines | `custom_boot/test/verify_templating_test.dart` | Substitution outcomes in the built bytes: web defines resolved, kept placeholders survived, `buildConfig` emitted, no `{{` left. |
| Local CanvasKit | `web_example/test/verify_compiler_flags_test.dart` | `useLocalCanvasKit` is declared, so the renderer loads from the app origin rather than gstatic.com — the regression a strict `script-src 'self'` exposes. |

To see a page render, run it with `flutter_dev run --bazel-target=<app> -d chrome`, which serves
it through the stock tool.

## 6. Standalone diagnostic scripts

These are not Bazel tests — they're standalone Dart scripts for manual investigation.

| Script | Purpose | Usage |
|--------|---------|-------|
| `e2e/_macos_test/verify_macos_app.dart` | Launch macOS app, verify window, screenshot | `dart run <script> <app.app> [title]` |
| `e2e/_linux_test/verify_linux_bundle.dart` | Verify Linux bundle directory structure | `dart run <script> <bundle_dir> [native_libs...]` |
| `e2e/_linux_test/verify_linux_app.dart` | Launch Linux GTK app under Xvfb, verify window, screenshot | `dart run <script> <bundle_dir> [title]` |
| `e2e/_windows_test/verify_windows_bundle.dart` | Verify Windows bundle directory structure | `dart run <script> <bundle_dir> [native_libs...]` |
| `e2e/_windows_test/verify_windows_app.dart` | Launch Windows app, verify window via PowerShell | `dart run <script> <bundle_dir> [title]` |
| `e2e/_windows_test/dxgi_screenshot.py` | Launch app + DXGI screenshot (captures D3D/Flutter) | `python <script> <exe_path> <output.png> [wait_s]` |
| `e2e/_compare/compare_artifacts.dart` | Diff flutter build vs bazel build outputs | `dart run <script> <flutter_dir> <bazel_dir>` |

## Quick reference: what to test when

| Change area | Minimum test scope |
|-------------|-------------------|
| Starlark rules (`flutter/*.bzl`) | Root `//...` + all e2e workspaces |
| macOS runner (`flutter/private/runners/macos/`) | macos_example `//...` + manual runtime test |
| Linux runner / bundle (`flutter/private/*linux*`) | linux_example, cross_compile_example, GCP VM visual test |
| Windows runner / bundle (`flutter/private/*windows*`) | windows_example (on Windows), GCP VM visual test |
| Desktop engine selection (debug/release) | cross_compile_example `bazel build :cross_linux` + verify on VM |
| Dart compilation / AOT | hello_world, ffi_example, macos_example |
| Asset bundling | hello_world (incl. `:verify_pub_assets_test` and `:verify_sub_assets_test`), plugin_example |
| Shader compilation or bundling, or how a workspace plugin is wired | plugin_example's `//impeller_shader` build tests |
| Web support | web_example, integration_web, and a `flutter_dev run -d chrome` by eye |
| FFI / native deps / native assets | ffi_example (incl. manual iOS-sim + macOS runtime tests), ffi_plugin_example |
| Plugins | plugin_example, ffi_plugin_example |
| Toolchain / SDK | smoke, hello_world |
| The dev loop (`tools/flutter_dev`, `flutter/dev_files.bzl`, `flutter/debug_agent`) | `bazel test //tools/flutter_dev/...` **and** `agent_e2e` on Android and Linux — see § 2 |
| New or changed analysis coverage (a target's `srcs` glob or `main`, a new `manual` tag, a new `analysis_options.yaml`) | Root `//...` **and** the probe — see § 1 |
| Golden comparator (`flutter/private/goldens/`, `flutter_test.bzl` bootstrap) | Root `//...` + codegen `//...` **and** the manual regeneration round trip below |
| Everything | All sections above |

### Dual-hub package skew (manual)

`e2e/dual_hub` runs two pub hubs over two lock files that agree on `path`
(1.9.1) and disagree on `clock` (1.1.2 in `//hub_a`, 1.1.3 in `//hub_b`). Both
locks state the same SDK constraint, so the spokes derive the same
`language_version` and the package version is the only thing that differs.

`bazel test //...` there covers the agreeing half — `:agreeing_bin` collects
`path` from both hubs and must build. It is a binary because the check runs
wherever a package_config is assembled — `collect_packages` (`dart_binary`,
`dart_test`, `package_config`, `dart_web_application`,
`dart_analysis_options`, the codegen `library_deps` path) and directly on a
library's transitive packages in `dart_analyze` and `dart_fix`. `dart_library`
itself never reaches it: it accumulates records into depsets and never dedups,
so a `build_test` over a bare library proves nothing. The analysis aspect
visiting the library *does* fire it.

The disagreeing half is `manual` because its contract is to fail analysis,
which no target in `bazel test //...` can have:

```sh
cd e2e/dual_hub
bazel build :disagreeing_bin   # must FAIL
```

The build must fail, naming both hubs and both versions:

```
Error in fail: Package "clock" is supplied more than once with different versions:
  - 1.1.2 (../ai_rules_flutter++flutter+hub_a__clock)
  - 1.1.3 (../ai_rules_flutter++flutter+hub_b__clock)
```

A build that succeeds instead, emitting a `package_config.json` that names
exactly one `clock` with no diagnostic, is the silent substitution this
workspace exists to catch: the binary compiles against one version's source tree
while the other lock pins the other.

`:disagreeing_bin` stays `manual`: a target whose contract is to fail analysis
cannot sit in `bazel test //...`. `:agreeing_bin` is the automated half and
must keep passing — two records for `path` at the same 1.9.1 agree, so the
guard lets them merge.

The root workspace has two tool hubs, `tool_deps` and `gen_l10n_deps`, and no
target reaches both. Do not add one: if they disagreed on a shared package, the
edge would be the bug.

### Golden regeneration (manual)

`e2e/codegen`'s `//:golden_test` and `//:golden_undeclared_test` cover the
comparator under `bazel test`: that one is installed, that a missing golden
fails, that a declared golden is found while an undeclared one is not, and that
diffs reach `bazel-testlogs`. What they cannot cover is `update()`, which writes
to the source tree — a test action has no source tree, and a committed golden
that this host's rendering matches would be a machine-specific artifact that
fails on another OS.

So the write path is checked by hand, on a **scratch** target with a golden path
nothing else uses. Never point it at a committed fixture: regeneration would
rewrite that fixture to this machine's rendering, which is exactly what the
suite avoids committing.

```sh
cd e2e/codegen
# ... add a scratch flutter_test with data = glob(["test/goldens/**"]) and a
# matchesGoldenFile('goldens/scratch_only.png') that nothing else references.

bazel run //:scratch_golden_test -- --update-goldens
#  → "flutter_test: wrote golden <workspace>/e2e/codegen/test/goldens/scratch_only.png"

bazel test //:scratch_golden_test
#  → PASSED. Regenerate-then-compare on the same host is the whole bar; it is
#    NOT evidence the PNG would match on another OS.

bazel test //:scratch_golden_test --test_arg=--update-goldens
#  → FAILED, exit 64, "only works under bazel run".

# Then delete the scratch target, its source, and the generated PNG.
```

The `--update-goldens` write path is also checked in CI, not only by hand:
`bazel run //:update_goldens_check -- --bazel=bazel` in `e2e/codegen`
(`e2e/codegen/tools/update_goldens_check.dart`) builds a scratch copy of the
workspace in a temporary directory, adds a golden test with a stale PNG, and
asserts that the test fails, that `bazel run <target> -- --update-goldens`
rewrites the PNG, and that the test then passes. It runs as its own step in the
`e2e-linux-app` job and in the dispatch-only `e2e-macos-apple` job.

### iOS hardware (manual)

`flutter_dev` hands an `ios_application`'s `.ipa` or `.app` to the stock tool, which finds the
device and its VM service itself. Untested so far: run `flutter_dev run` against
`e2e/ios_example` on a simulator and on a device, wired and wireless, and confirm that the app
renders and that `r` and `R` show an edit.
