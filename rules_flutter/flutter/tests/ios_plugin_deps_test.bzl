"""Unit tests for `flutter.pub(ios_plugin_deps = ...)` mapping and validation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "apple_plugin_targets",
    "detect_apple_swiftpm_deps",
    "with_apple_swiftpm_deps",
)
load("//flutter/private:flutter_pub_apple_deps.bzl", "select_apple_swiftpm_deps")
load(
    "//flutter/private:flutter_pub_plugin_deps.bzl",
    "ios_plugin_deps_lock_error",
    "mapped_apple_plugin_deps",
    "plugin_native_deps_apple_error",
    "plugin_native_deps_overlay_error",
)
load("//flutter/private:swiftpm_resolved.bzl", "pub_spoke_swiftpm_attrs")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _mapped_no_label_test_impl(ctx):
    """mapped_apple_plugin_deps with no label returns mapped=False and empty lists."""
    env = unittest.begin(ctx)
    result = mapped_apple_plugin_deps(None, ["macos/Classes"], ["ios/Classes"])
    asserts.false(env, result.mapped)
    asserts.equals(env, [], result.macos)
    asserts.equals(env, [], result.ios)
    return unittest.end(env)

_mapped_no_label_test = unittest.make(_mapped_no_label_test_impl)

def _mapped_with_label_test_impl(ctx):
    """mapped_apple_plugin_deps maps label only to platforms that have sources."""
    env = unittest.begin(ctx)
    label = "@mapped//:dep"

    ios_only = mapped_apple_plugin_deps(label, [], ["ios/Classes"])
    asserts.true(env, ios_only.mapped)
    asserts.equals(env, [], ios_only.macos)
    asserts.equals(env, [label], ios_only.ios)

    both = mapped_apple_plugin_deps(label, ["macos/Classes"], ["ios/Classes"])
    asserts.true(env, both.mapped)
    asserts.equals(env, [label], both.macos)
    asserts.equals(env, [label], both.ios)

    no_srcs = mapped_apple_plugin_deps(label, [], [])
    asserts.true(env, no_srcs.mapped)
    asserts.equals(env, [], no_srcs.macos)
    asserts.equals(env, [], no_srcs.ios)
    return unittest.end(env)

_mapped_with_label_test = unittest.make(_mapped_with_label_test_impl)

def _with_apple_swiftpm_deps_renders_target_test_impl(ctx):
    """with_apple_swiftpm_deps splices the label into iOS targets and nowhere else."""
    env = unittest.begin(ctx)
    pkg = "two_plat"
    content = (
        apple_plugin_targets(pkg, ["macos/two_plat/Sources/two_plat"], [], "macos") + "\n" +
        apple_plugin_targets(pkg, ["ios/two_plat/Sources/two_plat"], [], "ios")
    )
    label = "@mapped//:dep"
    mapped = mapped_apple_plugin_deps(label, [], ["ios/two_plat/Sources/two_plat"])
    patched = with_apple_swiftpm_deps(content, pkg, mapped.macos, mapped.ios)

    asserts.equals(env, 2, len(patched.split(label)) - 1)
    macos_device = patched.split('name = "two_plat_apple_macos",')[1].split("visibility = [")[0]
    asserts.false(env, label in macos_device)
    macos_xtool = patched.split('name = "two_plat_apple_macos_xtool",')[1].split("visibility = [")[0]
    asserts.false(env, label in macos_xtool)
    ios_device = patched.split('name = "two_plat_apple_ios",')[1].split("visibility = [")[0]
    asserts.true(env, label in ios_device)
    ios_xtool = patched.split('name = "two_plat_apple_ios_xtool",')[1].split("visibility = [")[0]
    asserts.true(env, label in ios_xtool)
    return unittest.end(env)

_with_apple_swiftpm_deps_renders_target_test = unittest.make(
    _with_apple_swiftpm_deps_renders_target_test_impl,
)

def _lock_error_test_impl(ctx):
    """ios_plugin_deps_lock_error accepts locked keys and refuses unlocked keys."""
    env = unittest.begin(ctx)
    asserts.equals(env, "", ios_plugin_deps_lock_error({}, ["a", "b"]))
    asserts.equals(env, "", ios_plugin_deps_lock_error({"a": "//:a", "b": "//:b"}, ["a", "b"]))

    expected_ghost = (
        'flutter.pub(ios_plugin_deps = ...): key "ghost" is not a package in ' +
        "the lock. Name a locked package, or remove the entry."
    )
    asserts.equals(env, expected_ghost, ios_plugin_deps_lock_error({"ghost": "//:g"}, ["a"]))

    expected_alpha = (
        'flutter.pub(ios_plugin_deps = ...): key "alpha" is not a package in ' +
        "the lock. Name a locked package, or remove the entry."
    )
    asserts.equals(
        env,
        expected_alpha,
        ios_plugin_deps_lock_error({"zebra": "//:z", "alpha": "//:a"}, ["a"]),
    )

    expected_sdk = (
        'flutter.pub(ios_plugin_deps = ...): key "integration_test" is a Flutter SDK package; ' +
        "Flutter SDK packages are not configurable through ios_plugin_deps. Remove the entry."
    )
    sdk_lock = ["a", "integration_test"]
    asserts.equals(
        env,
        expected_sdk,
        ios_plugin_deps_lock_error({"integration_test": "//:x"}, sdk_lock, {"integration_test": True}),
    )
    asserts.equals(env, "", ios_plugin_deps_lock_error({"a": "//:a"}, sdk_lock, ["integration_test"]))
    asserts.equals(
        env,
        expected_ghost,
        ios_plugin_deps_lock_error({"ghost": "//:g"}, sdk_lock, ["integration_test"]),
    )
    asserts.equals(
        env,
        expected_alpha,
        ios_plugin_deps_lock_error({"integration_test": "//:x", "alpha": "//:a"}, sdk_lock, ["integration_test"]),
    )
    return unittest.end(env)

_lock_error_test = unittest.make(_lock_error_test_impl)

def _apple_error_test_impl(ctx):
    """plugin_native_deps_apple_error refuses a label when the plugin has no Apple sources."""
    env = unittest.begin(ctx)
    asserts.equals(env, "", plugin_native_deps_apple_error("my_pkg", None, [], []))
    asserts.equals(env, "", plugin_native_deps_apple_error("my_pkg", "", [], []))
    asserts.equals(env, "", plugin_native_deps_apple_error("my_pkg", "//:dep", [], ["ios/Classes"]))
    asserts.equals(env, "", plugin_native_deps_apple_error("my_pkg", "//:dep", ["macos/Classes"], []))

    expected = (
        'flutter.pub(ios_plugin_deps = ...): "my_pkg" has no iOS or macOS Apple ' +
        "sources, so its dependency reaches nothing. Remove the entry."
    )
    asserts.equals(
        env,
        expected,
        plugin_native_deps_apple_error("my_pkg", "//:dep", [], []),
    )
    return unittest.end(env)

_apple_error_test = unittest.make(_apple_error_test_impl)

def _overlay_error_test_impl(ctx):
    """plugin_native_deps_overlay_error refuses a label when an overlay replaces the spoke."""
    env = unittest.begin(ctx)
    asserts.equals(env, "", plugin_native_deps_overlay_error("my_pkg", None, False))
    asserts.equals(env, "", plugin_native_deps_overlay_error("my_pkg", None, True))
    asserts.equals(env, "", plugin_native_deps_overlay_error("my_pkg", "//:dep", False))

    expected = (
        'flutter.pub(ios_plugin_deps = ...): "my_pkg" uses an overlay BUILD, ' +
        "so the generated Apple targets do not receive its dependency. Remove " +
        "the entry or list it in the overlay."
    )
    asserts.equals(
        env,
        expected,
        plugin_native_deps_overlay_error("my_pkg", "//:dep", True),
    )
    return unittest.end(env)

_overlay_error_test = unittest.make(_overlay_error_test_impl)

def _pub_spoke_swiftpm_attrs_test_impl(ctx):
    """pub_spoke_swiftpm_attrs assigns plugin_deps only to the named plugin spoke."""
    env = unittest.begin(ctx)
    pub_tag = struct(
        lock = "//:pubspec.lock",
        name = "rules_flutter",
        swift_package_resolved = "//:Package.resolved",
        ios_plugin_deps = {"plugin_a": "//:dep_a"},
    )
    unmapped_tag = struct(
        lock = "//:pubspec.lock",
        name = "rules_flutter",
        swift_package_resolved = "//:Package.resolved",
        ios_plugin_deps = {},
    )
    attrs_a = pub_spoke_swiftpm_attrs(pub_tag, include_ios_native_deps = True, plugin_name = "plugin_a")
    attrs_b = pub_spoke_swiftpm_attrs(pub_tag, include_ios_native_deps = True, plugin_name = "plugin_b")
    attrs_b_unmapped = pub_spoke_swiftpm_attrs(
        unmapped_tag,
        include_ios_native_deps = True,
        plugin_name = "plugin_b",
    )

    asserts.equals(env, "//:dep_a", attrs_a.plugin_deps)
    asserts.equals(env, None, attrs_b.plugin_deps)
    asserts.equals(env, attrs_b_unmapped, attrs_b)
    asserts.equals(env, attrs_a.package_resolved, attrs_b.package_resolved)
    asserts.equals(env, attrs_a.package_sha256, attrs_b.package_sha256)
    return unittest.end(env)

_pub_spoke_swiftpm_attrs_test = unittest.make(_pub_spoke_swiftpm_attrs_test_impl)

def _detect_apple_swiftpm_deps_short_circuits_test_impl(ctx):
    """detect_apple_swiftpm_deps returns mapped labels without reading manifests or hub files."""
    env = unittest.begin(ctx)
    fake_ctx = struct(attr = struct(plugin_native_deps = "@mapped//:dep"))
    apple = struct(macos_srcs = [], ios_srcs = ["ios/Classes"])
    detected = detect_apple_swiftpm_deps(fake_ctx, "computed_plugin", apple)
    asserts.equals(env, [], detected.macos)
    asserts.equals(env, ["@mapped//:dep"], detected.ios)
    return unittest.end(env)

_detect_apple_swiftpm_deps_short_circuits_test = unittest.make(
    _detect_apple_swiftpm_deps_short_circuits_test_impl,
)

def _unmapped_missing_resolved_keeps_refusal_test_impl(ctx):
    """An unmapped plugin with no swift_package_resolved keeps existing refusal."""
    env = unittest.begin(ctx)
    pub_tag = struct(
        lock = "//:pubspec.lock",
        name = "deps",
        swift_package_resolved = None,
        ios_plugin_deps = {"other_plugin": "//:other_dep"},
    )
    attrs = pub_spoke_swiftpm_attrs(pub_tag, include_ios_native_deps = True, plugin_name = "spm_bigint_plugin")
    asserts.equals(env, None, attrs.plugin_deps)
    mapped = mapped_apple_plugin_deps(attrs.plugin_deps, [], ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"])
    asserts.false(env, mapped.mapped)

    manifest = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1"),
    ],
    targets: [
        .target(
            name: "spm_bigint_plugin",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "BigInt", package: "BigInt"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.define("SPM_TEST")],
        ),
    ],
)
"""
    pins = struct(resolved = "", pinned = [], unpinned = {}, hub = "deps")
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        manifest,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        pins,
    )
    asserts.false(env, selected.ok)
    asserts.true(env, "sets no `swift_package_resolved`" in selected.error)
    return unittest.end(env)

_unmapped_missing_resolved_keeps_refusal_test = unittest.make(
    _unmapped_missing_resolved_keeps_refusal_test_impl,
)

def ios_plugin_deps_test_suite(name):
    """Defines the `flutter.pub(ios_plugin_deps = ...)` unit tests.

    Args:
        name: Name of the test suite.
    """
    small_unittest_suite(
        name,
        _mapped_no_label_test,
        _mapped_with_label_test,
        _with_apple_swiftpm_deps_renders_target_test,
        _lock_error_test,
        _apple_error_test,
        _overlay_error_test,
        _pub_spoke_swiftpm_attrs_test,
        _detect_apple_swiftpm_deps_short_circuits_test,
        _unmapped_missing_resolved_keeps_refusal_test,
    )
