# Android from the Gradle model

A Flutter app's Android side is built from a description that Gradle writes once, the *pin file*
(`android_model.json`). Gradle evaluates the app's and every plugin's Android project and resolves the
Maven graph; Bazel builds from the result. No Gradle file is read by the rules, and no Gradle runs in a
build.

## What you run and what you check in

1. The app has its stock Android project (`android/`, as `flutter create --platforms=android .` writes
   it), and `flutter pub get` has run.
2. `bazel run //:android_pin` runs the app's own Gradle wrapper with an init script and writes
   `android_model.json` beside `pubspec.yaml`. Check it in.
3. `bazel build //:app` builds the split APKs of the debug build; `bazel build //:app_apk` the same app
   as one APK; `bazel run //:app_install` sends the splits that changed to a device and starts the app.
4. A release or profile build is another `flutter_android_app` with `variant = "release"` (or
   `"profile"`); see "Release and profile builds" below.

Pin again when a Gradle file of the app changes, or the plugins of `pubspec.lock` that have an Android
side do (one added, removed, or at another version). A build whose files or plugins differ from what the
pin was computed from fails and names them and the command:

```
//:android_model.json is stale: it was written by Gradle for other contents of
  android/app/build.gradle.kts
//:android_model.json is stale: pubspec.lock has other plugins with an Android side than it was written for
  url_launcher_android 6.3.36 (the pin has 6.3.35)
Pin again and commit the result:
  bazel run //:android_pin
```

The rest of `pubspec.lock` is not the Android side's business: a package that is Dart only can be
added or upgraded without a new pin. The pin holds the list (`android_plugins`: the names
`.flutter-plugins-dependencies` gives for Android, with the versions of
`.dart_tool/package_graph.json`, both written by `flutter pub get`), and the build compares it with
what the app's `pub_packages` say of the lock; an app that names no lock (`pub_packages` and no
package of a `flutter.pub` hub in `deps`) is not compared.

`bazel run //:android_pin -- --check` fails when the file is not what Gradle gives now, without writing
it (for CI). Two pins of the same inputs are the same bytes.

`MODULE.bazel`:

```starlark
bazel_dep(name = "rules_kotlin", version = "2.4.20")  # 2.3.0 or newer

android_model = use_extension("@rules_flutter//flutter:android.bzl", "android_model")
android_model.pin(model = "//:android_model.json")
use_repo(android_model, "android_model")

register_toolchains("@android_model//:kotlin_toolchain")
```

`BUILD.bazel`, beside `pubspec.yaml`:

```starlark
load("@android_model//:defs.bzl", "flutter_android_app")
load("@rules_flutter//flutter:android.bzl", "flutter_android_pin")
load("@rules_flutter//flutter:defs.bzl", "flutter_application")

flutter_application(name = "counter", main = "lib/main.dart", deps = [...])

flutter_android_pin(name = "android_pin")

flutter_android_app(
    name = "app",
    application = ":counter",
)
```

The pin step needs what a stock Flutter Android build needs: a JDK, the Android SDK, a Flutter SDK, and
the network for what Gradle has not resolved before. A build needs the Android SDK for the platform
(`android.jar` of the compile SDK and, for a release build, the platform's optional libraries and its
stubs of `java.lang.invoke`, which R8 links against) and the NDK's `llvm-strip`; `ANDROID_HOME` names
it. Everything else is fetched by the hashes in the pin.

## What is built

| Model item | Target | Actions |
|---|---|---|
| Maven artifact | its own repository, fetched by sha256 (an AAR is unpacked at fetch time); an import, a dex archive, compiled resources | `RdfDex`, `RdfResCompile` |
| Plugin project, library module of the app | one `kt_jvm_library` or `java_library` on the project's own compile classpath in Gradle's order; `BuildConfig`; the R class it compiles against; its manifest; dex; compiled resources | `KotlinCompile`, `Javac`, `RdfSymbols`, `RdfRJar`, `RdfManifestMerge`, `RdfDex`, `RdfResCompile` |
| App | the same, the merged manifest, the linked resources, the R classes of the app and of every library | `RdfManifestMerge`, `RdfAapt2Link`, `RdfRJar` |
| `//:app` | split APKs: `base` (manifest, resources, R classes, Maven code, native libraries, assets), one split per Gradle project (its dex), `dart` (`flutter_assets`) | `RdfDexMerge` for the Maven code, one `RdfApk` per split |
| `//:app_apk` | the whole app as one APK, as `flutter build apk --debug` gives | `RdfDexMerge` per scope, one `RdfApk` |

A plugin of the pub cache is built from its archive, fetched by the hash pub recorded. A project of
the workspace other than the app (a library module of the app, a plugin under development as a path
dependency) is built through a link to its directory, so an edit there rebuilds that project only. The
app's own sources are read in the package that calls `flutter_android_app`.

A plugin of the pub cache is fetched once more for this, by the same hash, although the pub layer has
the same archive: the Android model is its own module extension, and a repository of one extension
cannot name the repositories of another unless the user lists each one. Bazel's download cache
serves both, so nothing is downloaded twice. A plugin of the Flutter SDK itself (integration_test)
is linked from the SDK of the build.

The Dart side's native libraries (FFI libraries, the libraries of build hooks, which are a directory
whose names are known only when it is built) are packaged under `lib/<abi>/` with the Gradle side's.
Every native library is checked where it is packaged: a file under `lib/<abi>/` that is not an ELF
library of that ABI's machine fails the build, naming the file, instead of failing on the device.

The tools are AGP's own, at the versions the pin records: D8 and L8 from R8, the manifest merger, the
resource compiler and aapt2, the R class writer, the APK signer. Kotlin is compiled by `rules_kotlin`,
kapt and KSP included; its compiler must read the Kotlin standard library the model resolved (for the
Kotlin 2.4.0 of a Flutter 3.47 app: `rules_kotlin` 2.3.0 or newer). `rules_android` and
`rules_jvm_external` are not used, and `rules_flutter` does not depend on them.

The pin belongs to one Flutter version: the Java embedding and `libflutter.so` are Maven artifacts of
that version's engine. A build whose Flutter SDK has another engine fails and says to pin again.

An edit rebuilds its own part: a Kotlin edit in the app compiles the app's library, dexes one jar and
packages one split; a Dart edit builds the kernel and packages the `dart` split, and runs no compile,
dex, resource or signing action of native code.

`versionCode` and `versionName` are the pubspec's (`version: 1.2.3+4`), as in a stock build: where the
app's Gradle file takes them from Flutter (`flutter.versionCode`, `flutter.versionName`), the pin holds
a marker and the build reads `pubspec.yaml`, so a version bump needs no new pin. Where the Gradle file
sets its own values, those are used. A flavor's `versionNameSuffix` is kept.

## Variants and flavors

The pin records every variant of the app (`debug`, `profile`, `release`, and with flavors `devDebug`,
`devRelease`, ...); `flutter_android_pin(variants = ["debug", "devRelease"])` records fewer.
`flutter_android_app(variant = "devRelease")` builds one. The variant decides the mode, as the flag of
`flutter build apk` does, whatever `-c` the Bazel command line has: a debuggable build type is a debug
build, the `profile` build type a profile build, any other a release build. The variants of a
project have nearly the same classpath, so the pin stores a classpath that differs little from another
as that one's id and the differences (where Gradle orders the two alike; it does not always). With
every variant the pin of an app with nine plugins is about 1.8 times the pin of its debug variant
alone, where it was 2.2 times.

## Release and profile builds

```starlark
flutter_android_app(
    name = "app_release",
    application = ":counter",
    variant = "release",
    split_per_abi = True,
)
```

`bazel build //:app_release_apk` is what `flutter build apk --release` gives; with `split_per_abi`,
`//:app_release_apk_armeabi_v7a`, `//:app_release_apk_arm64_v8a` and `//:app_release_apk_x86_64` are
what `--split-per-abi` gives, with Flutter's version codes (`1000 * <ABI number> + versionCode`). `//:app_release_mapping` is the mapping
file that retraces a stack trace of that build.

| Step | As the stock build | Actions |
|---|---|---|
| The Dart program | one AOT library per ABI, `lib/<abi>/libapp.so`; `flutter_assets` without the kernel | the Dart side's AOT compile |
| Code | R8 over the whole program when the build type says `minifyEnabled` (Flutter's default for release): AGP's own driver and R8 by hash, full mode, with the rules of the app (AGP's default file and the Flutter tool's rules, carried in the pin; the app's own files), of the plugin projects (`consumerProguardFiles`) and of the Maven artifacts (`proguard.txt` of an AAR, `META-INF/com.android.tools/r8*` or `META-INF/proguard` of a jar) | `RdfR8` |
| Resources | linked to the proto format, shrunk by R8 in the same run when the build type says `shrinkResources`, converted and optimized (`aapt2 optimize --shorten-resource-paths`) | `RdfAapt2Link`, `RdfAapt2Convert`, `RdfAapt2Optimize` |
| Core library desugaring | the desugared library shrunk to what the app's final dex uses | `RdfL8` |
| Baseline profiles | those of the app (`src/main/baseline-prof.txt`) and of the AARs merged, rewritten by R8 and L8, compiled into `assets/dexopt/` | `RdfArtProfile` |
| Without `minifyEnabled` | D8 in release mode, no shrinking | `RdfDex`, `RdfDexMerge` |

A profile or release build carries the Dart program as machine code, one AOT library per ABI. The
ABIs are the Gradle project's, which for a stock app are the three of `flutter build apk`:
`armeabi-v7a`, `arm64-v8a` and `x86_64`; `abis = ["arm64-v8a"]` builds fewer. An ABI the Flutter SDK
has no AOT compiler for (`x86`, `riscv64`) fails the build, which says to set `abis`. A release build
has no split APKs (R8 works on the whole program); `//:app_release` is the APK.

### App bundles

`bazel build //:app_release_bundle` is what `flutter build appbundle` gives
(`bazel-bin/app_release_bundle.aab`): one module, `base`, with the manifest and the (shrunk) resources
in the proto format, the dex files, the native libraries, the assets and the Java resources, put
together as AGP's module task does and built by bundletool at the version AGP uses (by hash, from the
pin), with AGP's bundle configuration (`bundle { abi, density, language }` of the Gradle file,
uncompressed native libraries at 16 KB boundaries). Under `BUNDLE-METADATA` it carries the mapping
file, the baseline profile, R8's build record, AGP's marker file, and what AGP writes for the variant:

- `com.android.tools.build.libraries/dependencies.pb`, the Maven libraries of the app, which depends
  on which, and the repository of each (unless the Gradle file says `dependenciesInfo {
  includeInBundle = false }`). The pin records the report from the inputs of AGP's own task, in its
  order, and the build writes it with AGP's own message classes: the same bytes as the stock file.
- `com.android.tools.build.debugsymbols/<abi>/<library>.so.sym`, the symbol table of each native
  library that stripping makes smaller (`ndk { debugSymbolLevel }`: by default `SYMBOL_TABLE` in a
  build that is not debuggable; `FULL` gives `.so.dbg`), taken with the NDK's `llvm-objcopy` as AGP
  takes it. For this the AOT library is compiled without `--strip`, as in a stock build, and
  stripped when it is packaged. With `obfuscate` the compiler strips it all the same (its symbols
  would hold the names), so such a bundle has no symbol file for `libapp.so`.

Every variant has a bundle target (`//:app_bundle` is the debug one).

### Signing

A key store and its passwords are never in a checked-in file, an attribute, an action or a log.

- A debug build, and a release build whose signing configuration is the debug one (what the Flutter
  template writes: `signingConfig = signingConfigs.getByName("debug")`), are signed in the build with
  the debug key, which is no secret.
- A release build with any other signing configuration is built **unsigned**
  (`bazel-bin/app_release_apk-unsigned.apk`), and `bazel run //:app_release_sign` signs it outside
  the build, with AGP's signer and the schemes the signing configuration names. The pin records the
  configuration's name and schemes only. The key comes from where the stock tools' users keep it:
  - `android/key.properties` (the file Flutter's deployment guide has you write and keep out of
    version control: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`), or another such file
    named with `-- --key-properties <file>`; or
  - the environment, for CI: `ANDROID_KEYSTORE_FILE`, `ANDROID_KEYSTORE_PASSWORD`,
    `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, set from the CI system's secret store.

  The signed APKs are written to `build/app/outputs/flutter-apk/` of the app (where the stock tools
  put theirs), or into `-- --out <directory>`. `bazel run //:app_release_bundle_sign` does the same
  for the bundle (`build/app/outputs/bundle/release/app-release.aab`), signed as a jar.

### A Flutter module in a native app (add-to-app)

`flutter_android_aar` packages a `flutter_application` as an AAR: the AOT library
(`jni/<abi>/libapp.so`), `assets/flutter_assets/` and a manifest. A native Android app that is built
from its own pin carries it with `aars`:

```starlark
flutter_android_aar(name = "module_aar", application = ":module", package_name = "com.example.module", android_abi = "x86_64")

flutter_android_app(name = "host_app", variant = "release", aars = [":module_aar"])
```

The host's Gradle file names the Flutter engine and its Java embedding itself
(`io.flutter:flutter_embedding_release:1.0.0-<engine revision>` and `io.flutter:<abi>_release` from
`https://storage.googleapis.com/download.flutter.io`), as the pom of a stock `flutter build aar`
names them, so they are in the pin. An AAR of the build gives its manifest to the merge, its classes
to the dex and its native libraries and assets to the APK; it cannot carry resources or bundled jars
(the build fails and says so). `e2e/aar_host` is such an app. Not built: the Maven repository layout
of `flutter build aar` (the pom, one AAR per plugin); a module with plugins needs the plugins'
Android projects in the host's Gradle build.

### What a release build has that differs from the stock one

- `META-INF/version-control-info.textproto` (the commit of the checkout) and
  `kotlin-tooling-metadata.json` (a record of the Kotlin Gradle plugin) are not written.
- A release APK has no dependency block in its APK Signing Block (id `0x504b4453`: the dependency
  report, compressed and encrypted with a key of Google Play, which AGP adds unless the Gradle file
  says `dependenciesInfo { includeInApk = false }`). The encryption draws a new key every time, so
  the block cannot be an output of a build that gives the same bytes twice. The bundle has the report.
- The code is compiled by the Java and Kotlin compilers of the Bazel workspace, not by Gradle's, so
  compiler-made names (lambda numbers, synthetic classes) can differ; R8 then names classes in
  another order. Given the same class files, R8's output here is byte for byte the stock one.

## What is not built, and how it fails

Nothing is left out silently. What a new pin repairs (a variant the pin does not hold, a feature the
rules do not build) fails when the app is built, not when its package is loaded, so that the pin
target beside it still runs. The pin fails on a Gradle plugin class the rules cannot stand in for
(google-services is handled: the values it generates are recorded), on a project outside the app, the
pub cache and the Bazel workspace, on an app variant with several outputs, and on library projects
that depend on each other (two plugins whose pubspecs name each other: Gradle reports a circular
dependency between their tasks when it builds them). Generating the targets
fails, naming the project and the feature, on: data binding, view binding, Compose, RenderScript, ML
model binding, prefab; AIDL and shader sources; Java resource directories; a Kotlin compiler plugin
other than kapt and KSP; a Kotlin compiler argument the rules do not know; annotation processor
arguments in a Kotlin project; file dependencies (`libs/*.jar`); a shrinker rules file outside the
app; resource shrinking with `android.r8.optimizedResourceShrinking=false`; and native code built by
CMake or ndk-build. For the last, `flutter_android_app(native_built_elsewhere = [":jni"])` says that Bazel builds
that library on the Dart side.

A plugin project the model cannot express can be built by Gradle itself, as one cached action:
`flutter_android_pin(gradle_fallback = [":the_plugin"])`, then pin again. The build prints which
projects take this path. That one action is not hermetic: it runs the app's Gradle wrapper where the
app's Android project is, offline, with the JDK, Android SDK, Gradle home and pub cache of the machine
(pass them with `--action_env`), and needs `flutter pub get` done. Its result is cached under the
project's sources, the app's Gradle files and the pin. Native libraries and bundled jars of such a
project are not packaged yet.

## Testing what was built

`flutter_android_apk_test` of the pin's `defs.bzl` builds an app's APKs and checks them: classes and
entries that must (or must not) be there, which split holds what, the version, and always that no class
is defined twice, that native libraries are stored uncompressed at 16 KB boundaries, that the APK is
signed, and that the splits hold what the whole APK holds. `abi = "x86_64"` checks that ABI's APK of
an app built with `split_per_abi`. `flutter_android_bundle_test` does the same for the app bundle.

`flutter_android_sign_test(name, app)` is for an app whose signing configuration is its own: it makes
a key store in the test, runs `<app>_sign` and `<app>_bundle_sign` with that key in their
environment, and checks that the APK has a v2 signature with the key's certificate and that the
bundle verifies as a jar signed with it. No key is checked in.

## Hosts

The pin records aapt2 for Linux, macOS and Windows, and the hub picks the host's and the NDK's host
directory. Only Linux x86_64 has been run.

## Integration and drive tests

`flutter_integration_test(platform = "android", android_app = flutter_android_app)` builds the test
app's Android side with the app macro of the pin (pass the function loaded from the pin's
`defs.bzl`; `android_variant = "devDebug"` for a flavor), so the test runs the app's own Android
project with the plugins of its pubspec, integration_test's included, as `flutter test
integration_test` does. `flutter_drive_test(app = ":app_apk")` takes the whole APK of a debug app.
Both run on the pinned headless emulator. `e2e/integration_android` has both.

## Moving from the removed `android_binary` macros

`flutter_android_app` and `flutter_android_aab` of `@rules_flutter//flutter:android.bzl` (an
`android_binary` with the Flutter payload spliced in, plugins read from their Gradle files by a
lexer), the composable pieces around them (`flutter_android_engine`, `flutter_android_registrant`,
`flutter_android_manifest_gen`, `flutter_android_runner_lib_gen`, `flutter_android_plugin_library`,
`flutter_android_manifest_merge`, `flutter_android_apk_overlay`, ...) and the Android side of the pub
layer are removed. An app's Android side is built one way.

- **The Android project.** Add the app's stock Android project if it has only `android/app/src/main`
  (`flutter create --platforms=android .`), run `flutter pub get`, then `bazel run //:android_pin`, and
  check `android_model.json` in.
- **`MODULE.bazel`.** Add the `android_model` lines above and `rules_kotlin`. Remove the Android SDK
  repository of `rules_android`, the `rules_android_maven` install and its lock file, the `go_sdk`
  block, and `android_maven_deps` and `android_maven_ignore` of `flutter.pub` (both attributes are
  gone). Keep `rules_android_ndk` if the app has native code on the Dart side (FFI libraries,
  `package:jni`).
- **`BUILD.bazel`.** Load `flutter_android_app` from `@android_model//:defs.bzl`.

| Before | Now |
|---|---|
| `package_name`, `app_name`, `min_sdk_version`, `target_sdk_version` | `applicationId`, `android:label`, `minSdk`, `targetSdk` of the Gradle project |
| `manifest`, `debug_manifest`, `profile_manifest`, `permissions`, `resources` | the manifests and `res/` of `android/app/src/main`, `src/debug`, `src/profile` |
| `android_abi = "x64"` | `abis = ["x86_64"]`; by default the ABIs of the Gradle project |
| `-c dbg`, `-c opt`, `--@rules_flutter//flutter:profile` choosing the mode | `variant = "debug"`, `"profile"`, `"release"` (or a flavor's) |
| `keystore`, `keystore_password_file`, `key_alias`, the `//flutter:android_release_*` flags | the signing configuration of the Gradle file, and `bazel run //:<name>_sign` with `android/key.properties` or the environment (see "Signing") |
| `flutter_android_aab` | `//:<name>_bundle` of any `flutter_android_app` |
| `proguard_specs` | `proguardFiles` of the release build type |
| `deps = [":my_plugin_android"]`, `flutter_plugin(android_libs = ...)`, `flutter_android_plugin_library` | the plugin's own `android/build.gradle`; the app names the package as a path dependency in `pubspec.yaml` |
| `@<hub>//android:all_android_plugin_libs` | gone: an app has the plugins of its pubspec |
| `analyze_size = True` | `flutter_android_bundle(analyze_size = True, flutter_mode = "release")` |
| `//flutter:android_pure_go` | gone: no Go tool is built |
| `flutter_integration_test(android_package, android_deps, pub_hub_name)` | `android_app = flutter_android_app` |
| `flutter_drive_test(app = ":app", package_name = ...)` | `app = ":app_apk"` |

What changes in behaviour: an app has every Android plugin of its pubspec, as a stock build does (the
old macro packaged only the plugins the Dart graph of the target reached); a debug build is the
`debug` variant whatever `-c` says; and `INTERNET` in a release build comes from the main manifest
only, as in a stock project.
