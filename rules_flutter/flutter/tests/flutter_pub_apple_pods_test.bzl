"""Unit tests for CocoaPods resolution order, hub precomputation, and spoke resolution."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_apple.bzl", "detect_apple_swiftpm_deps", "with_apple_swiftpm_deps")
load("//flutter/private:flutter_pub_apple_local.bzl", "apply_apple_native_deps")
load(
    "//flutter/private:flutter_pub_apple_pods.bzl",
    "detect_apple_cocoapods_deps",
    "format_message_11",
    "format_message_9",
    "hub_cocoapods_attrs",
    "precompute_hub_apple_pods",
    "resolve_binary_pod_stub",
    "resolve_pod",
    "resolve_swiftpm_pod_stub",
)
load("//flutter/private:flutter_pub_apple_pods_hub.bzl", "read_ios_pod_native_deps")
load("//flutter/private:podfile_lock.bzl", "read_podfile_lock")
load("//flutter/private:swiftpm_resolved.bzl", "read_ios_native_deps")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_FIXTURE_LOCK = """PODS:
  - Flutter (1.0.0)
  - FlutterMacOS (1.0.0)
  - Firebase/Auth (10.0.0):
    - Firebase/Core (= 10.0.0)
    - FirebaseAuthPlatform (= 1.0.0)
  - Firebase/Core (10.0.0)
  - FirebaseAuthPlatform (1.0.0)
  - path_provider_foundation (0.0.1):
    - Flutter
    - FlutterMacOS
    - path_provider_foundation/Core (= 0.0.1)
  - path_provider_foundation/Core (0.0.1)
  - url_launcher_ios (0.0.1):
    - Flutter
    - url_launcher_platform_interface (= 1.0.0)
  - url_launcher_platform_interface (1.0.0)
  - custom_checkout_pod (1.2.0)
  - unmapped_pod (2.0.0)
DEPENDENCIES:
  - Firebase/Auth (from `~> 10.0.0`)
  - path_provider_foundation (from `.symlinks/plugins/path_provider_foundation/darwin`)
  - url_launcher_ios (from `.symlinks/plugins/url_launcher_ios/ios`)
EXTERNAL SOURCES:
  custom_checkout_pod:
    :git: https://github.com/example/custom.git
  path_provider_foundation:
    :path: .symlinks/plugins/path_provider_foundation/darwin
  url_launcher_ios:
    :path: .symlinks/plugins/url_launcher_ios/ios
COCOAPODS: 1.14.3
"""

_FLUTTERFIRE_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "firebase_auth", platforms: [.iOS("15.0")],
  products: [.library(name: "firebase-auth", targets: ["firebase_auth"])],
  dependencies: [
    .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "11.0.0"),
    .package(name: "firebase_core", path: "../firebase_core"),
  ],
  targets: [
    .target(name: "firebase_auth", dependencies: [
      .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
      .product(name: "firebase-core", package: "firebase_core"),
      "firebase_auth_local",
    ], path: "Sources/firebase_auth"),
    .target(name: "firebase_auth_local", path: "Sources/firebase_auth_local"),
  ]
)
"""

_MIXED_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "spm_plugin",
  products: [.library(name: "spm-plugin", targets: ["spm_plugin"])],
  dependencies: [.package(url: "https://github.com/example/sample-sdk", exact: "1.0.0")],
  targets: [.target(
    name: "spm_plugin",
    dependencies: [.product(name: "SampleKit", package: "sample-sdk")],
    path: "Sources/spm_plugin"
  )]
)
"""

_IOS_ONLY_SRCS = struct(macos_srcs = [], ios_srcs = ["ios/Classes"])

def _make_plugin_build(pkg, src):
    """Render minimal device and xtool `flutter_apple_plugin_library` blocks."""
    tpl = (
        "\nflutter_apple_plugin_library(\n" +
        '    name = "{pkg}_apple_ios{sfx}",\n' +
        '    srcs = ["{src}"],\n' +
        '    visibility = ["//visibility:public"],\n' +
        ")\n"
    )
    return tpl.format(pkg = pkg, sfx = "", src = src) + tpl.format(pkg = pkg, sfx = "_xtool", src = src)

def _make_hub_json(lock_text, lock_label, packages, pod_deps = None, pod_ignore = None, product_deps = None):
    """Build deterministic `ios_native_deps.json` text from a lock fixture."""
    deps_map = pod_deps if pod_deps != None else {}
    ignore_list = pod_ignore if pod_ignore != None else []
    products_map = product_deps if product_deps != None else {}
    parsed = read_podfile_lock(lock_text, lock_label)
    precomputed = precompute_hub_apple_pods("deps", packages, parsed, lock_label, deps_map, ignore_list)
    return json.encode({
        "ios_pod_deps": deps_map,
        "ios_pod_ignore": ignore_list,
        "ios_pods": precomputed,
        "swift_package_product_deps": products_map,
        "version": 1,
    })

def _mock_dir_entries(dirs_dict, dir_path):
    """Build mock `readdir()` entries for `dir_path`."""
    entries = []
    for child in dirs_dict.get(dir_path, []):
        c_str = str(child)
        c_base = c_str.rpartition("/")[2] if "/" in c_str else c_str
        entries.append(struct(basename = c_base, is_dir = c_str in dirs_dict))
    return entries

def _make_mock_path_fn(files, dirs_dict):
    """Build a mock `ctx.path` function backed by `files` and `dirs_dict`."""

    def _path(path_str):
        """Return a mock path struct for `path_str`."""
        p = str(path_str)
        is_dir = p in dirs_dict
        base = p.rpartition("/")[2] if "/" in p else p
        return struct(
            exists = (p in files) or is_dir,
            is_dir = is_dir,
            basename = base,
            readdir = lambda: _mock_dir_entries(dirs_dict, p),
        )

    return _path

def _make_mock_read_fn(files):
    """Build a mock `ctx.read` function that fails on undeclared reads."""

    def _read(path_str):
        """Read `path_str` from `files`, failing if unread laziness is violated."""
        p = str(path_str)
        if p not in files:
            fail("mock ctx.read on missing file: " + p)
        return files[p]

    return _read

def _make_mock_spoke_ctx(
        files,
        podfile_lock = "//:Podfile.lock",
        ios_native_deps = "//:ios_native_deps.json",
        hub_name = "deps",
        plugin_native_deps = None,
        dirs = None):
    """Create a mock repository context for Apple plugin spoke unit tests."""
    dirs_dict = dirs if dirs != None else {}
    return struct(
        attr = struct(
            hub_name = hub_name,
            ios_native_deps = ios_native_deps,
            lock_packages = [],
            package_resolved = None,
            package_sha256 = None,
            plugin_native_deps = plugin_native_deps,
            podfile_lock = podfile_lock,
            pubspec_lock = None,
        ),
        path = _make_mock_path_fn(files, dirs_dict),
        read = _make_mock_read_fn(files),
    )

def _step1_engine_pods_test_impl(ctx):
    """Step 1 skips `Flutter` and `FlutterMacOS` (and subspecs) unconditionally."""
    env = unittest.begin(ctx)
    for pod in ["Flutter", "FlutterMacOS", "Flutter/Engine", "FlutterMacOS/Engine"]:
        res = resolve_pod(pod, "deps", [], None, "//ios:Podfile.lock", {}, [])
        asserts.equals(env, "skip", res.kind)
        asserts.equals(env, "", res.label)
    return unittest.end(env)

_step1_engine_pods_test = unittest.make(_step1_engine_pods_test_impl)

def _step2_ios_pod_deps_test_impl(ctx):
    """Step 2 resolves subspec over root and wins over steps 3 and 4."""
    env = unittest.begin(ctx)
    pod_deps = {"Firebase/Auth": "@app//:auth", "Firebase": "@app//:umbrella"}
    res_auth = resolve_pod("Firebase/Auth", "deps", [], None, "//:lock", pod_deps, [])
    asserts.equals(env, "label", res_auth.kind)
    asserts.equals(env, "@app//:auth", res_auth.label)

    res_core_only = resolve_pod("Firebase/CoreOnly", "deps", [], None, "//:lock", pod_deps, [])
    asserts.equals(env, "@app//:umbrella", res_core_only.label)
    asserts.equals(env, "@app//:umbrella", resolve_pod("Firebase", "deps", [], None, "//:lock", pod_deps, []).label)

    ppf = "path_provider_foundation"
    podfile = struct(plugin_pods = {ppf: ppf}, pods = {})
    res_step3 = resolve_pod(ppf, "deps", [ppf], podfile, "//:lock", {ppf: "//custom:ppf"}, [])
    asserts.equals(env, "//custom:ppf", res_step3.label)

    res_step4 = resolve_pod("GoogleMaps", "deps", [], None, "//:lock", {"GoogleMaps": "//maps:gm"}, ["GoogleMaps"])
    asserts.equals(env, "//maps:gm", res_step4.label)
    return unittest.end(env)

_step2_ios_pod_deps_test = unittest.make(_step2_ios_pod_deps_test_impl)

def _step3_sibling_plugin_pod_test_impl(ctx):
    """Step 3 resolves locked sibling Flutter plugins by EXTERNAL SOURCES path."""
    env = unittest.begin(ctx)
    ppf = "path_provider_foundation"
    podfile = struct(plugin_pods = {ppf: ppf}, pods = {})
    res_ios = resolve_pod(ppf, "deps", [ppf], podfile, "//:lock", {}, [], "ios")
    asserts.equals(env, "plugin", res_ios.kind)
    asserts.equals(env, "@deps__path_provider_foundation//:path_provider_foundation_apple_ios", res_ios.label)

    res_macos = resolve_pod(ppf, "deps", [ppf], podfile, "//:lock", {}, [], "macos")
    asserts.equals(env, "@deps__path_provider_foundation//:path_provider_foundation_apple_macos", res_macos.label)

    podfile_div = struct(plugin_pods = {"Pigeon": "pigeon"}, pods = {})
    res_div = resolve_pod("Pigeon", "deps", ["pigeon"], podfile_div, "//:lock", {}, [], "ios")
    asserts.equals(env, "@deps__pigeon//:pigeon_apple_ios", res_div.label)

    res_absent = resolve_pod(ppf, "deps", ["other_pkg"], podfile, "//:lock", {}, [])
    asserts.equals(env, "unresolved", res_absent.kind)
    return unittest.end(env)

_step3_sibling_plugin_pod_test = unittest.make(_step3_sibling_plugin_pod_test_impl)

def _step3_subspec_self_edges_test_impl(ctx):
    """Plugin subspec self-edges skip self-linking while keeping subspec external deps."""
    env = unittest.begin(ctx)
    lock_self = (
        "PODS:\n  - my_plugin (1.0.0):\n    - my_plugin/Core\n" +
        "  - my_plugin/Core (1.0.0):\n    - ExternalPod (= 1.0.0)\n    - Flutter\n" +
        "  - ExternalPod (1.0.0)\nEXTERNAL SOURCES:\n  my_plugin:\n" +
        "    :path: .symlinks/plugins/my_plugin/ios\n"
    )
    hub_json = _make_hub_json(lock_self, "//:self.lock", ["my_plugin"], {"ExternalPod": "//ext:target"})
    mock_ctx = _make_mock_spoke_ctx(
        {"//:self.lock": lock_self, "//:ios_native_deps.json": hub_json},
        podfile_lock = "//:self.lock",
    )
    res = detect_apple_cocoapods_deps(mock_ctx, "my_plugin", struct(macos_srcs = [], ios_srcs = ["ios/Classes"]), None)
    asserts.equals(env, ["//ext:target"], res.ios)
    return unittest.end(env)

_step3_subspec_self_edges_test = unittest.make(_step3_subspec_self_edges_test_impl)

def _step4_ios_pod_ignore_test_impl(ctx):
    """Step 4 drops ignored root and subspec pods, while step 3 wins over step 4."""
    env = unittest.begin(ctx)
    ignore = ["GoogleMaps", "Firebase/Analytics"]
    asserts.equals(env, "drop", resolve_pod("GoogleMaps", "deps", [], None, "//:lock", {}, ignore).kind)
    asserts.equals(env, "drop", resolve_pod("GoogleMaps/Utils", "deps", [], None, "//:lock", {}, ignore).kind)
    asserts.equals(env, "drop", resolve_pod("Firebase/Analytics", "deps", [], None, "//:lock", {}, ignore).kind)

    podfile = struct(plugin_pods = {"url_launcher_ios": "url_launcher_ios"}, pods = {})
    res_win = resolve_pod(
        "url_launcher_ios",
        "deps",
        ["url_launcher_ios"],
        podfile,
        "//:lock",
        {},
        ["url_launcher_ios"],
        "ios",
    )
    asserts.equals(env, "plugin", res_win.kind)
    asserts.equals(env, "@deps__url_launcher_ios//:url_launcher_ios_apple_ios", res_win.label)
    return unittest.end(env)

_step4_ios_pod_ignore_test = unittest.make(_step4_ios_pod_ignore_test_impl)

def _step5_6_stubs_and_checkout_test_impl(ctx):
    """Steps 5 and 6 stubs return None; checkout pods follow steps 2, 4, and 7."""
    env = unittest.begin(ctx)
    asserts.equals(env, None, resolve_binary_pod_stub())
    asserts.equals(env, None, resolve_swiftpm_pod_stub())

    parsed = read_podfile_lock(_FIXTURE_LOCK, "//:lock")
    asserts.true(env, "custom_checkout_pod" in parsed.checkout)
    res_map = resolve_pod("custom_checkout_pod", "deps", [], parsed, "//:lock", {"custom_checkout_pod": "//:cust"}, [])
    asserts.equals(env, "//:cust", res_map.label)
    res_ign = resolve_pod("custom_checkout_pod", "deps", [], parsed, "//:lock", {}, ["custom_checkout_pod"])
    asserts.equals(env, "drop", res_ign.kind)
    res_unres = resolve_pod("custom_checkout_pod", "deps", [], parsed, "//:lock", {}, [])
    asserts.equals(env, "unresolved", res_unres.kind)
    asserts.equals(env, "1.2.0", res_unres.version)
    return unittest.end(env)

_step5_6_stubs_and_checkout_test = unittest.make(_step5_6_stubs_and_checkout_test_impl)

def _deduplication_and_rendering_test_impl(ctx):
    """Duplicate labels deduplicate in lock order and splice into both Apple targets."""
    env = unittest.begin(ctx)
    lock_dedup = (
        "PODS:\n  - sample_plugin (1.0.0):\n    - DepFirst (= 1.0.0)\n" +
        "    - DepA (= 1.0.0)\n    - DepB (= 1.0.0)\n" +
        "  - DepFirst (1.0.0)\n  - DepA (1.0.0)\n  - DepB (1.0.0)\n" +
        "EXTERNAL SOURCES:\n  sample_plugin:\n    :path: .symlinks/plugins/sample_plugin/ios\n"
    )
    pod_deps = {"DepFirst": "//z_first:lib", "DepA": "//shared:umbrella", "DepB": "//shared:umbrella"}
    hub_json = _make_hub_json(lock_dedup, "//:dedup.lock", ["sample_plugin"], pod_deps)
    mock_ctx = _make_mock_spoke_ctx(
        {"//:dedup.lock": lock_dedup, "//:ios_native_deps.json": hub_json},
        podfile_lock = "//:dedup.lock",
    )
    res = detect_apple_cocoapods_deps(mock_ctx, "sample_plugin", _IOS_ONLY_SRCS, None)
    asserts.equals(env, ["//z_first:lib", "//shared:umbrella"], res.ios)

    initial_build = _make_plugin_build("sample_plugin", "ios/Classes/Plugin.m")
    rendered = with_apple_swiftpm_deps(initial_build, "sample_plugin", [], res.ios)
    part_ios = rendered.partition('name = "sample_plugin_apple_ios",')[2].partition("visibility = ")[0]
    part_xtool = rendered.partition('name = "sample_plugin_apple_ios_xtool",')[2].partition("visibility = ")[0]
    asserts.true(env, "//shared:umbrella" in part_ios and "//z_first:lib" in part_ios)
    asserts.true(env, "//shared:umbrella" in part_xtool and "//z_first:lib" in part_xtool)
    return unittest.end(env)

_deduplication_and_rendering_test = unittest.make(_deduplication_and_rendering_test_impl)

def _exact_error_messages_wording_test_impl(ctx):
    """Messages 9 and 11 match the design's exact refusal text."""
    env = unittest.begin(ctx)
    expected_m9 = (
        'Flutter plugin "firebase_auth" has iOS sources but //app/ios:Podfile.lock lists no pod for it ' +
        '(expected an EXTERNAL SOURCES entry ".symlinks/plugins/firebase_auth/ios"), and the ' +
        "plugin ships no Package.swift to fall back to. Run pod install for the app so the " +
        "lock lists every plugin, or list the plugin's dependencies with " +
        'flutter.pub(ios_plugin_deps = {"firebase_auth": "<label>"}).'
    )
    asserts.equals(env, expected_m9, format_message_9("firebase_auth", "//app/ios:Podfile.lock"))

    mock_m9 = _make_mock_spoke_ctx({"//app/ios:Podfile.lock": _FIXTURE_LOCK}, podfile_lock = "//app/ios:Podfile.lock")
    errs_m9 = []
    detect_apple_cocoapods_deps(mock_m9, "firebase_auth", _IOS_ONLY_SRCS, None, fail_fn = errs_m9.append)
    asserts.equals(env, [expected_m9], errs_m9)

    expected_m11_empty = (
        'Flutter plugin "flutter_sound" depends on pod "flutter_sound_core" (9.30.0 in //app/ios:Podfile.lock), ' +
        "which no Bazel target provides. Map it with " +
        'flutter.pub(ios_pod_deps = {"flutter_sound_core": "<label>"}) or ' +
        'declare it unneeded with flutter.pub(ios_pod_ignore = ["flutter_sound_core"]).'
    )
    msg11_empty = format_message_11("flutter_sound", "flutter_sound_core", "9.30.0", "//app/ios:Podfile.lock", "")
    asserts.equals(env, expected_m11_empty, msg11_empty)

    reason = "a source pod with no SwiftPM package in the built-in table"
    expected_m11_reason = (
        'Flutter plugin "flutter_sound" depends on pod "flutter_sound_core" (9.30.0 in //app/ios:Podfile.lock), ' +
        "which no Bazel target provides: " + reason + ". Map it with " +
        'flutter.pub(ios_pod_deps = {"flutter_sound_core": "<label>"}) or ' +
        'declare it unneeded with flutter.pub(ios_pod_ignore = ["flutter_sound_core"]).'
    )
    msg11_reason = format_message_11("flutter_sound", "flutter_sound_core", "9.30.0", "//app/ios:Podfile.lock", reason)
    asserts.equals(env, expected_m11_reason, msg11_reason)
    return unittest.end(env)

_exact_error_messages_wording_test = unittest.make(_exact_error_messages_wording_test_impl)

def _spoke_message_11_refusal_test_impl(ctx):
    """A spoke reaching an unresolved pod fails with verbatim Message 11."""
    env = unittest.begin(ctx)
    lock_bad = (
        "PODS:\n  - flutter_sound (9.30.0):\n    - flutter_sound_core (= 9.30.0)\n" +
        "  - flutter_sound_core (9.30.0)\nEXTERNAL SOURCES:\n  flutter_sound:\n" +
        "    :path: .symlinks/plugins/flutter_sound/ios\n"
    )
    hub_json = _make_hub_json(lock_bad, "//app/ios:Podfile.lock", ["flutter_sound"])
    mock_bad = _make_mock_spoke_ctx(
        {"//app/ios:Podfile.lock": lock_bad, "//:ios_native_deps.json": hub_json},
        podfile_lock = "//app/ios:Podfile.lock",
    )
    errors = []
    detect_apple_cocoapods_deps(mock_bad, "flutter_sound", _IOS_ONLY_SRCS, None, fail_fn = errors.append)
    expected = format_message_11("flutter_sound", "flutter_sound_core", "9.30.0", "//app/ios:Podfile.lock", "")
    asserts.equals(env, [expected], errors)
    return unittest.end(env)

_spoke_message_11_refusal_test = unittest.make(_spoke_message_11_refusal_test_impl)

def _flutterfire_manifest_cocoapods_mode_test_impl(ctx):
    """FlutterFire spoke in CocoaPods mode links mapped pod + POD-1 local target without SwiftPM pins."""
    env = unittest.begin(ctx)
    lock_fb = (
        "PODS:\n  - firebase_auth (10.0.0):\n    - Firebase/Auth (= 10.0.0)\n" +
        "  - Firebase/Auth (10.0.0)\nEXTERNAL SOURCES:\n  firebase_auth:\n" +
        "    :path: .symlinks/plugins/firebase_auth/ios\n"
    )
    pod_deps = {"Firebase/Auth": "//third_party:firebase_auth_umbrella"}
    hub_json = _make_hub_json(lock_fb, "//app/ios:Podfile.lock", ["firebase_auth"], pod_deps)
    local_src = "ios/firebase_auth/Sources/firebase_auth_local/local.m"
    files_fb = {
        "//app/ios:Podfile.lock": lock_fb,
        "//:ios_native_deps.json": hub_json,
        "ios/firebase_auth/Package.swift": _FLUTTERFIRE_MANIFEST,
        local_src: "// objc\n",
    }
    mock_fb = _make_mock_spoke_ctx(
        files_fb,
        podfile_lock = "//app/ios:Podfile.lock",
        dirs = {"ios/firebase_auth/Sources/firebase_auth_local": [local_src]},
    )
    apple = struct(macos_srcs = [], ios_srcs = ["ios/firebase_auth/Sources/firebase_auth"])
    initial_build = _make_plugin_build("firebase_auth", "Sources/firebase_auth/dummy.m")
    rendered = apply_apple_native_deps(mock_fb, "firebase_auth", apple, initial_build)
    asserts.true(env, "//third_party:firebase_auth_umbrella" in rendered)
    asserts.false(env, "FirebaseAuth" in rendered)
    asserts.false(env, "firebase_core" in rendered)
    asserts.true(env, ":firebase_auth_apple_ios__firebase_auth_local" in rendered)
    asserts.true(env, 'name = "firebase_auth_apple_ios__firebase_auth_local"' in rendered)
    return unittest.end(env)

_flutterfire_manifest_cocoapods_mode_test = unittest.make(_flutterfire_manifest_cocoapods_mode_test_impl)

def _mixed_mode_fallback_test_impl(ctx):
    """Unlocked plugin shipping `ios/<pkg>/Package.swift` or `darwin/<pkg>/Package.swift` uses SwiftPM."""
    env = unittest.begin(ctx)
    hub_json = _make_hub_json(
        _FIXTURE_LOCK,
        "//:Podfile.lock",
        ["spm_plugin"],
        product_deps = {"sample-sdk:SampleKit": "//third_party:sample_kit"},
    )
    mock_ios = _make_mock_spoke_ctx({
        "//:Podfile.lock": _FIXTURE_LOCK,
        "//:ios_native_deps.json": hub_json,
        "ios/spm_plugin/Package.swift": _MIXED_MANIFEST,
    })
    res_ios = detect_apple_swiftpm_deps(
        mock_ios,
        "spm_plugin",
        struct(macos_srcs = [], ios_srcs = ["ios/spm_plugin/Sources/spm_plugin"]),
    )
    asserts.equals(env, ["//third_party:sample_kit"], res_ios.ios)

    mock_darwin = _make_mock_spoke_ctx({
        "//:Podfile.lock": _FIXTURE_LOCK,
        "//:ios_native_deps.json": hub_json,
        "darwin/spm_plugin/Package.swift": _MIXED_MANIFEST,
    })
    src_dir = ["darwin/spm_plugin/Sources/spm_plugin"]
    res_darwin = detect_apple_swiftpm_deps(mock_darwin, "spm_plugin", struct(macos_srcs = src_dir, ios_srcs = src_dir))
    asserts.equals(env, ["//third_party:sample_kit"], res_darwin.ios)
    asserts.equals(env, ["//third_party:sample_kit"], res_darwin.macos)
    return unittest.end(env)

_mixed_mode_fallback_test = unittest.make(_mixed_mode_fallback_test_impl)

def _pod7_precedence_and_laziness_test_impl(ctx):
    """POD-7 wins without reading files; pure-Dart and engine-only spokes stay lazy."""
    env = unittest.begin(ctx)
    mock_pod7 = _make_mock_spoke_ctx({}, plugin_native_deps = "@custom_mapped//:all")
    res_pod7 = detect_apple_swiftpm_deps(mock_pod7, "any_plugin", _IOS_ONLY_SRCS)
    asserts.equals(env, ["@custom_mapped//:all"], res_pod7.ios)

    no_srcs = struct(macos_srcs = [], ios_srcs = [])
    res_dart = detect_apple_swiftpm_deps(_make_mock_spoke_ctx({}), "pure_dart_pkg", no_srcs)
    asserts.equals(env, [], res_dart.macos)
    asserts.equals(env, [], res_dart.ios)

    mock_engine_only = _make_mock_spoke_ctx({"//:Podfile.lock": _FIXTURE_LOCK})
    res_engine = detect_apple_swiftpm_deps(
        mock_engine_only,
        "path_provider_foundation",
        struct(macos_srcs = ["darwin/Classes"], ios_srcs = ["darwin/Classes"]),
    )
    asserts.equals(env, [], res_engine.macos)
    asserts.equals(env, [], res_engine.ios)

    res_macos_only = detect_apple_swiftpm_deps(
        mock_engine_only,
        "macos_only_plugin",
        struct(macos_srcs = ["macos/Classes"], ios_srcs = []),
    )
    asserts.equals(env, [], res_macos_only.macos)
    asserts.equals(env, [], res_macos_only.ios)
    return unittest.end(env)

_pod7_precedence_and_laziness_test = unittest.make(_pod7_precedence_and_laziness_test_impl)

def _unreferenced_unresolved_pod_laziness_test_impl(ctx):
    """An unreferenced unresolved pod in `ios_native_deps.json` does not fail other spokes."""
    env = unittest.begin(ctx)
    hub_json = _make_hub_json(
        _FIXTURE_LOCK,
        "//:Podfile.lock",
        ["path_provider_foundation", "url_launcher_ios"],
        pod_deps = {"url_launcher_platform_interface": "//third_party:url_interface"},
    )
    cocoa_read = read_ios_pod_native_deps(hub_json, "//:ios_native_deps.json", "deps")
    asserts.equals(env, "unresolved", cocoa_read.ios_pods["unmapped_pod"].kind)

    mock_url = _make_mock_spoke_ctx({"//:Podfile.lock": _FIXTURE_LOCK, "//:ios_native_deps.json": hub_json})
    res_url = detect_apple_swiftpm_deps(mock_url, "url_launcher_ios", _IOS_ONLY_SRCS)
    asserts.equals(env, ["//third_party:url_interface"], res_url.ios)
    return unittest.end(env)

_unreferenced_unresolved_pod_laziness_test = unittest.make(_unreferenced_unresolved_pod_laziness_test_impl)

def _hub_precomputation_and_reader_test_impl(ctx):
    """Hub attrs work with or without a lock, and the hub JSON reader fails closed."""
    env = unittest.begin(ctx)
    no_lock_tag = struct(ios_pod_deps = {"PodB": "//b:t", "PodA": "//a:t"}, ios_pod_ignore = ["IgnB", "IgnA"])
    no_lock_attrs = hub_cocoapods_attrs("deps", ["pkg"], None, "", no_lock_tag)
    asserts.equals(env, {"PodA": "//a:t", "PodB": "//b:t"}, no_lock_attrs.ios_pod_deps)
    asserts.equals(env, ["IgnA", "IgnB"], no_lock_attrs.ios_pod_ignore)
    asserts.equals(env, "{}", no_lock_attrs.ios_pods_json)

    hub_json = _make_hub_json(
        _FIXTURE_LOCK,
        "//ios:Podfile.lock",
        ["path_provider_foundation", "url_launcher_ios"],
        pod_deps = {"Firebase/Auth": "//third_party:auth"},
        pod_ignore = ["custom_checkout_pod"],
        product_deps = {"ident:prod": "//:prod_label"},
    )
    swiftpm_read = read_ios_native_deps(hub_json, "//:ios_native_deps.json", "deps")
    asserts.equals(env, "//:prod_label", swiftpm_read.product_deps["ident:prod"])

    cocoa_read = read_ios_pod_native_deps(hub_json, "//:ios_native_deps.json", "deps")
    asserts.equals(env, "skip", cocoa_read.ios_pods["Flutter"].kind)
    asserts.equals(env, "//third_party:auth", cocoa_read.ios_pods["Firebase/Auth"].label)
    asserts.equals(env, "drop", cocoa_read.ios_pods["custom_checkout_pod"].kind)

    base = {"version": 1, "ios_pod_deps": {}, "ios_pod_ignore": []}
    bad_cases = [
        ({"version": 2}, "unsupported version"),
        ({"version": 1, "ios_pod_deps": 123}, "has no `ios_pod_deps` object"),
        ({"version": 1, "ios_pod_deps": {}, "ios_pod_ignore": "str"}, "has no `ios_pod_ignore` list"),
        (base | {"ios_pods": [1]}, "has no `ios_pods` object"),
        (base | {"ios_pods": {"P": {"kind": "bad"}}}, "invalid entry"),
    ]
    for payload, snippet in bad_cases:
        bad = read_ios_pod_native_deps(json.encode(payload), "//:file", "deps")
        asserts.false(env, bad.ok)
        asserts.true(env, 'flutter.pub hub "deps"' in bad.error and "//:file" in bad.error)
        asserts.true(env, snippet in bad.error)
    return unittest.end(env)

_hub_precomputation_and_reader_test = unittest.make(_hub_precomputation_and_reader_test_impl)

def _golden_resolution_test_impl(ctx):
    """Precomputation over the full synthetic lock classifies every pod deterministically."""
    env = unittest.begin(ctx)
    parsed = read_podfile_lock(_FIXTURE_LOCK, "//fixture:Podfile.lock")
    precomputed = precompute_hub_apple_pods(
        hub_name = "hub",
        all_package_names = ["path_provider_foundation", "url_launcher_ios"],
        podfile = parsed,
        lock_label = "//fixture:Podfile.lock",
        ios_pod_deps = {"Firebase/Auth": "//vendor:firebase_auth", "custom_checkout_pod": "//vendor:custom_checkout"},
        ios_pod_ignore = ["FirebaseAuthPlatform"],
    )
    expected_kinds = {
        "Firebase/Auth": "label",
        "Firebase/Core": "unresolved",
        "FirebaseAuthPlatform": "drop",
        "Flutter": "skip",
        "FlutterMacOS": "skip",
        "custom_checkout_pod": "label",
        "path_provider_foundation": "plugin",
        "path_provider_foundation/Core": "plugin",
        "unmapped_pod": "unresolved",
        "url_launcher_ios": "plugin",
        "url_launcher_platform_interface": "unresolved",
    }
    for pod_name, expected_kind in expected_kinds.items():
        asserts.equals(env, expected_kind, precomputed[pod_name]["kind"])
    asserts.equals(env, "//vendor:firebase_auth", precomputed["Firebase/Auth"]["label"])
    asserts.equals(env, "path_provider_foundation", precomputed["path_provider_foundation"]["package"])
    asserts.equals(env, "2.0.0", precomputed["unmapped_pod"]["version"])
    return unittest.end(env)

_golden_resolution_test = unittest.make(_golden_resolution_test_impl)

def flutter_pub_apple_pods_test_suite(name):
    """Test suite for CocoaPods dependency resolution in rules_flutter."""
    small_unittest_suite(
        name + "_unit",
        _step1_engine_pods_test,
        _step2_ios_pod_deps_test,
        _step3_sibling_plugin_pod_test,
        _step3_subspec_self_edges_test,
        _step4_ios_pod_ignore_test,
        _step5_6_stubs_and_checkout_test,
        _deduplication_and_rendering_test,
        _exact_error_messages_wording_test,
        _spoke_message_11_refusal_test,
        _flutterfire_manifest_cocoapods_mode_test,
        _mixed_mode_fallback_test,
        _pod7_precedence_and_laziness_test,
        _unreferenced_unresolved_pod_laziness_test,
        _hub_precomputation_and_reader_test,
        _golden_resolution_test,
    )
    native.test_suite(name = name, tests = [":" + name + "_unit"])
