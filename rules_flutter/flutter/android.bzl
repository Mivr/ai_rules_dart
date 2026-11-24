"""Flutter rules for Android builds.

An app's Android side is its stock Android project (`android/`, as `flutter create
--platforms=android .` writes it), built from a pin file that Gradle writes once:

    # MODULE.bazel
    android_model = use_extension("@rules_flutter//flutter:android.bzl", "android_model")
    android_model.pin(model = "//:android_model.json")
    use_repo(android_model, "android_model")
    register_toolchains("@android_model//:kotlin_toolchain")

    # BUILD.bazel, beside pubspec.yaml
    load("@android_model//:defs.bzl", "flutter_android_app")
    load("@rules_flutter//flutter:android.bzl", "flutter_android_pin")
    load("@rules_flutter//flutter:defs.bzl", "flutter_application")

    flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

    flutter_android_pin(name = "android_pin")  # bazel run //:android_pin

    flutter_android_app(name = "app", application = ":my_app")

`flutter_android_app` is in the pin's own repository (`@android_model//:defs.bzl`), with
`flutter_android_apk_test` and `flutter_android_bundle_test`: debug, profile and release APKs, one
APK per ABI and app bundles, as the variants of the Gradle project. See docs/android-model.md.
"""

load(
    "//flutter/private:flutter_android_application.bzl",
    _flutter_android_aar = "flutter_android_aar",
    _flutter_android_bundle = "flutter_android_bundle",
)
load("//flutter/private:flutter_drive_test.bzl", _flutter_drive_test = "flutter_drive_test")
load("//flutter/private/android_model:extension.bzl", _android_model = "android_model")
load("//flutter/private/android_model:pin.bzl", _flutter_android_pin = "flutter_android_pin")

visibility("public")

# `android_model.pin(model = "//:android_model.json")` in MODULE.bazel makes a repository whose
# `defs.bzl` has `flutter_android_app`; `flutter_android_pin` is the target that writes the pin file.
android_model = _android_model
flutter_android_pin = _flutter_android_pin

# The Dart payload of an app for one Android ABI (the AOT library, the native libraries of the Dart
# graph, `flutter_assets`). `flutter_android_app` packages it; name it directly to build or inspect
# the payload alone.
flutter_android_bundle = _flutter_android_bundle

# Packages a flutter_application as an AAR for a native Android host app (add-to-app).
flutter_android_aar = _flutter_android_aar

# Runs a host-side driver script against an Android emulator or iOS simulator app.
flutter_drive_test = _flutter_drive_test
