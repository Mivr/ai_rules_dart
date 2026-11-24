# Add-to-app iOS xcframeworks

Flutter's documented add-to-app path embeds a Flutter screen in an existing
Xcode application. The Xcode target links prebuilt xcframeworks produced by
`flutter build ios-framework`; `rules_flutter` produces the same artifact set
hermetically with `flutter_ios_xcframeworks`, from an ordinary
`flutter_application`.

This page is the detailed reference. The README section is the short version.

## Usage

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
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

`bazel build //:my_app_xcframeworks` writes the set under
`bazel-bin/my_app_xcframeworks/`:

```
my_app_xcframeworks/
  App.xcframework/
    Info.plist
    ios-arm64/App.framework/
    ios-arm64_x86_64-simulator/App.framework/
  Flutter.xcframework/
  FlutterPluginRegistrant.xcframework/
  <Plugin>.xcframework/
```

Add each `.xcframework` directory to the Xcode target under **Frameworks,
Libraries, and Embedded Content**, with **Embed & Sign**.

`flutter_ios_xcframeworks` is exported from `flutter/ios.bzl`. The target is
tagged `manual` by default and restricted to macOS hosts, because the AOT
device and simulator slices need a Darwin host to compile.

## Attributes

| Attribute | Description |
|---|---|
| `name` | Target name. `DefaultInfo.files` is the xcframework set. |
| `application` | A `flutter_application` target. Required; omitting it fails with `flutter_ios_xcframeworks: application is required`. Its transitive native plugins become xcframeworks. |
| `minimum_os_version` | Minimum iOS deployment target written into every framework plist. Defaults to `IOS_MINIMUM_OS_VERSION`, which is the version the prebuilt engine is built for; a lower value is refused. `App.framework` keeps the value its own framework rule writes. |
| `visibility` | Standard target visibility, forwarded to the result target. |
| `tags` | Standard Bazel tags. Defaults to `["manual"]`; the internal device and simulator targets are always `manual`. |
| `target_compatible_with` | Standard compatibility constraints. Defaults to `["@platforms//os:macos"]`; override it only if another host can build the Darwin slices. |
| `**kwargs` | Other common target attributes (`testonly`, `features`, and so on) are forwarded to the result target. |

## What each xcframework contains

### `App.xcframework`

Exactly two slices:

| `LibraryIdentifier` | `SupportedPlatform` | `SupportedPlatformVariant` | `SupportedArchitectures` |
|---|---|---|---|
| `ios-arm64` | `ios` | — | `[arm64]` |
| `ios-arm64_x86_64-simulator` | `ios` | `simulator` | `[arm64, x86_64]` |

Each slice is an `App.framework` with the AOT `App` binary, its `Info.plist` and
`flutter_assets/`. The device slice is built for `ios_arm64`; the simulator
slice is `macho_edit fat` of the `ios_sim_arm64` and `ios_x64` builds. Both
slices are AOT snapshots and export the engine's
`_kDartSnapshotText`/`_kDartSnapshotData` symbols, not the debug stub.

The add-to-app macro reuses `flutter_ios_framework` rather than assembling a
second App.framework. Its private `allow_simulator_aot` attribute makes the
simulator slice AOT, which ordinary simulator apps leave off because the
JIT-only simulator engine cannot load AOT code.

### `Flutter.xcframework`

This is the pinned iOS engine the rules already select for the compilation
configuration (`@flutter_ios_engine` for release and debug,
`@flutter_ios_engine_profile` for profile; see `flutter/private/ios_app.bzl`).
`@flutter_ios_engine` is a hub of aliases to a private release repository and a
private debug repository, so a debug-only build fetches only the debug engine;
the one `use_repo` entry is unchanged.
The rule writes the xcframework layout by symlinking every engine file at its
existing relative path, so the slice binaries are the pinned engine's own
files, never copied or rewritten.

### `FlutterPluginRegistrant.xcframework`

The application's generated `GeneratedPluginRegistrant.swift` is linked with
the plugin aggregator into a dynamic framework. Device and universal simulator
slices carry the same registration calls the Bazel runner uses, so an Xcode
runner can call `GeneratedPluginRegistrant.register(with:)`.

### `<Plugin>.xcframework`

Every native iOS plugin in the application's transitive graph contributes one
xcframework named after its pub package. The framework's binary is the plugin
library's compiled output from `ios_libs` (usually a
`flutter_apple_plugin_library`); its module and headers are the ones the
registrant imports. The `ios-arm64` slice holds the device build. The
`ios-arm64_x86_64-simulator` slice holds a universal static archive fused from
the plugin's arm64 and x86_64 simulator builds, so a plugin must build for both
the device and the simulator or the rule fails. A plugin package named `App`, `Flutter` or
`FlutterPluginRegistrant` is refused because its xcframework would collide with
the three fixed names.

## Hermetic assembly

No action runs `xcodebuild -create-xcframework`. The rule writes each
`.xcframework/Info.plist` and framework `Info.plist` in Starlark, symlinks the
engine and plugin files, and uses the `macho_edit` host tool the Apple rules
already run to fat-fuse, retag and install-name the linked slices. That is the
same tool and the same slice layout `flutter_darwin_xcframework_import` reads.
No new download and no extra host tool is introduced.

## Proof

`e2e/ios_framework` defines a plain `flutter_application`, a first-party Swift
plugin, and the macro over them. Its macOS-only
`//:verify_ios_xcframeworks_test` reads the built outputs and asserts:

- `App.xcframework/Info.plist` lists exactly the two slices in the table above;
- the device App slice is 64-bit arm64 Mach-O with platform iOS (2) and the
  simulator slice is 64-bit arm64 + x86_64 with platform iOS-simulator (7);
- both App slices export the AOT snapshot symbols;
- the `Flutter.xcframework` device binary is byte-identical to the pinned
  engine file included in the test data;
- `FlutterPluginRegistrant.xcframework` registers the workspace plugin; and
- the plugin's xcframework carries the plugin's compiled code.

The workspace is part of the `e2e-macos` matrix in
`.github/workflows/full.yaml`, so a plain `bazel test //...` in it runs the
proof on macOS.
