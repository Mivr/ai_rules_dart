"""Unit tests for the pub plugin spoke's SwiftPM product links."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "apple_plugin_targets",
    "apple_swiftpm_pins",
    "select_apple_swiftpm_deps",
    "with_apple_swiftpm_deps",
)
load("//flutter/private:flutter_pub_apple_local.bzl", "apply_apple_native_deps")
load("//flutter/private:starlark_literal.bzl", "starlark_string_literal")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_BIGINT_SHA = "55fc8a63f655a09d9216f2c9bc062c508f98d4eca4b8ebefaf295a3ea4ac8f22"

_BIGINT_RESOLVED = """{
  "pins" : [
    {
      "identity" : "bigint",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/attaswift/BigInt.git",
      "state" : {
        "revision" : "63feef7820abb1a8fb08587d7da56bb0b7db8751",
        "version" : "6.0.1"
      }
    }
  ],
  "version" : 3
}
"""

_BIGINT_MAP_HINT = ' Map it with flutter.pub(swift_package_product_deps = {"bigint:BigInt": "<label>"}).'

_BIGINT_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")],
    targets: [.target(name: "Helper"), .target(name: "spm_bigint_plugin", dependencies: ["Helper", .target(name: "Other"), .product(name: "BigInt", package: "BigInt")])],
)
"""

_CONDITIONED_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1"),
        .package(url: "https://example.com/MacOnly.git", exact: "1.0.0"),
    ],
    targets: [.target(name: "spm_bigint_plugin", dependencies: [.product(name: "BigInt", package: "BigInt", condition: .when(platforms: [.iOS])), .product(name: "MacOnly", package: "MacOnly", condition: .when(platforms: [.macOS]))])],
)
"""

_FRAMEWORK_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1"),
    ],
    targets: [.target(name: "spm_bigint_plugin", dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework"), .product(name: "BigInt", package: "BigInt")])],
)
"""

_TEMPLATE_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "spm_bigint_plugin",
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")],
            resources: [.process("PrivacyInfo.xcprivacy")],
            swiftSettings: [.define("SPM_TEST")],
        ),
    ],
)
"""

_TEMPLATE_BIGINT_MANIFEST = """// swift-tools-version: 5.9
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
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework"), .product(name: "BigInt", package: "BigInt")],
            resources: [.process("Resources")],
            swiftSettings: [.define("SPM_TEST")],
        ),
    ],
)
"""

def _pins(pinned = ["bigint"], unpinned = {}, resolved = "//:Package.resolved"):
    return struct(resolved = resolved, pinned = pinned, unpinned = unpinned, hub = "deps")

def _products_resolve_to_pinned_labels_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], selected.labels)
    return unittest.end(env)

def _conditions_filter_per_platform_test_impl(ctx):
    env = unittest.begin(ctx)
    ios = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _CONDITIONED_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(pinned = ["bigint", "maconly"]),
    )
    asserts.true(env, ios.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], ios.labels)
    macos = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _CONDITIONED_MANIFEST,
        "macos/spm_bigint_plugin",
        ["macos/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "macos",
        _pins(pinned = ["bigint", "maconly"]),
    )
    asserts.true(env, macos.ok)
    asserts.equals(env, ["@deps__swiftpm-maconly//:MacOnly"], macos.labels)
    return unittest.end(env)

def _flutterframework_product_is_skipped_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _FRAMEWORK_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], selected.labels)
    return unittest.end(env)

def _template_manifest_builds_without_link_test_impl(ctx):
    env = unittest.begin(ctx)
    with_resolved = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _TEMPLATE_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, with_resolved.ok)
    asserts.equals(env, [], with_resolved.labels)
    without_resolved = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _TEMPLATE_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
    )
    asserts.true(env, without_resolved.ok)
    asserts.equals(env, [], without_resolved.labels)
    return unittest.end(env)

def _real_world_manifest_settings_still_link_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = _BIGINT_MANIFEST.replace(
        'let package = Package(\n    name: "spm_bigint_plugin",',
        'let package = Package(\n    name: "spm_bigint_plugin",\n    defaultLocalization: "en",',
    ).replace(
        '.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")',
        '.package(url: "https://github.com/attaswift/BigInt.git", "6.0.0"..<"7.0.0")',
    ).replace(
        '.target(name: "spm_bigint_plugin", dependencies:',
        '.target(name: "spm_bigint_plugin", publicHeadersPath: "include", packageAccess: false, dependencies:',
    )
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        manifest,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], selected.labels)
    return unittest.end(env)

def _template_settings_leave_links_unchanged_test_impl(ctx):
    env = unittest.begin(ctx)
    with_settings = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _TEMPLATE_BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, with_settings.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], with_settings.labels)
    without_settings = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _FRAMEWORK_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, without_settings.ok)
    asserts.equals(env, with_settings.labels, without_settings.labels)
    return unittest.end(env)

def _flutterframework_first_names_real_package_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _TEMPLATE_BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "ios/spm_bigint_plugin/Package.swift" in selected.error)
    asserts.true(env, "BigInt" in selected.error)
    asserts.true(env, "FlutterFramework" not in selected.error)
    return unittest.end(env)

def _conditional_dependencies_still_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    conditional = _BIGINT_MANIFEST.replace(
        'dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")]',
        'dependencies: [\n        #if os(iOS)\n        .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1"),\n        #endif\n    ]',
    )
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        conditional,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "Package.swift" in selected.error)

    variable = _BIGINT_MANIFEST.replace(
        'url: "https://github.com/attaswift/BigInt.git"',
        "url: bigIntUrl",
    )
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        variable,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "Package.swift" in selected.error)
    return unittest.end(env)

def _undeclared_package_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = _BIGINT_MANIFEST.replace('package: "BigInt"', 'package: "Missing"')
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        manifest,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "Missing" in selected.error)
    return unittest.end(env)

def _path_package_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "spm_bigint_plugin",
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [.package(name: "Local", path: "../Local")],
    targets: [.target(name: "spm_bigint_plugin", dependencies: [.product(name: "L", package: "Local")])],
)
"""
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        manifest,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "Local" in selected.error)
    return unittest.end(env)

def _unpinned_package_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(pinned = []),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "bigint" in selected.error)
    asserts.true(env, "Package.resolved" in selected.error)
    return unittest.end(env)

def _missing_checksum_refuses_the_plugin_test_impl(ctx):
    env = unittest.begin(ctx)
    built = apple_swiftpm_pins(
        _BIGINT_RESOLVED,
        "{}",
        "//ios:Package.resolved",
        "@deps_unpinned//:swift_package_sha256.json",
        "deps_unpinned",
    )
    asserts.true(env, built.ok)
    assertions = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        built.pins,
    )
    asserts.true(env, not assertions.ok)
    asserts.true(env, 'Flutter plugin "spm_bigint_plugin"' in assertions.error)
    asserts.true(env, "ios/spm_bigint_plugin/Package.swift" in assertions.error)
    asserts.true(env, 'has no `swift_package_sha256["bigint"]` entry' in assertions.error)
    return unittest.end(env)

def _pinned_checksum_still_links_the_product_test_impl(ctx):
    env = unittest.begin(ctx)
    built = apple_swiftpm_pins(
        _BIGINT_RESOLVED,
        '{"bigint": "' + _BIGINT_SHA + '"}',
        "//ios:Package.resolved",
        "@deps//:swift_package_sha256.json",
        "deps",
    )
    asserts.true(env, built.ok)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        built.pins,
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], selected.labels)
    return unittest.end(env)

def _unfetchable_pin_reports_its_reason_test_impl(ctx):
    env = unittest.begin(ctx)
    reason = "deps__swiftpm-bigint: SwiftPM package \"bigint\" cannot be fetched: test reason."
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(unpinned = {"bigint": reason}),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, reason in selected.error)
    return unittest.end(env)

def _missing_resolved_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "bigint" in selected.error)
    asserts.true(env, "swift_package_resolved" in selected.error)
    return unittest.end(env)

def _unreadable_manifest_without_packages_builds_on_test_impl(ctx):
    env = unittest.begin(ctx)
    broken = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(\n"
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        broken,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.labels)

    broken_packages = broken.replace("Package(", "Package(name: \"p\", dependencies: [.package(")
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        broken_packages,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    return unittest.end(env)

def _manifests_without_links_resolve_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    nodeps = _BIGINT_MANIFEST.replace('    dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")],\n', "").replace(', dependencies: ["Helper", .target(name: "Other"), .product(name: "BigInt", package: "BigInt")]', "")
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        nodeps,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.labels)

    # The manifest's target builds nothing the spoke emits.
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/other/Sources/other"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.labels)
    return unittest.end(env)

def _deps_render_on_both_backends_test_impl(ctx):
    env = unittest.begin(ctx)
    content = apple_plugin_targets(
        "spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        [],
        "ios",
    )
    asserts.equals(env, content, with_apple_swiftpm_deps(content, "spm_bigint_plugin", [], []))
    patched = with_apple_swiftpm_deps(content, "spm_bigint_plugin", [], ["@deps__swiftpm-bigint//:BigInt"])
    asserts.true(env, patched != content)
    asserts.equals(env, 2, len(patched.split("@deps__swiftpm-bigint//:BigInt")) - 1)
    asserts.equals(env, 2, len(patched.split("    deps = [\n")) - 1)
    asserts.equals(env, 2, len(patched.split("    visibility = [")) - 1)
    return unittest.end(env)

def _plugin_defines_render_on_both_backends_test_impl(ctx):
    env = unittest.begin(ctx)
    srcs_dirs = ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"]
    base = apple_plugin_targets("spm_bigint_plugin", srcs_dirs, [], "ios")
    defines = ["PERMISSION_CAMERA=1", "PERMISSION_MICROPHONE"]
    content = apple_plugin_targets(
        "spm_bigint_plugin",
        srcs_dirs,
        [],
        "ios",
        plugin_defines = defines,
    )
    defines_block = "    plugin_defines = {},\n".format(starlark_string_literal(defines))
    asserts.equals(env, 2, content.count(defines_block))
    asserts.equals(
        env,
        base.replace("    includes = [],\n", "    includes = [],\n" + defines_block),
        content,
    )
    asserts.equals(env, base, apple_plugin_targets("spm_bigint_plugin", srcs_dirs, [], "ios"))
    return unittest.end(env)

def _mapped_product_resolves_without_pins_test_impl(ctx):
    env = unittest.begin(ctx)
    mapped = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
        {"bigint:BigInt": "//:bigint_group"},
    )
    asserts.true(env, mapped.ok)
    asserts.equals(env, ["//:bigint_group"], mapped.labels)

    # A resolved file that does not pin the package cannot override the map.
    mapped_over_unpinned = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(pinned = []),
        {"bigint:BigInt": "//:bigint_group"},
    )
    asserts.true(env, mapped_over_unpinned.ok)
    asserts.equals(env, ["//:bigint_group"], mapped_over_unpinned.labels)
    return unittest.end(env)

def _unmapped_product_without_resolved_keeps_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "swift_package_resolved" in selected.error)
    asserts.true(env, selected.error.endswith(_BIGINT_MAP_HINT))
    return unittest.end(env)

def _unpinned_product_gains_the_mapping_hint_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(pinned = []),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "Package.resolved" in selected.error)
    asserts.true(env, selected.error.endswith(_BIGINT_MAP_HINT))
    return unittest.end(env)

def _conditioned_out_product_is_not_mapped_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _CONDITIONED_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(pinned = ["bigint"]),
        {"maconly:MacOnly": "//:mac_group"},
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], selected.labels)
    return unittest.end(env)

def _mapping_identity_case_insensitive_product_exact_test_impl(ctx):
    env = unittest.begin(ctx)
    mapped = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
        {"BigInt:BigInt": "//:bigint_group"},
    )
    asserts.true(env, mapped.ok)
    asserts.equals(env, ["//:bigint_group"], mapped.labels)

    wrong_product_case = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
        {"bigint:BIGINT": "//:bigint_group"},
    )
    asserts.true(env, not wrong_product_case.ok)
    asserts.true(env, wrong_product_case.error.endswith(_BIGINT_MAP_HINT))
    return unittest.end(env)

def _unfetchable_pin_keeps_reason_without_hint_test_impl(ctx):
    env = unittest.begin(ctx)
    reason = "deps__swiftpm-bigint: SwiftPM package \"bigint\" cannot be fetched: test reason."
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(unpinned = {"bigint": reason}),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, reason in selected.error)
    asserts.true(env, "Map it with" not in selected.error)
    return unittest.end(env)

_BYNAME_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")],
    targets: [.target(name: "spm_bigint_plugin", dependencies: [DEPS])],
)
"""

def _select_byname(deps, manifest = _BYNAME_MANIFEST, product_deps = {}):
    return select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        manifest.replace("DEPS", deps),
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
        product_deps,
    )

def _byname_product_links_like_product_test_impl(ctx):
    env = unittest.begin(ctx)
    for spelling in ['"BigInt"', '.byName(name: "BigInt")']:
        selected = _select_byname(spelling)
        asserts.true(env, selected.ok, selected.error)
        asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], selected.labels)
    return unittest.end(env)

def _byname_of_own_target_links_nothing_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = _BYNAME_MANIFEST.replace("    targets: [", '    targets: [.target(name: "Helper"), ')
    selected = _select_byname('"Helper", .target(name: "Missing")', manifest)
    asserts.true(env, selected.ok, selected.error)
    asserts.equals(env, [], selected.labels)
    return unittest.end(env)

def _ambiguous_byname_names_plugin_dep_and_fix_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = _BYNAME_MANIFEST.replace("dependencies: [.package(", 'dependencies: [.package(url: "https://example.com/Other.git", exact: "1.0.0"), .package(')
    selected = _select_byname('"BigInt"', manifest)
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, '"BigInt"' in selected.error)
    asserts.true(env, ".product(name:" in selected.error)

    mapped = _select_byname('"BigInt"', manifest, {"bigint:BigInt": "//:bigint_group"})
    asserts.true(env, mapped.ok, mapped.error)
    asserts.equals(env, ["//:bigint_group"], mapped.labels)
    return unittest.end(env)

def _unresolvable_byname_fails_the_fetch_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = _BYNAME_MANIFEST.replace('dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")],', "")
    selected = _select_byname('"Nope"', manifest)
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, '"Nope"' in selected.error)
    return unittest.end(env)

def _spaced_package_declaration_is_refused_when_unreadable_test_impl(ctx):
    env = unittest.begin(ctx)
    prefix = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"p\", dependencies: ["
    for spelling in [".package (url: bigIntUrl)", ".package\n(url: bigIntUrl)", ". package(url: bigIntUrl)"]:
        selected = _select_byname("", prefix + spelling + "])\n")
        asserts.true(env, not selected.ok, spelling)
        asserts.true(env, "spm_bigint_plugin" in selected.error, spelling)

    commented = "// swift-tools-version: 5.9\n// .package(url: x)\nlet s = \".package (\"\nlet package = Package(\n"
    selected = _select_byname("", commented)
    asserts.true(env, selected.ok, selected.error)
    asserts.equals(env, [], selected.labels)
    return unittest.end(env)

def _fake_spoke_ctx(files, dirs):
    """Build a fake spoke repository context backed by `files` and `dirs`."""

    def _path(rel):
        """Fake `ctx.path` entry for `rel`."""
        key = str(rel)
        children = [struct(basename = name, is_dir = is_d) for name, is_d in dirs.get(key, [])]
        return struct(
            exists = key in files or key in dirs,
            is_dir = key in dirs,
            basename = key[key.rfind("/") + 1:],
            readdir = lambda: children,
        )

    return struct(
        attr = struct(
            plugin_native_deps = None,
            podfile_lock = None,
            package_resolved = "//:Package.resolved",
            package_sha256 = "//:package_sha256.json",
            ios_native_deps = None,
            hub_name = "deps",
            lock_packages = ["spm_bigint_plugin"],
            pubspec_lock = "//:pubspec.lock",
            scc_targets = {},
            plugin_defines = [],
        ),
        path = _path,
        read = lambda rel: files[str(rel)],
    )

def _apply_apple_native_deps_byname_product_test_impl(ctx):
    """`apply_apple_native_deps` links a by-name product without a local-walk refusal."""
    env = unittest.begin(ctx)
    manifest = _BYNAME_MANIFEST.replace(
        "    targets: [",
        '    targets: [.target(name: "Helper"), ',
    ).replace("DEPS", '"BigInt", .byName(name: "BigInt"), "Helper"')
    fake = _fake_spoke_ctx(
        files = {
            "//:Package.resolved": _BIGINT_RESOLVED,
            "//:package_sha256.json": '{"bigint": "%s"}' % _BIGINT_SHA,
            "ios/spm_bigint_plugin/Package.swift": manifest,
            "ios/spm_bigint_plugin/Sources/Helper/Helper.swift": "public enum Helper {}\n",
        },
        dirs = {
            "ios/spm_bigint_plugin/Sources": [("spm_bigint_plugin", True), ("Helper", True)],
            "ios/spm_bigint_plugin/Sources/Helper": [("Helper.swift", False)],
        },
    )
    srcs = ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"]
    apple = struct(macos_srcs = [], ios_srcs = srcs, macos_podspec = None, ios_podspec = None)
    base = apple_plugin_targets("spm_bigint_plugin", srcs, [], "ios")
    rendered = apply_apple_native_deps(fake, "spm_bigint_plugin", apple, base)
    asserts.equals(env, 2, len(rendered.split("@deps__swiftpm-bigint//:BigInt")) - 1)
    asserts.true(env, '":spm_bigint_plugin_apple_ios__Helper",' in rendered)
    asserts.true(env, '"ios/spm_bigint_plugin/Sources/Helper/Helper.swift",' in rendered)
    return unittest.end(env)

def _helper_spoke(primary_deps, helper_deps, extra_targets = ""):
    """Run `apply_apple_native_deps` on a manifest whose `Helper` target has deps."""
    manifest = _BYNAME_MANIFEST.replace(
        "    targets: [",
        '    targets: [.target(name: "Helper", dependencies: [%s]), %s' % (helper_deps, extra_targets),
    ).replace("DEPS", primary_deps)
    fake = _fake_spoke_ctx(
        files = {
            "//:Package.resolved": _BIGINT_RESOLVED,
            "//:package_sha256.json": '{"bigint": "%s"}' % _BIGINT_SHA,
            "ios/spm_bigint_plugin/Package.swift": manifest,
            "ios/spm_bigint_plugin/Sources/Helper/Helper.swift": "public enum Helper {}\n",
            "ios/spm_bigint_plugin/Sources/Other/Other.swift": "public enum Other {}\n",
        },
        dirs = {
            "ios/spm_bigint_plugin/Sources": [("spm_bigint_plugin", True), ("Helper", True), ("Other", True)],
            "ios/spm_bigint_plugin/Sources/Helper": [("Helper.swift", False)],
            "ios/spm_bigint_plugin/Sources/Other": [("Other.swift", False)],
        },
    )
    srcs = ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"]
    apple = struct(macos_srcs = [], ios_srcs = srcs, macos_podspec = None, ios_podspec = None)
    base = apple_plugin_targets("spm_bigint_plugin", srcs, [], "ios")
    return apply_apple_native_deps(fake, "spm_bigint_plugin", apple, base)

def _helper_spoke_impl(ctx):
    """Rule body: runs the spoke wiring so its `fail` surfaces at analysis."""
    _helper_spoke(ctx.attr.primary_deps, ctx.attr.helper_deps)
    return [DefaultInfo()]

_helper_spoke_rule = rule(
    implementation = _helper_spoke_impl,
    attrs = {
        "helper_deps": attr.string(),
        "primary_deps": attr.string(),
    },
)

def _expect_refusal_test_impl(ctx):
    """The spoke fetch fails with every expected substring."""
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_expect_refusal_test = analysistest.make(
    _expect_refusal_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
)

def _refusal_tests(name):
    """Registers the refused-sibling-product analysis tests; returns their labels."""
    labels = []
    for index, spelling in enumerate(['"BigInt"', '.product(name: "BigInt", package: "BigInt")']):
        spoke = "%s_spoke_%d" % (name, index)
        _helper_spoke_rule(name = spoke, primary_deps = '"Helper"', helper_deps = spelling, tags = ["manual"])
        _expect_refusal_test(
            name = "%s_refused_%d" % (name, index),
            target_under_test = ":" + spoke,
            expected_substrings = [
                'Flutter plugin "spm_bigint_plugin"',
                'of target "Helper"',
                '"BigInt"',
                '`.product(name: "BigInt", package: "<package>")` on the primary target, or link it there',
            ],
        )
        labels.append(":%s_refused_%d" % (name, index))
    return labels

def _linked_sibling_product_renders_as_base_test_impl(ctx):
    """A product the primary also links is not refused and links once."""
    env = unittest.begin(ctx)
    for primary in ['.product(name: "BigInt", package: "BigInt"), "Helper"', '"BigInt", "Helper"']:
        rendered = _helper_spoke(primary, '"BigInt"')
        asserts.equals(env, _helper_spoke(primary, ""), rendered)
        asserts.equals(env, 2, len(rendered.split("@deps__swiftpm-bigint//:BigInt")) - 1)
        asserts.true(env, '":spm_bigint_plugin_apple_ios__Helper",' in rendered)
    return unittest.end(env)

def _sibling_local_and_conditioned_deps_not_refused_test_impl(ctx):
    """A by-name local target, a conditioned-out product and FlutterFramework pass."""
    env = unittest.begin(ctx)
    helper = '"Other", .product(name: "BigInt", package: "BigInt", condition: .when(platforms: [.macOS])), ' + \
             '.product(name: "FlutterFramework", package: "FlutterFramework")'
    rendered = _helper_spoke('"Helper"', helper, '.target(name: "Other"), ')
    asserts.true(env, '":spm_bigint_plugin_apple_ios__Helper",' in rendered)
    asserts.equals(env, 0, len(rendered.split("@deps__swiftpm-bigint//:BigInt")) - 1)
    return unittest.end(env)

_products_resolve_to_pinned_labels_test = unittest.make(_products_resolve_to_pinned_labels_test_impl)
_mapped_product_resolves_without_pins_test = unittest.make(_mapped_product_resolves_without_pins_test_impl)
_unmapped_product_without_resolved_keeps_refusal_test = unittest.make(
    _unmapped_product_without_resolved_keeps_refusal_test_impl,
)
_unpinned_product_gains_the_mapping_hint_test = unittest.make(_unpinned_product_gains_the_mapping_hint_test_impl)
_conditioned_out_product_is_not_mapped_test = unittest.make(_conditioned_out_product_is_not_mapped_test_impl)
_mapping_identity_case_insensitive_product_exact_test = unittest.make(
    _mapping_identity_case_insensitive_product_exact_test_impl,
)
_unfetchable_pin_keeps_reason_without_hint_test = unittest.make(_unfetchable_pin_keeps_reason_without_hint_test_impl)
_conditions_filter_per_platform_test = unittest.make(_conditions_filter_per_platform_test_impl)
_flutterframework_product_is_skipped_test = unittest.make(_flutterframework_product_is_skipped_test_impl)
_template_manifest_builds_without_link_test = unittest.make(_template_manifest_builds_without_link_test_impl)
_real_world_manifest_settings_still_link_test = unittest.make(_real_world_manifest_settings_still_link_test_impl)
_template_settings_leave_links_unchanged_test = unittest.make(_template_settings_leave_links_unchanged_test_impl)
_flutterframework_first_names_real_package_test = unittest.make(_flutterframework_first_names_real_package_test_impl)
_conditional_dependencies_still_refused_test = unittest.make(_conditional_dependencies_still_refused_test_impl)
_undeclared_package_fails_test = unittest.make(_undeclared_package_fails_test_impl)
_path_package_fails_test = unittest.make(_path_package_fails_test_impl)
_unpinned_package_fails_test = unittest.make(_unpinned_package_fails_test_impl)
_missing_checksum_refuses_the_plugin_test = unittest.make(_missing_checksum_refuses_the_plugin_test_impl)
_pinned_checksum_still_links_the_product_test = unittest.make(_pinned_checksum_still_links_the_product_test_impl)
_unfetchable_pin_reports_its_reason_test = unittest.make(_unfetchable_pin_reports_its_reason_test_impl)
_missing_resolved_fails_test = unittest.make(_missing_resolved_fails_test_impl)
_unreadable_manifest_without_packages_builds_on_test = unittest.make(_unreadable_manifest_without_packages_builds_on_test_impl)
_byname_product_links_like_product_test = unittest.make(_byname_product_links_like_product_test_impl)
_byname_of_own_target_links_nothing_test = unittest.make(_byname_of_own_target_links_nothing_test_impl)
_ambiguous_byname_names_plugin_dep_and_fix_test = unittest.make(_ambiguous_byname_names_plugin_dep_and_fix_test_impl)
_unresolvable_byname_fails_the_fetch_test = unittest.make(_unresolvable_byname_fails_the_fetch_test_impl)
_spaced_package_declaration_is_refused_when_unreadable_test = unittest.make(_spaced_package_declaration_is_refused_when_unreadable_test_impl)
_manifests_without_links_resolve_empty_test = unittest.make(_manifests_without_links_resolve_empty_test_impl)
_deps_render_on_both_backends_test = unittest.make(_deps_render_on_both_backends_test_impl)
_plugin_defines_render_on_both_backends_test = unittest.make(_plugin_defines_render_on_both_backends_test_impl)
_apply_apple_native_deps_byname_product_test = unittest.make(_apply_apple_native_deps_byname_product_test_impl)
_linked_sibling_product_renders_as_base_test = unittest.make(_linked_sibling_product_renders_as_base_test_impl)
_sibling_local_and_conditioned_deps_not_refused_test = unittest.make(_sibling_local_and_conditioned_deps_not_refused_test_impl)

def flutter_pub_apple_test_suite(name):
    """Registers the Apple plugin spoke SwiftPM link unit tests."""
    small_unittest_suite(
        name + "_unit",
        _products_resolve_to_pinned_labels_test,
        _mapped_product_resolves_without_pins_test,
        _unmapped_product_without_resolved_keeps_refusal_test,
        _unpinned_product_gains_the_mapping_hint_test,
        _conditioned_out_product_is_not_mapped_test,
        _mapping_identity_case_insensitive_product_exact_test,
        _unfetchable_pin_keeps_reason_without_hint_test,
        _conditions_filter_per_platform_test,
        _flutterframework_product_is_skipped_test,
        _template_manifest_builds_without_link_test,
        _real_world_manifest_settings_still_link_test,
        _template_settings_leave_links_unchanged_test,
        _flutterframework_first_names_real_package_test,
        _conditional_dependencies_still_refused_test,
        _undeclared_package_fails_test,
        _path_package_fails_test,
        _unpinned_package_fails_test,
        _missing_checksum_refuses_the_plugin_test,
        _pinned_checksum_still_links_the_product_test,
        _unfetchable_pin_reports_its_reason_test,
        _missing_resolved_fails_test,
        _unreadable_manifest_without_packages_builds_on_test,
        _byname_product_links_like_product_test,
        _byname_of_own_target_links_nothing_test,
        _ambiguous_byname_names_plugin_dep_and_fix_test,
        _unresolvable_byname_fails_the_fetch_test,
        _spaced_package_declaration_is_refused_when_unreadable_test,
        _manifests_without_links_resolve_empty_test,
        _deps_render_on_both_backends_test,
        _plugin_defines_render_on_both_backends_test,
        _apply_apple_native_deps_byname_product_test,
        _linked_sibling_product_renders_as_base_test,
        _sibling_local_and_conditioned_deps_not_refused_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"] + _refusal_tests(name),
    )
