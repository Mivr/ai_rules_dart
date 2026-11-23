"""Unit tests for the manifest-to-BUILD translator."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:swiftpm_manifest.bzl", "parse_swiftpm_package")
load("//flutter/private:swiftpm_settings.bzl", "swiftpm_render_list_attr", "swiftpm_target_setting_entries")
load(
    "//flutter/private:swiftpm_translate.bzl",
    "swiftpm_c99name",
    "swiftpm_language_mode",
    "swiftpm_url_identity",
    "translate_swiftpm_package",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_BIGINT = """// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "BigInt",
    products: [.library(name: "BigInt", targets: ["BigInt"])],
    targets: [
        .target(name: "BigInt", path: "Sources"),
        .testTarget(name: "BigIntTests", dependencies: ["BigInt"], path: "Tests"),
    ]
)
"""

_MULTI = """// swift-tools-version:5.8
import PackageDescription
let package = Package(
    name: "Multi",
    products: [.library(name: "Everything", targets: ["One", "Two"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(name: "Named", url: "https://example.com/other/RealName.git", branch: "main"),
    ],
    targets: [
        .target(name: "One", dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser"), .product(name: "Thing", package: "Named")]),
        .target(name: "Two", dependencies: ["One"]),
    ],
    swiftLanguageVersions: [.v5],
)
"""

def _bigint_files(name):
    return struct(dir = "BigInt-1/Sources", srcs = ["BigInt-1/Sources/" + name + ".swift"])

def _c99name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "BigInt", swiftpm_c99name("BigInt"))
    asserts.equals(env, "my_pkg_1", swiftpm_c99name("my-pkg.1"))
    asserts.equals(env, "a_b", swiftpm_c99name("a b"))
    return unittest.end(env)

def _language_mode_test_impl(ctx):
    env = unittest.begin(ctx)
    mode = swiftpm_language_mode(6, 0, [])
    asserts.equals(env, (6, 0), (mode.major, mode.minor))
    mode = swiftpm_language_mode(5, 9, [])
    asserts.equals(env, (5, 0), (mode.major, mode.minor))
    mode = swiftpm_language_mode(4, 2, [])
    asserts.equals(env, (4, 2), (mode.major, mode.minor))
    mode = swiftpm_language_mode(6, 0, [struct(major = 5, minor = 0), struct(major = 6, minor = 0)])
    asserts.equals(env, (6, 0), (mode.major, mode.minor))
    mode = swiftpm_language_mode(5, 9, [struct(major = 4, minor = 2)])
    asserts.equals(env, (4, 2), (mode.major, mode.minor))
    asserts.equals(env, "swift-argument-parser", swiftpm_url_identity("https://github.com/apple/swift-argument-parser"))
    asserts.equals(env, "BigInt", swiftpm_url_identity("https://github.com/attaswift/BigInt.git"))
    return unittest.end(env)

def _translates_bigint_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", _BIGINT)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("bigint", "deps", parsed.model, ["bigint"], {"BigInt": _bigint_files("BigInt")})
    asserts.true(env, translated.ok)
    asserts.equals(env, "", translated.error)
    asserts.equals(env, ["BigInt"], translated.names)
    asserts.true(env, "load(\"@rules_swift//swift:swift.bzl\", \"swift_library\", \"swift_library_group\")" in translated.text)
    asserts.true(env, "name = \"BigInt_lib\"" in translated.text)
    asserts.true(env, "module_name = \"BigInt\"" in translated.text)
    asserts.true(env, "package_name = \"bigint\"" in translated.text)
    asserts.true(env, "\"-swift-version\", \"6\"" in translated.text)
    asserts.true(env, "\"BigInt-1/Sources/BigInt.swift\"" in translated.text)
    asserts.true(env, "name = \"BigInt\",\n    actual = \":BigInt_lib\"" in translated.text)
    asserts.true(env, not "BigIntTests" in translated.text)
    return unittest.end(env)

def _translates_groups_and_product_deps_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("multi", _MULTI)
    asserts.true(env, parsed.ok)
    files = {
        "One": struct(dir = "pkg/Sources/One", srcs = ["pkg/Sources/One/a.swift"]),
        "Two": struct(dir = "pkg/Sources/Two", srcs = ["pkg/Sources/Two/b.swift"]),
    }
    translated = translate_swiftpm_package("multi", "deps", parsed.model, ["multi", "swift-argument-parser", "RealName"], files)
    asserts.true(env, translated.ok)
    asserts.equals(env, ["One", "Two"], translated.names)
    asserts.true(env, "swift_library_group(\n    name = \"Everything\"" in translated.text)
    asserts.true(env, "\":One_lib\"" in translated.text)
    asserts.true(env, "\":Two_lib\"" in translated.text)
    asserts.true(env, "\"@deps__swiftpm-swift-argument-parser//:ArgumentParser\"" in translated.text)
    asserts.true(env, "\"@deps__swiftpm-RealName//:Thing\"" in translated.text)
    asserts.true(env, "\":One_lib\"" in translated.text)
    asserts.true(env, "\"-swift-version\", \"5\"" in translated.text)
    asserts.true(env, not "package_name" in translated.text)
    return unittest.end(env)

def _translates_without_pin_list_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("multi", _MULTI)
    asserts.true(env, parsed.ok)
    files = {
        "One": struct(dir = "pkg/Sources/One", srcs = ["pkg/Sources/One/a.swift"]),
        "Two": struct(dir = "pkg/Sources/Two", srcs = ["pkg/Sources/Two/b.swift"]),
    }
    translated = translate_swiftpm_package("multi", "deps", parsed.model, None, files)
    asserts.true(env, translated.ok)
    asserts.true(env, "\"@deps__swiftpm-swift-argument-parser//:ArgumentParser\"" in translated.text)
    asserts.true(env, "\"@deps__swiftpm-realname//:Thing\"" in translated.text)
    return unittest.end(env)

def _unpinned_product_dep_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("multi", _MULTI)
    translated = translate_swiftpm_package("multi", "deps", parsed.model, ["multi"], {
        "One": struct(dir = "d", srcs = ["d/a.swift"]),
        "Two": struct(dir = "d", srcs = ["d/b.swift"]),
    })
    asserts.true(env, not translated.ok)
    asserts.true(env, "not pinned in Package.resolved" in translated.error)
    asserts.true(env, "swift-argument-parser" in translated.error)
    return unittest.end(env)

def _special_target_refusal_points_at_overrides_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Blobby",
    products: [.library(name: "Blobby", targets: ["Blobby", "Blob"])],
    targets: [.target(name: "Blobby"), .binaryTarget(name: "Blob", url: "https://example.com/b.zip", checksum: "abc")],
)
"""
    parsed = parse_swiftpm_package("blobby", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("blobby", "deps", parsed.model, ["blobby"], {"Blobby": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, not translated.ok)
    asserts.true(env, "binary target" in translated.error)
    asserts.true(env, "swift_package_build_files[\"blobby\"]" in translated.error)

    # The same package translates once the binary target is unreachable.
    manifest = manifest.replace('"Blobby", "Blob"', '"Blobby"')
    parsed = parse_swiftpm_package("blobby", manifest)
    translated = translate_swiftpm_package("blobby", "deps", parsed.model, ["blobby"], {"Blobby": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, translated.ok)
    return unittest.end(env)

def _unknown_target_dep_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Broken",
    products: [.library(name: "Broken", targets: ["Broken"])],
    targets: [.target(name: "Broken", dependencies: ["Missing"])],
)
"""
    parsed = parse_swiftpm_package("broken", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("broken", "deps", parsed.model, ["broken"], {"Broken": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, not translated.ok)
    asserts.true(env, "unknown target" in translated.error)
    asserts.true(env, "not supported" in translated.error)
    asserts.true(env, ".product(name:" in translated.error)
    asserts.true(env, "swift_package_build_files" in translated.error)
    return unittest.end(env)

def _renamed_single_target_product_aliases_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Renamed",
    products: [.library(name: "Renamed", targets: ["Inner"])],
    targets: [.target(name: "Inner")],
)
"""
    parsed = parse_swiftpm_package("renamed", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("renamed", "deps", parsed.model, ["renamed"], {"Inner": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, translated.ok)
    asserts.true(env, "name = \"Renamed\",\n    actual = \":Inner_lib\"" in translated.text)
    return unittest.end(env)

def _case_insensitive_same_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Cased",
    products: [.library(name: "Cased", targets: ["Two"])],
    targets: [.target(name: "One"), .target(name: "Two", dependencies: ["one"])],
)
"""
    parsed = parse_swiftpm_package("cased", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("cased", "deps", parsed.model, ["cased"], {
        "One": struct(dir = "d", srcs = ["d/a.swift"]),
        "Two": struct(dir = "d", srcs = ["d/b.swift"]),
    })
    asserts.true(env, translated.ok)
    asserts.equals(env, ["One", "Two"], translated.names)
    asserts.true(env, "\":One_lib\"" in translated.text)
    return unittest.end(env)

def _case_insensitive_product_package_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "mixed",
    products: [.library(name: "mixed", targets: ["mixed"])],
    dependencies: [.package(url: "https://github.com/Apple/SwiftArgumentParser.git", from: "1.2.0")],
    targets: [.target(name: "mixed", dependencies: [.product(name: "ArgumentParser", package: "SWIFTARGUMENTPARSER")])],
)
"""
    parsed = parse_swiftpm_package("mixed", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("mixed", "deps", parsed.model, ["mixed", "swiftargumentparser"], {"mixed": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, translated.ok)
    asserts.true(env, "\"@deps__swiftpm-swiftargumentparser//:ArgumentParser\"" in translated.text)
    return unittest.end(env)

def _product_naming_test_target_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", _BIGINT.replace('targets: ["BigInt"]', 'targets: ["BigIntTests"]'))
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("bigint", "deps", parsed.model, ["bigint"], {"BigInt": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, not translated.ok)
    asserts.true(env, "test target" in translated.error)
    return unittest.end(env)

def _same_dep_onto_test_target_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Testing",
    products: [.library(name: "Testing", targets: ["Testing"])],
    targets: [.target(name: "Testing", dependencies: ["TestingTests"]), .testTarget(name: "TestingTests")],
)
"""
    parsed = parse_swiftpm_package("testing", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("testing", "deps", parsed.model, ["testing"], {"Testing": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, not translated.ok)
    asserts.true(env, "test target" in translated.error)
    return unittest.end(env)

def _executable_target_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Tooling",
    products: [.library(name: "Tooling", targets: ["Tool"])],
    targets: [.executableTarget(name: "Tool")],
)
"""
    parsed = parse_swiftpm_package("tooling", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("tooling", "deps", parsed.model, ["tooling"], {})
    asserts.true(env, not translated.ok)
    asserts.true(env, "executable target" in translated.error)
    asserts.true(env, "swift_package_build_files[\"tooling\"]" in translated.error)
    return unittest.end(env)

_c99name_test = unittest.make(_c99name_test_impl)
_language_mode_test = unittest.make(_language_mode_test_impl)
_translates_bigint_test = unittest.make(_translates_bigint_test_impl)
_translates_groups_and_product_deps_test = unittest.make(_translates_groups_and_product_deps_test_impl)
_translates_without_pin_list_test = unittest.make(_translates_without_pin_list_test_impl)
_unpinned_product_dep_fails_test = unittest.make(_unpinned_product_dep_fails_test_impl)
_special_target_refusal_points_at_overrides_test = unittest.make(_special_target_refusal_points_at_overrides_test_impl)
_unknown_target_dep_fails_test = unittest.make(_unknown_target_dep_fails_test_impl)
_renamed_single_target_product_aliases_test = unittest.make(_renamed_single_target_product_aliases_test_impl)
_case_insensitive_same_dep_test = unittest.make(_case_insensitive_same_dep_test_impl)
_case_insensitive_product_package_test = unittest.make(_case_insensitive_product_package_test_impl)
_product_naming_test_target_fails_test = unittest.make(_product_naming_test_target_fails_test_impl)
_same_dep_onto_test_target_fails_test = unittest.make(_same_dep_onto_test_target_fails_test_impl)
_executable_target_refusal_test = unittest.make(_executable_target_refusal_test_impl)

def swiftpm_translate_test_suite(name):
    """Registers the translator unit tests."""
    small_unittest_suite(
        name + "_unit",
        _c99name_test,
        _language_mode_test,
        _translates_bigint_test,
        _translates_groups_and_product_deps_test,
        _translates_without_pin_list_test,
        _unpinned_product_dep_fails_test,
        _special_target_refusal_points_at_overrides_test,
        _unknown_target_dep_fails_test,
        _renamed_single_target_product_aliases_test,
        _case_insensitive_same_dep_test,
        _case_insensitive_product_package_test,
        _product_naming_test_target_fails_test,
        _same_dep_onto_test_target_fails_test,
        _executable_target_refusal_test,
        _conditioned_dep_select_test,
        _dropped_dep_stays_out_test,
        _swift_settings_emit_test,
        _swift_define_is_target_local_test,
        _clang_target_emit_test,
        _c_family_define_attrs_test,
        _header_search_path_is_target_local_test,
        _header_search_path_is_normalized_test,
        _generated_map_emit_test,
        _generated_map_forms_emit_test,
        _mixed_source_refusal_test,
        _mixed_c_family_translates_test,
        _assembly_refusal_names_file_test,
        _private_headers_in_srcs_test,
        _select_attr_separator_test,
        _multi_select_emit_separator_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )

def _conditioned_dep_select_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Cond",
    products: [.library(name: "Cond", targets: ["Cond"])],
    dependencies: [.package(url: "https://example.com/Dep.git", from: "1.0.0")],
    targets: [.target(name: "Cond", dependencies: [.product(name: "Dp", package: "Dep", condition: .when(platforms: [.iOS])), "Help", .target(name: "Both", condition: .when(platforms: [.iOS, .macOS]))]), .target(name: "Help"), .target(name: "Both")],
)
"""
    parsed = parse_swiftpm_package("cond", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("cond", "deps", parsed.model, ["cond", "dep"], {
        "Cond": struct(dir = "d", srcs = ["d/a.swift"]),
        "Help": struct(dir = "d", srcs = ["d/h.swift"]),
        "Both": struct(dir = "d", srcs = ["d/b.swift"]),
    })
    asserts.true(env, translated.ok)
    asserts.equals(env, ["Cond", "Help", "Both"], translated.names)
    asserts.true(env, "\"@deps__swiftpm-dep//:Dp\"" in translated.text)
    asserts.true(env, "\":Help_lib\"" in translated.text)
    asserts.true(env, "\":Both_lib\"" in translated.text)
    asserts.true(env, "select({" in translated.text)
    asserts.true(env, "\"@platforms//os:ios\"" in translated.text)
    asserts.true(env, "\"//conditions:default\": []" in translated.text)
    asserts.true(env, not "@platforms//os:macos" in translated.text)
    return unittest.end(env)

_conditioned_dep_select_test = unittest.make(_conditioned_dep_select_test_impl)

_DROPPED_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Drop",
    products: [.library(name: "Drop", targets: ["Drop"])],
    targets: [.target(name: "Drop", dependencies: [.target(name: "Gone", condition: .when(platforms: [.tvOS])), .target(name: "Kept", condition: .when(platforms: [.tvOS, .macOS]))]), .target(name: "Gone"), .target(name: "Kept")],
)
"""

def _dropped_dep_stays_out_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("drop", _DROPPED_MANIFEST)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("drop", "deps", parsed.model, ["drop"], {
        "Drop": struct(dir = "d", srcs = ["d/a.swift"]),
        "Kept": struct(dir = "d", srcs = ["d/k.swift"]),
    })
    asserts.true(env, translated.ok)
    asserts.equals(env, ["Drop", "Kept"], translated.names)
    asserts.true(env, not ":Gone_lib" in translated.text)
    asserts.true(env, "\":Kept_lib\"" in translated.text)
    asserts.true(env, "\"@platforms//os:macos\"" in translated.text)
    return unittest.end(env)

_dropped_dep_stays_out_test = unittest.make(_dropped_dep_stays_out_test_impl)

_SETTINGS_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Set",
    products: [.library(name: "Set", targets: ["Set"])],
    targets: [.target(name: "Set", swiftSettings: [.define("SWIFT_FOO"), .enableUpcomingFeature("Existentials"), .enableExperimentalFeature("X", .when(platforms: [.macOS]))], linkerSettings: [.linkedLibrary("z"), .linkedFramework("CoreGraphics")])],
)
"""

def _swift_settings_emit_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("set", _SETTINGS_MANIFEST)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("set", "deps", parsed.model, ["set"], {"Set": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, translated.ok)
    asserts.true(env, "\"-DSWIFT_FOO\"" in translated.text)
    asserts.true(env, not "defines = [" in translated.text)
    asserts.true(env, "\"-enable-upcoming-feature\"" in translated.text)
    asserts.true(env, "\"Existentials\"" in translated.text)
    asserts.true(env, "\"@platforms//os:macos\"" in translated.text)
    asserts.true(env, "\"-enable-experimental-feature\"" in translated.text)
    asserts.true(env, "\"-lz\"" in translated.text)
    asserts.true(env, "\"-framework\"" in translated.text)
    asserts.true(env, "\"CoreGraphics\"" in translated.text)
    return unittest.end(env)

_swift_settings_emit_test = unittest.make(_swift_settings_emit_test_impl)

_SWIFT_DEFINE_LOCALITY_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Defs",
    products: [.library(name: "Defs", targets: ["Defs"])],
    targets: [.target(name: "Defs", dependencies: ["User"], swiftSettings: [.define("PLAIN_DEFINE"), .define("GATED_DEFINE", .when(platforms: [.iOS]))]), .target(name: "User")],
)
"""

def _swift_define_is_target_local_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("defs", _SWIFT_DEFINE_LOCALITY_MANIFEST)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("defs", "deps", parsed.model, ["defs"], {
        "Defs": struct(dir = "d", srcs = ["d/a.swift"]),
        "User": struct(dir = "d", srcs = ["d/u.swift"]),
    })
    asserts.true(env, translated.ok)
    asserts.true(env, "\"-DPLAIN_DEFINE\"" in translated.text)
    asserts.true(env, not "defines = [" in translated.text)
    asserts.true(env, "\"-DGATED_DEFINE\"" in translated.text)
    asserts.true(env, "select({" in translated.text)
    asserts.true(env, "\"@platforms//os:ios\"" in translated.text)
    return unittest.end(env)

_swift_define_is_target_local_test = unittest.make(_swift_define_is_target_local_test_impl)

_CLANG_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Shims",
    products: [.library(name: "Shims", targets: ["Shims"])],
    targets: [.target(name: "Shims", dependencies: [.target(name: "Help", condition: .when(platforms: [.iOS]))], cSettings: [.define("SHIMMED"), .headerSearchPath("detail")]), .target(name: "Help")],
)
"""

def _clang_files():
    return {
        "Shims": struct(dir = "pkg/Sources/Shims", srcs = [], c_srcs = ["pkg/Sources/Shims/Shims.c"], public_hdrs = ["pkg/Sources/Shims/include/Shims.h"], private_hdrs = ["pkg/Sources/Shims/secret.h"], explicit_map = "pkg/Sources/Shims/include/module.modulemap", map_in_include = True),
        "Help": struct(dir = "pkg/Sources/Help", srcs = ["pkg/Sources/Help/Help.swift"]),
    }

def _clang_target_emit_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("shims", _CLANG_MANIFEST)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("shims", "deps", parsed.model, ["shims"], _clang_files())
    asserts.true(env, translated.ok)
    asserts.equals(env, ["Shims", "Help"], translated.names)
    asserts.true(env, "load(\"@rules_cc//cc:cc_library.bzl\", \"cc_library\")" in translated.text)
    asserts.true(env, "cc_library(" in translated.text)
    asserts.true(env, "name = \"Shims_lib\"" in translated.text)
    asserts.true(env, "\"pkg/Sources/Shims/Shims.c\"" in translated.text)
    asserts.true(env, "\"pkg/Sources/Shims/include/Shims.h\"" in translated.text)
    asserts.true(env, "\"pkg/Sources/Shims/secret.h\"" in translated.text)
    asserts.true(env, "swift_interop_hint" in translated.text)
    asserts.true(env, "module_name = \"Shims\"" in translated.text)
    asserts.true(env, "module_map = \"pkg/Sources/Shims/include/module.modulemap\"" in translated.text)
    asserts.true(env, "\"pkg/Sources/Shims/include\"" in translated.text)
    asserts.true(env, "\"pkg/Sources/Shims/detail\"" in translated.text)
    asserts.true(env, "\"-DSHIMMED\"" in translated.text)
    asserts.true(env, "\"@platforms//os:ios\"" in translated.text)
    asserts.true(env, "\":Help_lib\"" in translated.text)
    asserts.true(env, "tags = [\"manual\"]" in translated.text)
    return unittest.end(env)

_clang_target_emit_test = unittest.make(_clang_target_emit_test_impl)

_DEFINE_SETTINGS_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Defs",
    products: [.library(name: "Defs", targets: ["Defs"])],
    targets: [.target(name: "Defs", cSettings: [.define("C_DEFINE", to: "7")], cxxSettings: [.define("CXX_DEFINE", to: "9")])],
)
"""

def _c_family_define_attrs_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("defs", _DEFINE_SETTINGS_MANIFEST)
    asserts.true(env, parsed.ok)
    files = {
        "Defs": struct(
            dir = "pkg/Sources/Defs",
            srcs = [],
            c_srcs = ["pkg/Sources/Defs/Defs.m"],
            public_hdrs = [],
            private_hdrs = [],
            explicit_map = None,
            map_in_include = False,
        ),
    }
    translated = translate_swiftpm_package("defs", "deps", parsed.model, ["defs"], files)
    asserts.true(env, translated.ok)
    block = _rule_block(translated.text, "Defs_lib")
    asserts.true(env, block != "")
    asserts.true(env, "copts = [" in block)
    asserts.true(env, "\"-DC_DEFINE=7\"" in block)
    asserts.true(env, "conlyopts = " not in block)
    asserts.true(env, "defines = " not in block)
    asserts.true(env, "cxxopts = [" in block)
    asserts.true(env, "\"-DCXX_DEFINE=9\"" in block)
    return unittest.end(env)

_c_family_define_attrs_test = unittest.make(_c_family_define_attrs_test_impl)

_HEADER_LOCALITY_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Shims",
    products: [.library(name: "Shims", targets: ["Shims"])],
    targets: [.target(name: "Shims", cSettings: [.headerSearchPath("detail"), .headerSearchPath("gated", .when(platforms: [.macOS])), .define("PRIVATE_DEFINE")], cxxSettings: [.headerSearchPath("cxx_detail")])],
)
"""

def _rule_block(text, name):
    """Return the rendered rule block carrying `name = "<name>"`.

    Args:
        text: The generated BUILD text.
        name: The rule name to find.

    Returns:
        The block, or "" when no block names it.
    """
    needle = "name = \"{name}\"".format(name = name)
    for block in text.split("\n\n"):
        if needle in block:
            return block
    return ""

def _header_search_path_is_target_local_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("shims", _HEADER_LOCALITY_MANIFEST)
    asserts.true(env, parsed.ok)
    files = {
        "Shims": struct(dir = "pkg/Sources/Shims", srcs = [], c_srcs = ["pkg/Sources/Shims/Shims.c"], public_hdrs = ["pkg/Sources/Shims/include/Shims.h"], private_hdrs = ["pkg/Sources/Shims/secret.h", "pkg/Sources/Shims/detail/config.h"], explicit_map = None, map_in_include = False),
    }
    translated = translate_swiftpm_package("shims", "deps", parsed.model, ["shims"], files)
    asserts.true(env, translated.ok)
    main = _rule_block(translated.text, "Shims_lib")
    helper = _rule_block(translated.text, "Shims_lib_private_headers")
    asserts.true(env, main != "")
    asserts.true(env, helper != "")
    asserts.true(env, "implementation_deps = [\":Shims_lib_private_headers\"]" in main)
    asserts.true(env, not "\"pkg/Sources/Shims/detail\"" in main)
    asserts.true(env, not "\"pkg/Sources/Shims/gated\"" in main)
    asserts.true(env, not "\"pkg/Sources/Shims/cxx_detail\"" in main)
    asserts.true(env, "\"pkg/Sources/Shims/detail\"" in helper)
    asserts.true(env, "\"pkg/Sources/Shims/gated\"" in helper)
    asserts.true(env, "\"pkg/Sources/Shims/cxx_detail\"" in helper)
    asserts.true(env, "\"@platforms//os:macos\"" in helper)
    asserts.true(env, "\"pkg/Sources/Shims/include\"" in main)
    asserts.true(env, "\"-DPRIVATE_DEFINE\"" in main)
    return unittest.end(env)

_header_search_path_is_target_local_test = unittest.make(_header_search_path_is_target_local_test_impl)

_HEADER_SEARCH_NORMALIZED_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Shims",
    products: [.library(name: "Shims", targets: ["Shims"])],
    targets: [.target(name: "Shims", cSettings: [.headerSearchPath("./x"), .headerSearchPath("")])],
)
"""

_HEADER_SEARCH_ESCAPE_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Shims",
    products: [.library(name: "Shims", targets: ["Shims"])],
    targets: [.target(name: "Shims", cSettings: [.headerSearchPath("../x")])],
)
"""

def _header_search_path_is_normalized_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("shims", _HEADER_SEARCH_NORMALIZED_MANIFEST)
    asserts.true(env, parsed.ok)
    entries = swiftpm_target_setting_entries(parsed.model.targets[0], "pkg/Sources/Shims", "clang")
    asserts.true(env, entries.ok)
    asserts.equals(env, ["pkg/Sources/Shims/x", "pkg/Sources/Shims"], [entry.text for entry in entries.private_includes if entry.platforms == None])
    escaped = parse_swiftpm_package("shims", _HEADER_SEARCH_ESCAPE_MANIFEST)
    asserts.true(env, escaped.ok)
    entries = swiftpm_target_setting_entries(escaped.model.targets[0], "pkg/Sources/Shims", "clang")
    asserts.true(env, not entries.ok)
    asserts.true(env, "escapes the target directory" in entries.detail)
    return unittest.end(env)

_header_search_path_is_normalized_test = unittest.make(_header_search_path_is_normalized_test_impl)

_GENERATED_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Gen",
    products: [.library(name: "Gen", targets: ["Gen"])],
    targets: [.target(name: "Gen", publicHeadersPath: "include")],
)
"""

def _generated_map_emit_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("gen", _GENERATED_MANIFEST)
    asserts.true(env, parsed.ok)
    files = {
        "Gen": struct(dir = "pkg/Sources/Gen", srcs = [], c_srcs = ["pkg/Sources/Gen/Gen.c"], public_hdrs = ["pkg/Sources/Gen/include/Gen.h"], private_hdrs = [], explicit_map = None, map_in_include = False),
    }
    translated = translate_swiftpm_package("gen", "deps", parsed.model, ["gen"], files)
    asserts.true(env, translated.ok)
    asserts.true(env, "module_name = \"Gen\"" in translated.text)
    asserts.true(env, "module_map = \"pkg/Sources/Gen/include/module.modulemap\"" in translated.text)
    asserts.true(env, "\"pkg/Sources/Gen/include\"" in translated.text)
    return unittest.end(env)

_generated_map_emit_test = unittest.make(_generated_map_emit_test_impl)

def _generated_map_forms_emit_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("gen", _GENERATED_MANIFEST)
    asserts.true(env, parsed.ok)

    # `<public>/<c99name>.h` umbrella-header form.
    files = {
        "Gen": struct(dir = "pkg/Sources/Gen", srcs = [], c_srcs = ["pkg/Sources/Gen/Gen.c"], public_hdrs = ["pkg/Sources/Gen/include/Gen.h", "pkg/Sources/Gen/include/Other.h"], private_hdrs = [], explicit_map = None, map_in_include = False),
    }
    translated = translate_swiftpm_package("gen", "deps", parsed.model, ["gen"], files)
    asserts.true(env, translated.ok)
    asserts.true(env, "module_map = \"pkg/Sources/Gen/include/module.modulemap\"" in translated.text)

    # `<public>/<c99name>/<c99name>.h` nested umbrella-header form.
    files = {
        "Gen": struct(dir = "pkg/Sources/Gen", srcs = [], c_srcs = ["pkg/Sources/Gen/Gen.c"], public_hdrs = ["pkg/Sources/Gen/include/Gen/Gen.h"], private_hdrs = [], explicit_map = None, map_in_include = False),
    }
    translated = translate_swiftpm_package("gen", "deps", parsed.model, ["gen"], files)
    asserts.true(env, translated.ok)
    asserts.true(env, "module_map = \"pkg/Sources/Gen/include/module.modulemap\"" in translated.text)

    # Umbrella-directory form (no umbrella header at all).
    files = {
        "Gen": struct(dir = "pkg/Sources/Gen", srcs = [], c_srcs = ["pkg/Sources/Gen/Gen.c"], public_hdrs = ["pkg/Sources/Gen/include/Other.h"], private_hdrs = [], explicit_map = None, map_in_include = False),
    }
    translated = translate_swiftpm_package("gen", "deps", parsed.model, ["gen"], files)
    asserts.true(env, translated.ok)
    asserts.true(env, "module_map = \"pkg/Sources/Gen/include/module.modulemap\"" in translated.text)
    return unittest.end(env)

_generated_map_forms_emit_test = unittest.make(_generated_map_forms_emit_test_impl)

def _mixed_source_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("shims", _CLANG_MANIFEST)
    asserts.true(env, parsed.ok)
    files = _clang_files()
    files["Shims"] = struct(dir = "pkg/Sources/Shims", srcs = ["pkg/Sources/Shims/Shims.swift"], c_srcs = ["pkg/Sources/Shims/Shims.c"])
    translated = translate_swiftpm_package("shims", "deps", parsed.model, ["shims"], files)
    asserts.true(env, not translated.ok)
    asserts.true(env, "mixes Swift and C-family sources" in translated.error)
    asserts.true(env, "\"Shims\"" in translated.error)
    return unittest.end(env)

_mixed_source_refusal_test = unittest.make(_mixed_source_refusal_test_impl)

def _mixed_c_family_translates_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("shims", _CLANG_MANIFEST)
    asserts.true(env, parsed.ok)
    files = _clang_files()
    files["Shims"] = struct(dir = "pkg/Sources/Shims", srcs = [], c_srcs = ["pkg/Sources/Shims/a.c", "pkg/Sources/Shims/b.cpp", "pkg/Sources/Shims/c.m", "pkg/Sources/Shims/d.mm"], public_hdrs = ["pkg/Sources/Shims/include/Shims.h"], private_hdrs = [], explicit_map = "pkg/Sources/Shims/include/module.modulemap", map_in_include = True)
    translated = translate_swiftpm_package("shims", "deps", parsed.model, ["shims"], files)
    asserts.true(env, translated.ok)
    asserts.true(env, "load(\"@rules_cc//cc:objc_library.bzl\", \"objc_library\")" in translated.text)
    asserts.true(env, "objc_library(" in translated.text)
    asserts.true(env, "\"pkg/Sources/Shims/a.c\"" in translated.text)
    asserts.true(env, "\"pkg/Sources/Shims/b.cpp\"" in translated.text)
    asserts.true(env, "\"pkg/Sources/Shims/c.m\"" in translated.text)
    asserts.true(env, "\"pkg/Sources/Shims/d.mm\"" in translated.text)
    files["Shims"] = struct(dir = "pkg/Sources/Shims", srcs = [], c_srcs = ["pkg/Sources/Shims/a.c", "pkg/Sources/Shims/b.cpp"], public_hdrs = ["pkg/Sources/Shims/include/Shims.h"], private_hdrs = [], explicit_map = "pkg/Sources/Shims/include/module.modulemap", map_in_include = True)
    translated = translate_swiftpm_package("shims", "deps", parsed.model, ["shims"], files)
    asserts.true(env, translated.ok)
    asserts.true(env, "cc_library(" in translated.text)
    return unittest.end(env)

_mixed_c_family_translates_test = unittest.make(_mixed_c_family_translates_test_impl)

def _assembly_refusal_names_file_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("shims", _CLANG_MANIFEST)
    asserts.true(env, parsed.ok)
    files = _clang_files()
    files["Shims"] = struct(dir = "pkg/Sources/Shims", srcs = [], c_srcs = ["pkg/Sources/Shims/a.c", "pkg/Sources/Shims/b.S"], public_hdrs = ["pkg/Sources/Shims/include/Shims.h"], private_hdrs = [], explicit_map = None, map_in_include = False)
    translated = translate_swiftpm_package("shims", "deps", parsed.model, ["shims"], files)
    asserts.true(env, not translated.ok)
    asserts.true(env, "assembly source" in translated.error)
    asserts.true(env, "\"pkg/Sources/Shims/b.S\"" in translated.error)
    asserts.true(env, "\"Shims\"" in translated.error)
    return unittest.end(env)

_assembly_refusal_names_file_test = unittest.make(_assembly_refusal_names_file_test_impl)

def _private_headers_in_srcs_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("shims", _CLANG_MANIFEST)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("shims", "deps", parsed.model, ["shims"], _clang_files())
    asserts.true(env, translated.ok)
    asserts.true(env, "srcs = [\n        \"pkg/Sources/Shims/Shims.c\",\n        \"pkg/Sources/Shims/secret.h\",\n    ]," in translated.text)
    asserts.true(env, "hdrs = [\n        \"pkg/Sources/Shims/include/Shims.h\",\n    ]," in translated.text)
    return unittest.end(env)

_private_headers_in_srcs_test = unittest.make(_private_headers_in_srcs_test_impl)

def _select_attr_separator_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = swiftpm_render_list_attr("conlyopts", [], [struct(text = "-DFOO", platforms = ["ios"])])
    asserts.true(env, rendered.endswith("}),"))
    asserts.true(env, "    conlyopts = select({" in rendered)
    rendered = swiftpm_render_list_attr("conlyopts", ["-DBASE"], [struct(text = "-DFOO", platforms = ["ios"])])
    asserts.true(env, rendered.endswith("}),"))
    asserts.true(env, "    ] +\n    select({" in rendered)
    return unittest.end(env)

_select_attr_separator_test = unittest.make(_select_attr_separator_test_impl)

_MULTI_SELECT_MANIFEST = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Multi",
    products: [.library(name: "Multi", targets: ["Multi"])],
    targets: [.target(name: "Multi", cSettings: [.define("GATED", .when(platforms: [.iOS]))], linkerSettings: [.linkedLibrary("z", .when(platforms: [.macOS]))])],
)
"""

def _multi_select_emit_separator_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("multi", _MULTI_SELECT_MANIFEST)
    asserts.true(env, parsed.ok)
    files = {
        "Multi": struct(dir = "pkg/Sources/Multi", srcs = [], c_srcs = ["pkg/Sources/Multi/Multi.c"], public_hdrs = ["pkg/Sources/Multi/include/Multi.h"], private_hdrs = [], explicit_map = None, map_in_include = False),
    }
    translated = translate_swiftpm_package("multi", "deps", parsed.model, ["multi"], files)
    asserts.true(env, translated.ok)
    asserts.true(env, "}),\n    " in translated.text)
    asserts.true(env, not ")}\n    " in translated.text.replace("}),\n    ", ""))
    return unittest.end(env)

_multi_select_emit_separator_test = unittest.make(_multi_select_emit_separator_test_impl)
