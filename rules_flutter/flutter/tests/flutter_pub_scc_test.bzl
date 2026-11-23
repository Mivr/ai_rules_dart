"""Unit tests for flutter_pub SCC spoke and lock hub generation.

Covers:
1. Hub root BUILD.bazel and android/BUILD.bazel rendering with empty and populated scc_targets.
2. Cross-spoke spoke_dep_labels, SwiftPM sibling plugin, and CocoaPods sibling plugin routing to
   scc_targets vs singletons.
3. cycle_breaks applied before SCC computation: broken 2-cycle, unbroken 2-cycle/3-cycle,
   3-cycle with one edge broken, and sub-cycle retention.
4. Merged spoke root BUILD.bazel and member <m>/BUILD.bazel + <m>/android/BUILD.bazel generation
   for 2-cycle and 3-cycle SCCs carrying assets, fonts, shaders, hooks, overlays, and plugins
   under the lazy Android repository model.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "apple_swiftpm_pins",
    "select_apple_swiftpm_deps",
)
load(
    "//flutter/private:flutter_pub_apple_pods.bzl",
    "detect_apple_cocoapods_deps",
    "precompute_hub_apple_pods",
)
load(
    "//flutter/private:flutter_pub_cycle_breaks.bzl",
    "spoke_dep_labels",
)
load(
    "//flutter/private:flutter_pub_lock_hub.bzl",
    "make_flutter_pub_hub_android_build_content",
    "make_flutter_pub_hub_build_content",
)
load(
    "//flutter/private:flutter_pub_path.bzl",
    "workspace_relative_lock_path",
)
load(
    "//flutter/private:flutter_pub_scc.bzl",
    "collect_path_deps",
    "hosted_fact_key",
    "lookup_fact_deps",
    "normalize_realpath",
    "parser_texts_digest",
    "plan_flutter_pub_sccs",
    "resolve_path_pubspec",
    "scc_member_deps_error",
    "scc_members_connectivity_error",
    "scc_planned_deps_error",
    "spoke_planned_deps_error",
)
load(
    "//flutter/private:flutter_pub_scc_build.bzl",
    "adapt_scc_member_android_overlay_content",
    "adapt_scc_member_overlay_content",
    "make_scc_member_android_build_content",
    "make_scc_member_build_content",
    "make_scc_merged_spoke_build_content",
    "scc_flutter_test_package_bzl_content",
)
load(
    "//flutter/private:flutter_pub_scc_target.bzl",
    "flutter_pub_scc_member_target",
)
load("//flutter/private:podfile_lock.bzl", "read_podfile_lock")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _hub_build_content_empty_scc_test_impl(ctx):
    """Hub BUILD and android/BUILD are byte-identical when scc_targets is empty."""
    env = unittest.begin(ctx)

    base_root = make_flutter_pub_hub_build_content(["bar", "foo"], "deps")
    explicit_root = make_flutter_pub_hub_build_content(["bar", "foo"], "deps", scc_targets = {})
    asserts.equals(env, base_root, explicit_root)

    base_android = make_flutter_pub_hub_android_build_content(["bar", "foo"], "deps")
    explicit_android = make_flutter_pub_hub_android_build_content(["bar", "foo"], "deps", scc_targets = {})
    asserts.equals(env, base_android, explicit_android)

    return unittest.end(env)

def _hub_build_content_with_sccs_test_impl(ctx):
    """Hub BUILD and android/BUILD route cycle members to the merged SCC spoke."""
    env = unittest.begin(ctx)

    scc_targets = {
        "cycle_a": "@deps__scc__cycle_a__cycle_b//:cycle_a",
        "cycle_b": "@deps__scc__cycle_a__cycle_b//:cycle_b",
    }
    packages = ["cycle_a", "cycle_b", "singleton_pkg"]

    root_content = make_flutter_pub_hub_build_content(packages, "deps", scc_targets = scc_targets)
    asserts.true(
        env,
        'load(":scc_android_edge.bzl", "flutter_pub_scc_android_edge")' in root_content,
        root_content,
    )
    asserts.true(
        env,
        '"//conditions:default": "@deps__scc__cycle_a__cycle_b//:cycle_a"' in root_content,
        root_content,
    )
    asserts.true(
        env,
        '"@platforms//os:android": ":_scc_android_cycle_a"' in root_content,
        root_content,
    )
    asserts.true(
        env,
        'deps = ["@deps__scc__cycle_a__cycle_b//:cycle_a"]' in root_content,
        root_content,
    )
    asserts.true(
        env,
        '"//conditions:default": "@deps__scc__cycle_a__cycle_b//:cycle_b"' in root_content,
        root_content,
    )
    asserts.true(
        env,
        '"@platforms//os:android": ":_scc_android_cycle_b"' in root_content,
        root_content,
    )
    asserts.true(
        env,
        '"@deps__scc__cycle_a__cycle_b//cycle_a/android:lib"' in root_content,
        root_content,
    )
    asserts.true(
        env,
        'actual = "@deps__singleton_pkg//:singleton_pkg"' in root_content,
        root_content,
    )

    android_content = make_flutter_pub_hub_android_build_content(packages, "deps", scc_targets = scc_targets)
    asserts.true(
        env,
        '"@deps__scc__cycle_a__cycle_b//cycle_a/android:lib"' in android_content,
        android_content,
    )
    asserts.true(
        env,
        '"@deps__scc__cycle_a__cycle_b//cycle_b/android:lib"' in android_content,
        android_content,
    )
    asserts.true(
        env,
        '"@deps__singleton_pkg//android:lib"' in android_content,
        android_content,
    )

    return unittest.end(env)

def _spoke_dep_labels_routing_test_impl(ctx):
    """Cross-spoke dep labels, SwiftPM sibling plugins, and CocoaPods siblings resolve via scc_targets."""
    env = unittest.begin(ctx)

    mock_ctx = struct(attr = struct(hub_name = "hub", scc_targets = {}))
    scc_targets = {
        "cycle_a": "@hub__scc__cycle_a__cycle_b//:cycle_a",
        "cycle_b": "@hub__scc__cycle_a__cycle_b//:cycle_b",
    }
    routed = spoke_dep_labels(
        mock_ctx,
        ["cycle_a", "other"],
        struct(uses_material_design = True),
        scc_targets = scc_targets,
    )
    asserts.equals(
        env,
        [
            "@hub__scc__cycle_a__cycle_b//:cycle_a",
            "@hub__other//:other",
            "@rules_flutter//flutter:material_icons",
        ],
        routed,
    )

    unrouted = spoke_dep_labels(mock_ctx, ["cycle_a", "other"], None, scc_targets = {})
    asserts.equals(env, ["@hub__cycle_a//:cycle_a", "@hub__other//:other"], unrouted)

    mock_with_attr = struct(attr = struct(hub_name = "hub", scc_targets = scc_targets))
    attr_routed = spoke_dep_labels(mock_with_attr, ["cycle_a", "other"], None)
    asserts.equals(env, ["@hub__scc__cycle_a__cycle_b//:cycle_a", "@hub__other//:other"], attr_routed)

    pins = apple_swiftpm_pins(
        '{"pins": [], "version": 2}',
        None,
        "//:Package.resolved",
        "",
        "hub",
        lock_packages = ["cycle_a", "cycle_b"],
        scc_targets = scc_targets,
    )
    asserts.true(env, pins.ok)
    manifest = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "cycle_a",
    dependencies: [.package(name: "cycle_b", path: "../cycle_b")],
    targets: [
        .target(
            name: "cycle_a",
            dependencies: [.product(name: "cycle_b", package: "cycle_b")]
        )
    ]
)
"""
    selected = select_apple_swiftpm_deps(
        "cycle_a",
        manifest,
        "ios/cycle_a",
        ["ios/cycle_a/Sources/cycle_a"],
        "ios",
        pins.pins,
    )
    asserts.equals(env, "", selected.error)
    asserts.equals(env, ["@hub__scc__cycle_a__cycle_b//:cycle_b_apple_ios"], selected.labels)

    _check_cocoapods_scc_routing(env, scc_targets)
    return unittest.end(env)

def _check_cocoapods_scc_routing(env, scc_targets):
    """Verify CocoaPods sibling plugin resolution routes through scc_targets."""
    podfile_text = """PODS:
  - Flutter (1.0.0)
  - cycle_a (0.1.0):
    - Flutter
    - cycle_b (= 0.1.0)
  - cycle_b (0.1.0):
    - Flutter
DEPENDENCIES:
  - cycle_a (from `.symlinks/plugins/cycle_a/ios`)
  - cycle_b (from `.symlinks/plugins/cycle_b/ios`)
EXTERNAL SOURCES:
  cycle_a:
    :path: .symlinks/plugins/cycle_a/ios
  cycle_b:
    :path: .symlinks/plugins/cycle_b/ios
COCOAPODS: 1.14.3
"""
    parsed = read_podfile_lock(podfile_text, "//:Podfile.lock")
    precomputed = precompute_hub_apple_pods(
        "hub",
        ["cycle_a", "cycle_b"],
        parsed,
        "//:Podfile.lock",
        {},
        [],
    )
    hub_json = json.encode({
        "ios_pod_deps": {},
        "ios_pod_ignore": [],
        "ios_pods": precomputed,
        "swift_package_product_deps": {},
        "version": 1,
    })
    files = {
        "//:Podfile.lock": podfile_text,
        "//:ios_native_deps.json": hub_json,
    }
    pod_ctx = struct(
        attr = struct(
            hub_name = "hub",
            podfile_lock = "//:Podfile.lock",
            ios_native_deps = "//:ios_native_deps.json",
            scc_targets = scc_targets,
        ),
        read = lambda p: files[str(p)],
    )
    pod_deps = detect_apple_cocoapods_deps(
        pod_ctx,
        "cycle_a",
        struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
        lambda _ctx, _pkg, _plat: [],
    )
    asserts.equals(env, ["@hub__scc__cycle_a__cycle_b//:cycle_b_apple_ios"], pod_deps.ios)

def _cycle_breaks_before_scc_2cycle_test_impl(ctx):
    """Broken 2-cycle yields singletons; unbroken yields a merged SCC spoke."""
    env = unittest.begin(ctx)

    lazy_single = plan_flutter_pub_sccs(["solo"], "hub", {}, {})
    asserts.equals(env, [], lazy_single.sccs)
    asserts.equals(env, ["solo"], lazy_single.singletons)
    asserts.equals(env, {}, lazy_single.planned_deps)

    deps = {"a": ["b"], "b": ["a"]}

    unbroken = plan_flutter_pub_sccs(["a", "b"], "hub", deps, {})
    asserts.equals(env, [["a", "b"]], unbroken.sccs)
    asserts.equals(env, [], unbroken.singletons)
    asserts.equals(env, "@hub__scc__a__b//:a", unbroken.scc_targets.get("a"))
    asserts.equals(env, "@hub__scc__a__b//:b", unbroken.scc_targets.get("b"))

    broken = plan_flutter_pub_sccs(["a", "b"], "hub", deps, {"a": ["b"]})
    asserts.equals(env, [], broken.sccs)
    asserts.equals(env, ["a", "b"], sorted(broken.singletons))
    asserts.equals(env, {}, broken.scc_targets)

    key = hosted_fact_key("pkg", "1.0.0", "ab" * 32, parser_texts_digest(["a"]))
    asserts.true(env, "pkg" in key)
    asserts.equals(env, None, lookup_fact_deps({}, key))
    asserts.equals(env, None, spoke_planned_deps_error("flutter_pub_package", "r", "a", ["b"], ["b"]))
    asserts.equals(env, None, scc_planned_deps_error("r", "a", ["b"]))
    asserts.equals(env, None, scc_member_deps_error("r", "a", ["b"], ["b"]))
    asserts.equals(env, None, scc_members_connectivity_error("r", {"a": ["b"], "b": ["a"]}))
    asserts.true(env, flutter_pub_scc_member_target != None)

    return unittest.end(env)

def _cycle_breaks_before_scc_3cycle_test_impl(ctx):
    """Unbroken 3-cycle merges; one break dissolves the 3-cycle; sub-cycle persists."""
    env = unittest.begin(ctx)

    deps_3 = {"a": ["b"], "b": ["c"], "c": ["a"]}

    unbroken = plan_flutter_pub_sccs(["a", "b", "c"], "hub", deps_3, {})
    asserts.equals(env, [["a", "b", "c"]], unbroken.sccs)
    asserts.equals(env, "@hub__scc__a__b__c//:a", unbroken.scc_targets.get("a"))
    asserts.equals(env, "@hub__scc__a__b__c//:b", unbroken.scc_targets.get("b"))
    asserts.equals(env, "@hub__scc__a__b__c//:c", unbroken.scc_targets.get("c"))

    broken_one = plan_flutter_pub_sccs(["a", "b", "c"], "hub", deps_3, {"a": ["b"]})
    asserts.equals(env, [], broken_one.sccs)
    asserts.equals(env, ["a", "b", "c"], sorted(broken_one.singletons))
    asserts.equals(env, {}, broken_one.scc_targets)

    deps_sub = {"a": ["b"], "b": ["a", "c"], "c": ["a"]}
    broken_sub = plan_flutter_pub_sccs(["a", "b", "c"], "hub", deps_sub, {"c": ["a"]})
    asserts.equals(env, [["a", "b"]], broken_sub.sccs)
    asserts.equals(env, ["c"], sorted(broken_sub.singletons))
    asserts.equals(env, "@hub__scc__a__b//:a", broken_sub.scc_targets.get("a"))
    asserts.equals(env, "@hub__scc__a__b//:b", broken_sub.scc_targets.get("b"))
    asserts.true(env, "c" not in broken_sub.scc_targets)

    return unittest.end(env)

def _mock_scc_member_inputs():
    """Builds mock asset, Apple, desktop, and plugin structs for 2-cycle tests."""
    return struct(
        assets = struct(
            fonts_json_str = '[{"family": "CustomFont"}]',
            font_files = {":font.ttf": "fonts/font.ttf"},
            pkg_assets = {":asset.png": "assets/asset.png"},
            pkg_shaders = {":shaders/shader.frag": "shaders/shader.frag"},
            pkg_asset_platforms = {":asset.png": ["android", "ios"]},
            pkg_asset_flavors = None,
        ),
        apple = struct(
            macos_srcs = ["macos/Classes"],
            ios_srcs = ["ios/Classes"],
            macos_includes = [],
            ios_includes = [],
            macos_manifests = ["macos/Resources/PrivacyInfo.xcprivacy"],
            ios_manifests = ["ios/Resources/PrivacyInfo.xcprivacy"],
        ),
        desktop = struct(linux = "linux", windows = "windows"),
        plugin = struct(
            defines = ["CYCLE_A_DEFINE=1"],
            platforms_json = (
                '{"android":{"package":"dev.example.cycle_a","pluginClass":"CycleAPlugin"},' +
                '"ios":{"pluginClass":"CycleAPlugin"}}'
            ),
            code_assets = ["@sqlite3//:code_asset"],
            has_unreplaced_hook = "",
            link_hook = "hook/link.dart",
            package_files = ["pubspec.yaml", "LICENSE*"],
        ),
    )

def _merged_spoke_build_2cycle_test_impl(ctx):
    """Merged spoke BUILD and member BUILD files for a 2-cycle with assets and plugins."""
    env = unittest.begin(ctx)

    apple_aliases = [
        'alias(name = "cycle_a_apple_ios", actual = "//cycle_a:cycle_a_apple_ios", ' +
        'visibility = ["//visibility:public"])',
    ]
    root_build = make_scc_merged_spoke_build_content(
        "hub__scc__cycle_a__cycle_b",
        ["cycle_a", "cycle_b"],
        ["@hub__outside_dep//:outside_dep"],
        apple_aliases = apple_aliases,
    )
    asserts.true(env, 'dart_library(\n    name = "merged",' in root_content_snippet(root_build), root_build)
    asserts.true(env, '"//cycle_a:cycle_a"' in root_build, root_build)
    asserts.true(env, '"//cycle_b:cycle_b"' in root_build, root_build)
    asserts.true(env, '"@hub__outside_dep//:outside_dep"' in root_build, root_build)
    asserts.true(env, 'flutter_pub_scc_member_target(\n    name = "cycle_a",' in root_build, root_build)
    asserts.true(env, 'flutter_pub_scc_member_target(\n    name = "cycle_b",' in root_build, root_build)
    asserts.true(env, '"//cycle_a:_flutter_info"' in root_build, root_build)
    asserts.true(env, '"//cycle_b:_flutter_info"' in root_build, root_build)
    asserts.true(env, 'name = "cycle_a_apple_ios"' in root_build, root_build)

    mocks = _mock_scc_member_inputs()
    member_build = make_scc_member_build_content(
        "cycle_a",
        "3.4",
        version = "1.0.0",
        plugin = mocks.plugin,
        assets = mocks.assets,
        apple = mocks.apple,
        desktop = mocks.desktop,
    )
    asserts.true(env, member_build.startswith("load("), member_build)
    asserts.true(env, '\ndart_package_member(\n    name = "cycle_a",' in member_build, member_build)
    asserts.true(env, '\nflutter_plugin(\n    name = "_flutter_info",' in member_build, member_build)
    asserts.true(env, "CustomFont" in member_build, member_build)
    asserts.true(env, "shaders/shader.frag" in member_build, member_build)
    asserts.true(env, "shader_includes = glob(" in member_build, member_build)
    asserts.true(env, "pkg_asset_platforms = {" in member_build, member_build)
    asserts.true(env, "PrivacyInfo.xcprivacy" in member_build, member_build)
    asserts.true(env, "cycle_a_apple_macos" in member_build, member_build)
    asserts.true(env, "cycle_a_apple_ios_xtool" in member_build, member_build)
    asserts.true(env, "cycle_a_linux" in member_build, member_build)
    asserts.true(env, "cycle_a_windows" in member_build, member_build)
    asserts.true(env, 'link_hook = "hook/link.dart"' in member_build, member_build)

    lib_member_build = make_scc_member_build_content(
        "cycle_b",
        "3.4",
        version = "1.0.0",
        assets = mocks.assets,
    )
    asserts.true(env, '\nflutter_library(\n    name = "_flutter_info",' in lib_member_build, lib_member_build)

    return unittest.end(env)

def _merged_spoke_android_and_overlay_test_impl(ctx):
    """Android subpackage BUILD and overlay adaptation for SCC members."""
    env = unittest.begin(ctx)

    android_build = make_scc_member_android_build_content("cycle_a", hub_name = "deps", android_plugin = True)
    asserts.true(env, 'actual = "@deps-android-cycle_a//android:lib"' in android_build, android_build)
    asserts.true(env, "load(" not in android_build, android_build)

    empty_android_build = make_scc_member_android_build_content("cycle_b", hub_name = "deps", android_plugin = False)
    asserts.true(env, "kt_android_library" in empty_android_build, empty_android_build)
    asserts.true(env, "srcs = []" in empty_android_build, empty_android_build)

    overlay_top = """load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")

flutter_plugin(
    name = "jni",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
    package_name = "jni",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "jni_java_support_srcs",
    srcs = glob(["java/**/*.java"]),
    visibility = ["//android:__pkg__"],
)
"""
    adapted_top = adapt_scc_member_overlay_content("jni", "3.4", "1.0.0", None, overlay_top)
    asserts.true(env, 'name = "_flutter_info"' in adapted_top, adapted_top)
    asserts.true(env, "    srcs = [],\n" in adapted_top, adapted_top)
    asserts.true(env, 'srcs = glob(["java/**/*.java"])' in adapted_top, adapted_top)
    asserts.true(env, '"//jni/android:__pkg__"' in adapted_top, adapted_top)
    asserts.true(env, 'dart_package_member(\n    name = "jni",' in adapted_top, adapted_top)

    overlay_android = 'kt_android_library(name = "lib", srcs = ["//:jni_java_support_srcs"])\n'
    adapted_android = adapt_scc_member_android_overlay_content("jni", overlay_android)
    asserts.true(env, '"//jni:jni_java_support_srcs"' in adapted_android, adapted_android)

    via_dispatcher = make_scc_member_android_build_content("jni", overlay_content = overlay_android)
    asserts.equals(env, adapted_android, via_dispatcher)

    return unittest.end(env)

def _merged_spoke_build_3cycle_test_impl(ctx):
    """Merged spoke BUILD for a 3-cycle includes all 3 members (and test runner support)."""
    env = unittest.begin(ctx)

    members = ["tri_a", "tri_b", "tri_c"]
    root_build = make_scc_merged_spoke_build_content("hub__scc__tri_a__tri_b__tri_c", members, [])
    for m in members:
        asserts.true(env, '"//%s:%s"' % (m, m) in root_build, root_build)
        asserts.true(env, 'flutter_pub_scc_member_target(\n    name = "%s",' % m in root_build, root_build)
        asserts.true(env, '"//%s:_flutter_info"' % m in root_build, root_build)

    test_member_build = make_scc_member_build_content("test", "3.4", version = "1.25.0")
    asserts.true(
        env,
        'load(":flutter_test_package.bzl", "flutter_test_package")' in test_member_build,
        test_member_build,
    )
    asserts.true(
        env,
        'flutter_test_package(\n    name = "test",\n    library = "//:_test_member",' in test_member_build,
        test_member_build,
    )
    content = scc_flutter_test_package_bzl_content()
    asserts.true(env, "flutter_test_package" in content)
    asserts.true(env, '"@rules_dart//dart:providers.bzl"' in content, content)
    asserts.true(env, '"DartTestRunnerInfo"' in content, content)
    asserts.true(env, '"DartTestRunnerSnapshotInfo"' in content, content)
    asserts.true(env, "dart/private" not in content, content)

    return unittest.end(env)

def root_content_snippet(content):
    """Helper to return content stripped of leading/trailing space for sub-checks."""
    return content.strip()

def _ci_entry(entries, seg):
    """Looks up `seg` in `entries` with NTFS case-insensitivity."""
    if seg in entries:
        return seg, entries[seg]
    target = seg.lower()
    for k, v in entries.items():
        if k.lower() == target:
            return k, v
    return None, None

def _win_node_children(val):
    """Returns direct child dictionary for a mock directory or metadata struct."""
    if type(val) == "struct":
        return getattr(val, "children", {})
    if type(val) == "dict":
        return val
    return {}

def _walk_win_children(rel_parts, node_val, more):
    """Walks `more` child path segments case-insensitively from `(rel_parts, node_val)`."""
    cur_parts = list(rel_parts)
    cur_val = node_val
    for idx in range(len(more)):
        seg = more[idx]
        matched_k, matched_v = _ci_entry(_win_node_children(cur_val), seg)
        cur_parts.append(matched_k if matched_k != None else seg)
        cur_val = matched_v
        if cur_val == None:
            cur_parts.extend(more[idx + 1:])
            break
    return cur_parts, cur_val

def _make_win_fs_node(root_real, rel_parts, node_val):
    """Creates a mock NTFS `path` node for Windows `collect_path_deps` tests."""
    rel = "/".join(rel_parts)
    default_real = (root_real.rstrip("/") + "/" + rel) if rel else root_real
    is_meta = type(node_val) == "struct"
    is_dir = type(node_val) == "dict" or (is_meta and getattr(node_val, "is_dir", False))
    real = getattr(node_val, "realpath", default_real) if is_meta else default_real
    text = getattr(node_val, "text", "") if is_meta else (node_val if type(node_val) == "string" else "")
    kids = _win_node_children(node_val)

    def get_child(*more):
        """Resolves child segments case-insensitively."""
        next_parts, next_val = _walk_win_children(rel_parts, node_val, more)
        return _make_win_fs_node(root_real, next_parts, next_val)

    def readdir():
        """Lists direct directory children with their true casing."""
        return [_make_win_fs_node(root_real, rel_parts + [k], kids[k]) for k in sorted(kids.keys())]

    return struct(
        basename = rel_parts[-1] if rel_parts else "",
        dirname = None,
        exists = node_val != None,
        is_dir = is_dir,
        realpath = real,
        text = text,
        get_child = get_child,
        readdir = readdir,
    )

def _windows_path_pubspec_test_impl(ctx):
    """Windows NTFS `build/` dirs, backslashes, mixed-case drives, and CRLF pubspecs succeed."""
    env = unittest.begin(ctx)

    win_root_real = "D:\\a\\ai_rules_flutter\\e2e\\hello_world"
    crlf_pubspec = (
        "name: win_pkg\r\n" +
        "version: 0.1.0\r\n" +
        "environment:\r\n" +
        "  sdk: ^3.4.0\r\n" +
        "dependencies:\r\n" +
        "  path_probe:\r\n" +
        "    path: ../../path_probe\r\n" +
        "  meta: ^1.11.0\r\n"
    )
    ws_tree = {
        "BUILD.bazel": "# root package\r\n",
        "MODULE.bazel": 'module(name = "hello_world")\r\n',
        "path_probe": {
            "build": {"output.txt": "artifact"},
            "lib": {"path_probe.dart": ""},
            "pubspec.yaml": "name: path_probe\r\nversion: 0.1.0\r\ndependencies:\r\n  collection: ^1.18.0\r\n",
        },
        "packages": {
            "win_pkg": struct(
                is_dir = True,
                realpath = "d:/a/AI_Rules_Flutter/e2e/hello_world/packages/win_pkg",
                children = {
                    "pubspec.yaml": struct(
                        is_dir = False,
                        realpath = "d:\\a\\AI_Rules_Flutter\\e2e\\hello_world\\packages\\win_pkg\\pubspec.yaml",
                        text = crlf_pubspec,
                    ),
                },
            ),
        },
        "escaped": struct(
            is_dir = True,
            realpath = "D:\\outside\\escaped",
            children = {"pubspec.yaml": "name: escaped\r\n"},
        ),
    }
    ws_root = _make_win_fs_node(win_root_real, [], ws_tree)

    # Confirm the NTFS reproducer: `path_probe/BUILD` matches `path_probe/build` (a directory).
    asserts.true(env, ws_root.get_child("path_probe", "BUILD").exists)
    asserts.true(env, ws_root.get_child("path_probe", "BUILD").is_dir)

    def mock_path(_label):
        """Returns the lock file path whose `.dirname` is `ws_root`."""
        return struct(dirname = ws_root)

    def mock_read(target):
        """Fails if passed a `Label` (matching Bazel PackageLookup on non-packages)."""
        if type(target) == "Label":
            fail("Unexpected Label passed to module_ctx.read: %s" % target)
        return target.text

    mock_module_ctx = struct(
        os = struct(name = "windows amd64"),
        path = mock_path,
        read = mock_read,
    )
    path_pkgs = {
        "path_probe": struct(path = "path_probe", version = "0.1.0"),
        "win_pkg": struct(path = "packages\\win_pkg", version = "0.1.0"),
    }
    collected = collect_path_deps(mock_module_ctx, "deps", path_pkgs, Label("//:pubspec.lock"))
    asserts.equals(env, ["collection"], collected["path_probe"])
    asserts.equals(env, ["meta", "path_probe"], collected["win_pkg"])

    asserts.equals(
        env,
        "packages/win_pkg",
        workspace_relative_lock_path("deps", "win_pkg", Label("//:pubspec.lock"), "packages\\win_pkg"),
    )

    _check_windows_refusals(env, ws_root, win_root_real)
    return unittest.end(env)

def _check_windows_refusals(env, ws_root, win_root_real):
    """Verifies Windows absolute paths, escapes, outside junctions, and root drives."""
    for bad_abs in ("D:/outside", "C:\\outside", "\\\\server\\share\\pkg"):
        res = resolve_path_pubspec(ws_root, win_root_real, "deps", "bad", bad_abs, "windows")
        asserts.true(env, res.error != None and "invalid path" in res.error, str(res.error))

    esc = resolve_path_pubspec(ws_root, win_root_real, "deps", "bad", "..\\outside", "windows")
    asserts.true(env, esc.error != None and "escapes workspace" in esc.error, str(esc.error))

    junc = resolve_path_pubspec(ws_root, win_root_real, "deps", "escaped", "escaped", "windows")
    asserts.true(env, junc.error != None and "resolves outside workspace" in junc.error, str(junc.error))

    asserts.equals(env, "D:", normalize_realpath("D:\\"))
    drive_root = _make_win_fs_node("D:/", [], {"pkg": {"pubspec.yaml": "name: pkg\r\n"}})
    ok_drive = resolve_path_pubspec(drive_root, "D:/", "deps", "pkg", "pkg", "windows")
    asserts.equals(env, None, ok_drive.error)

_hub_build_content_empty_scc_test = unittest.make(_hub_build_content_empty_scc_test_impl)
_hub_build_content_with_sccs_test = unittest.make(_hub_build_content_with_sccs_test_impl)
_spoke_dep_labels_routing_test = unittest.make(_spoke_dep_labels_routing_test_impl)
_cycle_breaks_before_scc_2cycle_test = unittest.make(_cycle_breaks_before_scc_2cycle_test_impl)
_cycle_breaks_before_scc_3cycle_test = unittest.make(_cycle_breaks_before_scc_3cycle_test_impl)
_merged_spoke_build_2cycle_test = unittest.make(_merged_spoke_build_2cycle_test_impl)
_merged_spoke_android_and_overlay_test = unittest.make(_merged_spoke_android_and_overlay_test_impl)
_merged_spoke_build_3cycle_test = unittest.make(_merged_spoke_build_3cycle_test_impl)
_windows_path_pubspec_test = unittest.make(_windows_path_pubspec_test_impl)

def flutter_pub_scc_test_suite(name):
    """Defines the flutter.pub SCC planner and spoke test suite."""
    small_unittest_suite(
        name,
        _hub_build_content_empty_scc_test,
        _hub_build_content_with_sccs_test,
        _spoke_dep_labels_routing_test,
        _cycle_breaks_before_scc_2cycle_test,
        _cycle_breaks_before_scc_3cycle_test,
        _merged_spoke_build_2cycle_test,
        _merged_spoke_android_and_overlay_test,
        _merged_spoke_build_3cycle_test,
        _windows_path_pubspec_test,
    )
