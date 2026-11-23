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

Pin again when `pubspec.lock`, a Gradle file of the app or the plugin set changes. A build whose files
differ from what the pin was computed from fails and names the files and the command:

```
//:android_model.json is stale: it was written by Gradle for other contents of
  android/app/build.gradle.kts
Pin again and commit the result:
  bazel run //:android_pin
```

`bazel run //:android_pin -- --check` fails when the file is not what Gradle gives now, without writing
it (for CI). Two pins of the same inputs are the same bytes.

`MODULE.bazel`:

```starlark
bazel_dep(name = "rules_kotlin", version = "2.4.20")

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

The tools are AGP's own, at the versions the pin records: D8 and L8 from R8, the manifest merger, the
resource compiler and aapt2, the R class writer, the APK signer. Kotlin is compiled by `rules_kotlin`,
kapt and KSP included. `rules_android` and `rules_jvm_external` are not used.

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
build, the `profile` build type a profile build, any other a release build.

## Release and profile builds

```starlark
flutter_android_app(
    name = "app_release",
    application = ":counter",
    variant = "release",
    abis = ["arm64-v8a", "x86_64"],
    split_per_abi = True,
)
```

`bazel build //:app_release_apk` is what `flutter build apk --release` gives; with `split_per_abi`,
`//:app_release_apk_arm64_v8a` and `//:app_release_apk_x86_64` are what `--split-per-abi` gives, with
Flutter's version codes (`1000 * <ABI number> + versionCode`). `//:app_release_mapping` is the mapping
file that retraces a stack trace of that build.

| Step | As the stock build | Actions |
|---|---|---|
| The Dart program | one AOT library per ABI, `lib/<abi>/libapp.so`; `flutter_assets` without the kernel | the Dart side's AOT compile |
| Code | R8 over the whole program when the build type says `minifyEnabled` (Flutter's default for release): AGP's own driver and R8 by hash, full mode, with the rules of the app (AGP's default file and the Flutter tool's rules, carried in the pin; the app's own files), of the plugin projects (`consumerProguardFiles`) and of the Maven artifacts (`proguard.txt` of an AAR, `META-INF/com.android.tools/r8*` or `META-INF/proguard` of a jar) | `RdfR8` |
| Resources | linked to the proto format, shrunk by R8 in the same run when the build type says `shrinkResources`, converted and optimized (`aapt2 optimize --shorten-resource-paths`) | `RdfAapt2Link`, `RdfAapt2Convert`, `RdfAapt2Optimize` |
| Core library desugaring | the desugared library shrunk to what the app's final dex uses | `RdfL8` |
| Baseline profiles | those of the app (`src/main/baseline-prof.txt`) and of the AARs merged, rewritten by R8 and L8, compiled into `assets/dexopt/` | `RdfArtProfile` |
| Without `minifyEnabled` | D8 in release mode, no shrinking | `RdfDex`, `RdfDexMerge` |

A profile or release build carries the Dart program as machine code, so it is built for the ABIs the
rules have an AOT compiler for: `arm64-v8a` and `x86_64`. A stock app asks for `armeabi-v7a` too; say
`abis = ["arm64-v8a", "x86_64"]`, or the build fails and tells you to. A release build has no split
APKs (R8 works on the whole program); `//:app_release` is the APK.

### App bundles

`bazel build //:app_release_bundle` is what `flutter build appbundle` gives
(`bazel-bin/app_release_bundle.aab`): one module, `base`, with the manifest and the (shrunk) resources
in the proto format, the dex files, the native libraries, the assets and the Java resources, put
together as AGP's module task does and built by bundletool at the version AGP uses (by hash, from the
pin), with AGP's bundle configuration (`bundle { abi, density, language }` of the Gradle file,
uncompressed native libraries at 16 KB boundaries). Under `BUNDLE-METADATA` it carries the mapping
file, the baseline profile, R8's build record and AGP's marker file. Every variant has a bundle target
(`//:app_bundle` is the debug one).

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

### What a release build has that differs from the stock one

- `META-INF/version-control-info.textproto` (the commit of the checkout) and
  `kotlin-tooling-metadata.json` (a record of the Kotlin Gradle plugin) are not written.
- A bundle has no `BUNDLE-METADATA/com.android.tools.build.libraries/dependencies.pb` (the list of
  Maven dependencies the Play Console reads) and no native debug symbols
  (`com.android.tools.build.debugsymbols`).
- The code is compiled by the Java and Kotlin compilers of the Bazel workspace, not by Gradle's, so
  compiler-made names (lambda numbers, synthetic classes) can differ; R8 then names classes in
  another order. Given the same class files, R8's output here is byte for byte the stock one.

## What is not built, and how it fails

Nothing is left out silently. The pin fails on a Gradle plugin class the rules cannot stand in for
(google-services is handled: the values it generates are recorded), on a project outside the app, the
pub cache and the Bazel workspace, and on an app variant with several outputs. Generating the targets
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
an app built with `split_per_abi`.

## Hosts

The pin records aapt2 for Linux, macOS and Windows, and the hub picks the host's and the NDK's host
directory. Only Linux x86_64 has been run.

## Moving from `flutter_android_app` of `@rules_flutter//flutter:android.bzl`

That macro (an `android_binary` with the Flutter payload spliced in, plugins read from their Gradle
files by a lexer) still exists beside this path until every workspace has moved. An app is on one
path or the other: built from a pin, its Dart packages bring no Android library of their own.

- Add the app's stock Android project if it has only `android/app/src/main`, run the pin and check
  `android_model.json` in.
- `MODULE.bazel`: add the `android_model` lines above. The Android SDK and NDK repositories of
  `rules_android`, the `rules_android_maven` install with its lock file, `android_maven_deps` and
  `android_maven_ignore` of `flutter.pub`, and the Go SDK override are not needed by this path.
- `BUILD.bazel`: load `flutter_android_app` from `@android_model//:defs.bzl`. `package_name`,
  `permissions`, `manifest` and the like go: the application id, the manifests, the resources and the
  SDK levels are the Gradle project's.
