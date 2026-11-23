> **Built and maintained by AI agents.** `ai_rules_flutter` is written, reviewed, tested and released by AI
> agents. Every change passes deterministic gates before it merges: hermeticity checks, byte-identical outputs,
> strict code-quality limits.
>
> **Open an issue or a PR.** Bugs, missing SDK features and slow builds are all welcome. Our agents read every
> one, fix what they can and release the fix.
>
> The goal is a fully autonomous Bazel rules workforce that keeps improving these rules, until they beat the
> hand-written alternatives.
>
> Security reports: [GitHub private advisory](https://github.com/Mivr/ai_rules_flutter/security/advisories/new), reviewed by the human owner [@Mivr](https://github.com/Mivr). Continues [aran/rules_flutter](https://github.com/aran/rules_flutter) by Aran Donohue,
> with many thanks: see [History and thanks](#history-and-thanks).

# rules_flutter

Bazel rules for building Flutter apps.

> **Status: alpha.** It works today, but the public API may still change. Feedback and contributions are welcome.

rules_flutter compiles Dart to kernel or AOT native code, bundles assets, and packages the result for macOS, iOS, Android, Linux, Windows, and the web. It builds on [ai_rules_dart](https://github.com/Mivr/ai_rules_dart) for Dart compilation and hands platform packaging to the rulesets that already do it well: `rules_apple`, `rules_android`, and friends. For development, `flutter_dev` builds the app with Bazel and hands it to the stock `flutter` tool, which gives you hot reload, hot restart, DevTools, the IDE debuggers and its `--machine` protocol; a debug agent package lets a script drive the running app through that protocol.

## Why build Flutter with Bazel

If `flutter build` works for you, here is what Bazel adds:

- **Reproducible builds.** Every input is tracked, so the same source produces the same output on every machine.
- **Remote caching.** Build outputs are content-addressed and shared across a team. A change to one package rebuilds only what depends on it.
- **Remote execution.** Compile on cloud workers, and build macOS, Linux, and Android targets from one `bazel build`.
- **One build graph.** Flutter apps, backend services, Rust and C++ libraries, and infrastructure code live together with real dependency tracking.
- **Native code without a second build system.** Depend on `cc_library`, `rust_shared_library`, or `swift_library` targets directly. No CMake, Gradle, or CocoaPods.
- **build_runner as a Bazel action.** Code generators such as json_serializable and freezed run through rules_dart's `dart_build_runner`, cached and sandboxed like any other action.

## Contents

- [Getting started](#getting-started)
- [Flutter SDK versions](docs/flutter-sdk-versions.md): pins, custom releases, offline SDKs, mirrors
- [Dependencies](#dependencies): pub packages, build hooks, native code
- [Building for each platform](#building-for-each-platform): macOS, iOS, Android, Linux, Windows, web, cross-compiling, release permissions
- [Rules reference](#rules-reference): libraries, applications, tests, plugins, code generation, providers
- [The dev loop](#the-dev-loop): running apps, hot reload, driving an app from a script
- [Examples](#examples)

## Getting started

### Requirements

| Platform | What you need |
|---|---|
| All | Bazel 9 or newer. The rules download Flutter 3.47.7 themselves. |
| macOS | Xcode, for `rules_apple` and `rules_swift`. |
| iOS | Xcode. The simulator needs no signing identity. A physical device does; see [Running on an iOS device](#running-on-an-ios-device). |
| Android | The Android SDK and NDK, with `ANDROID_HOME` and `ANDROID_NDK_HOME` set. `unzip` must be on PATH on every host or remote executor that builds Android targets, since rules_android 0.8 runs the host `unzip`. See [Android](#android). |
| Linux | A C++ toolchain. From macOS, an LLVM cross-toolchain. |
| Windows | MSVC for native builds. From macOS or Linux, a C++ cross-toolchain, debug builds only. |
| Web | Nothing extra. Compiling Dart to WASM or JavaScript is fully hermetic. |

### MODULE.bazel

`ai_rules_flutter` is released from this repository together with [`Mivr/ai_rules_dart`](https://github.com/Mivr/ai_rules_dart), which it builds on. Take both from the GitHub releases with `archive_override` in your root `MODULE.bazel`:

```starlark
bazel_dep(name = "ai_rules_flutter", version = "0.20.0", repo_name = "rules_flutter")
bazel_dep(name = "ai_rules_dart", version = "0.18.0", repo_name = "rules_dart")

archive_override(
    module_name = "ai_rules_flutter",
    urls = ["https://github.com/Mivr/ai_rules_flutter/releases/download/v0.20.0/rules_flutter-v0.20.0.tar.gz"],
    integrity = "sha256-1AyJQxzuzfL4p4A8wex8VUZerGOXIokNlhPv+2yYNug=",
    strip_prefix = "rules_flutter-0.20.0",
)

archive_override(
    module_name = "ai_rules_dart",
    urls = ["https://github.com/Mivr/ai_rules_dart/releases/download/v0.18.0/rules_dart-v0.18.0.tar.gz"],
    integrity = "sha256-9sFt975mhYbFlKNUJ0F9dExQzCu6yv9Dc+WEGsxVuO0=",
    strip_prefix = "rules_dart-0.18.0",
)

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(flutter_version = "3.47.7")
flutter.pub(
    name = "deps",
    lock = "//:pubspec.lock",
)
use_repo(flutter, "deps", "flutter_toolchains")

register_toolchains("@flutter_toolchains//:all")
```

Keep the `ai_rules_dart` override in your root `MODULE.bazel` at or above the floor that rules_flutter's `MODULE.bazel` names in its `bazel_dep` on `ai_rules_dart`: an older one fails to load, on the first `@rules_dart` file it lacks.

`flutter.toolchain` downloads the Flutter SDK and engine. `flutter.pub` reads your `pubspec.lock` and creates a repository, here named `deps`, with one target per package: `@deps//:flutter`, `@deps//:flutter_test`, `@deps//:collection`, and so on. See [Pub packages](#pub-packages).

Some platforms need one more repository from the same extension. Add it to `use_repo` when you build for that platform:

| Platform | Add to `use_repo` |
|---|---|
| macOS | `flutter_macos_engine` |
| iOS | `flutter_ios_engine` |
| Android | `flutter_android_engine_arm64`, or `flutter_android_engine_x64` for `android_abi = "x64"` |
| Web | `flutter_web_sdk` |

Static analysis needs nothing extra. rules_dart's analysis resolves `dart:ui` in a `flutter_library`, `flutter_plugin` or `flutter_test` through the `sky_engine` package, which those rules add to the analyzer's closure themselves. Their compiled output does not change.

### Flutter SDK versions

The stock release is pinned by `flutter.toolchain(flutter_version = ...)`, and every SDK byte it downloads is verified against a sha256 recorded in `flutter/private/versions.bzl` — a missing checksum fails the fetch rather than accepting unverified bytes. Your root module's pin wins over any version a dependency requests.

Two extensions cover the rest. A root-registered custom release (an older stable, a rebuild, an enterprise engine) carries its own pinned checksums through `flutter.version`, and `flutter.toolchain(local_path = ...)` sources every repository out of a pre-extracted SDK on disk instead of the network. To mirror stock bytes, keep the stock version and point Bazel at the mirror with `--downloader_config` so the recorded checksums still verify everything. See [Flutter SDK versions](docs/flutter-sdk-versions.md).

#### Overriding `rules_dart`

`rules_flutter` uses APIs from [`ai_rules_dart`](https://github.com/Mivr/ai_rules_dart) (`@rules_dart//dart:defs.bzl` and `@rules_dart//dart:utils.bzl`) that are not in upstream's `rules_dart` releases on the Bazel Central Registry. Its floor is `ai_rules_dart` 0.28.3, released on GitHub under that module name with `repo_name = "rules_dart"`. The block above gives the latest released, CI-tested pair: `ai_rules_flutter` 0.20.0 with `ai_rules_dart` 0.18.0. The `archive_override` pair in [MODULE.bazel](#modulebazel) above is the supported setup; every downloaded byte is verified against its `integrity` hash.

To live at the heads instead of these releases (local development against a checkout of each repository's `main`), replace the two `archive_override` blocks with overrides onto your clones. Because Bzlmod ignores module overrides in non-root modules, the overrides go in your root `MODULE.bazel`:

```starlark
bazel_dep(name = "ai_rules_dart", version = "0.28.3", repo_name = "rules_dart")

git_override(
    module_name = "ai_rules_dart",
    commit = "e7163aab8f9171f54693cd1b99feb7d3cee9602d",
    remote = "https://github.com/Mivr/ai_rules_dart.git",
)
```

with the matching `local_path_override` (or `--override_module`) for `ai_rules_flutter` itself, as the `e2e/*` workspaces show.

### .bazelrc

Two settings are required. Paste them into your project's `.bazelrc`:

```bazelrc
# rules_flutter's Java dependencies (rules_jvm_external 7+, rules_android 0.8+)
# ship tool jars compiled for Java 21+. Bazel's default tool JDK is older.
common --tool_java_language_version=25
common --tool_java_runtime_version=remotejdk_25

# Windows only: lets Bazel create real symlinks (runfiles trees and SDK
# layouts use them where available) instead of falling back to copies.
startup --windows_enable_symlinks
```

Without the Java settings you get `UnsupportedClassVersionError` when an action runs, or `could not locate class file for java.lang.Record` when one compiles.

### Your first app

Start from a project made with `flutter create`. It has `lib/main.dart`, a `pubspec.yaml`, and one folder per platform. rules_flutter reads those files as they are. You add a `BUILD.bazel`:

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    pubspec_srcs = glob(["assets/**"]),
    pub_packages = "@deps//packages",
    deps = ["@deps//:flutter"],
)

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.my_app",
)
```

`flutter_application` compiles the Dart code and bundles the assets. Each platform then has a macro, like `flutter_macos_app`, that wraps it in a runnable app. Three attributes deserve a note:

- `package_name` must match the `name:` field in `pubspec.yaml`. Hot reload and code generation both rely on it.
- `pubspec_srcs` lists the files `pubspec.yaml` names: its assets, fonts and shaders. The pubspec says what the bundle holds, as it does for `flutter build`, including the Material icon font when it sets `uses-material-design: true`. See [Assets](#assets).
- `pub_packages` names every package of the lock (`@<hub>//packages`), so the package config the bundle reads is the one `pub get` writes: `NOTICES` then holds the dev dependencies' licences too. Without it, a regular dependency the pubspec names that `deps` do not reach fails the build, as a stale `pub get` does.

Build it, or run it with hot reload:

```sh
bazel build //:my_app_macos
bazel run @rules_flutter//tools/flutter_dev -- run --bazel-target=//:my_app_macos -d macos
```

The second command runs from the Flutter project directory; see [The dev loop](#the-dev-loop).

### Build modes

Bazel's compilation mode flag selects how the Dart is compiled:

| Flag | Mode | Dart compilation | Use it for |
|---|---|---|---|
| `-c dbg` | Debug | Kernel `.dill`, run by the JIT | Development, hot reload |
| none (fastbuild) | Release | AOT native code | CI, tests |
| `-c opt` | Release | AOT native code, stripped | Production |
| `-c opt --@rules_flutter//flutter:profile` | Profile | AOT native code, stripped, with the Dart VM service | Measuring performance with DevTools |

Note that a plain `bazel build` is a release build, not a debug one. That matters for [permissions](#release-builds-and-permissions).

Profile mode is `flutter run --profile`: release-speed code that still serves the Dart VM service, so DevTools can record timelines and CPU profiles. It has no hot reload. Profile uses its own engine and gen_snapshot on every platform, downloaded the first time a profile build needs them, because the engine refuses a snapshot compiled for a different mode. The flag needs `-c opt`, and the build fails if it is set with any other `-c`. Like upstream Flutter, there is no profile mode for the iOS simulator: build profile for a physical device. A `.bazelrc` config saves typing:

```
build:profile -c opt --@rules_flutter//flutter:profile
```

## Dependencies

### Pub packages

`flutter.pub` turns `pubspec.lock` into Bazel targets. Every package in the lock gets a target in the hub repository: `@deps//:collection`, `@deps//:url_launcher`, `@deps//:flutter_test`. List them in `deps` like any other target:

```starlark
flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = [
        "@deps//:flutter",
        "@deps//:collection",
        "@deps//:url_launcher",
    ],
)
```

`flutter.pub` plans the lock with rules_dart's pub planner, the one `pub.from_lock` uses: the first evaluation asks each hosted package's server for its listing (`<url>/api/packages/<name>`, what `dart pub get` reads; the archive only when the server has no listing), records the dependency names it learns as lockfile facts, and later evaluations make no request. Each package gets its own repository, which fetches only its own archive and checks its pubspec against the planned names, so adding or removing a package refetches no other package. A module that ships a lock to its users can ship its plan with it, `flutter.pub(plan = ...)`, written by `bazel run @rules_dart//dart/pub/plan -- write --lock <pubspec.lock> --out <plan.json>`: its users then plan it with no request at all.

Plugins need no special treatment. A pub package that is a Flutter plugin arrives as a plugin target, and the platform macros register it and build its native code. On Android `flutter_android_app` packages the Kotlin and Java of the plugins your app's Dart dependencies reach, and no others, so an unrelated plugin in the lock never changes the app. The hub also exposes `@deps//android:all_android_plugin_libs`, the Android library of every plugin in the lock, for a target that names it.

A plugin's Gradle build is not read while the hub's spokes are fetched. Each Android plugin has its own repository, and its `android/build.gradle` (`build.gradle.kts`) is read only when an Android target analyses the spoke's `android:lib` alias. An iOS-, macOS-, web- or Dart-only build therefore resolves the hub without reading any Gradle model, so an untranslatable Android dependency cannot fail it. A wildcard query over the hub (`bazel query @deps//...`) reaches the Android targets and therefore fetches those plugin repositories.

Permissions a plugin declares in its own manifest, such as `record_android`'s `RECORD_AUDIO`, reach the app's manifest as they do under Gradle. You don't need `--merge_android_manifest_permissions`.

### Federated plugins

Federated plugin resolution follows Flutter's `resolvePlatformImplementation` rules per target platform. A plugin is **direct** when the application's own code depends on it: its `flutter_plugin` or pub-package target is in the `deps` of the `flutter_application` itself, or in the `deps` of a first-level library the application owns. The plugin dependencies of a third-party pub package never make a plugin direct, because Flutter counts only the dependencies of the application's own pubspec. A plugin reached only through deeper dependencies is not direct. A plugin reached both ways is direct, whatever order `deps` lists them in: the direct mark is the shallowest depth over all paths, and deduplication by name never loses it.

For one umbrella and platform, resolution follows Flutter's order and nothing else:

1. **Single candidate**: Exactly one candidate implementation is registered.
2. **Direct candidate**: Else the one candidate that is direct is registered, and the other candidates and the default are not. An umbrella that implements itself inline counts as a candidate, and yields to a direct alternative.
3. **Endorsed default**: Else the endorsed `default_package` is registered, when it is one of the candidates. A default that is not among the candidates is never invented.
4. **Error**: Else a build-time error names the umbrella, the platform, and every candidate.

Two or more candidates that are direct (conflicting direct implementations), and several candidates without a default and none direct, fail closed with an error naming the umbrella, the platform, and every candidate. A plugin set with no federated plugin resolves to the same list in the same order as before.

### Path dependencies

A `path:` entry with `relative: true` in the lock is resolved against the lock file's own directory and linked into a `flutter_pub_path_package` spoke as a tree of symlinks, so the workspace never copies the package. The entry is accepted only when the lock's `relative` marker is true and its path is workspace-relative: any other marker (false, missing, empty) and any absolute path fail the extension evaluation naming the hub and the package. The spoke links only what its generator reads or exposes — `lib/`, the pubspec, hook scripts, declared assets, fonts, and shaders (plus each shader's own directory), and the plugin's declared platform directories — parsed from the package's own `pubspec.yaml` and mirrored one file at a time into real repository directories. `example/`, `build/`, `.dart_tool/`, dot-directories, undeclared files, and the package's own BUILD files stay unlinked (skipped subtrees are not even watched), so machine-local output such as `example/build/` or a `.plugin_symlinks` cycle can never affect the fetch; every directory in the spoke is real: each symlink is a single file, and a directory reaching the link step fails the fetch, so the generated BUILD files land in the spoke, never in the user's source tree. Every linked file and directory is watched, so adding, changing, or removing one refetches the spoke; without the watch, files added inside nested asset directories would stay invisible until something else retriggered the fetch. A source symlink resolving to the package or one of its ancestors fails the fetch naming the package and the link, and the package directory itself, any of its parent components, or any replicated symlink resolving outside the workspace's real root fails the fetch naming the package, the offending path, and its real path — host bytes can never enter the bundle. A path that escapes the workspace, or resolves to the workspace root itself, fails the extension evaluation rather than symlinking outside the workspace. The package's pubspec `name` and `version` must match the lock entry, since overlays and code assets are selected by lock name and version; a mismatch fails the fetch naming the hub, the lock key, and both values. A shader's `#include` siblings are linked only from the declared shaders' own directories, so `example/build/` output can never become an include. A path plugin's `android/build.gradle*` is translated exactly as a hosted plugin's: `android_maven_deps` and `android_maven_ignore` from `flutter.pub` apply to it too.

The lock must belong to the root module. A `relative: true` path resolves in the lock-owning module, and module-extension label attributes already resolve in the defining module while the spoke's `workspace_root` is always the root module, so a lock owned by a non-root module has no repository-local root to resolve against; resolving it in the consumer workspace would silently link the wrong directory. A path dependency locked by another module therefore fails the extension evaluation, naming the hub, the package, and the owning module — declare the `path:` dependency in the root module's own lock instead.

### Other dependency sources

`flutter.pub` serves every entry of the lock from where `flutter pub get` took it, on rules_dart's pub planner: a hosted package from its server (pub.dev or any other, the archive from the listing's `archive_url`), a `git` package from the commit `resolved-ref` names at its `path` (the `ref`, a branch say, is not read), a `path` package as above, and an `sdk` package from the Flutter SDK (`flutter`, `flutter_test`, `flutter_driver`, `flutter_localizations`, `flutter_web_plugins`, `integration_test`, `flutter_goldens` and `fuchsia_remote_debug_protocol`; `sky_engine` comes with the toolchain). `dependency_overrides` and `pubspec_overrides.yaml` need nothing of their own: the lock holds the overriding entry with its source. Any other `sdk` package, any other `source`, and a path outside the workspace fail the extension evaluation naming the hub, the package and what to do. A server that needs a token gets it from a Bazel credential helper, the same way as for `pub.from_lock`; see rules_dart's `docs/pub.md` (Private servers and tokens). `e2e/pub_sources` builds an app with a git package from a repository subdirectory and a path plugin.

### Breaking a repository cycle

When pub resolves two packages that depend on each other — `dio` and `dio_web_adapter` are the common pair — one Bazel repository per package forms a repository cycle: `flutter.pub` creates a spoke for each, and each spoke names the other's spoke in `deps`. `flutter.pub` now merges pub dependency cycles into a single spoke automatically, so `cycle_breaks` is no longer needed for cycles (and remains only as an optional edge-dropping override when explicitly desired). `cycle_breaks` drops only the named spoke-to-spoke edges; both packages still get their spokes, hub aliases, and `android:all_android_plugin_libs` entries.

```starlark
flutter.pub(
    name = "deps",
    lock = "//:pubspec.lock",
    cycle_breaks = {"dio": ["dio_web_adapter"]},
)
```

Each key and listed dependency must name a package in the lock: a key that does not is rejected at extension evaluation, naming `flutter.pub(cycle_breaks = ...)` and the entry. A listed dependency the key's own `pubspec.yaml` does not declare fails the evaluation with the same naming. An empty list drops nothing.

Dropping an edge is safe only when the dependency is reached through a conditional import for a platform this build does not target: the Dart code that needs it is not compiled, so the missing edge removes only the Bazel repository cycle. If the build does target that platform, the break removes a library the code needs and the build fails.

### Assets

The app's `pubspec.yaml` says what its asset bundle holds, as it does for `flutter build`: assets and their resolution variants, platform- and flavor-conditioned entries, fonts, shaders, transformers and `uses-material-design`. One action per app writes the bundle with the Flutter tool's own code; list the files the pubspec names in `pubspec_srcs`. A pub package's assets reach the bundle when the app's pubspec depends on the package, as under `flutter build`. See [Assets](docs/assets.md), which also says what moves out of BUILD files.

### Android from the Gradle model

An app's Android side can be built from a pin file that Gradle writes once (`bazel run //:android_pin`):
one library per plugin project, one import per Maven artifact by hash, AGP's own tools, split APKs for
the debug loop and the whole APK equal to `flutter build apk --debug`. BOMs, kapt, KSP and any Maven
coordinate work, because Gradle resolved them. See [docs/android-model.md](docs/android-model.md).

### Android native (Gradle) dependencies

A plugin's `android/build.gradle` (`build.gradle.kts`) runtime dependencies (`implementation`, `api`, `runtimeOnly`) are translated to `@rules_android_maven` labels automatically. This happens in the plugin's own Android repository, and only when an Android target needs it: the spoke fetch itself never reads the Gradle model. Gradle evaluates exactly one build file per project directory, so when both files are present the repository reads `build.gradle` for everything — dependencies, namespace, native-build and ProGuard detection alike. Common AndroidX artifacts are built in; anything else must be mapped in `MODULE.bazel`:

```starlark
flutter.pub(
    name = "deps",
    lock = "//:pubspec.lock",
    android_maven_deps = {
        "com.example:thing": "@rules_android_maven//:com_example_thing_thing",
    },
)
```

A plugin dependency found in neither table fails that Android repository's fetch naming the package, the build file, and every offending entry — a missing native library would otherwise compile and crash on the device. A coordinate that genuinely needs no label goes in `android_maven_ignore`; declarations that are not Maven coordinates at all (version-catalog `libs.*` refs, variables, local jars) need a plugin overlay instead, via `flutter.plugin_overlays`.

The parser reads the build script statement by statement (comments stripped outside string literals; statements split on newlines, `;`, `{` and `}` at bracket depth 0, so a parenthesised call spanning lines reads as one statement), so layout is insignificant: a single-line `dependencies { implementation '...' }`, two declarations on one line separated by `;`, and Gradle's `add('implementation', '...')` (single- or double-quoted, both DSLs) all resolve. Only `dependencies` blocks outside `buildscript` count. `apply from:` scripts in every DSL spelling (`apply from: 'x.gradle'`, `apply(from: 'x.gradle')`, `apply(from = "x.gradle.kts")`) are read when the path stays inside the package, recursively, with cycle detection and a depth cap. The Android namespace is read from the same statement model (`namespace` in any `android` block, even on one line or nested, or top-level `android.namespace = ...`; the last declaration wins; commented-out or string-embedded declarations never count). Anything unmodellable fails the fetch instead of dropping the dependency: nested blocks such as `constraints {}`, `dependencies` mentions outside the block form (`project.dependencies.add(...)`), map notation, catalog refs, variables, interpolated coordinates, an unbalanced bracket, a non-literal namespace, and `apply from:` with a URL, an absolute or escaping path, a missing file, or a non-literal argument. The plugin's Android namespace must be a valid Java package name, and every `android_maven_deps` value must be a label (`@...` or `//...`); anything else fails naming the plugin or the key.

#### Pinning Maven dependencies

Every Android build should pin `@rules_android_maven` to avoid resolving artifacts dynamically with Coursier on every cold fetch. To pin the merged install in your root workspace:

1. Add `lock_file = "//:rules_android_maven_install.json",` to your own `maven.install(name = "rules_android_maven", ...)` declaration (or declare one with just the name if your root adds no extra artifacts):

```starlark
maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
maven.install(
    name = "rules_android_maven",
    lock_file = "//:rules_android_maven_install.json",
)
use_repo(maven, "rules_android_maven")
```

2. Run `bazel run @rules_android_maven//:pin` to generate the lock file, and check it in.

`rules_flutter` does not ship a lock file in its own `MODULE.bazel`: under `rules_jvm_external` (6.9 `private/extensions/maven.bzl:630-637` and 7.1 `private/extensions/maven.bzl:784-793`), a dependency module's lock is used only when the consumer's root declares no same-named install, and a root install always replaces it (with none when the root declares no lock). A library lock would therefore stop applying as soon as a consumer adds or bumps an artifact. Furthermore, `rules_jvm_external` permits only one module to pin a given install name (:653-661). Pinning at the workspace root ensures hermetic, sha256-verified downloads for the union of all declared artifacts.

### iOS native (SwiftPM) dependencies

An iOS app's SwiftPM pins (`ios/.../xcshareddata/swiftpm/Package.resolved`, versions 2 and 3) become one spoke repository per pin, holding the pinned sources and a BUILD file translated from the package's `Package.swift`:

```starlark
flutter.pub(
    name = "deps",
    lock = "//:pubspec.lock",
    swift_package_resolved = "//ios/Runner.xcworkspace/xcshareddata/swiftpm:Package.resolved",
    swift_package_sha256 = {
        "bigint": "55fc8a63f655a09d9216f2c9bc062c508f98d4eca4b8ebefaf295a3ea4ac8f22",
    },
)
```

Every pin needs a `swift_package_sha256` entry: the SHA-256 of the source archive the pin resolves to, `https://github.com/<owner>/<repo>/archive/<revision>.tar.gz` from its `location` and `state.revision`. Compute it with `curl` plus `sha256sum` over that URL. A pin without an entry still gets a spoke, but its fetch fails before any download — `has no `swift_package_sha256["bigint"]` entry: download <url> and record its SHA-256 digest` — because an unpinned download would otherwise bake one machine's bytes into every build. The spoke is named `<hub>__swiftpm-<identity>` (for example `@deps__swiftpm-bigint`), and each `.library` product is a target of that name: an `alias` when the product has one target (even under another name), a `swift_library_group` otherwise.

A product can also come from a Bazel target you already build, with no pin at all. Map `<identity>:<product>` to that target with `swift_package_product_deps`:

```starlark
swift_library_group(
    name = "firebase_analytics_product",
    deps = ["//third_party/firebase:analytics"],
)

flutter.pub(
    name = "deps",
    lock = "//:pubspec.lock",
    swift_package_product_deps = {
        "firebase-analytics:FirebaseAnalytics": "//:firebase_analytics_product",
    },
)
```

A key's identity half is written in lowercase (`[a-z0-9._-]+`; an uppercase key is refused) but compared case-insensitively against the plugin's manifest, so `bigint:BigInt` matches a manifest that spells the package `BigInt`. The product half matches exactly as the plugin's `Package.swift` spells it. Labels resolve in the module that writes the tag, like `lock` and `swift_package_resolved`. A mapped product needs no `swift_package_resolved` file, no `swift_package_sha256` entry and no translatable manifest: the plugin links the mapped label instead of a `<hub>__swiftpm-<identity>` spoke, and a hub may mix mapped and pinned products. When a product is not mapped and has no pin, the refusal ends with `Map it with flutter.pub(swift_package_product_deps = {"<identity>:<product>": "<label>"}).`; a pin that exists but cannot be fetched keeps its own checksum reason without that hint.

Only the translatable manifest subset parses: the `// swift-tools-version:X[.Y[.Z]]` first line, `import PackageDescription`, and one literal `let package = Package(...)` with `name`, `platforms`, `products` (`.library` only; executable and plugin products are dropped), `dependencies` (`.package` with `url:`, `id:`, `path:` and optionally `name:`; `from:`/`exact:`/`branch:`/`revision:` are ignored), `targets` (a regular `.target` with `name:`, `dependencies:`, `path:`, `exclude:`, `sources:`, `publicHeadersPath:`, `cSettings:`, `cxxSettings:`, `swiftSettings:`, `linkerSettings:`; a `.testTarget` keeps only its name and is ignored), `swiftLanguageVersions`/`swiftLanguageModes`, and `cLanguageStandard`/`cxxLanguageStandard`. A product's targets seed reachability; same-package string, `.target(name:)` and `.byName(name:)` dependencies are followed (matching case-insensitively, since `Package.resolved` lowercases the identity), `.product(name:package:)` resolves against the manifest's `.package` declarations (by `name:` first, else by the url's last path segment, case-insensitively) and must be pinned in `Package.resolved`. A product naming a test target, or a target depending on one, fails the fetch. Each reached target becomes a `<target>_lib` `swift_library` with the SwiftPM `c99name` module name, `package_name` for tools 5.9+, `-swift-version` from the declared modes (else Swift 6 for tools 6.0+, 5 for 5.x, 4.2/4 for those tools), and explicit `srcs` collected at fetch from the target dir (`path:`, normalized the way SwiftPM does so `.` is the package root, or the first existing `Sources/`, `Source/`, `src/`, `srcs/` subdirectory). A reached target whose sources are all C-family (`.c`, `.m`, `.mm`, `.cc`, `.cpp`, `.cxx`, headers, at most one `module.modulemap`) becomes a `<target>_lib` `cc_library` — `objc_library` when it holds `.m`/`.mm` — under the same `c99name` module name: any mix of C, C++, Objective-C and Objective-C++ sources translates to that one library, the way SwiftPM builds such targets. Public headers are the headers under the `publicHeadersPath:` directory, else under `include/`; an explicit `publicHeadersPath: ""` or `"."` names the target directory itself, while an absent argument keeps `include/`; a header there stays public even when `sources:` does not list it, since `sources:` only drops the automatic compile rule; every other header is private, compiling with the target's own sources in `srcs` but invisible to dependents. The module map follows SwiftPM's order: a `module.modulemap` in the public headers directory is used as-written, else `<public>/<c99name>.h` is the umbrella header, else `<public>/<c99name>/<c99name>.h`, else the public headers directory itself is the umbrella directory, with header paths relative to the map file; the map, explicit or generated, reaches Swift importers through a `swift_interop_hint`, so the one map Swift and clang use is SwiftPM's, while a target with no public headers is link-only and gets no hint. Per-target settings translate too: `.define` becomes `-Dname`/`-Dname=value` (`copts` for `cSettings`, `cxxopts` for `cxxSettings`, and `copts` for Swift ones, so it applies to the declaring target only and a `cSettings` define reaches `.c`, `.m` and `.mm` alike), `.headerSearchPath` becomes a search path on a target-local private-headers helper reached through `implementation_deps` (never an `includes` entry that reaches dependents; the public-headers directory still propagates), `.enableUpcomingFeature`/`.enableExperimentalFeature` become `-enable-upcoming-feature`/`-enable-experimental-feature` compiler flags, and `.linkedFramework`/`.linkedLibrary` become `-framework <name>`/`-l<name>` link flags. Any setting or dependency gated on `.when(platforms:)` becomes a `select()` on the target OS, keeping the `.iOS`/`.macOS` arms and ignoring any other listed platform (a list naming neither drops the entry on both platforms); a target mixing Swift and C-family sources fails the fetch naming the package and the target, as do assembly sources (`.s`, `.S`) naming the file, `.unsafeFlags` and any other setting kind naming the package, the target, the setting kind and the line (flags SwiftPM does not model would otherwise leak into the build), `cSettings`/`cxxSettings` on a Swift target, a feature setting on a C-family target, and any condition but `.when(platforms: [...])` — a `configuration:` condition or any other condition key fails the fetch naming the condition, the package and the target.

A top-level string constant folds when it is exactly one of three literal forms: `let <name> = "<value>"`, `let <name>: Version = "<value>"` or `let <name>: String = "<value>"`. A later statement may use it wherever the parser expects a string literal — a bare identifier argument value such as `url: someUrl`, `from: someVersion` or `.define(..., to: someValue)`, or a whole `\(<name>)` inside a string — and the constant must be declared before its use. The declaration statement is dropped, the use is replaced by the constant's source text, and every other declaration is still refused: a `var`, a function, a `let` array, a computed `let` (a ternary, a member access, a call), `ProcessInfo`, and any other interpolation. A refused plugin manifest says to list its native dependencies with `flutter.pub(ios_plugin_deps = {"<plugin>": "<label>"})`; a refused package manifest says to replace its translation with `flutter.pub(swift_package_build_files = {"<identity>": "<label>"})`.

A pub plugin (hosted or path) that ships `ios/<pkg>/Package.swift` — or the shared `darwin/<pkg>/Package.swift` — links its products the same way: the spoke reads the manifest with the same parser, finds the library target whose sources the platform builds, and resolves its `.product(name:package:)` dependencies (matched as above, case-insensitively) to `@<hub>__swiftpm-<identity>//:<product>` labels on both backends' `flutter_apple_plugin_library` targets. The plugin's own same-package targets build too: every target its `.library` product lists, and every target the primary target reaches through same-package dependencies, becomes `<pkg>_apple_<plat>__<c99name>` — a `swift_library` for a Swift target, an ObjC-only `objc_library` for a C-family target — while the primary `rules_apple` library depends on them and the `xtool` library compiles their files in its own `srcs`. A same-package dependency gated on `.when(platforms:)` is followed only on its listed platforms, so each platform's libraries build only the targets that platform needs. Target settings translate the same way (`exclude:`, `publicHeadersPath:`, `.headerSearchPath`, `.define` and `.when(platforms:)`), `resources:` stays skipped, and a reached `binaryTarget` fails with `binary targets in plugin manifests land in POD-10`; a missing target directory fails naming the plugin, the target and the directory. The resolved file and the hub's checksum table are constant labels on every pub spoke but are read only when the package actually ships a manifest, so adding, removing or re-checksumming a pin re-fetches only the spokes that read them; a pure-Dart spoke keeps its marker. A product `condition:` of `.when(platforms: [.iOS])` (or `.macOS`) links only for that platform; any other platform, a non-`when` condition, or a trait fails the fetch. Hub-side target dependencies carry the same rule: a `.when(platforms:)`-gated dependency becomes a `select()` on the target OS, and anything else fails naming the condition, the package, and the target. Same-package dependencies are skipped, and so is the plugin template's `FlutterFramework` path product (Flutter's own linking covers it; a `FlutterFramework` resolving to anything but the template path package is not skipped). Refusals name the plugin, its manifest, and the fix: a `.product(package:)` naming no declared package, matching a declaration with no url or id, a local path dependency, or an unusable url segment fails the fetch; a product whose package is not pinned in the hub's `Package.resolved` fails naming the missing identity (`... which is not pinned in the hub's Package.resolved (...): re-resolve the app with Xcode ...`); an unfetchable pin fails the plugin's own fetch with the same checksum refusal, naming the plugin, its manifest and the missing `swift_package_sha256` entry before any archive download; a manifest the parser cannot read fails when it declares `.package(` dependencies; and a hub with no `swift_package_resolved` fails any plugin that declares SwiftPM packages. `e2e/integration_ios` proves the link end to end: the `spm_bigint_plugin` path plugin's manifest depends on BigInt 6.0.1, `//:plugin_spm_test` now asserts the define reached both compiles and that the simulator computes `1267650600228229401496703205376 0 PLUGIN_FLAG`, the `spm_graph_plugin` path plugin's manifest depends on swift-algorithms 1.2.0 (whose `RealModule` product dependency pulls in swift-numerics 1.0.2, down through its C `_NumericsShims`), `//:plugin_spm_graph_test` asserts the simulator computes `6 2.718281828459045`, the `spm_objc_plugin` path plugin's Swift target imports a class from its separate ObjC target and `//:plugin_spm_objc_test` asserts the simulator computes `149`, and the full-matrix workflow queries the unpinned twin spoke and asserts the refusal.

Anything else fails the fetch instead of mistranslating: a version 1 resolved file, malformed JSON, a pin whose `kind` is not `remoteSourceControl`, whose `location` is not a GitHub repository (`https://github.com/<owner>/<repo>` with or without `.git` in any host letter case, or `git@github.com:<owner>/<repo>.git`), whose `state.revision` is missing or not a 40-character commit hash, or without a `swift_package_sha256` entry (each still gets a spoke, but its fetch fails before any download, naming the fix), the plain `Package.swift` manifest missing from the archive top level, a versioned `Package@swift-*.swift` sitting next to it, a `resources`/`plugins` target argument, an implicit resource SwiftPM processes without `resources:` (`.xcassets`, `.xib`, `.nib`, `.storyboard`, `.xcstrings`, `.xcdatamodeld`, `.xcdatamodel`, `.xcmappingmodel`, `.metal`, `.xcprivacy`, or `.lproj` content) naming the package, the target and the resource path, a reached `executableTarget`/`binaryTarget`/`systemLibrary`/`plugin`/`macro` target, a missing target directory, sources reaching zero Swift files, a target mixing Swift and C-family sources naming the package and the target, or holding assembly sources naming the file (READMEs, licenses and DocC catalogs are skipped, as are `exclude:`/`sources:` entries naming nothing on disk), a `path:`, `sources:`, `exclude:`, `publicHeadersPath:` or `.headerSearchPath` that is absolute or leaves its base (SwiftPM drops empty and `.` segments and a trailing `/` first, so `.`, `./x`, `x/` and `""` stay inside the target), `#if`, string interpolation, variables, and unknown `Package`/product/target arguments. Every message names the package identity, `Package.swift`, and the line. A `swift_package_build_files` entry (`identity ->` label, resolved in the module that writes the `flutter.pub` tag) replaces the generated BUILD file with a hand-written one but still downloads the pinned archive, so the identity keeps needing its `swift_package_sha256` entry; it is the escape hatch for refused packages. The spoke's repository root is the package root: the archive's single top-level directory (`<Repo>-<revision>/`) is stripped, so an override BUILD file sees `Package.swift` and `Sources/...` at the root, whatever the pinned revision, and a pin bump never breaks it. For example, `swift_package_build_files = {"bigint": "//third_party:bigint.BUILD"}` with

```starlark
load("@rules_swift//swift:swift_library.bzl", "swift_library")

swift_library(
    name = "BigInt",
    srcs = glob(["Sources/**/*.swift"]),
    module_name = "BigInt",
    visibility = ["//visibility:public"],
)
```

in `//third_party:bigint.BUILD`.

### iOS plugin preprocessor defines (`ios_plugin_defines`)

A CocoaPods app adds preprocessor defines to one plugin's Apple code in its Podfile `post_install` (`GCC_PREPROCESSOR_DEFINITIONS`). `flutter.pub(ios_plugin_defines = ...)` is the Bazel analogue, keyed by the plugin's pub package name:

```starlark
flutter.pub(
    name = "deps",
    lock = "//:pubspec.lock",
    ios_plugin_defines = {
        "permission_handler_apple": [
            "PERMISSION_CAMERA=1",
            "PERMISSION_MICROPHONE",
        ],
    },
)
```

Every entry reaches that plugin's C-family compiles (a pure Objective-C plugin, and the ObjC half of a mixed plugin) as `-D<entry>` on both the iOS and macOS `flutter_apple_plugin_library` targets, and a plugin's defines reach every same-package local target its manifest reaches alongside its primary target. Only an entry without `=` (`NAME`) also reaches the Swift compile, as `-D<NAME>`: a Swift compilation condition carries no value, so `NAME=VALUE` adds no Swift flag rather than silently dropping the value. An entry whose name before the first `=` is not a C preprocessor name fails evaluation, as does a key naming no locked package or naming a Flutter SDK package (`integration_test`, `flutter_test`, ...); a key whose package has no Apple sources, or whose BUILD comes from an overlay, fails the spoke fetch because the defines would reach nothing. The `xtool` backend refuses a non-empty list: it compiles every source in one `swiftc` invocation with no define flags, so remove `ios_plugin_defines` or build with `backend = "rules_apple"`.

Static `GCC_PREPROCESSOR_DEFINITIONS` from a plugin's `.podspec` (`pod_target_xcconfig` / `xcconfig`) are applied automatically and overridden per macro name by `ios_plugin_defines`; string-literal values such as `'LIBRARY_NAME="my-plugin"'` keep their C quotes in Objective-C compiles. Podspec values built with Ruby interpolation are skipped: pass those through `ios_plugin_defines`.

`permission_handler_apple` 9.6.4 reads these defines (from its `PermissionHandlerEnums.h`; the pub archive's SHA-256 is `b69e6b8300f9584af5ab81b41cdaa544e1b45e6fca0a30b0f9a9a120d90fc8a5`): `PERMISSION_APP_TRACKING_TRANSPARENCY`, `PERMISSION_ASSISTANT`, `PERMISSION_BLUETOOTH`, `PERMISSION_CAMERA`, `PERMISSION_CONTACTS`, `PERMISSION_CRITICAL_ALERTS`, `PERMISSION_EVENTS`, `PERMISSION_EVENTS_FULL_ACCESS`, `PERMISSION_LOCATION`, `PERMISSION_MEDIA_LIBRARY`, `PERMISSION_MICROPHONE`, `PERMISSION_NOTIFICATIONS`, `PERMISSION_PHOTOS`, `PERMISSION_PHOTOS_ADD_ONLY`, `PERMISSION_REMINDERS`, `PERMISSION_SENSORS`, `PERMISSION_SPEECH_RECOGNIZER`.

### iOS plugin native dependencies (`ios_plugin_deps`)

When a plugin's native Apple dependencies are computed by a program rather than a readable manifest, map the plugin's pub package name to one Bazel target holding every native dependency its Apple code needs:

```starlark
flutter.pub(
    name = "deps",
    lock = "//:pubspec.lock",
    ios_plugin_deps = {
        "google_sign_in_ios": "//third_party/google_sign_in:apple_deps",
    },
)
```

Labels resolve in the module that writes the tag. Each mapped plugin spoke receives only its own label, skips reading `<platform>/<pkg>/Package.swift`, `darwin/<pkg>/Package.swift`, `Package.resolved` and the hub's native-deps table, and links that target on both `rules_apple` and `xtool` for every Apple platform where the plugin ships sources while still compiling the plugin's own sources. A key naming no locked package or a Flutter SDK package fails evaluation; a key whose package has no iOS or macOS Apple sources, or uses an overlay `BUILD`, fails the spoke fetch because the dependency would reach nothing.

### Regenerating pubspec.lock

Bazel reads `pubspec.lock` and never writes it. To regenerate it, use the Flutter toolchain the rules pin rather than a Flutter installed on your machine:

```sh
bazel run @rules_flutter//flutter:pub -- get       # after editing pubspec.yaml
bazel run @rules_flutter//flutter:pub -- upgrade
bazel run @rules_flutter//flutter:pub -- add qr
```

Arguments pass through to `dart pub` unchanged, and the command runs at your workspace root, so the lock lands where `flutter.pub` reads it.

The version of Flutter that resolves the lock matters, and a mismatch is easy to miss. Pub treats the running Dart and Flutter versions as constraints, so an older installation quietly picks older packages, and the lock it writes is still valid. For example, resolving `e2e/plugin_example` with Flutter 3.41.6 pins `meta 1.17.0`, while the pinned 3.44.1 toolchain pins `meta 1.18.0`. Nothing downstream can tell the difference.

The fetched toolchain contains engine artifacts and a Dart SDK but no `bin/flutter`, so this target runs `dart pub` with `FLUTTER_ROOT` pointed at a tree assembled from the same Flutter release. That tree is fetched the first time you run the target. Because it is `dart pub` rather than `flutter pub`, it writes `pubspec.lock` and `.dart_tool/package_config.json` and does not write `.flutter-plugins-dependencies`. rules_flutter generates plugin registrants from the build graph, so nothing needs that file.

A package below the workspace root, such as a `tools/*` package, is resolved by the same target with pub's `--directory` flag. The path is relative to the workspace root:

```sh
bazel run @rules_flutter//flutter:pub -- get --directory tools/my_tool
```

### Packages with build hooks

Some pub packages compile native code through a Dart `hook/build.dart` (Dart Native Assets). Bazel does not run those hooks. Instead:

- **Curated replacements.** rules_dart keeps a registry of Bazel-native equivalents (`@rules_dart//dart/ext:registry.bzl`). Where one exists, such as `sqlite3`, `flutter.pub` attaches it automatically. An app that depends on `drift` gets `libsqlite3` without naming it.
- **Overlays.** For a package with a hook and no curated entry, you can write a `BUILD.bazel.tpl` that reproduces what the hook builds. rules_flutter bundles overlays under `ext/`, and you can add your own with `flutter.plugin_overlays(roots = [...])`. A hub consults the root module's roots first, then its own module's roots, so a dependency's overlays never replace the BUILD files of the root's packages (or another module's). Authoring one is described in [docs/TESTING.md](docs/TESTING.md) under "Native Assets overlay authoring".
- **Ignoring a hook.** If a package's native code is never reached in your app, say so: `flutter.pub(ignore_hooks = ["<package>"])`.

A hook that nothing replaces is an error when `flutter_application` reaches it. The alternative would be a build that succeeds and then fails at runtime on an unresolved `@Native` symbol.

### Native code from Bazel

A Flutter app can depend on native code built by any Bazel rule that produces a shared library: `rules_cc`, `rules_rust`, and so on. List the library in `native_deps` and it is bundled beside the app, where `dart:ffi` can open it:

```starlark
cc_shared_library(
    name = "my_native_lib",
    deps = [":my_cc_lib"],
)

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    native_deps = [":my_native_lib"],
    deps = ["@deps//:flutter"],
)
```

If you would rather bind with `@Native(assetId: ...)` and let the Dart VM find the library, declare it as a Native Asset with `flutter_native_asset` from `@rules_flutter//flutter:native_assets.bzl`, and carry it on a `flutter_plugin`. `e2e/ffi_example` shows both styles side by side.

#### Native edits in the dev loop

A running process cannot pick up a rebuilt native library; it keeps the one it already loaded. After an edit to native code, run `flutter_dev run` again: it rebuilds the app, and the stock tool reinstalls and relaunches it.

On the web the same wrapper goes in `flutter_web_bundle`'s `native_modules`, which both serves the `.wasm` module and declares it. The situation is the same: the page instantiates the module once and a hot reload does not re-run `main()`. A web hot restart does re-run `main()`, so it re-fetches the module with no relaunch.

### Bazel modules

What a plain consumer's module graph pulls in, by feature. Floors are what `rules_flutter`'s own `MODULE.bazel` declares; higher versions resolve by MVS as usual, except where noted.

| Feature | Modules | Notes |
|---|---|---|
| Every app | `ai_rules_dart` 0.28.3 (repo_name `rules_dart`; the `Mivr` fork release, taken via `archive_override` above), `bazel_skylib`, `platforms`, `package_metadata` | Dart compilation, hooks, codegen. |
| iOS / macOS bundles | `rules_apple` ≥ 4.5.3, `rules_swift`, `apple_support`, `rules_cc` | 4.5.3 is the proven floor: `e2e/min_versions` pins it exactly and builds both Apple legs. `rules_swift`/`apple_support` float to the graph's maxima (4.5.3 accepts Swift at compatibility level 3). |
| Android APK | `rules_android` 0.8.0, `rules_kotlin`, `rules_java`, `rules_jvm_external` 7.1, `rules_go` ≥ 0.59.0 | 0.8.0 is the floor: the signing overlay reads `rules_android`'s `apk_signing_method` flag, which exists only in 0.8.0+. The pinned `go_sdk.download` (Go 1.26.2, checksummed) in `rules_flutter`'s `MODULE.bazel` applies to every consumer without its own `go_sdk` block — it sorts before `rules_android`'s bundled unpinned 1.22.4 whatever order the root lists the modules in, while a root `go_sdk` block still wins; plain consumers fetch no Go SDK until a Go toolchain resolves. The `.bazelrc` Java settings above are required, and the build host needs `unzip` and `python3` for the AAR extractors. |
| xtool Darwin backend (opt-in) | `llvm` 0.8.19, exec-host toolchain archive only | Needs only `flutter.darwin_sdk(url = ..., sha256 = ...)` or `flutter.darwin_sdk(path = ...)` in the root module — no other `MODULE.bazel` lines. Plain consumers fetch no LLVM archive and register no LLVM toolchain (see `docs/dependencies.md`). |
| Repository tools, `gen_l10n` | Resolved inside `rules_flutter` | `rules_flutter_tool_deps` and `rules_flutter_gen_l10n_deps` are the ruleset's own isolated `pub.from_lock` hubs in rules_dart's `pub` extension, shipped with their plans, so a consumer makes no pub request for them and never names them. |
| No feature | No `rules_python` | The iOS screenshot/tunnel helpers are `dart_binary` drivers over a host `python3` (a documented host prerequisite like Xcode), so neither this repo's graph nor any consumer's contains `rules_python`. |

Dev-only and never evaluated by consumers: `rules_multitool`, `buildifier_prebuilt`, `bazelrc-preset.bzl`, the eight `@llvm//toolchain:*` registrations, and the root-only `single_version_override` pinning this repo's own builds to `rules_apple` 5.2.0. (The `go_sdk.download` pin, by contrast, is a regular dependency so every consumer's Android host tools use it; it only downloads when a Go toolchain resolves. `llvm` itself is a regular dependency so the opt-in xtool backend can resolve it, but only a configured `flutter.darwin_sdk` — or this repo's own builds — fetches a toolchain archive.)

## Building for each platform

Every platform has two levels of API:

- **A convenience macro** such as `flutter_macos_app`. It finds the runner files `flutter create` wrote, wires up every internal target, and is what most apps should use.
- **Composable rules** such as `flutter_macos_runner_lib_gen`, for when you need control over a piece the macro decides for you. Each platform section shows them in a collapsed block.

The macros take `flutter create` output as it is. You do not need to edit the generated `Runner` folders.

### macOS

Requires Xcode. Run `flutter create --platforms=macos .` first so `macos/Runner/` exists.

```starlark
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    app_name = "My App",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `bundle_id` | The macOS bundle identifier. Required. |
| `app_name` | Display name for the menu bar and window title. Defaults to the target name. |
| `minimum_os_version` | Defaults to `"12.0"`, which is what the prebuilt engine is built for. A lower value is refused rather than warned about. |
| `info_plist` | Replaces the discovered `macos/Runner/Info.plist`. |
| `version` | An `apple_bundle_version` target. Defaults to `"1.0"`. |
| `entitlements` | Replaces the entitlements wiring. By default the macro finds `macos/Runner/DebugProfile.entitlements` and `Release.entitlements` and picks one by compilation mode. |
| `additional_entitlements` | Entitlement plist files merged into the selected base in every compilation mode. See [Release builds and permissions](#release-builds-and-permissions). |
| `app_icons` | Defaults to the `AppIcon.appiconset` in `macos/Runner/Assets.xcassets`. See [App icons](#app-icons). |
| `runner_deps` | `swift_library` targets linked into the runner. See [App Intents](#app-intents). |

The output is a `.app` bundle containing `FlutterMacOS.framework`, `App.framework`, and `flutter_assets/`.

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:macos.bzl",
    "flutter_entitlements_merge",
    "flutter_macos_engine",
    "flutter_macos_framework_gen",
    "flutter_macos_info_plist_gen",
    "flutter_macos_menu_xib_gen",
    "flutter_macos_native_libs_gen",
    "flutter_macos_registrant_gen",
    "flutter_macos_runner_lib_gen")

flutter_macos_framework_gen(name = "my_framework", application = ":my_app")
flutter_macos_registrant_gen(name = "my_registrant", application = ":my_app")
flutter_macos_engine(name = "my_engine")
flutter_macos_native_libs_gen(name = "my_native_libs", application = ":my_app")
flutter_macos_info_plist_gen(name = "my_info_plist", app_name = "My App")
flutter_macos_menu_xib_gen(name = "my_menu_xib", app_name = "My App")

flutter_macos_runner_lib_gen(
    name = "my_runner",
    registrant = ":my_registrant",
    engine = ":my_engine",
)

# rules_apple's `entitlements` takes one file. This merges additions into it.
# Additions only; a key present in both with different values is an error.
# Also exported from flutter:ios.bzl.
flutter_entitlements_merge(
    name = "my_entitlements",
    base = "macos/Runner/Release.entitlements",
    additions = ["entitlements/Network.entitlements"],
)

macos_application(
    name = "my_macos_app",
    bundle_id = "com.example.myapp",
    additional_contents = {
        ":my_framework": "Frameworks",
        ":my_native_libs": "Frameworks",
    },
    infoplists = [":my_info_plist"],
    resources = [":my_menu_xib"],
    deps = [":my_runner"],
)
```

</details>

### iOS

Requires Xcode. Run `flutter create --platforms=ios .` first so `ios/Runner/` exists, and add `flutter_ios_engine` to `use_repo`.

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_app")

flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. The app's flavor comes from this target (`flavor = "prod"`): `flutter_ios_app` has no `flavor` attribute, so declare one `flutter_application` and one `flutter_ios_app` per flavor; there is no second way to set the flavor. |
| `bundle_id` | The iOS bundle identifier. Required. |
| `families` | Device families. Defaults to `["iphone"]`, unlike `flutter create` (iPhone and iPad). An iPhone-only app runs in a small window on iPadOS. Adding `"ipad"` needs an icon set without the 76x76@1x iPad icon `flutter create` generates, which `actool` rejects. |
| `app_name` | Display name. Defaults to the target name. |
| `minimum_os_version` | Defaults to `"15.0"`, which is what the prebuilt engine is built for. A lower value is refused rather than warned about. |
| `info_plist` | Replaces the discovered `ios/Runner/Info.plist`. |
| `version` | An `apple_bundle_version` target. Defaults to `"1.0"`. |
| `launch_storyboard` | Replaces the launch storyboard. |
| `entitlements` | Replaces the entitlements wiring. By default the macro uses `ios/Runner/Runner.entitlements` if it exists. An app with no entitlements file is fine. |
| `additional_entitlements` | Entitlement plist files merged into the base in every compilation mode. Works even when the app has no entitlements file. See [Release builds and permissions](#release-builds-and-permissions). |
| `provisioning_profile` | A `.mobileprovision` file, usually a `local_provisioning_profile` target. Required for device builds, unused by simulator builds. See [Running on an iOS device](#running-on-an-ios-device). |
| `signing` | Whether to code sign the bundle. Defaults to `True`. On `rules_apple`, a device build always needs a `provisioning_profile`, so `False` is refused at analysis; an unsigned device bundle is the `xtool` backend's output. See [Unsigned device builds](#unsigned-device-builds). Separately, on `rules_apple` a `-c dbg` simulator bundle skips code signing by default (`apple.skip_codesign_simulator_bundles`); `features = ["-apple.skip_codesign_simulator_bundles"]` signs it as before, and device and `-c opt` builds are unaffected. |
| `app_icons` | Defaults to the `AppIcon.appiconset` in `ios/Runner/Assets.xcassets`. See [App icons](#app-icons). |
| `runner_deps` | `swift_library` targets linked into the runner. See [App Intents](#app-intents). |
| `exclude_plugins` | Plugin module names left out of the registrant. iOS only: the Android, Linux, macOS and Windows registrants take no such attribute and always register every collected native plugin. See [iOS plugin registrant](#ios-plugin-registrant). |
| `generated_registrant` | Whether the macro generates the Swift plugin registrant and wires it into the app. Defaults to `True`. `False` defines no registrant target and leaves the app's own registrant, listed in `additional_deps`, to register the plugins. See [iOS plugin registrant](#ios-plugin-registrant). |
| `swift_copts` | Extra flags for the runner's `swift_library`, appended after the flags the macro sets itself. `rules_apple` only; a non-empty list on the `xtool` backend fails at analysis. See [iOS plugin registrant](#ios-plugin-registrant). |
| `additional_deps` | Labels appended to the final bundle's `deps`, after the runner, `App.framework` and the native frameworks, so a library that implements the app's own registrant is linked into the app. Not added to the runner; `runner_deps` does that. See [iOS plugin registrant](#ios-plugin-registrant). |

`rules_apple`'s `ios_application` handles the transition to iOS arm64.

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:ios.bzl",
    "flutter_entitlements_merge",
    "flutter_ios_engine",
    "flutter_ios_framework_gen",
    "flutter_ios_info_plist_gen",
    "flutter_ios_native_frameworks_gen",
    "flutter_ios_registrant_gen",
    "flutter_ios_runner_lib_gen")

flutter_ios_framework_gen(name = "my_framework", application = ":my_app")
flutter_ios_registrant_gen(name = "my_registrant", application = ":my_app")
flutter_ios_engine(name = "my_engine")
flutter_ios_info_plist_gen(name = "my_info_plist", app_name = "My App")

# Frameworks for the app's Native Assets and `native_deps` libraries. If you
# leave this out of `deps` below, the app builds and renders normally and
# then fails every native call at runtime.
flutter_ios_native_frameworks_gen(name = "my_native_frameworks", application = ":my_app")

flutter_ios_runner_lib_gen(
    name = "my_runner",
    registrant = ":my_registrant",
    engine = ":my_engine",
)

ios_application(
    name = "my_ios_app",
    bundle_id = "com.example.myapp",
    families = ["iphone"],
    minimum_os_version = "15.0",
    deps = [":my_framework", ":my_native_frameworks", ":my_runner"],
)
```

`flutter_ios_framework_gen` keeps `flutter_assets` inside `App.framework` in
every build. A debug build that assembles its own bundle can leave the assets
out of the framework, so rules_apple's imported-framework processor does not
re-copy the kernel on every Dart edit. Call the `flutter_ios_framework` rule
directly with `split_debug_assets = True`, take its `flutter_assets` output
group, and add the files to the app root with an `apple_resource_group`:

```starlark
load("@rules_apple//apple:resources.bzl", "apple_resource_group")
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_framework")

flutter_ios_framework(
    name = "my_framework_split",
    application = ":my_app",
    split_debug_assets = True,
)

filegroup(
    name = "my_split_assets",
    srcs = [":my_framework_split"],
    output_group = "flutter_assets",
)

apple_resource_group(
    name = "my_split_assets_group",
    structured_resources = [":my_split_assets"],
    strip_structured_resources_prefixes = ["my_framework_split/App.framework"],
)

ios_application(
    name = "my_ios_app",
    resources = [":my_split_assets_group"],
    # ...plus the deps shown above.
)
```

A debug app then has `Runner.app/flutter_assets/...` at its root. An AOT
(release or profile) build ignores the request: its assets stay inside
`App.framework` and the output group is empty.

</details>

#### Add-to-app xcframeworks

`flutter_ios_xcframeworks` produces the xcframework set Flutter's add-to-app
docs ask an existing Xcode project to link, without building an
`ios_application` with Bazel:

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_xcframeworks")

flutter_application(
    name = "my_app",
    main = "lib/main.dart",
    deps = ["@deps//:flutter"],
)

flutter_ios_xcframeworks(
    name = "my_app_xcframeworks",
    application = ":my_app",
)
```

The target's files are four kinds of xcframework:

- **`App.xcframework`** has exactly two slices: `ios-arm64/App.framework` for a
  device and `ios-arm64_x86_64-simulator/App.framework` for the simulator.
  Both carry an AOT snapshot; the simulator slice is universal arm64 +
  x86_64.
- **`Flutter.xcframework`** is the pinned engine the rules already select for
  the configuration. Its files are links to that engine, not copies.
- **`FlutterPluginRegistrant.xcframework`** links the application's generated
  `GeneratedPluginRegistrant.swift`.
- **One `<Plugin>.xcframework` per native iOS plugin** in the application's
  transitive graph.

The layout and every `Info.plist` are written by the rule, so no
`xcodebuild -create-xcframework` runs. Drag the directories into the Xcode
target's "Frameworks, Libraries, and Embedded Content" and set them to
"Embed & Sign". The target is `manual` and macOS-only by default because the
AOT slices need a Darwin host.

See [Add-to-app iOS xcframeworks](docs/ios-add-to-app.md) for the full
attribute reference, the slice layout and the e2e proof.

#### Running on an iOS device

Simulator builds need no code signing, and a `-c dbg` simulator bundle is not code signed by default: `flutter_ios_app` enables rules_apple's `apple.skip_codesign_simulator_bundles` there, which saves about 3 s of `ProcessAndSign` per edit. Device builds and `-c opt` builds are signed as before. To sign a debug simulator bundle, pass `features = ["-apple.skip_codesign_simulator_bundles"]`. Device builds need a provisioning profile, which is per-developer and should stay out of version control. `flutter_ios_app` takes it directly:

```starlark
# In a git-ignored //device package, so the credential stays local.
load("@rules_apple//apple:apple.bzl", "local_provisioning_profile")

local_provisioning_profile(
    name = "profile",
    profile_name = "iOS Team Provisioning Profile: *",
    tags = ["manual"],
)
```

```starlark
flutter_ios_app(
    name = "my_app_ios_device",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    provisioning_profile = "//device:profile",
)
```

That is the only difference from the simulator target, unless the app ships entitlements its profile cannot grant — see below. `flutter_ios_app` is tagged `manual` by default, so `bazel build //...` on a fresh clone does not try to load the missing `//device` package.

Keep the app target in the committed BUILD file and put only the `local_provisioning_profile` in `//device`. The profile is the one genuinely per-developer fact. If the whole device app lives in a git-ignored package it is invisible to review and CI, and it drifts. Two of this repository's own examples once had a device app that had quietly diverged from its committed simulator twin. The same advice applies if you assemble the app from the composable rules: give the device `ios_application` the same `deps` as the simulator one.

Then run it:

```sh
bazel run @rules_flutter//tools/flutter_dev -- run --bazel-target=//:my_app_ios_device -d <device id>
```

Each iOS example ships a `device.example/` folder. Copy it to a git-ignored `device/` and set your bundle id.

**Finding the profile's name.** `profile_name` matches the profile's `Name` field, and that is not always `iOS Team Provisioning Profile: <bundle id>`. Xcode mints a per-bundle-id profile only for an App ID registered in the developer portal. For an unregistered id, which most example and scratch apps have, automatic signing issues the team wildcard profile, `iOS Team Provisioning Profile: *`, and that is what covers your bundle id. List what you have:

```sh
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -extract Name raw -
done
```

Without `provisioning_profile`, and with `signing` left on, a device build fails at analysis with "The provisioning_profile attribute must be set for device builds on this platform (ios)".

**Entitlements your profile cannot grant.** A simulator build is ad-hoc signed and validates nothing. A device build is signed against the profile, and an entitlement the profile does not grant fails it:

```
Target "//:my_app_ios_device" uses entitlements with the "aps-environment" key,
but the profile does not have this key
```

`aps-environment` is the common one. Xcode writes it into `ios/Runner/Runner.entitlements` the moment Push Notifications is enabled, it stays there long after the code that used it is gone, and a team wildcard profile can never grant it — push requires a registered App ID. The message names the profile, so the file is the last place you look, and `flutter_ios_app` discovers it silently because it is on disk. Pass `entitlements = False` on the device target to ship none:

```starlark
flutter_ios_app(
    name = "my_app_ios_device",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    entitlements = False,
    provisioning_profile = "//device:profile",
)
```

Deleting the file is the wrong fix. It is the app's real answer for the profile that *does* grant push, and Xcode will write it again.

#### Unsigned device builds

`rules_apple` builds a device app only with a `provisioning_profile`: its device
pipeline adds a provisioning-profile step to every build, and no feature turns
that step off. `signing = False` therefore fails at analysis on that backend,
with an error naming the target and saying that rules_apple requires a
`provisioning_profile` for every device build.

An unsigned device bundle is the `xtool` backend's output:

```starlark
flutter_ios_app(
    name = "my_app_ios_device_unsigned",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    backend = "xtool",
    signing = False,
)
```

This is the bundle shape `flutter build ios --no-codesign` produces: no profile
embedded and no `LC_CODE_SIGNATURE` written. On `xtool`, `signing = False`
keeps any `features` the caller passes unchanged and rejects a
`provisioning_profile` and every signing attribute (`zsign`, `certificate`,
`certificate_password_file`, `certificate_password_env`,
`certificate_password`), because those ask for signing. Running on a device
still needs the signed target above. The `xtool` backend cannot build the
examples in this repository: it rejects their storyboards and asset catalog.

**Getting a profile.** This is an Apple Developer account operation, and the rules cannot do it for you. You need a development profile whose App ID matches your `bundle_id`, installed under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Either create the App ID and a profile in the developer portal, download it, and double-click it, or let Xcode do it from any project with the right bundle id and automatic signing:

```sh
xcodebuild -project <some>.xcodeproj -scheme <scheme> -configuration Debug \
  -destination generic/platform=iOS \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

The project can be a scratch project. It does not need to be the app you build with Bazel, which has no `.xcodeproj` at all. Free "Personal Team" profiles expire after about seven days. When a build fails with "no provisioning profile was found named …", mint a fresh one.

#### Checking an iOS release build

There is no way to run a release iOS build without a signing credential. That matters because release-only problems, such as [missing permissions](#release-builds-and-permissions), show up when you run the app, not when you read the code.

- **Device, `-c opt`.** The real thing. Needs a provisioning profile.
- **Simulator, `-c opt`.** Refused at analysis: "The iOS simulator runs debug builds only". So is the default `fastbuild`. The simulator engine runs kernel under the JIT and cannot load an AOT snapshot, so such a bundle would install, launch, and show a blank white screen with only `Engine run configuration was invalid` in the system log. `flutter build ios --simulator --release` refuses it too.

Use `-c dbg` on the simulator and a device for release. A test that needs a simulator bundle under a plain `bazel test //...` gets one from `flutter_ios_simulator_build`, which builds its `targets` with `-c dbg` whatever the command line says. Name it in a test's `data`, or use `flutter_ios_simulator_build_test` in place of a `build_test`:

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_simulator_build_test")

flutter_ios_simulator_build_test(
    name = "ios_app_build_test",
    targets = [":app_ios"],
)
```

#### iOS plugin registrant

By default the registrant is `GeneratedPluginRegistrant.swift`: the runner is Swift and calls it directly. Apps whose runner is Objective-C (`AppDelegate.m`) need the Objective-C registrant instead, which is a composable-rules build: `language = "objc"` on `flutter_ios_registrant_gen` emits `GeneratedPluginRegistrant.h` and `GeneratedPluginRegistrant.m` matching the flutter tool's own template, exposed through the `hdrs` and `srcs` output groups. Wire the groups into your own library — `includes` names the registrant's output directory so other sources can use `#import "GeneratedPluginRegistrant.h"` (the `.m` needs no flag: it imports its sibling header with quotes):

```starlark
load("@rules_cc//cc:objc_library.bzl", "objc_library")

flutter_ios_registrant_gen(
    name = "my_registrant",
    application = ":my_app",
    language = "objc",
)

filegroup(name = "registrant_hdrs", srcs = [":my_registrant"], output_group = "hdrs")
filegroup(name = "registrant_srcs", srcs = [":my_registrant"], output_group = "srcs")

objc_library(
    name = "my_registrant_lib",
    hdrs = [":registrant_hdrs"],
    srcs = [":registrant_srcs"],
    includes = ["my_registrant"],
)
```

`exclude_plugins` drops named plugin modules from the registrant — no import and no registration call, in either language — for plugins compiled conditionally or linked elsewhere. It is iOS-only: the other platforms' registrants always register every collected native plugin, so an Android or desktop build cannot drop one. A name that is not a native iOS plugin of the application is an error listing the valid names, so a typo fails the build instead of silently shipping an unregistered plugin:

```starlark
flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    exclude_plugins = ["deferred_plugin"],
)
```

##### Supplying your own registrant

An app that registers its plugins itself — an Objective-C runner, or a Swift runner with its own registrant — turns the generated one off and links its library into the bundle. `generated_registrant = False` defines no `__<name>_registrant` target and adds no registrant source to the runner: on `rules_apple` the runner `swift_library` takes only the app's sources, and on `xtool` the bundle is built without a `registrant`. `additional_deps` appends labels to the final bundle's `deps` after the runner, `App.framework` and the native frameworks, so the library that implements the registrant is linked into the app. It is separate from `runner_deps`, which is for libraries the runner's own sources import.

```starlark
load("@rules_cc//cc:objc_library.bzl", "objc_library")

# The app's own Objective-C registrant. `generated_registrant = False`
# leaves it out of the runner, and `additional_deps` links it into the app.
objc_library(
    name = "own_registrant",
    srcs = ["CustomPluginRegistrant.m"],
    hdrs = ["CustomPluginRegistrant.h"],
    includes = ["."],
)

# A bridging header the Swift runner imports. Listing it here makes the
# header an input of the runner's compile action.
objc_library(
    name = "bridging_header",
    hdrs = ["Runner-Bridging-Header.h"],
)

flutter_ios_app(
    name = "my_objc_ios_app",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    generated_registrant = False,
    additional_deps = [":own_registrant"],
    runner_deps = [":bridging_header"],
    swift_copts = [
        "-import-objc-header",
        "$(execpath :Runner-Bridging-Header.h)",
    ],
)
```

`swift_copts` is appended to the runner `swift_library`'s `copts` after the flags the macro sets itself. It is supported on the `rules_apple` backend only: the `xtool` bundle rule compiles the runner itself, so a non-empty `swift_copts` there fails at analysis with an error naming the attribute instead of being dropped.

A file named by a `$(execpath ...)` flag must also be an input of the runner, for example through a target listed in `runner_deps`, because an undeclared input fails the sandbox.

`exclude_plugins` only edits a registrant the macro generates, so combining it with `generated_registrant = False` is an analysis error naming both attributes.

### App icons

On Apple platforms the icon comes from an asset catalog. `actool` compiles the catalog and needs to be told which set inside it is the app icon, which is what `rules_apple`'s `app_icons` attribute does and what listing the same PNGs under `resources` cannot. `flutter_ios_app` and `flutter_macos_app` find the `AppIcon.appiconset` that `flutter create` wrote and forward it, so an app that never mentions its icon ships the one in its tree, the same as `flutter build`.

To ship a different icon, pass `app_icons` the files of an `.appiconset` or of an Icon Composer `.icon` bundle. `rules_apple` 4.5+ generates the older sizes from an `.icon` bundle. Name one or the other, not both. `app_icons = []` ships no icon.

Discovery is per platform, and a missing catalog is not an error. A tree made with `flutter create --platforms=ios .` has `ios/Runner/Assets.xcassets` and no macOS counterpart, so the iOS app gets its icon and the macOS app gets the placeholder. If one platform shows your icon and the other does not, check for the catalog first.

macOS icons use the platform's own grid rather than a full-bleed square: the rounded shape sits inset to roughly 824 of the 1024-point canvas, which is what makes it line up with other Dock icons. The rules pass the catalog through untouched.

One `flutter create` quirk is handled for you on macOS. Its `Info.plist` declares `CFBundleIconFile` as an empty string for Xcode to fill in, while `macos_application` generates its own value from the catalog, and Apple's plisttool refuses two different values for one key. The macro drops the empty placeholder. A plist that names a real icon file is left alone, and will still conflict if you also pass `app_icons`.

### App Intents

To ship App Intents, give the Swift library to two attributes. `runner_deps` links it into the runner, so its code is in the binary. rules_apple's `app_intents` (which passes through `**kwargs`) extracts the metadata into the bundle: `Contents/Resources/Metadata.appintents` on macOS, `Metadata.appintents` at the bundle root on iOS. `app_intents` does not link the library, and `runner_deps` does not extract anything, so an app that gives it to only one ships either metadata with no code or code that the system never learns about.

```starlark
swift_library(
    name = "intents",
    srcs = ["Intents/PingIntent.swift"],
    # rules_apple's aspect refuses a library that does not name the framework.
    linkopts = ["-Wl,-framework,AppIntents"],
    module_name = "Intents",
)

flutter_macos_app(
    name = "app",
    app_intents = [":intents"],
    runner_deps = [":intents"],
    # ...
)
```

`e2e/macos_example` and `e2e/ios_example` each build such an app and check the bundle names the intent and the binary links it. When `appintentsmetadataprocessor` fails on a schema validation error, rules_apple's wrapper reports `version.json.sorted: No such file or directory` and hides the processor's own message. Run the processor by hand to read the real error.

### App extensions

Widgets, Control Center controls, share extensions and other app extensions are written in Swift and built with rules_apple's `ios_extension` or `macos_extension`. `flutter_ios_app` and `flutter_macos_app` pass `extensions` through to `ios_application` and `macos_application`, which embed each `.appex` in `PlugIns/` (iOS) or `Contents/PlugIns/` (macOS). Flutter does not run inside an extension: an extension cannot link the Flutter engine or Dart code from these rules. Share data with the app through an App Group instead.

```starlark
load("@rules_apple//apple:ios.bzl", "ios_extension")
load("@rules_apple//apple:versioning.bzl", "apple_bundle_version")
load("@rules_swift//swift:swift.bzl", "swift_library")

apple_bundle_version(
    name = "version",
    build_version = "1.0",
    short_version_string = "1.0",
)

swift_library(
    name = "widgets_lib",
    srcs = ["extensions/Widgets.swift"],
    linkopts = ["-Wl,-framework,AppIntents"],
    module_name = "Widgets",
)

ios_extension(
    name = "widgets",
    app_intents = [":widgets_lib"],
    bundle_id = "com.example.myapp.widgets",
    entitlements = "extensions/AppGroup.entitlements",
    families = ["iphone"],
    infoplists = ["extensions/Widgets-Info.plist"],
    minimum_os_version = "17.0",
    version = ":version",
    deps = [":widgets_lib"],
)

flutter_ios_app(
    name = "my_app_ios",
    additional_entitlements = ["extensions/AppGroup.entitlements"],
    application = ":my_app",
    bundle_id = "com.example.myapp",
    extensions = [":widgets"],
)
```

What the extension needs:

- **A version equal to the app's.** rules_apple gives an extension no version unless you pass one, and the system expects an extension's version to match its app's. `flutter_ios_app` and `flutter_macos_app` default to 1.0, so pass an `apple_bundle_version` of 1.0, or the same one you give the app.
- **A bundle id under the app's**, such as `com.example.myapp.widgets`.
- **An Info.plist with the bundle keys.** Besides `NSExtension` and its `NSExtensionPointIdentifier`, give `CFBundleName` (`$(PRODUCT_NAME)`), `CFBundleExecutable` (`$(EXECUTABLE_NAME)`), `CFBundleIdentifier` (`$(PRODUCT_BUNDLE_IDENTIFIER)`) and `CFBundlePackageType` `XPC!`. Without them the simulator refuses to install the app.
- **Its App Intents.** A control's button, an interactive widget or a configurable widget runs an App Intent in the extension, so give the library to the extension's `app_intents` as well as its `deps`. rules_apple 5.2.0's `macos_extension` has no `app_intents` attribute. `e2e/macos_example/patches/` has a patch that adds it; apply it with `single_version_override(module_name = "rules_apple", version = "5.2.0", patch_strip = 1, patches = [...])`. Overrides only apply in the root module, so an app needs the override in its own `MODULE.bazel`; it does not come with rules_flutter.
- **On macOS, a sandbox.** macOS loads a widget or share extension only if its entitlements include `com.apple.security.app-sandbox`.
- **Visibility** to the package of the app target, if it lives elsewhere. `flutter_ios_app` and `flutter_macos_app` must sit in the package that holds `ios/Runner/` or `macos/Runner/`.

An extension can have a higher `minimum_os_version` than the app. rules_apple accepts that without comment and each bundle records its own minimum, so the system skips the extension on an older OS. Control Center controls need iOS 18 or macOS 26; either raise the extension's minimum or include the control in the `WidgetBundle` behind `if #available`, as the examples do.

**App Groups.** Give each extension an `entitlements` file with `com.apple.security.application-groups`, and merge the same file into the app with `additional_entitlements`. A simulator build is not checked against anything, so the group works there. On macOS, the `group.` form needs a provisioning profile that lists the group, and the team-prefixed form (`<TEAM ID>.name`) needs a signature from that team, which a team wildcard profile gives without listing any group. An app signed ad hoc gets neither: it builds, and its extensions register, but writes into the group container are refused.

**Signing.** rules_apple signs each extension in its own target, so the app's `provisioning_profile` does not reach its extensions. Give each extension its own `provisioning_profile`. On macOS, an extension without one is signed with the build's `--@rules_apple//apple/build_settings:signing_certificate_name`, and with none set, ad hoc, so it has no team and loses its App Group even inside a team-signed app. A profile can only grant an App Group if it is made for an explicit App ID that has the group, so a device build with groups needs an App ID and a profile for the app and for each extension, registered in the developer portal. The team wildcard profile (`iOS Team Provisioning Profile: *`) covers any bundle id but grants no App Group, and a device build that asks for an entitlement its profile lacks fails. `e2e/ios_example` has a device variant, `:app_extensions_device`, signed with the wildcard; it leaves the App Group out of the app and its extensions for that reason. On macOS the wildcard is enough with a team-prefixed group: `e2e/macos_example`'s `:app_extensions_team` gives the app and each extension the `Mac Team Provisioning Profile: *` wildcard, and the app writes into its group container. Its profile and group live in a git-ignored `//device` package made from `device.example/`, because the group carries the team id. A macOS `local_provisioning_profile` needs `profile_extension = ".provisionprofile"`; rules_apple otherwise looks for a `.mobileprovision`. `codesign --verify --deep --strict` passes on an app whose extension was signed ad hoc, so it does not catch a missing profile; compare `TeamIdentifier` across the bundles instead, as `:verify_macos_team_signing_test` does.

`e2e/ios_example` and `e2e/macos_example` each build an app with a widget extension holding a widget and a control, and a share extension, and check where each lands, what each declares, and that all share one App Group.

### Android

Run `flutter create --platforms=android .` first so `android/app/src/main/` exists with its manifest, resources, and Kotlin sources.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_app")

flutter_android_app(
    name = "my_app_android",
    application = ":my_app",
    package_name = "com.example.myapp",
)
```

Add these to `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_android_ndk", version = "0.1.5")

use_repo(flutter, "deps", "flutter_toolchains", "flutter_android_engine_arm64")

# The NDK CC toolchain, used for native and FFI deps built for Android and
# to strip the engine's native libraries, as a Gradle build does.
android_ndk_repository_extension = use_extension(
    "@rules_android_ndk//:extension.bzl",
    "android_ndk_repository_extension",
)
use_repo(android_ndk_repository_extension, "androidndk")
register_toolchains("@androidndk//:all")
```

**Environment variables.** Two are needed, and both are read by repository rules while Bazel fetches:

| Variable | Value | Read by |
|---|---|---|
| `ANDROID_HOME` | The SDK root, for example `~/Library/Android/sdk`. | `rules_android` |
| `ANDROID_NDK_HOME` | A versioned NDK directory, for example `$ANDROID_HOME/ndk/28.2.13676358`. | `rules_android_ndk` |

`ANDROID_NDK_HOME` has to name the versioned directory, not the `ndk/` folder above it. Pointing at the parent fails with a message that mentions neither the variable nor the mistake:

```
Error in readdir: can't readdir(), not a directory:
  .../Android/sdk/ndk/toolchains/llvm/prebuilt/darwin-x86_64
```

Exporting the variables in your shell works. To put them in `.bazelrc`, use `--repo_env`. `--action_env` only reaches build actions, and repository rules never see it:

```bazelrc
common --repo_env=ANDROID_HOME=/path/to/Android/sdk
common --repo_env=ANDROID_NDK_HOME=/path/to/Android/sdk/ndk/28.2.13676358
```

**Persistent workers.** No Android worker flag is enabled: the preset and `e2e/android_example/.bazelrc` leave aapt2, desugar and dex at Bazel's defaults, because the gain was not measured (see [docs/perf-android-workers.md](docs/perf-android-workers.md)). Nothing needs turning off. To try workers yourself, add the flags to your own `.bazelrc.user`, and remove them to go back.

With `ANDROID_NDK_HOME` unset, the build stops during fetch:

```
ERROR: An error occurred during the fetch of repository
  'rules_android_ndk++android_ndk_repository_extension+androidndk':
  Error in fail: Either the ANDROID_NDK_HOME environment variable or the
  path attribute of android_ndk_repository must be set.
```

No platform flags are needed to build. `flutter_android_app` transitions the application, including its AOT compile and FFI deps, to the Android platform for its `android_abi`:

```sh
bazel build //:my_app_android
```

**Pure Go host tools.** `flutter_android_app` builds rules_android's Go host tools in rules_go pure mode: without a C++ toolchain, so the hermetic LLVM runtimes are never compiled from source. The APK is unchanged (only the host tools' own binaries differ). The setting is scoped to the app — desktop builds and your own Go targets keep their configuration. Opt out with `--@rules_flutter//flutter:android_pure_go=false`; you need that only if the app's own subtree contains cgo Go code, which pure mode cannot compile. Hand-assembled Tier-2 `android_binary` targets are unaffected either way: add the global `--@rules_go//go/config:pure=true` yourself if you want the same saving there and have no cgo Go code.

**Release signing.** The APK signs with the debug keystore, as an `android_binary` does. In debug builds (`-c dbg`), the default signature scheme is `v2` alone when `minSdkVersion` is 24 or higher, falling back to `v1_v2` below 24 (the repo's minimum SDK `21` requires v1 JAR signatures to install on Android API 21–23); an explicit `@rules_android//flags:apk_signing_method` flag overrides this default. To sign the APK with a release key, pass `keystore` (a `.jks` or PKCS#12 `.p12` file) together with `keystore_password_file` and `key_alias`; set `key_password_file` as well when the key has its own password. Both passwords travel as `file:` references to file inputs, so their text never appears on the command line. When `key_password_file` is unset, `--key-pass` is omitted and apksigner unlocks the key with the keystore password. Only each file's first line is read, so end it with a newline. A `keystore` without its password file or alias fails analysis naming the missing attribute. When `keystore` is unset, the `//flutter:android_release_keystore`, `//flutter:android_release_keystore_password_file` and `//flutter:android_release_key_alias` flags supply the same three values, so CI can inject a secret without editing BUILD files; an explicit attribute always wins over its flag. Every secret setting must name a target with exactly one file: a flag or attribute pointing at an empty or multi-file target fails analysis naming the setting, the target and the file count, instead of silently falling back to debug signing. Never hide a secret behind an `allow_empty` glob — a CI secret that was never written would otherwise have shipped a debug-signed release. Google Play requires an Android App Bundle for new apps, not an APK: build one with `flutter_android_aab` (see "Android App Bundle (AAB) for Google Play" below).

The release signing action always runs locally (`no-remote`): Bazel never uploads the keystore or the password files to a remote executor or a remote cache. A password file's content digest would otherwise land in the shared action cache, an execution log or a build event stream, where it is an offline brute-force oracle for a human-chosen password. Keep the secrets out of version control — have CI write them to gitignored files and point the flags at those — and out of remote and disk caches: a secret checked into the source tree is still an action input whose digest is recorded in the local disk cache and in any build event output you keep.

```sh
# //secret is a gitignored directory the CI job populates, never committed:
bazel build //:my_app_android \
  --@rules_flutter//flutter:android_release_keystore=//secret:upload \
  --@rules_flutter//flutter:android_release_keystore_password_file=//secret:store_pass \
  --@rules_flutter//flutter:android_release_key_alias=upload
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `package_name` | The Android package name, for example `"com.example.myapp"`. Required. |
| `app_name` | Display name. Defaults to the target name. |
| `android_abi` | `"arm64"` (default) or `"x64"`. Selects the engine and the Android platform. |
| `min_sdk_version` | Minimum Android SDK version. |
| `target_sdk_version` | Target Android SDK version. |
| `manifest` | A manifest you wrote yourself, used verbatim. Placeholders like `${applicationName}` are not substituted, so do not pass `flutter create`'s own manifest here; let the macro discover that one. |
| `debug_manifest` | A variant manifest whose permissions merge into `-c dbg` builds only. `None` (default) discovers `android/app/src/debug/AndroidManifest.xml`. A label overrides discovery. `False` disables variant handling. |
| `profile_manifest` | The same for profile builds. `None` (default) discovers `android/app/src/profile/AndroidManifest.xml`. |
| `permissions` | Permission names added to the manifest in every compilation mode, for example `["android.permission.INTERNET"]`. See [Release builds and permissions](#release-builds-and-permissions). |
| `keystore` | Release keystore (`.jks` or PKCS#12 `.p12`) signing the APK instead of the debug key. Needs `keystore_password_file` and `key_alias`. See [Release signing](#release-signing). |
| `keystore_password_file` | File holding the keystore password, read by apksigner through `--ks-pass file:<path>`. Falls back to the `//flutter:android_release_keystore_password_file` flag. |
| `key_alias` | Alias of the signing key inside `keystore`. Falls back to the `//flutter:android_release_key_alias` flag. |
| `key_password_file` | File holding the signing key's own password, read through `--key-pass file:<path>`. When unset, `--key-pass` is omitted and the keystore password unlocks the key. |
| `analyze_size` | Emit an instructions-size JSON breakdown (`<name>_size.json`) from `gen_snapshot`. Included in default outputs and exposed via the `analyze_size` output group. Default `False`. |
| `multidex` | Defaults to `"native"`. |

**Split APKs (debug).** In a debug build `flutter_android_app` can also emit the Dart payload (`flutter_assets/`, including the kernel blob) as its own split APK, and everything else (engine, dex, resources, manifest, native libraries) as a base APK. Both are signed with the app's signing configuration. They are two output groups, not default outputs, and a release build leaves both empty:

```
bazel build //:my_app_android -c dbg --output_groups=base_apk,payload_apk
```

A Dart edit changes only the payload split, so the base APK's bytes, and the inputs of its signing action, stay the same and the base is not re-signed. The single `<name>.apk` stays the default output and is what a release build produces.

**Code-size analysis.** Set `analyze_size = True` on `flutter_android_app` to pass `--print-instructions-sizes-to` to `gen_snapshot` and produce a `<name>_size.json` instruction-size breakdown. The file is a default output and also readable through the `analyze_size` output group:

```starlark
flutter_android_app(
    name = "my_app_android",
    application = ":my_app",
    package_name = "com.example.myapp",
    analyze_size = True,
)
```

Fetch it directly with:

```sh
bazel build //:my_app_android --output_groups=analyze_size
```

`analyze_size` works in every compilation mode that runs `gen_snapshot` (release and profile builds); in debug mode, where `gen_snapshot` does not run, it fails analysis.

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:android.bzl",
    "flutter_android_bundle",
    "flutter_android_engine",
    "flutter_android_manifest_gen",
    "flutter_android_manifest_merge",
    "flutter_android_permissions_manifest",
    "flutter_android_runner_lib_gen")
load("@rules_android//android:rules.bzl", "android_binary")

flutter_android_bundle(name = "my_bundle", application = ":my_app")
flutter_android_engine(name = "my_engine")
flutter_android_manifest_gen(name = "my_manifest", package_name = "com.example.myapp")

flutter_android_runner_lib_gen(
    name = "my_runner",
    package_name = "com.example.myapp",
    engine = ":my_engine",
)

android_binary(
    name = "my_apk",
    manifest = ":my_manifest",
    multidex = "native",
    deps = [":my_bundle_native_libs", ":my_engine", ":my_runner"],
)
```

`flutter_android_bundle` output groups:

| Group | Contents |
|---|---|
| `native_libs` | `libapp.so` (AOT code) plus any `native_deps` libraries |
| `flutter_assets` | The `flutter_assets/` tree |
| `mobile_install` | JNI-structured symlinks and assets for `bazel mobile-install` |

</details>

#### Android App Bundle (AAB) for Google Play

Google Play requires an Android App Bundle for new apps. `flutter_android_aab` takes the same `application` and `package_name` attributes as `flutter_android_app` and emits `<name>.aab`. It wires the same runner, plugin registrant and manifest, then builds the bundle with rules_android 0.8.0's public `android_application` macro (`@rules_android//android:rules.bzl`) and a minimal bundle config. The proto-format resource link, the module conversion and `bundletool build-bundle` are that macro's own actions, with the bundletool of its toolchain: the `com.android.tools.build:bundletool` Maven artifact locked by version and sha256 in `rules_android_maven_install.json`, so a missing or wrong checksum fails the build. The native libraries per ABI and `flutter_assets` go into the bundle's base module. Like `flutter_android_app`, it needs the Android SDK and NDK. rules_android 0.8.0 is the floor the rule was built against.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_aab")
load("@rules_flutter//flutter:defs.bzl", "flutter_application")

flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

flutter_android_aab(
    name = "my_app_aab",
    application = ":my_app",
    package_name = "com.example.myapp",
)
```

`bazel build //:my_app_aab` produces `my_app_aab.aab`. Pass `keystore`, `keystore_password_file` and `key_alias` (and `key_password_file` when the key has its own password), or set the `//flutter:android_release_*` flags, and the bundle is signed with `jarsigner` from the Bazel-managed JDK toolchain; the passwords are read from their files at execution time. **Without a keystore the bundle is unsigned**: the rule never debug-signs a release bundle, so sign it before uploading to Google Play. The `e2e/android_example` workspace runs `bundletool validate` and `bundletool dump manifest` on the produced bundle.

#### Android library (AAR) for a native host app

`flutter_android_aar` packages a `flutter_application` as an Android library, for a monorepo whose host app is native Android. It uses no Gradle and no host tool; the archive is made by one action over declared inputs.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_aar")
load("@rules_flutter//flutter:defs.bzl", "flutter_application")

flutter_application(name = "module", main = "lib/main.dart", deps = [...])

flutter_android_aar(
    name = "module_aar",
    application = ":module",
    package_name = "com.example.module",
    android_abi = "arm64-v8a",
)
```

| Attribute | Meaning |
|---|---|
| `application` | The `flutter_application`; transitioned to the Android platform for `android_abi`. |
| `package_name` | The package written to the AAR's `AndroidManifest.xml`. |
| `android_abi` | `"arm64-v8a"` (default) or `"x86_64"`. An unknown ABI fails analysis naming `android_abi`. |

`<name>.aar` holds `jni/<abi>/libapp.so` (the AOT-compiled Dart library for `android_abi`), `assets/flutter_assets/`, `AndroidManifest.xml`, an empty `classes.jar` and an empty `R.txt`. Only release (`-c opt`) and profile (`--//flutter:profile`) are packaged; a debug build fails analysis naming `flutter_android_aar` and `debug`, because a debug AAR needs the JIT kernel, which this rule does not package.

Output groups:

| Group | Contents |
|---|---|
| `engine_maven` | The pinned release `flutter.jar` for `android_abi` (the Java embedding classes and `libflutter.so`), taken from the `flutter_android_engine_<abi>` repository and its `release_sha256` pin. The rule adds no download and no checksum of its own. Release and profile both use the release `flutter.jar`. |

A host app consumes the AAR with `aar_import` and the engine jar with `java_import`, selecting the group with a filegroup:

```starlark
load("@rules_android//android:rules.bzl", "aar_import", "android_binary", "android_library")
load("@rules_java//java:java_import.bzl", "java_import")

filegroup(
    name = "module_engine",
    srcs = [":module_aar"],
    output_group = "engine_maven",
)

aar_import(name = "module_import", aar = ":module_aar")

java_import(name = "module_engine_import", jars = [":module_engine"])

android_library(
    name = "host_lib",
    srcs = glob(["src/**/*.kt"]),
    deps = [":module_import", ":module_engine_import"],
)

android_binary(
    name = "host_app",
    manifest = "AndroidManifest.xml",
    deps = [":host_lib"],
)
```

Running the host app with the embedded module on an emulator is not covered yet: a later item adds an end-to-end workspace that does it, and the host-side snippet above is not built by CI until then.

### Linux

Run `flutter create --platforms=linux .` first. If `linux/runner/` is missing, the rules use a built-in runner.

```starlark
load("@rules_flutter//flutter:linux.bzl", "flutter_linux_app")

flutter_linux_app(
    name = "my_app_linux",
    application = ":my_app",
    gtk_app_id = "com.example.myapp",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `app_name` | Binary name. Defaults to the target name. |
| `gtk_app_id` | GTK application id. Defaults to `"com.example.flutter"`. A `linux/runner/` from `flutter create` gets it as `APPLICATION_ID`. |
| `window_title` | Window title. Defaults to `app_name`, then the target name. A `linux/runner/` from `flutter create` sets its own title and ignores this. |

The output directory:

```
my_app/
  my_app                     GTK runner executable
  lib/
    libapp.so                AOT-compiled Dart
    libflutter_linux_gtk.so  Flutter engine
    *.so                     native plugin libraries, if any
  data/
    flutter_assets/          fonts, images, shaders, asset manifest
    icudtl.dat               ICU data
```

**GTK3 and your C++ toolchain.** rules_flutter ships its own hermetic sysroot for the GTK3 headers and libraries, and links those libraries as explicit files. It adds no `-L` and no `-lgtk-3` flags. Your toolchain's `--sysroot` stays the only owner of libc, libm, and the rest of the C runtime. This matters because a Debian sysroot's `libm.so` is a linker script with absolute paths that `lld` rewrites only for scripts under `--sysroot`; a second sysroot on the search path would break `-lm` with a "no such file" error naming a file that exists.

**Cross-compiling from macOS** works in debug mode only, because Flutter publishes no cross-compiling `gen_snapshot` for desktop targets. See [Cross-compiling](#cross-compiling).

```sh
bazel build //:my_app_linux -c dbg --platforms=@rules_flutter//flutter/platforms:linux_x64
```

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:linux.bzl",
    "flutter_linux_bundle",
    "flutter_linux_engine",
    "flutter_linux_registrant_gen",
    "flutter_linux_runner_lib_gen")

flutter_linux_engine(name = "flutter_engine")
flutter_linux_registrant_gen(name = "app_registrant", application = ":my_app")

flutter_linux_runner_lib_gen(
    name = "my_runner",
    engine = ":flutter_engine",
    registrant = ":app_registrant",
    gtk_app_id = "com.example.myapp",
)

flutter_linux_bundle(
    name = "my_linux_app",
    application = ":my_app",
    runner = ":my_runner",
)
```

</details>

### Windows

Run `flutter create --platforms=windows .` first. If `windows/runner/` is missing, the rules use a built-in runner.

```starlark
load("@rules_flutter//flutter:windows.bzl", "flutter_windows_app")

flutter_windows_app(
    name = "my_app_windows",
    application = ":my_app",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `app_name` | Binary name. Defaults to the target name. |

The output directory:

```
my_app/
  my_app.exe             Win32 runner executable
  flutter_windows.dll    Flutter engine
  app.so                 AOT-compiled Dart, as ELF
  data/
    flutter_assets/      fonts, images, shaders, asset manifest
    icudtl.dat           ICU data
```

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:windows.bzl",
    "flutter_windows_bundle",
    "flutter_windows_engine",
    "flutter_windows_registrant_gen",
    "flutter_windows_runner_lib_gen")

flutter_windows_engine(name = "flutter_engine")
flutter_windows_registrant_gen(name = "app_registrant", application = ":my_app")

flutter_windows_runner_lib_gen(
    name = "my_runner",
    engine = ":flutter_engine",
    registrant = ":app_registrant",
)

flutter_windows_bundle(
    name = "my_windows_app",
    application = ":my_app",
    runner = ":my_runner",
)
```

</details>

### Web

Run `flutter create --platforms=web .` first so `web/` has its `index.html`, `manifest.json`, and icons. Add `flutter_web_sdk` to `use_repo`.

```starlark
load("@rules_flutter//flutter:web.bzl", "flutter_web_app")

flutter_web_app(
    name = "my_app_web",
    package_name = "my_app",
    main = "lib/main.dart",
    pubspec_srcs = glob(["assets/**"]),
    pub_packages = "@deps//packages",
    deps = ["@deps//:flutter"],
)
```

Unlike the other platforms, the web macro takes `main` and `deps` directly rather than a `flutter_application`. Web compilation goes through dart2wasm or dart2js, which is a different pipeline from the AOT one.

| Attribute | Description |
|---|---|
| `package_name` | The Dart package name, same as `pubspec.yaml`. Required. |
| `deps` | `dart_library` or `flutter_library` targets. Required. |
| `main` | The entry point. Defaults to `"lib/main.dart"`. It can sit outside the package's `lib/`; list any file it imports by relative path in `srcs`. |
| `pubspec`, `pubspec_srcs`, `pub_packages` | As on `flutter_application`. `pubspec` defaults to the package's `pubspec.yaml`, and the macro adds the files under `web/` to `pubspec_srcs`. See [Assets](docs/assets.md). |
| `base_href` | Substituted for `$FLUTTER_BASE_HREF` in `web/index.html`. Defaults to `"/"`. |
| `web_defines` | Values for `{{NAME}}` placeholders in `web/index.html` and `web/flutter_bootstrap.js`, as `flutter build web --web-define` takes them. |
| `pwa` | Ship `flutter_service_worker.js` and register it. Defaults to `True`. The worker adds no offline caching. Like `flutter build web`, which [deprecated its caching worker](https://github.com/flutter/flutter/issues/156910), it unregisters itself and reloads its clients, which frees visitors still holding a caching worker from an older deployment. |

The macro always compiles with dart2wasm and renders with skwasm. Compiler settings such as `optimization_level_wasm` and `minify_wasm` pass through to `flutter_web_bundle`. For dart2js or CanvasKit, use `flutter_web_bundle` directly.

The project's `web/` directory, beside its `pubspec.yaml`, is read by the Flutter tool's own code, as `flutter build web` reads it, so raw `flutter create` output works unchanged. `web/index.html` and the optional `web/flutter_bootstrap.js` are templates: `{{flutter_js}}`, `{{flutter_build_config}}`, `$FLUTTER_BASE_HREF` and the other placeholders are substituted, and an unknown placeholder is left in place with a warning. The rest of `web/` is copied into the bundle root. The page title and the manifest are what `web/index.html` and `web/manifest.json` say, and `version.json` comes from the pubspec's `version` or from `build_name` and `build_number`. One project directory holds one web app; to build another from the same package, give it a directory of its own with a `pubspec.yaml` and a `web/`, and point `flutter_web_bundle`'s `pubspec` at it.

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:web.bzl", "flutter_web_bundle")

# WASM, the default:
flutter_web_bundle(
    name = "my_app_web",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = ["@deps//:flutter"],
)

# JavaScript, for wider browser support:
flutter_web_bundle(
    name = "my_app_web_js",
    package_name = "my_app",
    main = "lib/main.dart",
    compiler = "dart2js",
    renderer = "canvaskit",
    deps = ["@deps//:flutter"],
)
```

</details>

#### Content-Security-Policy

A `<meta http-equiv="Content-Security-Policy">` in `web/index.html` applies both to the built bundle and to the dev loop (`flutter_dev run -d chrome`), because the stock tool serves the same page. Measured on `e2e/web_example` with Flutter 3.47:

| Policy | Built bundle (WASM) | Dev loop (DDC) |
|---|---|---|
| `script-src 'self' 'wasm-unsafe-eval'` | Renders | Blank page |
| `script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'` | Renders | Renders |

The dev loop needs `'unsafe-inline'`. Adding `'unsafe-eval'` instead changes nothing. The failure is silent: DWDS connects, the VM service answers, every module loads, no CSP violation reaches the console, and the app never paints. `connect-src 'self' ws: wss:` is enough for the dev loop's WebSocket.

A bundle served under `default-src 'self'` must also serve its own renderer, with `use_local_canvaskit = True`. Otherwise the engine's fetch of `skwasm.js` from `www.gstatic.com` is blocked and the page stays blank. Flutter's font fallback from `fonts.gstatic.com` is blocked too, which is harmless unless the app needs those glyphs.

So a policy strict enough to be useful cannot live in the dev loop's `web/index.html` today, because the dev loop reads the same file. If you need one, build the production bundle with `flutter_web_bundle` from a project directory of its own, whose `pubspec.yaml` and `web/index.html` carry the policy. `e2e/web_example/custom_boot`'s `inline_boot` is built that way.

### Cross-compiling

`gen_snapshot`, the AOT compiler, runs on the host and produces code for the target. Flutter publishes a different binary per host and target pair, and not every pair exists.

| Host | Target | AOT (release / profile) | JIT (debug) | Notes |
|---|---|:---:|:---:|---|
| macOS | macOS | Yes | Yes | Native build |
| macOS | iOS | Yes | Yes | `rules_apple` handles the transition |
| macOS | Android | Yes | Yes | The Android rules handle the transition |
| macOS | Linux | No | Yes | Needs an LLVM cross-toolchain |
| macOS | Windows | No | Yes | Needs a Windows cross-toolchain |
| macOS | Web | Yes | n/a | Web uses dart2wasm or dart2js, not gen_snapshot |
| Linux | Linux | Yes | Yes | Native build |
| Linux | Android | Yes | Yes | The Android rules handle the transition |
| Linux | iOS | No | Yes | Debug/JIT kernel only; AOT requires a Darwin-target `gen_snapshot` (macOS host) |
| Linux | macOS | No | Yes | Debug/JIT kernel only; AOT requires a Darwin-target `gen_snapshot` (macOS host) |
| Linux | Windows | No | Yes | Needs a Windows cross-toolchain |
| Linux | Web | Yes | n/a | |
| Windows | Windows | Yes | Yes | Native build |
| Windows | Android | Yes | Yes | The Android rules handle the transition |
| Windows | macOS | No | Yes | Debug/JIT kernel only; AOT requires a Darwin-target `gen_snapshot` (macOS host) |
| Windows | Linux | No | Yes | Needs a Linux cross-toolchain |
| Windows | Web | Yes | n/a | |

The gap is desktop-to-desktop and non-macOS-to-Apple AOT:
- **Apple release and profile AOT (`ios_*`, `macos_*`) requires a macOS host (or a Darwin-target `gen_snapshot`).** Each `gen_snapshot` binary has its target OS and ABI compiled in at build time (`DART_TARGET_OS_*` in the Dart VM); `--snapshot_kind=app-aot-macho-dylib` only selects the Mach-O container format and does not change the generated machine code's target ABI. In particular, Apple arm64 reserves register `x18` for the platform and uses a different FFI argument ABI from Linux/Android arm64, and `dart:ui` calls the Flutter engine through `@Native` FFI. Because Flutter only publishes Darwin-targeted `gen_snapshot` binaries for macOS hosts, release and profile AOT builds for iOS and macOS are only registered on macOS hosts and fail at analysis on Linux and Windows. Debug/JIT (`-c dbg`) compiles platform-independent kernel `.dill` with `frontend_server` and works from Linux and Windows.
- **Desktop to desktop:** there is no release or profile AOT cross-compile between desktop OSes (macOS, Linux, Windows), because Flutter does not publish cross-OS desktop `gen_snapshot` binaries. Build debug bundles across with `-c dbg`, or build release/profile natively on the target OS.
- **Linux-to-Apple debug builds (`backend = "xtool"` and `flutter.darwin_sdk`):** Opt-in Linux-to-iOS/macOS debug cross-compilation (`backend = "xtool"` or `--@rules_flutter//flutter/settings:apple_backend=xtool`) compiles the native Swift/Objective-C runner against an `xtool` `darwin.artifactbundle` (`iPhoneOS.sdk`, `iPhoneSimulator.sdk`, `MacOSX.sdk`) configured via `flutter.darwin_sdk(...)` in your root `MODULE.bazel`.
  > **Important — Apple SDK licensing:** `rules_flutter` never bundles, hosts, or downloads an Apple SDK by default (`url` and `path` both default to `""`). Apple's Xcode and platform SDKs (`iPhoneOS.sdk`, `iPhoneSimulator.sdk`, `MacOSX.sdk`) are proprietary software governed by the Apple Xcode and Apple SDKs Agreement. You must obtain and supply your own `darwin.artifactbundle` (via `flutter.darwin_sdk(url = ..., sha256 = ...)` from your own private artifact store or `flutter.darwin_sdk(path = ...)` on disk) in compliance with Apple's licensing terms.
- **Apple `xtool` backend (`backend = "xtool"`):** `flutter_ios_app` and `flutter_macos_app` accept `backend = "xtool"` (with `--@rules_flutter//flutter/settings:apple_backend=xtool`) to assemble `.ipa` and `.app.zip` bundles via `xtool_pack` without instantiating `rules_apple` targets. On macOS, when `menu_xib` is omitted and no `macos/Runner/Base.lproj/MainMenu.xib` is present on disk, the runner builds a default application menu programmatically; passing any `menu_xib` explicitly or leaving a conventional `macos/Runner/Base.lproj/MainMenu.xib` on disk fails at analysis because compiling `.xib` files requires Xcode `ibtool` (remove `macos/Runner/Base.lproj/MainMenu.xib` and omit `menu_xib`, or use `backend = "rules_apple"`). When signing with `zsign` and a PKCS#12 `certificate` (`.p12`), pass the certificate password via `certificate_password_file` (a file label read at execution time) or `certificate_password_env` (an environment variable name read at execution time, forwarded with `--action_env`). Plain-text `certificate_password` is rejected at analysis so signing secrets never appear on action command lines, build event streams, or `bazel aquery` output.

### Release builds and permissions

`flutter create`'s scaffold grants network access in debug and profile builds only, and these rules reproduce that. An app that reaches the network under `-c dbg` can be offline under `-c opt` with no build error, no exception, and nothing in its log. The same shape exists on every platform, because in every case the debug-only grant is for the Dart VM service, not for the app:

| Platform | What debug has that release does not | Why |
|---|---|---|
| macOS | `com.apple.security.network.server` and `com.apple.security.cs.allow-jit` in `DebugProfile.entitlements`, which profile builds use too. `Release.entitlements` has only `app-sandbox`. | The sandbox must let the VM service bind and the JIT map executable pages. |
| Android | `android.permission.INTERNET`, from `android/app/src/debug/AndroidManifest.xml` (and `src/profile/` in profile builds). | Android enforces `INTERNET` at the kernel level. Without it the VM service cannot bind even a loopback socket. |
| iOS | `NSBonjourServices` and `NSLocalNetworkUsageDescription`, merged in by these rules for non-release builds. | The engine advertises the VM service over mDNS. |

An app that uses the network for itself has to say so once, in a way that applies to every compilation mode:

```starlark
flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    additional_entitlements = ["entitlements/Network.entitlements"],
)

flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    additional_entitlements = ["entitlements/Network.entitlements"],
)

flutter_android_app(
    name = "my_app_android",
    application = ":my_app",
    package_name = "com.example.myapp",
    permissions = ["android.permission.INTERNET"],
)
```

where `entitlements/Network.entitlements` is an ordinary plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
```

These attributes add to whichever base file the compilation mode selected, so one declaration covers debug and release, and the `flutter create` files stay untouched. A key the base already has with the same value is deduplicated, so declaring `network.server` above is safe even though `DebugProfile.entitlements` already grants it. A key the base has with a different value is an error naming the key and both files.

Note that `com.apple.security.network.client` is in neither scaffold file. Most Flutter apps go through `NSURLSession`, which the sandbox exempts. A raw socket is not exempt, so if you open one, you need this key.

**iOS local network privacy.** iOS 14 and later gate LAN access behind `NSLocalNetworkUsageDescription` and `NSBonjourServices`. The rules add both to non-release builds for the VM service and drop them in release. An app that needs LAN access for itself declares them in `ios/Runner/Info.plist`, where they survive into `-c opt`. The rules merge the VM service keys into that file, keeping your usage description and adding `_dartVmService._tcp` to your Bonjour list. The iOS simulator does not enforce local network privacy, so only a physical device tells you whether these keys are right.

**Check the artifact.** A `build_test` cannot see any of this. Read the built app:

```sh
# macOS: the entitlements codesign embedded
unzip -oq bazel-bin/my_app_macos.zip -d /tmp/app && \
  codesign -d --entitlements - "/tmp/app/My App.app"

# Android: the compiled manifest inside the APK
aapt2 dump xmltree --file AndroidManifest.xml bazel-bin/my_app_android.apk

# iOS: the processed Info.plist inside the .ipa
unzip -oq bazel-bin/my_app_ios.ipa -d /tmp/ipa && \
  plutil -p "/tmp/ipa/Payload/my_app_ios.app/Info.plist"
```

Remember that a plain `bazel build` is a release build, so it already takes the release side of each of these choices. `e2e/macos_example`, `e2e/android_example`, and `e2e/ios_example` each have a test that reads the built artifact this way.

## Rules reference

The core rules load from `@rules_flutter//flutter:defs.bzl`.

### flutter_library

Collects the Dart sources and the package's own files for a Flutter package. It does not compile anything. It carries `DartInfo` and `FlutterInfo` to whatever depends on it.

```starlark
flutter_library(
    name = "my_lib",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@deps//:some_package"],
    data = ["pubspec.yaml"] + glob(["assets/**"]),
    package_name = "my_lib",
)
```

| Attribute | Description |
|---|---|
| `srcs` | Dart source files. Required. |
| `deps` | `dart_library` or `flutter_library` targets. |
| `data` | The package's own files outside `lib/`: its `pubspec.yaml`, its licence, and the files its pubspec names (assets, fonts, shaders). An app whose pubspec depends on the package bundles them at `packages/<package_name>/...`, as `flutter build` does. See [Assets](docs/assets.md). |
| `package_name` | The Dart package name. Defaults to the last component of the Bazel package path. |
| `language_version` | The Dart language version, matching the `sdk:` constraint in `pubspec.yaml`. |

### flutter_application

Compiles a Flutter app. In debug mode (`-c dbg`) it produces a kernel `.dill` for the JIT. Otherwise it produces AOT native code. Either way it also builds the `flutter_assets/` bundle. The platform macros consume its `FlutterApplicationInfo`.

```starlark
flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    pubspec_srcs = glob(["assets/**"]),
    pub_packages = "@deps//packages",
    deps = [
        ":my_lib",
        "@deps//:flutter",
    ],
    native_deps = [":my_native_lib"],
)
```

| Attribute | Description |
|---|---|
| `main` | The entry point. Required. It can sit outside the package's `lib/`, as `flutter run -t` allows: `test_driver/app.dart`, say. See [Hot reload and hot restart](#hot-reload-and-hot-restart). |
| `package_name` | The Dart package name, the same as `pubspec.yaml`'s `name:`. Required. It keys the compiled libraries under stable `package:` URIs, which hot reload matches against, and resolves `package:<self>/...` imports. |
| `srcs` | Other Dart sources in the app package, including generated ones. List here any file a `main` outside `lib/` imports by relative path. |
| `deps` | `dart_library` or `flutter_library` targets. |
| `pubspec` | The app's `pubspec.yaml`, which says what the asset bundle holds. Its directory is the project directory. Defaults to the package's `pubspec.yaml`. See [Assets](docs/assets.md). |
| `pubspec_srcs` | The files the pubspec names: assets, fonts, shaders, and `l10n.yaml` with the files it names. A named file that is not listed fails the build, naming it. |
| `pub_packages` | Every package of the lock, `@<hub>//packages` (a `flutter_pub_packages` target), for the package config the bundle reads, as `pub get` writes it. |
| `asset_transformers` | The executables run for the pubspec's asset `transformers`, each mapped to the package name the pubspec gives: `{":binary": "package"}`. |
| `build_name`, `build_number` | `--build-name` and `--build-number`; by default the pubspec's `version`. They reach `version.json`. |
| `flavor` | The application flavor, e.g. `"dev"` or `"prod"`. Sets `FLUTTER_APP_FLAVOR` and bundles the pubspec's assets for that flavor, as `flutter build --flavor` does. Default `""` (no flavor). |
| `default_flavor` | Repeats the pubspec's `default-flavor`. Used as the flavor only when `flavor` is unset; an explicit `flavor` wins. rules_flutter does not check it against the pubspec. Default `""`. |
| `native_deps` | Shared libraries to bundle for `dart:ffi`. |
| `defines` | Dart environment defines, the `-D` flags. |
| `dart_defines` | A `dart_defines` target: Dart environment defines from `.json`/`.env` files, `-D` flagfiles and values. See *Defines files and `dart_defines`* below. |
| `defines_files` | Files of Dart environment defines in `.json` or `.env` format; a spelling of `dart_defines` (the `flutter_application` macro makes a `<name>_dart_defines` target of them). Content is parsed in an action and never reaches the compile command line. |
| `define_flagfiles` | Files holding compiler `-Dname=value` arguments, one per line; a spelling of `dart_defines`, like `defines_files`. |
| `language_version` | The Dart language version, matching `pubspec.yaml`. |
| `obfuscate` | Obfuscate Dart symbols in the AOT output. Pair with `split_debug_info`. Default `False`. |
| `split_debug_info` | Write debug info to a separate `.symbols` file. Default `False`. |
| `extra_gen_snapshot_options` | Extra flags for `gen_snapshot`: only the allow-list in `flutter/private/flutter_aot_compile.bzl`. Set `analyze_size = True` on the app target to get the size JSON instead of passing `--print-instructions-sizes-to`. `--no-obfuscate` fails with `obfuscate = True` and `--no-dwarf-stack-traces` fails with `split_debug_info = True`. |
| `track_widget_creation` | Record widget creation locations for the DevTools inspector and the stock tool's hot reload. Default `True`, as in stock `flutter`; applies to debug and profile builds, never to release. |
| `tree_shake_icons` | Keep only the icon glyphs the app uses, in release and profile builds. Default `True`. |
| `link_hook_assets` | The data assets packages' link hooks emit, each `package:<package>/<name>`. See [Link hooks](#link-hooks). |
| `min_os_version` | Minimum Apple deployment target, passed to `gen_snapshot` as `--macho-min-os-version`. |

**Obfuscated releases.** `obfuscate` renames Dart identifiers and forces `--strip`, so pair it with `split_debug_info` to keep the symbols for deobfuscation. `gen_snapshot` also writes an obfuscation map next to the snapshot; fetch it with `bazel build :my_app --output_groups=obfuscation_map` (or read `FlutterApplicationInfo.obfuscation_map`). For an Android build, read the `debug_info` (`.symbols`) and `obfuscation_map` output groups of the `flutter_android_bundle` (`__<name>_bundle` of a `flutter_android_app`): they hold the files of the build that ships in the APK. `extra_gen_snapshot_options` is an allow-list: only flags that read or write no file and change neither the snapshot kind, outputs, target nor debugging info. `--save-obfuscation-map` and `--save-debugging-info` fail analysis — use `obfuscate` and `split_debug_info` instead; `--print-instructions-sizes-to` fails analysis — use `analyze_size = True` instead — and `--no-strip` fails with `obfuscate`.

**Application flavors.** The `flavor` attribute selects the application flavor, defining `FLUTTER_APP_FLAVOR=<flavor>` in every compile mode (read via `appFlavor` from `package:flutter/services.dart`) and bundling the pubspec's assets as `flutter build --flavor` does (unconditional entries and matching flavor entries are kept; non-matching entries are omitted). Declare one target per flavor, and let platform app targets wrap each flavor's application target:

```starlark
flutter_application(
    name = "app_dev",
    package_name = "my_app",
    main = "lib/main.dart",
    flavor = "dev",
    deps = [":my_lib", "@deps//:flutter"],
)

flutter_application(
    name = "app_prod",
    package_name = "my_app",
    main = "lib/main.dart",
    flavor = "prod",
    deps = [":my_lib", "@deps//:flutter"],
)
```

The flavor is set by the `flavor` attribute only: declaring `FLUTTER_APP_FLAVOR` in `defines` or via `--@rules_flutter//flutter:extra_dart_defines` with a value other than `flavor` fails analysis, as does setting `FLUTTER_APP_FLAVOR` on an unflavored target, naming the target and both values. A `flavor` containing whitespace, `=`, or `,` is not a valid Dart define value and also fails analysis.

`default_flavor` repeats the `default-flavor` of the application's `pubspec.yaml`, which Bazel cannot read. When `flavor` is unset, the application behaves exactly as if `flavor` were the `default_flavor` value; an explicit `flavor` wins, whatever `default_flavor` holds. rules_flutter does not check that `default_flavor` agrees with the pubspec, so keep the two in step. The flavor rules above apply to the effective flavor.

**Defines from the command line.** The repeatable flag `--@rules_flutter//flutter:extra_dart_defines=KEY=VALUE` adds a define to every Dart compile: native kernel, `flutter_test`, dart2wasm, and dart2js. Each occurrence of the flag is one define, so values may contain commas. When a key is set both by the flag and by the `defines` attribute, the flag wins. Reserved defines (`dart.vm.*`, `dart.library.*`, `dart.tool.*`, `flutter.*`) are set by the build and SDK and cannot be passed. In the dev loop, pass `--dart-define` to `flutter_dev run` as to `flutter run`; for the build Bazel makes, add `--bazel-arg=--@rules_flutter//flutter:extra_dart_defines=KEY=VALUE` too.

**Defines are configuration in a debug build.** A debug build compiles Dart as kernel modules, one per library, so an edit recompiles one module. An application's `defines`, its flavor and its `dart_defines` are the configuration of its `deps`: every dependency module compiles with them, and so does the app's own entry module. Applications with equal settings share every module; an application with another set compiles its closure once more (cached like any other build). The same holds for `flutter_test` and `flutter_kernel_target` with `defines`. Native code (a plugin's `native_deps`, its platform libraries, code and native assets) keeps one configuration whatever the defines. Add `common --incompatible_exclude_starlark_flags_from_exec_config` to your `.bazelrc` (rules_dart's `dart/consumer.bazelrc` carries it) so a new set of defines does not rebuild the build tools too. A define value may hold a comma: a module takes it whole.

**Defines files and `dart_defines`.** A `dart_defines` target holds Dart environment defines from `.json` and `.env` files (`srcs`), files of already-spelled `-Dname=value` lines (`flagfiles`) and `KEY=VALUE` strings (`values`, which win over the files). It parses them once per configuration, and the compile reads its output, so the values never appear on the command line or in `bazel aquery`. Applications that name the same `dart_defines` target share their debug modules:

```starlark
load("@rules_flutter//flutter:defs.bzl", "dart_defines", "flutter_application")

dart_defines(
    name = "dev_defines",
    srcs = ["config/dev.json"],
)

flutter_application(
    name = "app_dev",
    package_name = "my_app",
    main = "lib/main.dart",
    dart_defines = ":dev_defines",
    flavor = "dev",
    deps = [":my_lib", "@deps//:flutter"],
)
```

`flutter_application(defines_files = [...], define_flagfiles = [...])` is a spelling of the same thing: the macro declares a `dart_defines` target named `<name>_dart_defines` from them. Two applications spelled this way do not share modules, because each names its own target; name one `dart_defines` target where applications share their defines. A `.json` file must define a top-level object whose values are strings, numbers, or booleans:

```json
{
  "API_URL": "https://api.example.com",
  "ENABLE_LOGGING": true,
  "TIMEOUT_SECS": 30
}
```

A `.env` file defines one `KEY=VALUE` per line (blank lines and lines starting with `#` are ignored, values are trimmed and quotes are not processed):

```env
# Environment configuration
API_URL=https://api.example.com
DEBUG=false
```

Precedence, lowest to highest: the `dart_defines` target (its files, then its `values`), then `defines`, then the flavor, then `--@rules_flutter//flutter:extra_dart_defines`. A key set by a higher-precedence source overrides matching keys from the files. A key may appear in only one file of one `dart_defines` target.

### flutter_test

Compiles and runs widget and unit tests on the Dart VM with Flutter's test engine. Assertions are enabled.

```starlark
flutter_test(
    name = "widget_test",
    package_name = "my_app",
    main = "test/widget_test.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)
```

It takes the compile attributes of `flutter_application` (`main`, `srcs`, `deps`, `defines`, `package_name`, `language_version`) and its bundle attributes (`pubspec`, `pubspec_srcs`, `pub_packages`, `asset_transformers`) plus the usual `data` and `env`. Unlike `flutter_application`, it takes `pubspec` only when you set it; without one, the test's bundle holds only what the packages of its `deps` contribute. Values in `env` are literal; there is no `$(location)` expansion.

`enable_impeller = True` renders with Impeller in `flutter_tester`, as `flutter test --enable-impeller` does, instead of software Skia. A test that draws a shader SkSL cannot compile needs it, and so does a golden meant to match an Impeller device. Shaders are compiled for `flutter_tester` either way, as `flutter test` compiles them.

**Layering check.** A `flutter_test` is layering-checked as rules_dart's `dart_test` is: its `main`, its `srcs` and every first-party library below it may import only packages that their own direct `deps` provide (the test's own `package_name` counts as provided for its `srcs`). A test that imports a package only some dep depends on fails to build, naming the target, the file and the package; declare the target that provides the package in `deps`. The generated bootstrap is not checked. The check runs when the test builds, as a validation. It is on by default; the feature `dart_layering_check` turns it off, per package (`package(features = ["-dart_layering_check"])`) or per build (`--features=-dart_layering_check`). Every Flutter program rule is checked, and `dart_layering_check` is the one opt-out. The checked rules are: `flutter_test`, `flutter_application` (so the android, ios, linux, macos and windows rules that build one) and `flutter_web_bundle` (so `flutter_web_app`), the web, Linux, Android and iOS `flutter_integration_test` and `flutter_drive_test` with a `.dart` driver. An application or web bundle is checked the same way, over its `main`, `srcs` and the first-party libraries below; the generated web wrapper is not checked. An integration test is checked over its entry, `srcs` and `app_srcs` against its direct `deps`, and its `package_name` (default: the target name) counts as provided; a drive test checks its `.dart` driver and `srcs`. The generated bootstraps and the Android helper app are not checked, and the one application built with the feature off is the application that `flutter_integration_test` builds for iOS around its generated bootstrap, which imports packages by design. `dart:mirrors` is refused in every Flutter program and in every library below it, every other `dart:` library passes, and a library named in `--@rules_dart//dart:refused_dart_libraries` is refused in addition to it.

Bazel's test protocol applies, as it does to `dart_test`:

- **Time.** The target's `size` or `timeout` replaces `package:test`'s 30-second default, so a test with no `timeout:` of its own runs as long as Bazel lets the target run. A `timeout:` written on a test still applies, and `Timeout.factor` scales Bazel's limit.
- **`--test_filter`.** A regular expression matched against each test's full name, group names included, like `flutter test --name`. A target the filter matches nothing in passes, so `bazel test //... --test_filter=x` runs only what it names.
- **`shard_count`.** Splits the suite's tests into contiguous shares, one per shard.
- **Tags.** `include_tags` runs only tests matching every one of these `package:test` tag selectors (library, group or test level), as `flutter test --tags` intersects them; each entry is a boolean selector (`a && b`, `a || b`, `!a`, parentheses), and several entries — or comma-separated values in one entry — all have to match. `exclude_tags` skips tests matching any of them, as `flutter test --exclude-tags` unions them, and wins over `include_tags`. An attribute selection that matches no test fails the target, so a misspelled tag is a failure rather than an empty pass; a `--test_env=FLUTTER_TEST_TAGS=...` (or `FLUTTER_TEST_EXCLUDE_TAGS`) selection that matches nothing still passes with a note. A `--test_env=...` value at run time overrides the attribute. A `@Tags` on the test entrypoint itself is extracted at build time and always honoured, reaching every test through the suite's root group; a `@Tags` on a file the entrypoint imports stays invisible, as under `flutter test`.
- **Results.** Each case is reported in the `test.xml` Bazel collects, so CI shows cases rather than one pass or fail per target.

#### Golden files

Goldens must be listed in `data`, or the test cannot see them:

```starlark
flutter_test(
    name = "widget_test",
    main = "test/widget_test.dart",
    data = glob(["test/goldens/**"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)
```

This is the first thing to check when a golden fails, because the failure message does not say it. The comparator reads goldens from runfiles, so a PNG in the source tree that is not an input of the test is invisible to it, and it fails with `Could not be compared against non-existent file`, the same message you get when the file really is absent. If you can see the file on disk and the test says it does not exist, it is almost certainly undeclared. Making declared inputs the only inputs is what keeps a cached pass meaningful.

Otherwise `matchesGoldenFile('goldens/x.png')` means what it means under `flutter test`: the golden is read from `goldens/x.png` next to the test's `main`, and a mismatch reports the pixel difference the same way. When a comparison fails, the four diff images (`masterImage`, `testImage`, `isolatedDiff`, `maskedDiff`) are written under `bazel-testlogs/<pkg>/<target>/test.outputs/failures/`, and the failure message names the path. Upstream writes them beside the test, which under Bazel would be inside the sandbox and gone before you could open them.

To regenerate goldens, use upstream's flag under `bazel run`:

```sh
bazel run //:widget_test -- --update-goldens
```

That writes the PNGs into the source tree next to the test and names each one. The same flag under `bazel test` exits with code 64, because a test action cannot write to the source tree and a golden regenerated into the sandbox would report success while changing nothing. There is no repo-wide command; it is one `bazel run` per target, which `bazel query 'tests(//...)'` can drive.

Two limits come from Flutter rather than from these rules:

- **Goldens are host-specific.** Font rendering and antialiasing differ between operating systems, so a PNG generated on macOS may not match on Linux or Windows. Regenerate on the platform that checks them, or keep per-OS golden directories.
- **Replacing the comparator disables regeneration.** If a test assigns its own `goldenFileComparator`, `--update-goldens` calls that object's `update()`, which for `LocalFileComparator` writes into runfiles. The run passes, prints nothing, and leaves the source PNG unchanged.

#### Modular compilation and the test action's cache key

Each library in a `flutter_test` closure is compiled once into its own outline kernel (a separate, action-cached build action), and the test action links the entry module against those outlines and runs the resulting kernel under `flutter_tester`. Editing one library therefore recompiles only that library's outline plus the link — other libraries' outlines are reused.

A test action re-runs only when its cache key changes. The key is the test kernel plus the `flutter_assets/` tree plus the runner binary plus the test env: editing a library that no test links, touching an asset no test bundles, or changing an unrelated target leaves a passing test cached.

#### flutter_prebuilt_test

Runs an already built test kernel under the same `flutter_tester` runtime — the same runner, protocol, env contract, JUnit XML and golden handling as `flutter_test` — without compiling anything itself. Use it when your own pipeline builds the kernel: split a large suite so one kernel build feeds many test shards, or reuse one kernel across targets whose test env differs. A `flutter_test` exposes exactly what it needs as output groups:

```starlark
filegroup(
    name = "widget_test_kernel",
    srcs = [":widget_test"],
    output_group = "test_kernel",
)

filegroup(
    name = "widget_test_assets",
    srcs = [":widget_test"],
    output_group = "test_assets",
)

flutter_prebuilt_test(
    name = "widget_prebuilt_test",
    dill = ":widget_test_kernel",
    assets = ":widget_test_assets",
)
```

`test_kernel` is the test `.dill`, `test_base_kernel` the base dill it links against at run time (empty for whole-program kernels), `test_assets` its `flutter_assets/` tree, and `test_library_tags` the entrypoint's `@Tags` as a `{"tags": [...]}` JSON file, for `flutter_prebuilt_test`'s `library_tags`. The assets tree comes from a `flutter_test`'s `test_assets` group, bundled for the `tester` platform from the test's `pubspec` as `flutter test` bundles it; rules_flutter has no separate rule that builds one.

To compile the kernel yourself, write the bootstrap with `flutter_test_bootstrap` from `@rules_flutter//flutter:utils.bzl` (merging `FLUTTER_TEST_BOOTSTRAP_ATTRS` into your rule's attrs for the golden block) and compile it as the entry point with `flutter_kernel_compile_action` (passing the bootstrap as `main`); then run the resulting dill under `flutter_prebuilt_test`. Extract the suite's `@Tags` with the public `//flutter/private/tools:extract_library_tags` tool and feed the JSON to `library_tags`, or the suite runs without its root-group tags. A kernel compiled from any other entry point does not dial the harness back and fails to connect. `e2e/hello_world/custom_test_kernel.bzl` is this pipeline as a running target, over the same suites its `flutter_test` twins run. For the modular variant — one entry-module compile against the dependency outlines plus a link, so body-only edits never recompile the whole program — use `flutter_modular_test_kernel` instead; `e2e/hello_world/custom_modular_test_kernel.bzl` is that pipeline as a running target, in both link modes. By default the link is complete (`use_base_dill = False`): every reachable module lands in the kernel and it runs under `flutter_prebuilt_test` with no `base_dill` — `:widget_modular_prebuilt_test` is that green run. With `use_base_dill = True` the kernel delta-links against the shared `flutter_test` base dill instead and the returned base dill must reach `flutter_prebuilt_test`'s `base_dill`: the delta is incomplete without it and `flutter_tester` aborts before connecting when it is missing — `:widget_modular_based_prebuilt_test` is that green run, fed from the kernel's `test_base_kernel` group.

### flutter_integration_test

Builds a Flutter application with an integration test (`package:integration_test` / `package:flutter_test` `WidgetTester` code) compiled in as its entrypoint, runs it on the target platform, and collects results as a Bazel test.

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_integration_test")

flutter_integration_test(
    name = "app_test",
    platform = "web",
    package_name = "my_app",
    main = "integration_test/app_test.dart",
    app_srcs = glob(["lib/**/*.dart"]),
    pubspec = "pubspec.yaml",
    pubspec_srcs = glob(["assets/**"]),
    pub_packages = "@deps//packages",
    deps = [
        "@deps//:flutter",
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

For `platform = "web"`, add `flutter_web_sdk` and `flutter_chrome_headless_shell` to `use_repo(flutter, ...)` in `MODULE.bazel`, and add `integration_test: {sdk: flutter}` under `dev_dependencies` in `pubspec.yaml`. The test runner serves the compiled web bundle from `127.0.0.1` on an ephemeral port, launches the hermetic pinned `chrome-headless-shell` binary with its pinned shared-library closure (`--no-sandbox`, `--disable-dev-shm-usage`), drives the in-app `WidgetTester` suite over a WebSocket channel, and fails the test on any assertion failure, uncaught error, browser crash, or timeout.

For `platform = "linux"`, the rule compiles the Linux desktop GTK runner, Dart kernel (or AOT `libapp.so`), bundled `flutter_assets/`, and any transitive native Linux plugins (`flutter_linux_plugin_library`) into a Linux application bundle. At test time, the runner starts a hermetic `Xvfb` virtual display (`@flutter_linux_headless_runtime`, choosing a free display via `-displayfd`) and runs the app against sha256-pinned GTK3, GLib, fontconfig, and Mesa `llvmpipe` software-rasterizer shared libraries — requiring no host X server, `Xvfb`, or GTK installation.

For `platform = "android"`, add `flutter_android_engine_x64` (or `flutter_android_engine_arm64` for `android_abi = "arm64"`) and `flutter_android_headless_runtime` to `use_repo(flutter, ...)` in `MODULE.bazel`. The rule compiles a full Android APK (`android_binary`) with the integration test as its entrypoint, generated `MainActivity` and `GeneratedPluginRegistrant`, bundled `flutter_assets/`, and any transitive Android plugins (`flutter_android_plugin_library` attached via `flutter_plugin.android_libs`). At test time on Linux (`x86_64` with `/dev/kvm`), the runner boots a hermetic sha256-pinned Android 35 `aosp_atd` `x86_64` emulator headless (`-no-window`, `-gpu swiftshader_indirect`, `-accel on`) against its pinned shared-library closure (`@flutter_android_headless_runtime`), installs and launches the APK via `adb`, forwards the test harness WebSocket port over `adb reverse`, and fails the test on any assertion failure, uncaught error, native crash, ANR, or timeout.

### integration_test on the iOS simulator

With `platform = "ios"`, `flutter_integration_test` builds the app for the iOS simulator and drives its in-app `WidgetTester` suite there. The package needs the conventional `ios/Runner/` sources (as generated by `flutter create --platforms=ios .`): the macro bundles the integration test as the `flutter_application` entrypoint, wraps it in a `flutter_ios_app`, rebuilds that app for the simulator in debug through `ios_sim_debug_app` (`-c dbg` plus `--ios_multi_cpus=sim_arm64` on the app only — the simulator runs the JIT engine, never AOT), and runs it through the iOS test rule. At test time on a macOS host with Xcode and a simulator runtime, the runner boots a simulator, installs the `.ipa` via `simctl`, resolves the app's data container with `simctl get_app_container` and writes the per-launch harness WebSocket URL into a file under its `tmp/` (there is no fixed port; on iOS `Platform.environment` is always empty, so a launch-environment variable cannot carry the URL — the in-app bootstrap reads the file), launches the app by bundle id, and fails the test on any assertion failure, uncaught error, crash, or timeout — including a run that executes zero cases.

```starlark
flutter_integration_test(
    name = "app_test",
    platform = "ios",
    package_name = "my_app",
    main = "integration_test/app_test.dart",
    app_srcs = glob(["lib/**/*.dart"]),
    pubspec = "pubspec.yaml",
    pubspec_srcs = glob(["assets/**"]),
    pub_packages = "@deps//packages",
    deps = [
        "@deps//:flutter",
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

The bundle id defaults to `com.example.<package path>.<name>.<label hash>` — the readable test name plus a short deterministic hash of the test target's full label — so two tests never share one (the simulator refuses a second install under a known id); pass `ios_bundle_id` to take control with a fixed id, used verbatim. The per-launch harness URL carries a random per-run token the harness checks, so a stray dial-back from another run is refused, never adopted. The generated test carries the `exclusive` tag (merged with your `tags`), so Bazel never runs two simulator tests at once. Pass `ios_runner_srcs` / `ios_info_plist` to override the conventional `ios/Runner/*.swift` discovery and `ios/Runner/Info.plist`. The app, debug-app, and test targets carry `target_compatible_with = ["@platforms//os:macos"]`, so `bazel test //...` skips them on Linux; the bootstrap and kernel-compile targets stay portable. See `e2e/integration_ios` for the full workspace: a counter + asset app with a Swift method-channel plugin, a green suite, and a `manual` red twin proving failures are loud. The red twin (`//:app_test_red`) carries one deliberately wrong expectation; its run fails with `RED_TWIN_MUST_FAIL` in the output, which the CI red-twin step asserts — if that string is missing, the harness swallowed a failure.

| Attribute | Description |
|---|---|
| `platform` | Target platform (`"web"`, `"linux"`, `"android"`, or `"ios"`). Defaults to `"web"`. |
| `main` | Integration test Dart entrypoint. Required if `srcs` does not contain a single file. |
| `srcs` | Integration test Dart source files. If `main` is omitted and `srcs` has one file, that file is used as `main`. |
| `app_srcs` | Application Dart source files compiled alongside the integration test. |
| `deps` | `dart_library`, `flutter_library`, or `flutter_plugin` targets (`@deps//:flutter`, `@deps//:flutter_test`, `@deps//:integration_test`, or application libraries and plugins). |
| `pubspec`, `pubspec_srcs`, `pub_packages` | The app's `pubspec.yaml`, the files it names, and every package of the lock, as on `flutter_application`; `pubspec` is not defaulted here. See [Assets](docs/assets.md). |
| `flavor` | Application flavor (`"dev"`, `"prod"`, etc.). Sets `FLUTTER_APP_FLAVOR` and bundles the pubspec's assets for that flavor. Defaults to `""` (no flavor). |
| `package_name` | Dart package name matching `pubspec.yaml`. |
| `compiler` | Web compiler (`"dart2js"` or `"dart2wasm"`). Defaults to `"dart2js"`. |
| `renderer` | Web renderer (`"canvaskit"` or `"skwasm"`). Defaults to matching `compiler`. |
| `gtk_app_id` | Linux GTK application identifier (`platform = "linux"`). Defaults to `"com.example.flutter_integration_test"`. |
| `window_title` | Linux GTK window title (`platform = "linux"`). Defaults to the target name. |
| `android_package_name` | Android application package name (`platform = "android"`). Defaults to `"com.example.flutter_integration_test"`. |
| `android_abi` | Android ABI (`"x64"` or `"arm64"`, `platform = "android"`). Defaults to `"x64"`. |
| `ios_bundle_id` | iOS CFBundleIdentifier (`platform = "ios"`). Defaults to `"com.example.<package path>.<name>.<label hash>"` (label hash keeps distinct targets distinct), used verbatim when set. |
| `ios_runner_srcs` | Runner Swift sources (`platform = "ios"`). Defaults to `None`, which discovers the package's `ios/Runner/*.swift`. |
| `ios_info_plist` | `Info.plist` override (`platform = "ios"`). Defaults to `None`, which preprocesses the package's `ios/Runner/Info.plist`. |
| `include_tags` | Run only tests matching every one of these `package:test` tag selectors, as `flutter test --tags` intersects them. An attribute selection that matches no test fails the target. |
| `exclude_tags` | Skip tests matching any of these `package:test` tag selectors, as `flutter test --exclude-tags` unions them. Wins over `include_tags`. A `--test_env=FLUTTER_TEST_TAGS=...` (or `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute. A `@Tags` on the test entrypoint itself is extracted at build time and always honoured; a `@Tags` on an imported file stays invisible, as under `flutter test`. |

### flutter_drive_test

Launches an app on a device, then runs a Dart driver script on the host against it, the way `flutter drive` and `package:flutter_driver` do. The device is the hermetic, pinned headless Android emulator for an Android app, or an iOS simulator for an iOS simulator app. `flutter_integration_test` runs the test inside the app; `flutter_drive_test` runs a script on the host against the running app. The test passes when the driver exits 0 and fails with the driver's exit status otherwise. The app is terminated and any emulator or simulator the test booted is shut down when the test ends, pass or fail, and a launch timeout names the step that timed out.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_app", "flutter_drive_test")

flutter_android_app(
    name = "app_android",
    application = ":app",
    package_name = "com.example.app",
)

# Host Dart and `flutter_driver` come from the toolchain and the pinned pub
# lock, never the host machine. `driver` may also point at a `dart_binary`.
flutter_drive_test(
    name = "drive_test",
    app = ":app_android",
    driver = "test_driver/main_test.dart",
    package_name = "com.example.app",
    deps = [
        "@deps//:flutter_driver",
        "@deps//:test",
    ],
)
```

For an iOS simulator app, load the rule from `@rules_flutter//flutter:ios.bzl` (it is exported from both files) and pass the simulator build of the app (`ios_sim_debug_app`) as `app`; an iOS simulator `app` makes the test `enormous`, `exclusive` and macOS-only automatically:

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_drive_test", "flutter_ios_app", "ios_sim_debug_app")

flutter_ios_app(name = "app_ios", application = ":app", bundle_id = "com.example.app")

ios_sim_debug_app(name = "app_ios_sim", app = ":app_ios", tags = ["manual"])

flutter_drive_test(
    name = "drive_ios_test",
    app = ":app_ios_sim",
    driver = "test_driver/main_test.dart",
    deps = ["@deps//:flutter_driver", "@deps//:test"],
)
```

Build the app in debug mode (`bazel test -c dbg :drive_test`; `ios_sim_debug_app` transitions the iOS app to debug simulator automatically): a release app hosts no Dart VM service for the driver to connect to.

| Attribute | Description |
| --- | --- |
| `app` | Required. The app under test: an Android app as `flutter_android_app` builds it, or an iOS simulator app (an `.ipa`) as `ios_sim_debug_app` builds it. An iOS simulator `app` tags the test `exclusive` and restricts it to macOS (`size = "enormous"`). A target of neither kind fails analysis naming `app`. |
| `driver` | Required. The host driver — either a `.dart` script (compiled with the hermetic Dart toolchain against `deps` and `srcs`) or a `dart_binary` target. Its exit status is the test's. A missing `driver` fails analysis naming `driver`. |
| `package_name` | The Android application ID of `app`. Required for an Android app; also serves as a fallback for `bundle_id` on iOS. |
| `bundle_id` | Optional bundle identifier of an iOS simulator `app`; defaults to the app's `CFBundleIdentifier` (or `package_name`). |
| `deps`, `srcs` | Optional Dart dependencies (from the pinned pub lock) and helper `.dart` files when `driver` is a `.dart` script. |
| `data`, `env` | Optional runtime files and extra environment variables (`$(rlocationpath ...)` expanded over `data`). |
| `size`, `tags` | `size` defaults to `large` (`enormous` for an iOS simulator `app`); `manual` is always added to `tags` (`exclusive` too on iOS), so the test stays out of wildcard test runs. |

Supported device kinds are the Android emulator and the iOS simulator. The driver runs with these variables in its environment, on top of the test's own:

| Variable | Android emulator | iOS simulator |
| --- | --- | --- |
| `VM_SERVICE_URL` | The app's Dart VM service URI, forwarded to the host (`http://127.0.0.1:<port>/<token>=/`), as `package:flutter_driver` reads it. | The app's Dart VM service URI (`http://127.0.0.1:<port>/<token>=/`); the simulator shares the host's loopback. |
| `FLUTTER_DRIVE_VM_SERVICE_URI` | The same URI. | The same URI. |
| `FLUTTER_DRIVE_ANDROID_SERIAL` | The emulator's `adb` serial. | Not set. |
| `FLUTTER_DRIVE_IOS_UDID` | Not set. | The simulator's UDID. |
| `FLUTTER_DRIVE_PACKAGE` | The `package_name`. | The bundle id. |

The Android leg uses the same pinned emulator and `adb` as `flutter_integration_test(platform = "android")` (x86_64 API 35, KVM required), so it adds no download. The iOS leg boots or reuses a simulator through `xcrun simctl` the way `flutter_integration_test(platform = "ios")` does and needs only the runner's Xcode and a simulator runtime; it adds no download either, and a simulator that was already booted is left running.

### flutter_plugin

Declares a Flutter plugin written in your workspace: its Dart code plus per-platform native implementations. Plugins from pub do not need this; the hub declares them.

```starlark
flutter_plugin(
    name = "multiply_plugin",
    srcs = ["lib/multiply_plugin.dart"],
    dart_plugin_class = "MultiplyPlugin",
    native_deps = ["//:multiply"],
    platforms = ["macos", "linux", "windows", "ios"],
)
```

| Attribute | Description |
|---|---|
| `srcs` | Dart sources. |
| `deps` | `dart_library` or `flutter_library` targets. |
| `platforms` | The platforms the plugin supports. |
| `dart_plugin_class` | The Dart class registered with the engine at startup. |
| `plugin_class` | The native plugin class, for plugins with a native registration. |
| `android_package` | The Java package of the Android `plugin_class`. Required when `platforms` lists `android` with a `plugin_class`. |
| `android_libs` | `flutter_android_plugin_library` targets auto-wired into `flutter_android_app` and `flutter_integration_test(platform = "android")`. |
| `linux_libs` | `flutter_linux_plugin_library` targets auto-wired into `flutter_linux_app` and `flutter_integration_test(platform = "linux")`. |
| `native_deps` | Shared libraries bundled for `dart:ffi`. |
| `native_assets` | `flutter_native_asset` targets, usually inside a `select()` on platform. |
| `data` | The package's `pubspec.yaml`, its licence, and the files its pubspec names (assets, fonts, shaders), as on `flutter_library`. |
| `resources` | Non-Dart files the package ships inside `lib/`. |
| `package_name`, `language_version`, `version` | The package's name, language version, and version. |
| `link_hook` | The package's `hook/link.dart`. See [Link hooks](#link-hooks). `flutter_library` takes it too. |

A plugin's native code is its own target. Swift goes in a `flutter_apple_plugin_library` per platform, passed as `apple_libs`. Kotlin or Java goes in a `flutter_android_plugin_library` passed as `android_libs` on `flutter_plugin` (or listed directly in `flutter_android_app(deps = ...)`), which packages it, registers its plugin class and merges its `manifest` (receivers, services, permissions) into the app's. Its `flutter_engine` is a `flutter_android_engine(neverlink = True)`: the plugin compiles against the engine and the app ships its own, of the app's ABI. `e2e/plugin_example/glass_plugin` and `e2e/integration_android/android_greeting_plugin` show both.

A plugin may mix Objective-C and Swift in one `flutter_apple_plugin_library`. The Swift half compiles into the `<module_name>` module and publishes `<module_name>-Swift.h`; the Objective-C half compiles after it and reaches Swift with `#import "<module_name>-Swift.h"`. Only the declarations Swift marks `@objc` appear in that header. In the other direction, Swift reaches the plugin's Objective-C declarations through a `<module_name>-Bridging-Header.h` or by importing the headers-only `<module_name>_objc` Clang module. The public target still carries both halves' objects, headers, `SwiftInfo` and `FlutterApplePluginInfo`, so `apple_libs` on `flutter_plugin` and the runner link them unchanged. Pure-Swift and pure-ObjC plugins keep their single-layer shape. `e2e/plugin_example/mixed_plugin` is the build fixture.

`e2e/ffi_example` shows a plugin built on Native Assets, `e2e/ffi_plugin_example` one with a Dart plugin class and `native_deps`, and `e2e/plugin_example` one with a Dart plugin class only.

### Asset keys

Keys are the Flutter tool's own, since the tool writes the bundle. An app's assets and shaders are keyed by the path its pubspec gives, relative to the pubspec's directory: `assets/logo.png` named by `apps/sub/pubspec.yaml` loads as `assets/logo.png`, and `shaders/ripple.frag` is where `FragmentProgram.fromAsset` looks for it. A package's are keyed `packages/<package>/<path>`. Every file in `pubspec_srcs` must sit under the pubspec's directory; one outside it fails analysis, naming the file and the directory. App, `flutter_test` (`test_assets`) and `flutter_integration_test` bundles key alike.

### Link hooks

A package can decide what it ships from how the app uses it. Mark a `final class` with `@RecordUse()` from `package:meta` (1.19 or later), and write a `hook/link.dart` that reads the recorded uses with `package:record_use` and emits data assets with `package:data_assets`. The hook may import pure Dart from its own package's `lib/`, not Flutter.

```starlark
flutter_plugin(
    name = "symbols",
    srcs = glob(["lib/**/*.dart"]),
    link_hook = "hook/link.dart",
    platforms = [],
    deps = ["@deps//:data_assets", "@deps//:hooks", "@deps//:meta", "@deps//:record_use"],
)

flutter_application(
    name = "app",
    link_hook_assets = ["package:symbols/index.json"],
    deps = [":symbols", "@deps//:flutter"],
    # ...
)
```

Keep the hook file out of `srcs`. Bazel names every output before anything runs, so the application lists each asset its packages' hooks emit. A hook that emits an asset not listed, skips one that is, or reports an error fails the build with its own message. An application that sets `link_hook_assets` runs the hook of every package in its `deps` that has one.

In a release or profile build the kernel compile records the uses (`--recorded-uses`), each hook runs over them, and the assets are bundled at `flutter_assets/packages/<package>/<name>`, listed in `AssetManifest`, and loaded with `rootBundle.load('packages/<package>/<name>')`. Debug builds are JIT compiles, which record nothing: no hook runs and no asset is bundled, so load what the hook would have indexed on demand there. `e2e/_overlay_tests/link_hooks` is a working example, including the failing case.

### Lower-level rules

These are what `flutter_application` is made of. Most apps never need them.

| Rule | What it does |
|---|---|
| `flutter_kernel_target` | Compiles Dart to a kernel `.dill` with Flutter's patched platform kernel. |
| `flutter_aot_target` | Compiles Dart to an AOT shared library (`.so` on Linux and Android, `.dylib` on macOS) with `gen_snapshot`. |
| `flutter_pub_packages` | Every package of a pub lock, for an app's `pub_packages`. A Flutter hub declares one as `@<hub>//packages`. |
| `flutter_native_library` | Pairs a native library with the files its bindings are generated from (`binding_contract`). |
| `flutter_native_asset`, `flutter_data_asset` | Declare Dart Native Assets, from `@rules_flutter//flutter:native_assets.bzl`. A data asset is bundled at `flutter_assets/packages/<package>/<name>`. |

#### flutter_apple_xcframework_import

Imports one prebuilt Apple framework, either an `.xcframework` or a plain
`.framework`, for an iOS or macOS app. It is the supported path for a
vendored framework and for the frameworks a binary pod or SwiftPM binary
target brings, and it needs no `backend` argument: the same
`@rules_flutter//flutter/settings:apple_backend` setting that chooses the app
backend chooses the import.

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_apple_xcframework_import")

flutter_apple_xcframework_import(
    name = "tinykit",
    framework = "TinyKit.xcframework",
    linkage = "static",
)
```

The signature is `flutter_apple_xcframework_import(name, framework, linkage =
"static", alwayslink = False, sdk_frameworks = [], weak_sdk_frameworks = [],
sdk_dylibs = [])`.

`framework` names the files of the single `.xcframework` or `.framework`
directory, usually a `filegroup`. The label's spelling decides the shape, so
the macro never resolves its files at load time. `linkage` is `"static"`
(default) or `"dynamic"`; it picks `apple_static_xcframework_import` or
`apple_dynamic_xcframework_import` for an xcframework, and
`apple_static_framework_import` or `apple_dynamic_framework_import` for a
plain framework. `alwayslink`, `sdk_frameworks`, `weak_sdk_frameworks` and
`sdk_dylibs` are forwarded to a static `rules_apple` import. Use
`alwayslink = True` for a framework whose Objective-C categories must load
(`-ObjC`).

On the xtool backend the import is `flutter_darwin_xcframework_import` for
either shape, with `linkage = "dynamic"` becoming `is_dynamic = True`. A
label that names neither shape, a `linkage` other than the two values, or an
argument that backend cannot carry fails analysis with a message naming the
argument; the dynamic `rules_apple` imports take neither `alwayslink` nor an
SDK framework or dylib list, and the xtool backend links prebuilt frameworks
with `-F`/`-framework` and carries none of them either.

#### Composing your own compile rules (`flutter:utils.bzl`)

A rule in another module can run the same kernel compile `flutter_application` uses, loading only `@rules_flutter//flutter:utils.bzl`:

```starlark
load(
    "@rules_flutter//flutter:utils.bzl",
    "FLUTTER_KERNEL_COMPILE_ATTRS",
    "FLUTTER_KERNEL_COMPILE_TOOLCHAINS",
    "compile_package_config",
    "flutter_kernel_compile_action",
    "flutter_kernel_compile_tools",
)
```

`flutter_kernel_compile_tools(ctx)` resolves the tool files (`dartaotruntime`, `kernel_filter_tool`, `frontend_server`, `platform_dill` — the release dill with `product = True`), `compile_package_config` writes the `package_config.json` (with `extra_roots` for packages that contribute no sources, such as `flutter` or `sky_engine` from the toolchain — the caller must also make those roots' files action inputs), and `flutter_kernel_compile_action(ctx, tools, sources, outputs, options, dills)` runs the compile: `flutter_kernel_sources(...)` names what it reads (`main`, `srcs`, `package_config`, plus `entrypoint_uri`, `filesystem_roots`, `native_assets_manifest` and `dart_plugin_registrant_uri`), `flutter_kernel_outputs(...)` what it writes (`output`, `recorded_uses`), `flutter_kernel_options(...)` how it runs (`aot`, `defines`, `extra_flags`, `target`, and `vm_flags` — allow-listed Dart VM flags before the snapshot: heap/GC sizing such as `--old-gen-heap-size=1073741824`, and bare diagnostics such as `--enable-asserts`), `flutter_kernel_dills(...)` the pre-compiled dills it builds on (`from_dill`, and `import_dill` — a pre-compiled summary passed as `--import-dill`), and a trailing `resource_set` constrains host resources. Merge `FLUTTER_KERNEL_COMPILE_ATTRS` into the rule's `attrs` and declare `FLUTTER_KERNEL_COMPILE_TOOLCHAINS`; the rule keeps its own `main`, `srcs` and `deps`.

Soundness rule for `vm_flags` and `extra_flags`: only the documented tuning flags may precede the snapshot — anything naming a file or a host side effect (`--packages`, `--*-dill`, `--platform`, `--native-assets`, `--timeline-recorder`, `--snapshot*`, `--observe`, `--dfe` and similar in `vm_flags`; any `frontend_server` flag naming a file the compile does not declare in `extra_flags`) fails the build at analysis. The guard behind the compile (`kernel_filter`) takes every allowed read from a manifest the action writes from its declared files — never from the compile argv — so a smuggled flag cannot widen what the compile may read.

Soundness rule for `import_dill`: `frontend_server` re-reads an imported dill's whole source closure on every compile, so the consuming compile must still declare those sources — the guard accepts the declared reads and refuses anything undeclared. Pass `--incremental` (via `extra_flags`) so the compiler does not additionally re-read the dill's own entry main. `e2e/smoke` shows the full chain from another module: a plain kernel, one with `vm_flags` and `resource_set`, and one consuming a real `import_dill` dill.

The same file also publishes the modular path the built-in `flutter_test` and app rules compile with when eligible: `flutter_kernel_module_aspect` (the same aspect object the built-in rules use, so a library's module action keeps its action key across built-in and custom pipelines), the `FlutterKernelModuleInfo` provider it produces, the `FLUTTER_MODULAR_KERNEL_ATTRS` / `FLUTTER_MODULAR_KERNEL_TOOLCHAINS` dicts a calling rule merges and declares, and two entry functions — `flutter_modular_test_kernel(ctx, test_uri, deps, output, use_base_dill = False)`, which writes the `flutter_test` bootstrap protocol entry, compiles it against the dependency outlines and links it (run the result under `flutter_prebuilt_test`), and `flutter_modular_app_kernel(ctx, main, package_name, srcs, deps, output, use_base_dill = False)`, which does the same for an app entry point with the debug platform dill prepended.

Use the whole-program path when the pipeline needs native assets: they route a custom modular kernel to a build error (it has no whole-program fallback). A custom kernel's `defines` and the global `extra_dart_defines` work as they do for the built-in rules: its `deps` edge makes them the closure's configuration, so every module and the entry compile with them; a value may hold a comma. Use the modular path when incremental rebuilds matter: a body-only edit to one library then recompiles only that library's module plus the entry/link actions, never the whole program — in both link modes. The default complete link (`use_base_dill = False`, as in rules_dart's `modular_executable_kernel`) puts every reachable module in the kernel, which runs with no `base_dill`; pass `use_base_dill = True` to delta-link against the shared `flutter_test` base instead, and feed the returned base dill to `flutter_prebuilt_test`'s `base_dill` exactly as a `flutter_test` kernel's `test_base_kernel` must. The delta pays off when many tests share one SDK base: each per-test dill stays small while the base builds once. A custom kernel with no `defines` leaves the configuration untouched, so its modules share their action keys with the built-in rules. `e2e/hello_world/custom_modular_test_kernel.bzl` is both pipelines as running targets: a custom modular test kernel over two `flutter_library` packages under `flutter_prebuilt_test` (complete and base-linked), and a custom modular app kernel.

Stability note: `flutter:utils.bzl` is stable for external use. `flutter_kernel_compile_action` takes grouped parameter objects — `flutter_kernel_sources(...)`, `flutter_kernel_outputs(...)`, `flutter_kernel_options(...)` and `flutter_kernel_dills(...)` — so the flat keyword call shape is gone, but existing calls keep their command line and action keys.

### Code generation

Pub builders (json_serializable, freezed, go_router_builder, ...) run through rules_dart's `dart_build_runner`, which runs the package's own `build_runner` as one Bazel action and declares the files it writes. A package that imports Flutter also needs an SDK summary that includes the engine libraries (`dart:ui`, ...), built once by `build_runner_sdk_summary` from `sky_engine`:

```starlark
load("@rules_dart//dart:defs.bzl", "build_runner_sdk_summary", "dart_build_runner")
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

# `@build_deps` is a rules_dart `pub.from_lock` hub over the same pubspec.lock
# (which must have build_runner 2.8 or newer).
build_runner_sdk_summary(
    name = "flutter_sdk_summary",
    embedder = "@flutter_sky_engine//:sky_engine",
    runner = "@build_deps//build_runner:runner",
)

dart_build_runner(
    name = "gen",
    outs = ["lib/routes.g.dart"],
    runner = "@build_deps//build_runner",
    sdk_summary = ":flutter_sdk_summary",
    deps = ["@deps//:flutter", "@deps//:go_router"],
)

flutter_library(
    name = "my_pkg",
    package_name = "my_pkg",
    srcs = ["lib/routes.dart", ":lib/routes.g.dart"],
    deps = ["@deps//:flutter", "@deps//:go_router"],
)
```

`e2e/build_runner` is the worked example (its root `BUILD.bazel` and `go_router_pkg/BUILD.bazel`). A hand-written generator is a `dart_binary` run by skylib's `run_binary`; `e2e/codegen` shows that shape, including generated code in dependency packages and hot reload over regenerated sources.

#### flutter_gen_l10n

Generates `AppLocalizations` from `.arb` files, the equivalent of `flutter gen-l10n`.

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_gen_l10n")

flutter_gen_l10n(
    name = "app_l10n",
    arbs = [
        "lib/l10n/app_en.arb",
        "lib/l10n/app_es.arb",
        "lib/l10n/app_es_419.arb",
    ],
)

flutter_test(
    name = "l10n_test",
    package_name = "my_app",
    srcs = [":app_l10n"],
    main = "test/l10n_test.dart",
    deps = [
        "@deps//:flutter",
        "@deps//:flutter_localizations",
        "@deps//:flutter_test",
        "@deps//:intl",
    ],
)
```

The generated files land beside the `.arb` files, and a consumer collects them by listing the target in `srcs`. The attributes mirror the flags of `flutter gen-l10n` with the same defaults: `template_arb_file`, `output_class`, `use_deferred_loading`, and so on. `l10n.yaml` is not read, because Bazel has to know the output file names during analysis and a config file read while the action runs cannot tell it.

A few things to know:

- **Keep `@@locale` consistent with the filename.** The rule derives output names from the arb filenames, while the generator decides what to write from each file's `@@locale`. If `app_english.arb` declares `"@@locale": "en"`, Bazel expects `app_localizations_english.dart` and the generator writes `app_localizations_en.dart`, which surfaces as "output was not created". Bazel cannot read file contents during analysis, so the rule cannot check this for you.
- **Outputs are grouped by primary language.** `app_es.arb` and `app_es_419.arb` produce one `app_localizations_es.dart` holding both classes, matching upstream.
- **Generated files always use LF line endings.** Upstream copies the line endings of `pubspec.yaml`, which would make the output depend on a file the action does not declare.
- **There is no `format` attribute.** Formatting shells out to the `dart` binary, which the action does not have. Setting it is an error rather than a silent no-op. rules_dart's format check covers hand-written files only, so the generated sources are not checked.
- **Two copies of `intl` are in play.** The generator has its own. An app using the generated code needs `intl` in its own lock. Upstream has the same split.

The generator is carved out of `flutter_tools` at fetch time with a set of patches, so a Flutter version bump re-validates it. A release that moves the patch context fails the patch, and a new release also needs a `source_sha256` in `flutter/private/versions.bzl`. Two things those checks cannot catch: a newly added read of an undeclared file at run time, which shows up as a `PathNotFoundException`, and a newly adopted `dart:io` API newer than the Dart that rules_dart provides, which shows up as a compile error naming a missing type. The fix for the second is to cut the dead code that uses it, as the existing patches do for an unused `NetworkInterface` wrapper. See `flutter/private/flutter_gen_l10n_repo.bzl`.

On Windows, the repository rule extracts all of `packages/flutter_tools` (about 19 MB) and uses twenty of its files. The deepest path is around 130 characters from the repository root, which fits within `MAX_PATH` given a short `output_user_root`.

### Providers

**`FlutterSdkInfo`** comes from the toolchain and carries the engine binaries and SDK files a custom rule needs. Core host fields live directly on `@rules_flutter//flutter:toolchain_type`; lazy-fetched fields (`gen_snapshot`, `platform_kernel_dill_product`, `const_finder`, `font_subset`, `engine_library`, `linux_sysroot`, `material_icons_font`) live on optional sub-toolchains so builds only download the repositories they use. Use `resolve_flutter_sdk_info(ctx)` with `FLUTTER_OPTIONAL_TOOLCHAINS` (from `@rules_flutter//flutter:providers.bzl` or `@rules_flutter//flutter:toolchain.bzl`) to merge them:

```starlark
load("@rules_flutter//flutter:providers.bzl", "FLUTTER_OPTIONAL_TOOLCHAINS", "resolve_flutter_sdk_info")

# In rule(..., toolchains = ["@rules_flutter//flutter:toolchain_type"] + FLUTTER_OPTIONAL_TOOLCHAINS):
sdk = resolve_flutter_sdk_info(ctx)
```

| Field | Type | Description |
|---|---|---|
| `version` | `str` | The Flutter SDK version, for example `"3.47.7"`. |
| `engine_revision` | `str` | The engine commit hash. |
| `dart` | `File` | Deprecated. The `dart` executable from the bundled Dart SDK; prefer `@rules_dart//dart:exec_tools_toolchain_type`. |
| `dartaotruntime` | `File` | The runtime for AOT snapshots. |
| `gen_snapshot` | `File` or `None` | The AOT compiler (resolved via `@rules_flutter//flutter:aot_toolchain_type`). |
| `frontend_server` | `File` | `frontend_server_aot.dart.snapshot`, for kernel compilation. |
| `platform_kernel_dill` | `File` | `platform_strong.dill`, the debug platform kernel. |
| `platform_kernel_dill_product` | `File` or `None` | `platform_strong_product.dill`, the release platform kernel (resolved via `@rules_flutter//flutter:product_tools_toolchain_type`). |
| `patched_sdk` | `Target` | The Flutter-patched Dart SDK root. |
| `icu_data` | `File` | `icudtl.dat`. |
| `tool_files` | `depset[File]` | Deprecated. All files in the bundled Dart SDK and patched SDK; prefer `@rules_dart//dart:exec_tools_toolchain_type` or the action-specific `dart_*_files` sets. |
| `dart_vm_files` | `depset[File]` | Minimal Dart SDK files needed to run the `dart` VM on a snapshot (`bin/dart`, `bin/dartvm`). |
| `dart_pub_files` | `depset[File]` | Minimal Dart SDK files needed for `dart pub` (`bin/dart`, `bin/dartaotruntime`, `bin/snapshots/dartdev_aot.dart.snapshot`, `version`). |
| `dart2wasm_files` | `depset[File]` | Minimal Dart SDK files needed for `dart compile wasm` (`bin/dart`, `bin/dartaotruntime`, `bin/snapshots/dart2wasm_product.snapshot`, `bin/wasm-opt`). |
| `dart2js_files` | `depset[File]` | Minimal Dart SDK files needed for `dart compile js` (`bin/dart`, `bin/dartvm`, `bin/snapshots/dart2js.dart.snapshot`). |
| `engine_library` | `Target` or `None` | The platform engine runtime library. `None` for mobile and web (resolved via `@rules_flutter//flutter:desktop_engine_toolchain_type`). |
| `linux_sysroot` | `Target` or `None` | The Chromium sysroot filegroup for Linux GTK3 builds (resolved via `@rules_flutter//flutter:desktop_engine_toolchain_type`). |
| `const_finder` | `File` or `None` | `const_finder.dart.snapshot`, for icon tree shaking (resolved via `@rules_flutter//flutter:product_tools_toolchain_type`). |
| `font_subset` | `File` or `None` | The `font-subset` binary (resolved via `@rules_flutter//flutter:product_tools_toolchain_type`). |
| `material_icons_font` | `File` or `None` | `MaterialIcons-Regular.otf` (resolved via `@rules_flutter//flutter:material_icons_toolchain_type`). |
| `assets_tool` | `FlutterAssetsToolInfo` or `None` | The asset tool of this release, compiled against its `package:flutter_tools`, which writes every asset bundle. See [Assets](docs/assets.md). |
| `impellerc` | `File` or `None` | The shader compiler. |
| `shader_lib` | `list[File]` | Shader include files for impellerc. |
| `target_os`, `target_arch` | `str` | The cross-compilation target, or empty for a native build. |

A Flutter workspace's Dart toolchain is the Dart SDK bundled with its Flutter release. Analysis, formatting, codegen, `dart_test` and `dart_binary` all use it, so the workspace downloads one Dart SDK, not two. A root module that registers its own Dart toolchain before `@flutter_toolchains` keeps it.

**`FlutterInfo`** is carried by `flutter_library` and `flutter_plugin`:

| Field | Type | Description |
|---|---|---|
| `plugins` | `list[struct]` | Plugin metadata, each with `name`, `platforms`, and `implements`. |
| `transitive_native_libs` | `depset[File]` | Shared libraries from plugins' `native_deps`. |

**`FlutterApplicationInfo`** is carried by `flutter_application` and consumed by the platform rules:

| Field | Type | Description |
|---|---|---|
| `aot_output` | `File` or `None` | AOT native code. `None` in debug mode. |
| `kernel_dill` | `File` or `None` | The kernel `.dill`. `None` in release mode. |
| `flutter_assets` | `File` | The `flutter_assets/` tree. |
| `icu_data` | `File` | `icudtl.dat`. |
| `native_libs` | `list[File]` | Shared libraries from `native_deps`. |
| `is_debug` | `bool` | `True` for a debug build. |
| `native_plugin_registrant` | `File` or `None` | The generated plugin registrant source for desktop platforms. |

## The dev loop

Bazel builds the app; the stock `flutter` tool installs, launches, reloads, restarts and debugs it.
`flutter_dev` (`tools/flutter_dev`) is the small piece in between: it builds the target, writes the
package config and the links to generated sources that the stock tool and the IDE read, and runs
`flutter run --use-application-binary` or `flutter attach`. Every option other than `--bazel*` is
the stock tool's, so `-d`, `--machine`, `--dart-define` and the IDE plugins work as with
`flutter run`.

```sh
bazel run @rules_flutter//tools/flutter_dev -- run --bazel-target=//:my_app_android -d emulator-5554
```

The stock tool must be the Flutter release the rules build with. See
[its README](tools/flutter_dev/README.md) for what it writes into the project, IDE launch
configurations, and a table that maps the old `flutter_bazel` command's flags to their
replacements.

### Driving the app from a script

Coding agents and end-to-end tests drive a running app through the stock tool's `--machine`
protocol: `flutter_dev run --machine`, then `app.callServiceExtension` with the commands of the
debug agent (`ext.rules_flutter.tap`, `enterText`, `getText`, `waitFor`, `pressKey`, ...),
`app.restart` for hot reload and restart, `device.takeScreenshot` and the `app.log` events. The
agent is an ordinary Dart-only plugin the app depends on in debug,
`@rules_flutter//flutter/debug_agent`; [its README](flutter/debug_agent/README.md) lists every
command and shows how to set it up for an agent.

## Examples

The `e2e/` directory holds working workspaces, each with its own tests:

| Directory | What it shows |
|---|---|
| `e2e/smoke` | The smallest possible toolchain check. |
| `e2e/hello_world` | A minimal app on every platform: kernel, AOT, assets, macOS, iOS, Android, Linux, Windows, and web. |
| `e2e/codegen` | Per-file and aggregate code generation, generated code in dependency packages, and hot reload over generated sources. |
| `e2e/ffi_example` | Native code as Dart Native Assets and as `native_deps`, side by side. |
| `e2e/ffi_plugin_example` | A `flutter_plugin` with a Dart plugin class and `native_deps`. |
| `e2e/plugin_example` | Pub plugins from the hub, and a `flutter_plugin` with a Dart plugin class only. |
| `e2e/macos_example` | A full macOS app with bundle structure checks. |
| `e2e/ios_example` | An iOS app. Requires Xcode. |
| `e2e/android_example` | An Android APK built three ways, with APK content checks. |
| `e2e/linux_example` | A Linux app built three ways, with bundle checks. |
| `e2e/windows_example` | A Windows app built three ways, with bundle checks. |
| `e2e/web_example` | WASM and JavaScript web builds from the project's `web/` directory. |
| `e2e/integration_web` | End-to-end web `flutter_integration_test` running in hermetic `chrome-headless-shell`. |
| `e2e/integration_linux` | End-to-end Linux desktop `flutter_integration_test` with a native C++ plugin running under hermetic `Xvfb` and Mesa `llvmpipe`. |
| `e2e/integration_android` | End-to-end Android `flutter_integration_test` with a Kotlin method-channel plugin running in a hermetic headless Android emulator with KVM. |
| `e2e/integration_ios` | End-to-end iOS simulator `flutter_integration_test` with a Swift method-channel plugin. Requires Xcode; Linux CI builds the portable Dart side only. |
| `e2e/cross_compile_example` | A Linux bundle cross-compiled from macOS. |
| `e2e/multi_window_example` | Multi-window macOS and multi-scene iOS with `FlutterEngineGroup`. |
| `e2e/dual_hub` | Two pub hubs in one workspace that disagree on a package version. |

[docs/TESTING.md](docs/TESTING.md) describes how the repository itself is tested, including the manual checks that need a display or a device.

## History and thanks

`ai_rules_flutter` started as [aran/rules_flutter](https://github.com/aran/rules_flutter), written by
[Aran Donohue](https://github.com/aran). He designed this rule set and wrote 323 of its commits: the toolchain,
the platform packaging and `flutter.pub` that everything here still builds on.
Thank you, Aran. This project would not exist without your work, and its whole history is kept here with your
name on every one of those commits.

From October 15 to October 28, 2026 the rules were developed in the
[Mivr/rules_flutter](https://github.com/Mivr/rules_flutter) fork. They continue here as a standalone project: every
upstream and fork commit, every tag and every release is in this repository. The fork's closed issues stay where
they are. New issues, releases and the BCR module `ai_rules_flutter` live here. Upstream's own rules continue at
[aran/rules_flutter](https://github.com/aran/rules_flutter). We keep reading upstream and port its ideas with
credit to their authors.

## License

See [LICENSE](LICENSE).
