"""Native plugin packages for the scale bench's generated workspace.

`gen_monorepo.py generate --plugins=N` calls `add_plugins` after the Dart
monorepo is written. The workspace gains N path plugins under `plugins/`,
a seeded mix of the three kinds the public rules support, each declared the
way a user declares it:

- `source`: an iOS source plugin (Swift or Objective-C `ios/Classes` plus a
  podspec);
- `swiftpm`: an iOS plugin with a `Package.swift` whose dependencies are
  pinned in a recorded `Package.resolved`, every pin carrying its archive
  sha256 in `swift_package_sha256`;
- `maven`: an Android plugin (Kotlin or Java `android/src`, a `build.gradle`)
  whose Maven coordinates are mapped with `android_maven_deps` and recorded
  with their sha256 in `plugins/maven_pins.json`.

The app targets depend on all N plugins. Every checksum below was read from
the repository's own fixtures (`e2e/integration_ios/MODULE.bazel` and
`e2e/hello_world/rules_android_maven_install.json`); none is invented.
"""

import json
import os
import re

from gen_files import write_plain

KINDS = ("source", "swiftpm", "maven")
PLUGINS_DIR = "plugins"
SWIFTPM_DIR = PLUGINS_DIR + "/swiftpm"
MAVEN_PINS_REL = PLUGINS_DIR + "/maven_pins.json"
INSTALL_JSON_REL = "rules_android_maven_install.json"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

# identity -> (repository, revision, version, archive sha256).
SPM_PINS = {
    "bigint": (
        "https://github.com/attaswift/BigInt.git",
        "63feef7820abb1a8fb08587d7da56bb0b7db8751", "6.0.1",
        "55fc8a63f655a09d9216f2c9bc062c508f98d4eca4b8ebefaf295a3ea4ac8f22"),
    "swift-algorithms": (
        "https://github.com/apple/swift-algorithms.git",
        "f6919dfc309e7f1b56224378b11e28bab5bccc42", "1.2.0",
        "a4b0ad3a0db2170d1c1a7f521aec9d7a1fd3a8180e7a51049d856ae27ab43b72"),
    "swift-numerics": (
        "https://github.com/apple/swift-numerics.git",
        "0a5bc04095a675662cf24757cc0640aa2204253b", "1.0.2",
        "2127f4ad551b0f1763595060eca64454884382907b14289844fbd2815c7635eb"),
}
# SwiftPM variant -> the pin identities its Package.swift depends on.
SPM_VARIANTS = (("bigint",), ("swift-algorithms", "swift-numerics"))

# (rules_android_maven_install.json key, version, sha256 of the artifact).
MAVEN_CATALOG = (
    ("androidx.annotation:annotation", "1.9.1",
     "38322afa7345c37e29c65ec8852178ae1c26e23096a0634d07a4a3893931f58c"),
    ("androidx.core:core:aar", "1.17.0",
     "e1bd22bbcf5cee3a992dedb7d2d3c3b31c9f761c01e56d00ea443c8aaa981182"),
    ("androidx.fragment:fragment:aar", "1.8.9",
     "12de5b89ab6641c1d8da82b63dc816652622b06d2781b949b6fbd2dff9fac492"),
    ("androidx.lifecycle:lifecycle-common", "2.10.0",
     "9d3a9980095b769deb4f328f7f325439b188147124d66dc42edd55e3e7beea37"),
    ("androidx.tracing:tracing:aar", "1.2.0",
     "6faa90390d1fdbf0adb9a99bf99de67b94c6c6f35aea9510593a9d17973736a2"),
    ("androidx.window:window:aar", "1.3.0",
     "4aef04a1390b91869abef45164e915ea3407d2e03b159c44d003cb9443c27e93"),
)
MAVEN_DEPS_PER_PLUGIN = 2

_HUB_TAG = ("flutter.pub(\n"
            "    name = \"deps\",\n"
            "    lock = \"//:pubspec.lock\",\n"
            ")\n")


def plugin_name(index):
    """Pub package name of plugin `index`."""
    return "benchplugin%d" % index


def class_name(index):
    """Native plugin class name of plugin `index`."""
    return "BenchPlugin%d" % index


def plugin_kinds(count, rng):
    """Seeded mix of `count` kinds; every kind appears from count >= 3.

    Kinds cycle through KINDS, so the mix is balanced, then a seeded
    Fisher-Yates shuffle fixes the order for the seed.
    """
    kinds = [KINDS[i % len(KINDS)] for i in range(count)]
    for i in range(count - 1, 0, -1):
        j = rng.below(i + 1)
        kinds[i], kinds[j] = kinds[j], kinds[i]
    return kinds


def maven_coordinate(key, version):
    """`group:artifact:version` of a catalog install-json key."""
    group, artifact = key.split(":")[:2]
    return "%s:%s:%s" % (group, artifact, version)


def maven_label(key):
    """`@rules_android_maven` label of a catalog install-json key."""
    group, artifact = key.split(":")[:2]
    return "@rules_android_maven//:" + re.sub(r"[.\-]", "_", group) + "_" \
        + re.sub(r"[.\-]", "_", artifact)


def _pubspec_text(index, platform_block):
    return (
        "name: %s\n"
        "description: Scale bench native plugin.\n"
        "version: 0.0.1\n"
        "publish_to: none\n"
        "\n"
        "environment:\n"
        "  sdk: ^3.13.0\n"
        "\n"
        "dependencies:\n"
        "  flutter:\n"
        "    sdk: flutter\n"
        "\n"
        "flutter:\n"
        "  plugin:\n"
        "    platforms:\n"
        "%s" % (plugin_name(index), platform_block))


def _dart_text(index):
    cls = class_name(index)
    return (
        "import 'package:flutter/services.dart';\n"
        "\n"
        "/// Method-channel client for scale bench plugin %d.\n"
        "class %s {\n"
        "  /// Creates a [%s] instance.\n"
        "  const %s();\n"
        "\n"
        "  static const MethodChannel _channel = MethodChannel(\n"
        "    'rules_flutter/%s',\n"
        "  );\n"
        "\n"
        "  /// Asks the native side for its value.\n"
        "  Future<String?> value() {\n"
        "    return _channel.invokeMethod<String>('value');\n"
        "  }\n"
        "}\n" % (index, cls, cls, cls, plugin_name(index)))


def _swift_body(index, imports):
    cls = class_name(index)
    return (
        "%s"
        "import Flutter\n"
        "import UIKit\n"
        "\n"
        "public class %s: NSObject, FlutterPlugin {\n"
        "  public static func register(with registrar: FlutterPluginRegistrar) {\n"
        "    let channel = FlutterMethodChannel(\n"
        "      name: \"rules_flutter/%s\", binaryMessenger: registrar.messenger())\n"
        "    registrar.addMethodCallDelegate(%s(), channel: channel)\n"
        "  }\n"
        "\n"
        "  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {\n"
        "    result(call.method == \"value\" ? \"%s\" : FlutterMethodNotImplemented)\n"
        "  }\n"
        "}\n" % (imports, cls, plugin_name(index), cls, cls))


def _objc_files(index):
    cls = class_name(index)
    header = ("#import <Flutter/Flutter.h>\n"
              "\n"
              "@interface %s : NSObject <FlutterPlugin>\n"
              "@end\n" % cls)
    source = ("#import \"%s.h\"\n"
              "\n"
              "@implementation %s\n"
              "+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {\n"
              "  FlutterMethodChannel *channel = [FlutterMethodChannel\n"
              "      methodChannelWithName:@\"rules_flutter/%s\"\n"
              "            binaryMessenger:[registrar messenger]];\n"
              "  [registrar addMethodCallDelegate:[[%s alloc] init] channel:channel];\n"
              "}\n"
              "\n"
              "- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {\n"
              "  result([call.method isEqualToString:@\"value\"] ? @\"%s\" : FlutterMethodNotImplemented);\n"
              "}\n"
              "@end\n" % (cls, cls, plugin_name(index), cls, cls))
    return {"Classes/%s.h" % cls: header, "Classes/%s.m" % cls: source}


def _podspec_text(index):
    return (
        "Pod::Spec.new do |s|\n"
        "  s.name             = '%s'\n"
        "  s.version          = '0.0.1'\n"
        "  s.summary          = 'Scale bench source plugin.'\n"
        "  s.homepage         = 'https://example.com'\n"
        "  s.authors          = { 'Bench' => 'bench@example.com' }\n"
        "  s.source           = { :path => '.' }\n"
        "  s.source_files     = 'Classes/**/*'\n"
        "  s.dependency 'Flutter'\n"
        "  s.platform         = :ios, '12.0'\n"
        "end\n" % plugin_name(index))


def _source_plugin_files(index, variant):
    """iOS source plugin: Swift (variant 0) or Objective-C (variant 1)."""
    ios = {"%s.podspec" % plugin_name(index): _podspec_text(index)}
    if variant == 0:
        ios["Classes/%s.swift" % class_name(index)] = _swift_body(index, "")
    else:
        ios.update(_objc_files(index))
    files = {"ios/" + rel: text for rel, text in ios.items()}
    files["pubspec.yaml"] = _pubspec_text(
        index, "      ios:\n        pluginClass: %s\n" % class_name(index))
    return files


def _package_swift(index, identities):
    packages = "".join(
        "        .package(url: \"%s\", exact: \"%s\"),\n"
        % (SPM_PINS[i][0], SPM_PINS[i][2]) for i in identities)
    products = "".join(
        "                .product(name: \"%s\", package: \"%s\"),\n"
        % (_product(i), i) for i in identities)
    return (
        "// swift-tools-version: 5.9\n"
        "import PackageDescription\n"
        "\n"
        "let package = Package(\n"
        "    name: \"%s\",\n"
        "    platforms: [.iOS(\"12.0\")],\n"
        "    products: [.library(name: \"%s\", targets: [\"%s\"])],\n"
        "    dependencies: [\n%s    ],\n"
        "    targets: [\n"
        "        .target(\n"
        "            name: \"%s\",\n"
        "            dependencies: [\n%s            ]\n"
        "        )\n"
        "    ]\n"
        ")\n" % (plugin_name(index), plugin_name(index), plugin_name(index),
                 packages, plugin_name(index), products))


def _product(identity):
    return {"bigint": "BigInt", "swift-algorithms": "Algorithms",
            "swift-numerics": "RealModule"}[identity]


def _swiftpm_plugin_files(index, variant):
    """iOS SwiftPM plugin whose dependency pins are recorded and checked."""
    identities = SPM_VARIANTS[variant]
    imports = "".join("import %s\n" % _product(i) for i in identities)
    base = "ios/%s/" % plugin_name(index)
    return {
        base + "Package.swift": _package_swift(index, identities),
        base + "Sources/%s/%s.swift" % (plugin_name(index),
                                        class_name(index)):
            _swift_body(index, imports),
        "pubspec.yaml": _pubspec_text(
            index, "      ios:\n        pluginClass: %s\n" % class_name(index)),
    }


def _kotlin_plugin(index, package):
    return (
        "package %s\n"
        "\n"
        "import io.flutter.embedding.engine.plugins.FlutterPlugin\n"
        "import io.flutter.plugin.common.MethodCall\n"
        "import io.flutter.plugin.common.MethodChannel\n"
        "import io.flutter.plugin.common.MethodChannel.MethodCallHandler\n"
        "import io.flutter.plugin.common.MethodChannel.Result\n"
        "\n"
        "class %s : FlutterPlugin, MethodCallHandler {\n"
        "    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {\n"
        "        MethodChannel(binding.binaryMessenger, \"rules_flutter/%s\")\n"
        "            .setMethodCallHandler(this)\n"
        "    }\n"
        "\n"
        "    override fun onMethodCall(call: MethodCall, result: Result) {\n"
        "        if (call.method == \"value\") result.success(\"%s\") else result.notImplemented()\n"
        "    }\n"
        "\n"
        "    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}\n"
        "}\n" % (package, class_name(index), plugin_name(index),
                 class_name(index)))


def _java_plugin(index, package):
    return (
        "package %s;\n"
        "\n"
        "import androidx.annotation.NonNull;\n"
        "import io.flutter.embedding.engine.plugins.FlutterPlugin;\n"
        "import io.flutter.plugin.common.MethodCall;\n"
        "import io.flutter.plugin.common.MethodChannel;\n"
        "\n"
        "public class %s implements FlutterPlugin, MethodChannel.MethodCallHandler {\n"
        "    @Override\n"
        "    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {\n"
        "        new MethodChannel(binding.getBinaryMessenger(), \"rules_flutter/%s\")\n"
        "            .setMethodCallHandler(this);\n"
        "    }\n"
        "\n"
        "    @Override\n"
        "    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {\n"
        "        if (call.method.equals(\"value\")) result.success(\"%s\"); else result.notImplemented();\n"
        "    }\n"
        "\n"
        "    @Override\n"
        "    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {}\n"
        "}\n" % (package, class_name(index), plugin_name(index),
                 class_name(index)))


def _build_gradle(package, coords):
    deps = "".join("    implementation '%s'\n" % c for c in coords)
    return (
        "group = '%s'\n"
        "version = '1.0'\n"
        "\n"
        "android {\n"
        "    namespace = '%s'\n"
        "    compileSdk = 35\n"
        "}\n"
        "\n"
        "dependencies {\n%s}\n" % (package, package, deps))


def _maven_plugin_files(index, variant, entries):
    """Android plugin: Kotlin (variant 0) or Java (variant 1) + Maven deps."""
    package = "com.example.bench.%s" % plugin_name(index)
    path = "android/src/main/%s/%s/" % (
        "kotlin" if variant == 0 else "java", package.replace(".", "/"))
    ext = ".kt" if variant == 0 else ".java"
    text = (_kotlin_plugin if variant == 0 else _java_plugin)(index, package)
    coords = [maven_coordinate(k, v) for k, v, _ in entries]
    platform = ("      android:\n        package: %s\n        pluginClass: %s\n"
                % (package, class_name(index)))
    return {
        path + class_name(index) + ext: text,
        "android/build.gradle": _build_gradle(package, coords),
        "pubspec.yaml": _pubspec_text(index, platform),
    }


def _package_files(index, kind, rng):
    """(files, spm identities, maven entries) of one plugin package."""
    variant = rng.below(2)
    spm, picks = (), []
    if kind == "source":
        files = _source_plugin_files(index, variant)
    elif kind == "swiftpm":
        spm = SPM_VARIANTS[variant]
        files = _swiftpm_plugin_files(index, variant)
    else:
        pool = list(MAVEN_CATALOG)
        for _ in range(MAVEN_DEPS_PER_PLUGIN):
            picks.append(pool.pop(rng.below(len(pool))))
        files = _maven_plugin_files(index, variant, sorted(picks))
    files["lib/%s.dart" % plugin_name(index)] = _dart_text(index)
    return files, spm, picks


def package_resolved_text(identities):
    """Xcode `Package.resolved` recording the pins in `identities`."""
    pins = []
    for identity in sorted(identities):
        location, revision, version, _ = SPM_PINS[identity]
        pins.append(
            "    {\n"
            "      \"identity\" : \"%s\",\n"
            "      \"kind\" : \"remoteSourceControl\",\n"
            "      \"location\" : \"%s\",\n"
            "      \"state\" : {\n"
            "        \"revision\" : \"%s\",\n"
            "        \"version\" : \"%s\"\n"
            "      }\n"
            "    }" % (identity, location, revision, version))
    return "{\n  \"pins\" : [\n" + ",\n".join(pins) + "\n  ],\n" \
        "  \"version\" : 2\n}\n"


def hub_tag_text(spm_identities, maven_keys):
    """`flutter.pub(name = "deps")` with the plugin declarations."""
    text = "flutter.pub(\n    name = \"deps\",\n"
    if maven_keys:
        text += "    android_maven_deps = {\n" + "".join(
            "        \"%s\": \"%s\",\n" % (
                ":".join(k.split(":")[:2]), maven_label(k))
            for k in sorted(maven_keys)) + "    },\n"
    text += "    lock = \"//:pubspec.lock\",\n"
    if spm_identities:
        text += ("    swift_package_resolved = \"//%s:Package.resolved\",\n"
                 "    swift_package_sha256 = {\n" % SWIFTPM_DIR)
        text += "".join(
            "        \"%s\": \"%s\",\n" % (i, SPM_PINS[i][3])
            for i in sorted(spm_identities)) + "    },\n"
    return text + ")\n"


def edit_module(module_text, tag_text):
    """MODULE.bazel with the hub tag replaced (appended in a bare module)."""
    if _HUB_TAG in module_text:
        return module_text.replace(_HUB_TAG, tag_text, 1)
    if "flutter.pub(" in module_text:
        raise ValueError("MODULE.bazel hub tag has an unexpected shape")
    return (module_text + "\nflutter = use_extension("
            "\"@rules_flutter//flutter:extensions.bzl\", \"flutter\")\n"
            + tag_text)


def edit_pubspec_yaml(text, names):
    """pubspec.yaml with one `path:` dependency per plugin."""
    deps = "".join("  %s:\n    path: %s/%s\n" % (n, PLUGINS_DIR, n)
                   for n in names)
    if "dependencies:\n" in text:
        return text.replace("dependencies:\n", "dependencies:\n" + deps, 1)
    return text.rstrip("\n") + "\ndependencies:\n" + deps


def edit_pubspec_lock(text, names):
    """pubspec.lock with one `source: path` package per plugin."""
    entries = "".join(
        "  %s:\n    dependency: \"direct main\"\n    description:\n"
        "      path: %s/%s\n      relative: true\n    source: path\n"
        "    version: \"0.0.1\"\n" % (n, PLUGINS_DIR, n) for n in names)
    if "packages: {}\n" in text:
        return text.replace("packages: {}\n", "packages:\n" + entries, 1)
    return text.replace("\nsdks:\n", "\n" + entries + "sdks:\n", 1)


def edit_app_build(text, names):
    """app/BUILD.bazel with every plugin added to the app's dependencies."""
    flutter = "        \"@deps//:flutter\",\n"
    plugins = "".join("        \"@deps//:%s\",\n" % n for n in names)
    return text.replace(flutter, plugins + flutter)


def verify_maven_pins(install_json_text, pins):
    """Raises unless every pin's sha256 equals the install file's.

    `install_json_text` is the workspace's rules_android_maven lock file;
    a coordinate missing from it, or recorded with another digest, fails.
    """
    artifacts = json.loads(install_json_text).get("artifacts", {})
    for key, pin in pins.items():
        shasums = (artifacts.get(key) or {}).get("shasums") or {}
        if pin["sha256"] not in shasums.values():
            raise ValueError(
                "maven pin %s sha256 %s is not in %s"
                % (key, pin["sha256"], INSTALL_JSON_REL))


def _read(out_dir, rel):
    with open(os.path.join(out_dir, rel), encoding="utf-8") as fh:
        return fh.read()


def _write_all_plugins(out_dir, kinds, rng):
    """Writes every package; returns (spm identities, maven pin map)."""
    spm, pins = set(), {}
    for index, kind in enumerate(kinds):
        files, identities, picks = _package_files(index, kind, rng)
        for rel, text in files.items():
            write_plain(out_dir, "%s/%s/%s" % (
                PLUGINS_DIR, plugin_name(index), rel), text)
        spm.update(identities)
        for key, version, sha in picks:
            pins[key] = {"coordinate": maven_coordinate(key, version),
                         "sha256": sha}
    return spm, pins


def add_plugins(out_dir, count, rng):
    """Adds `count` seeded native plugins to a generated workspace.

    Returns {"plugins": count, "kinds": {kind: n}} for the stats file.
    """
    kinds = plugin_kinds(count, rng)
    names = [plugin_name(i) for i in range(count)]
    spm, pins = _write_all_plugins(out_dir, kinds, rng)
    if spm:
        write_plain(out_dir, SWIFTPM_DIR + "/Package.resolved",
                    package_resolved_text(spm))
        write_plain(out_dir, SWIFTPM_DIR + "/BUILD.bazel",
                    "exports_files([\"Package.resolved\"])\n")
    if pins:
        write_plain(out_dir, MAVEN_PINS_REL,
                    json.dumps(pins, indent=2, sort_keys=True) + "\n")
        if os.path.isfile(os.path.join(out_dir, INSTALL_JSON_REL)):
            verify_maven_pins(_read(out_dir, INSTALL_JSON_REL), pins)
    write_plain(out_dir, "MODULE.bazel", edit_module(
        _read(out_dir, "MODULE.bazel"), hub_tag_text(spm, pins)))
    write_plain(out_dir, "pubspec.yaml",
                edit_pubspec_yaml(_read(out_dir, "pubspec.yaml"), names))
    write_plain(out_dir, "pubspec.lock",
                edit_pubspec_lock(_read(out_dir, "pubspec.lock"), names))
    write_plain(out_dir, "app/BUILD.bazel",
                edit_app_build(_read(out_dir, "app/BUILD.bazel"), names))
    return {"plugins": count,
            "kinds": {k: kinds.count(k) for k in KINDS}}
