"""Generated app BUILD targets and Android scaffolding for the bench."""

from gen_files import write_plain

TRACK_LINE = "    track_widget_creation = True,\n"


def _app_ios_build_text():
    """iOS targets: Tier-1 app, explicit App.framework and sim test."""
    return (
        "# iOS, Tier-1 style: the macro discovers ios/Runner/ from `flutter create`\n"
        "# and tags every internal target \"manual\" itself, so a Linux `//...`\n"
        "# skips the whole stack without any explicit constraint here.\n"
        "flutter_ios_app(\n"
        "    name = \"app_ios\",\n"
        "    app_name = \"Bench\",\n"
        "    application = \":app\",\n"
        "    bundle_id = \"com.example.bench\",\n"
        ")\n"
        "\n"
        "# Explicit public App.framework target for the device_release bench\n"
        "# config: AOT gen_snapshot for arm64 plus framework assembly, with no\n"
        "# ios_application, so no signing and no provisioning profile.\n"
        "flutter_ios_framework_gen(\n"
        "    name = \"app_framework\",\n"
        "    application = \":app\",\n"
        ")\n"
        "\n"
        "flutter_ios_simulator_build_test(\n"
        "    name = \"app_ios_sim\",\n"
        "    targets = [\":app_ios\"],\n"
        "    target_compatible_with = [\"@platforms//os:macos\"],\n"
        ")\n"
    )


def _app_android_build_text():
    """Android target: discovers the generated android/app/src/main scaffold."""
    return (
        "\n"
        "# Android, Tier-1 style: the macro discovers the conventional\n"
        "# android/app/src/main/ scaffold and declares the app's APK output.\n"
        "flutter_android_app(\n"
        "    name = \"app_android\",\n"
        "    package_name = \"com.example.bench\",\n"
        "    app_name = \"Bench\",\n"
        "    application = \":app\",\n"
        ")\n"
    )


def _app_web_build_text(app_deps):
    """Web target: the deployment directory from the same layered Dart code."""
    return (
        "\n"
        "# Web, Tier-1 style: built-in page templates when web/ has none, and\n"
        "# the declared output is the deployment directory.\n"
        "flutter_web_app(\n"
        "    name = \"app_web\",\n"
        "    package_name = \"app\",\n"
        "    app_name = \"Bench\",\n"
        "    deps = [\n"
        "%s" % app_deps
        + "        \"@deps//:flutter\",\n"
        "    ],\n"
        ")\n"
    )


def write_app_build(out_dir, top_layer, track_widget_creation=False):
    """app/BUILD.bazel: VM application, analyzer library, iOS, Android, Web.

    flutter_ios_app tags every internal target "manual" itself, so iOS stays
    out of a Linux //... (the ios/Runner/ scaffold it discovers is copied
    from the hello_world fixture). Seven top-level targets: the shared
    flutter_application, its analyzer library, the full Tier-1 simulator/
    device app, an explicit public App.framework target (Tier-2
    flutter_ios_framework_gen over the same application, so the bench's
    device_release config builds a stable public label instead of the
    macro's private __app_ios_app_framework), the simulator build test, the
    Android APK and the Web deployment directory over the same application.
    `track_widget_creation` writes the attribute on that application.
    """
    app_deps = "".join("        \"//packages/pkg%d\",\n" % a for a in top_layer)
    build = (
        "load(\"@rules_flutter//flutter:defs.bzl\", \"flutter_application\", \"flutter_library\")\n"
        "load(\"@rules_flutter//flutter:android.bzl\", \"flutter_android_app\")\n"
        "load(\"@rules_flutter//flutter:ios.bzl\", \"flutter_ios_app\", \"flutter_ios_framework_gen\", \"flutter_ios_simulator_build_test\")\n"
        "load(\"@rules_flutter//flutter:web.bzl\", \"flutter_web_app\")\n"
        "\n"
        "flutter_application(\n"
        "    name = \"app\",\n"
        "    package_name = \"app\",\n"
        "    main = \"lib/main.dart\",\n"
        + (TRACK_LINE if track_widget_creation else "")
        + "    deps = [\n"
        "%s" % app_deps
        + "        \"@deps//:flutter\",\n"
        "    ],\n"
        ")\n"
        "\n"
        "# The app rule is a bundle and carries no DartInfo, so the sources are\n"
        "# declared once more as a library for the analyzer to stage.\n"
        "flutter_library(\n"
        "    name = \"app_lib\",\n"
        "    package_name = \"app\",\n"
        "    srcs = glob([\"lib/**/*.dart\"]),\n"
        "    deps = [\n"
        "%s" % app_deps
        + "        \"@deps//:flutter\",\n"
        "    ],\n"
        ")\n"
        "\n"
    ) + _app_ios_build_text() + _app_android_build_text(
    ) + _app_web_build_text(app_deps)
    write_plain(out_dir, "app/BUILD.bazel", build)
    return 7


def write_android_scaffolding(out_dir):
    """Writes the conventional android/app/src/main scaffold the rule reads.

    The generated app uses a fixed com.example.bench package: the manifest
    names `.MainActivity`, the Kotlin runner declares the same package, and
    the launch styles resolve without depending on copied fixture files.
    """
    write_plain(
        out_dir, "app/android/app/src/main/AndroidManifest.xml",
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
        "    <application\n"
        "        android:label=\"Bench\"\n"
        "        android:name=\"${applicationName}\">\n"
        "        <activity\n"
        "            android:name=\".MainActivity\"\n"
        "            android:exported=\"true\"\n"
        "            android:launchMode=\"singleTop\"\n"
        "            android:theme=\"@style/LaunchTheme\"\n"
        "            android:configChanges=\"orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode\"\n"
        "            android:hardwareAccelerated=\"true\"\n"
        "            android:windowSoftInputMode=\"adjustResize\">\n"
        "            <intent-filter>\n"
        "                <action android:name=\"android.intent.action.MAIN\"/>\n"
        "                <category android:name=\"android.intent.category.LAUNCHER\"/>\n"
        "            </intent-filter>\n"
        "        </activity>\n"
        "        <meta-data\n"
        "            android:name=\"flutterEmbedding\"\n"
        "            android:value=\"2\" />\n"
        "    </application>\n"
        "</manifest>\n")
    write_plain(
        out_dir,
        "app/android/app/src/main/kotlin/com/example/bench/MainActivity.kt",
        "package com.example.bench\n"
        "\n"
        "import io.flutter.embedding.android.FlutterActivity\n"
        "\n"
        "class MainActivity : FlutterActivity()\n")
    write_plain(
        out_dir, "app/android/app/src/debug/AndroidManifest.xml",
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
        "    <uses-permission android:name=\"android.permission.INTERNET\"/>\n"
        "</manifest>\n")
    write_plain(
        out_dir, "app/android/app/src/main/res/values/styles.xml",
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<resources>\n"
        "    <style name=\"LaunchTheme\" parent=\"@android:style/Theme.Light.NoTitleBar\">\n"
        "        <item name=\"android:windowBackground\">@drawable/launch_background</item>\n"
        "    </style>\n"
        "    <style name=\"NormalTheme\" parent=\"@android:style/Theme.Light.NoTitleBar\">\n"
        "        <item name=\"android:windowBackground\">?android:colorBackground</item>\n"
        "    </style>\n"
        "</resources>\n")
    write_plain(
        out_dir, "app/android/app/src/main/res/drawable/launch_background.xml",
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<layer-list xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
        "    <item android:drawable=\"@android:color/white\"/>\n"
        "</layer-list>\n")


def render_app_main(top_layer):
    """Application entrypoint wiring every top-layer feature package.

    Builds every top-layer package's widget and calls every top-layer
    package's entry point with a probe main reads from a runtime source
    (`int.tryParse` on a non-numeric literal is always null here, so the
    probe is zero at run time) the compiler cannot fold, keeping the
    guarded cross-package calls reachable for AOT tree-shaking. The summed
    entry results flow into a displayed string, so edited functions below
    the top layer have a reachable use.
    """
    out = ["import 'package:flutter/material.dart';"]
    dep_imports = sorted(
        "import 'package:pkg%d/pkg%d.dart';" % (a, a) for a in top_layer
    )
    out.extend(dep_imports)
    out.append("")
    out.append("/// Bench application wiring the top-layer feature packages.")
    out.append("void main() {")
    out.append("  final int probe = int.tryParse('probe') ?? 0;")
    out.append("  var reach = 0;")
    for a in top_layer:
        out.append("  reach += entry%d(3, probe);" % a)
    out.append("  runApp(")
    out.append("    MaterialApp(")
    out.append("      home: Scaffold(")
    out.append("        body: Center(")
    out.append("          child: Column(")
    out.append("            mainAxisSize: MainAxisSize.min,")
    out.append("            children: [")
    for a in top_layer:
        out.append("              W%dx0(value: value%dx0())," % (a, a))
    out.append("              Text('reach: $reach'),")
    out.append("            ],")
    out.append("          ),")
    out.append("        ),")
    out.append("      ),")
    out.append("    ),")
    out.append("  );")
    out.append("}")
    return "\n".join(out) + "\n"
