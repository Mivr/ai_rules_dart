"""What differs between the Flutter release lines these rules support.

The one place that says how a build differs by SDK line. A line is a release's
`<major>.<minor>`: every patch of it, a custom release (`flutter.version`) and
a local SDK get their line's behaviour, decided by the version they carry. A
version between two listed lines takes the older one's, a version above the
newest takes the newest's, and one below the oldest takes the oldest's (it
does not work anyway: the tables list no such release).

Rules read the entry from `FlutterSdkInfo.line`, which the toolchain sets;
repository rules, which have no toolchain, call `flutter_sdk_line` with the
version they fetch. No other file compares Flutter versions.

Each entry names the stock change it follows (pull requests are
flutter/flutter's):

- `icon_tree_shaker`: what the icon font shaker of `flutter_tools` reads.
  `"const_finder"`: it runs `const_finder.dart.snapshot` (shipped in
  `font-subset.zip`) over the app's kernel; a web build compiles that kernel
  with `dart compile js --cfe-only`. `"recorded_uses"`: it reads the uses the
  compilers record (the AOT compile's `--recorded-uses`, dart2js's
  `--write-resources`, dart2wasm's `--recorded-uses`), and `font-subset.zip`
  has no `const_finder` (#190225, #191702, Flutter 3.50).
- `ddc_dart_sdk_js`: where the web SDK keeps the DDC `dart_sdk.js` the dev
  loop serves; `kernel/ddc/{stable,canary}` since #193193 (Flutter 3.50).
- `assets_tool_api`: the directory of `//flutter/private/assets_tool` whose
  `assets_tool_api.dart` holds the asset tool's calls into `flutter_tools`
  whose API differs by line
  (`TargetPlatform.fromName` replaced `getTargetPlatformForName`,
  `writeBundle` takes the `platform`, `Artifact.constFinder` left with the
  shaker; Flutter 3.50).
- `test_bundle_native_assets_manifest`: whether flutter_tester and the engine
  resolve `@Native` assets through the `NativeAssetsManifest.json` in the
  assets directory, which a test bundle and an integration test's bundle then
  carry (#192800, "Flutter-owned NativeAssetsManifest", Flutter 3.50); before,
  through the mapping library in the kernel alone.
- `android_gradle_plugin`: the Android Gradle plugin versions the build tools
  are built and tested with on this line: the oldest the e2e apps use and the
  one `flutter create` names (`templateAndroidGradlePluginVersion` in
  `gradle_utils.dart`). The floors themselves are stock's: the pin runs the
  release's own Gradle plugin, whose `DependencyVersionChecker.kt` refuses AGP
  below 8.11.1 and Kotlin below 2.2.20 in 3.47, and AGP below 9.1.1 and Kotlin
  below 2.4.10 in 3.50; the pin records the engine, which the build checks
  against the toolchain's (`flutter_android_bundle`), whatever the line.

Not entries, because one rule serves every line: the `sky_engine` part stubs
(planted only where the archive lacks the file) and the asset tool's pin rows
(per version, in `flutter_assets_tool_versions.bzl`).
"""

visibility(["//flutter/...", "//tools/..."])

FLUTTER_SDK_LINES = {
    "3.50": struct(
        icon_tree_shaker = "recorded_uses",
        ddc_dart_sdk_js = "kernel/ddc/canary/dart_sdk.js",
        assets_tool_api = "api_3_50",
        test_bundle_native_assets_manifest = True,
        android_gradle_plugin = ("9.1.1", "9.3.1"),
    ),
    "3.47": struct(
        icon_tree_shaker = "const_finder",
        ddc_dart_sdk_js = "kernel/ddcLibraryBundle-canvaskit/dart_sdk.js",
        assets_tool_api = "api_3_47",
        test_bundle_native_assets_manifest = False,
        android_gradle_plugin = ("9.1.0", "9.1.0"),
    ),
}

def _minor(version):
    """`(major, minor)` of a version or line string, or None."""
    parts = version.split("-")[0].split("+")[0].split(".")
    if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
        return None
    return (int(parts[0]), int(parts[1]))

def flutter_sdk_line_name(version):
    """The key of `FLUTTER_SDK_LINES` whose behaviour a Flutter version gets.

    Args:
      version: A Flutter version, such as `3.47.7`, `3.50.10` (a custom
        release) or `3.48.0-1.0.pre` (a local SDK).

    Returns:
      The line's key, such as `"3.47"`.
    """
    lines = sorted([(_minor(k), k) for k in FLUTTER_SDK_LINES.keys()])
    v = _minor(version)
    if v == None:
        return lines[-1][1]
    chosen = lines[0][1]
    for minor, key in lines:
        if minor <= v:
            chosen = key
    return chosen

def flutter_sdk_line(version):
    """The `FLUTTER_SDK_LINES` entry of a Flutter version.

    Args:
      version: A Flutter version (see `flutter_sdk_line_name`).

    Returns:
      The line's struct.
    """
    return FLUTTER_SDK_LINES[flutter_sdk_line_name(version)]
