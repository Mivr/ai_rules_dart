"""Unit tests for the plugin-local walk refusing untranslatable manifests."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_apple_local.bzl",
    "detect_apple_local_targets",
    "parse_plugin_local_package",
    "plugin_local_targets",
)
load("//flutter/private:flutter_pub_apple_local_refusal.bzl", "local_manifest_decision")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_HEAD = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "demo",
    platforms: [.iOS("13.0")],
    products: [.library(name: "demo", targets: ["demo"])],
    targets: [
        .target(name: "demo", dependencies: ["demo_objc"], path: "Sources/demo"),
        .target(name: "demo_objc", path: "Sources/demo_objc"__SETTINGS__),
    ]
)
"""

def _declarative(settings):
    return _HEAD.replace("__SETTINGS__", settings)

def _decide(text, others = []):
    return local_manifest_decision("demo", text, parse_plugin_local_package("demo", text), others)

def _check_refused(env, text, needles, others = []):
    res = _decide(text, others)
    asserts.false(env, res.ok)
    for needle in needles:
        asserts.true(env, needle in res.error, "%r missing from %r" % (needle, res.error))

def _define_when_test_impl(ctx):
    env = unittest.begin(ctx)
    text = _declarative(', cSettings: [.define("FOO", .when(configuration: .debug))]')
    _check_refused(env, text, ["demo", "Package.swift", "demo_objc", "configuration:"])
    return unittest.end(env)

def _unsafe_flags_test_impl(ctx):
    env = unittest.begin(ctx)
    text = _declarative(', cSettings: [.unsafeFlags(["-fno-objc-arc"])]')
    _check_refused(env, text, ["demo", "demo_objc", ".unsafeFlags("])
    return unittest.end(env)

def _unknown_setting_test_impl(ctx):
    env = unittest.begin(ctx)
    text = _declarative(", swiftSettings: [.interoperabilityMode(.Cxx)]")
    _check_refused(env, text, ["demo", "demo_objc", "interoperabilityMode"])
    return unittest.end(env)

_PROGRAM = """// swift-tools-version: 5.9
import PackageDescription
let extra = 1
let package = Package(
    name: "demo",
    products: [.library(name: "demo", targets: ["demo"])],
    targets: [
        .target(name: "demo", path: "Sources/demo"),
        .target(name: "demo_objc", path: "Sources/demo_objc"),
    ]
)
"""

_SINGLE = """// swift-tools-version: 5.9
import Foundation
import PackageDescription
let env = ProcessInfo.processInfo.environment["X"]
let package = Package(
    name: "demo",
    products: [.library(name: "demo", targets: ["demo"])],
    targets: [.target(name: "demo", path: "Sources/demo")]
)
"""

def _program_two_targets_test_impl(ctx):
    env = unittest.begin(ctx)
    _check_refused(env, _PROGRAM, ["demo", "Package.swift"])
    return unittest.end(env)

def _program_sibling_dir_test_impl(ctx):
    env = unittest.begin(ctx)
    _check_refused(env, _SINGLE, ["demo", "Package.swift"], ["ios/demo/Sources/other"])
    return unittest.end(env)

def _single_target_program_test_impl(ctx):
    env = unittest.begin(ctx)
    res = _decide(_SINGLE)
    asserts.true(env, res.ok)
    asserts.false(env, res.parsed.ok)
    return unittest.end(env)

def _fake_ctx(mapped):
    reads = []
    return struct(
        reads = reads,
        attr = struct(plugin_native_deps = "//:deps" if mapped else None),
        read = lambda p: reads.append(p) or _declarative(', cSettings: [.unsafeFlags(["-x"])]'),
        path = lambda p: struct(exists = True, readdir = lambda: [], is_dir = True),
    )

def _mapped_skips_read_test_impl(ctx):
    env = unittest.begin(ctx)
    fake = _fake_ctx(True)
    apple = struct(macos_srcs = ["darwin/demo/Sources/demo"], ios_srcs = ["ios/demo/Sources/demo"])
    res = detect_apple_local_targets(fake, "demo", apple)
    asserts.true(env, res.ios.ok and res.macos.ok)
    asserts.equals(env, [], res.ios.labels)
    asserts.equals(env, [], fake.reads)
    return unittest.end(env)

def _demo_dep_manifest(deps):
    """Build a single-target demo manifest with `deps` on `demo`."""
    return """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "demo",
    platforms: [.iOS("13.0")],
    products: [.library(name: "demo", targets: ["demo"])],
    targets: [
        .target(name: "demo", dependencies: [%s], path: "Sources/demo"),
    ]
)
""" % deps

def _unknown_same_target_refusal_test_impl(ctx):
    """An explicit `.target(name:)` on an unknown target is still refused."""
    env = unittest.begin(ctx)
    explicit = parse_plugin_local_package("demo", _demo_dep_manifest('.target(name: "Missing")'))
    asserts.true(env, explicit.ok, explicit.error)
    refused = plugin_local_targets("demo", explicit.model, "ios/demo", "ios/demo/Sources/demo", "ios")
    asserts.false(env, refused.ok)
    asserts.equals(env, 'Flutter plugin "demo": target "demo" depends on unknown target "Missing".', refused.error)

    byname = parse_plugin_local_package("demo", _demo_dep_manifest('"Missing", .byName(name: "Missing")'))
    asserts.true(env, byname.ok, byname.error)
    skipped = plugin_local_targets("demo", byname.model, "ios/demo", "ios/demo/Sources/demo", "ios")
    asserts.true(env, skipped.ok, skipped.error)
    asserts.equals(env, [], skipped.targets)
    return unittest.end(env)

_define_when_test = unittest.make(_define_when_test_impl)
_unsafe_flags_test = unittest.make(_unsafe_flags_test_impl)
_unknown_setting_test = unittest.make(_unknown_setting_test_impl)
_program_two_targets_test = unittest.make(_program_two_targets_test_impl)
_program_sibling_dir_test = unittest.make(_program_sibling_dir_test_impl)
_single_target_program_test = unittest.make(_single_target_program_test_impl)
_mapped_skips_read_test = unittest.make(_mapped_skips_read_test_impl)
_unknown_same_target_refusal_test = unittest.make(_unknown_same_target_refusal_test_impl)

def swiftpm_local_refusal_test_suite(name):
    """Declares the local-refusal unit tests.

    Args:
        name: The suite name.
    """
    small_unittest_suite(
        name,
        _define_when_test,
        _unsafe_flags_test,
        _unknown_setting_test,
        _program_two_targets_test,
        _program_sibling_dir_test,
        _single_target_program_test,
        _mapped_skips_read_test,
        _unknown_same_target_refusal_test,
    )
