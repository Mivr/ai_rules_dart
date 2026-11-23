"""Unit tests for the `Package.swift` manifest parser."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_apple_byname.bzl", "apple_swiftpm_declares_package")
load("//flutter/private:swiftpm_manifest.bzl", "parse_swiftpm_package", "parse_swiftpm_plugin_package")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_BIGINT = """// swift-tools-version:6.0
//
//  Package.swift
//  BigInt
//

import PackageDescription

let package = Package(
    name: "BigInt",
    platforms: [
        .macOS(.v10_13),
        .iOS(.v12),
        .tvOS(.v12),
        .watchOS(.v4),
        .macCatalyst(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "BigInt", targets: ["BigInt"])
    ],
    targets: [
        .target(
            name: "BigInt", path: "Sources"),
        .testTarget(
            name: "BigIntTests", dependencies: ["BigInt"], path: "Tests"),
    ]
)
"""

_KITCHEN_SINK = """// swift-tools-version: 5.9
/* A block comment spanning
   two lines. */
import PackageDescription // trailing comment

let package = Package(
    name: "KitchenSink",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "KitchenSink", targets: ["KitchenSink", "Helper"], type: .dynamic),
        .executable(name: "tool", targets: ["tool"]),
        .plugin(name: "plug", targets: ["plug"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(id: "tool-registry-id", exact: "2.0.0"),
        .package(name: "Local", path: "../Local"),
        .package(name: "Named", url: "https://example.com/other/RealName.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "KitchenSink",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser"), "Helper", .target(name: "Helper2"), .byName(name: "Helper3")],
            exclude: ["skip"],
            sources: ["main"],
        ),
        .target(name: "Helper"),
        .target(name: "Helper2", path: "Custom"),
        .target(name: "Helper3"),
        .executableTarget(name: "tool"),
        .testTarget(name: "KitchenSinkTests", dependencies: ["KitchenSink"]),
        .binaryTarget(name: "Blob", url: "https://example.com/blob.zip", checksum: "abc"),
        .systemLibrary(name: "Sys"),
        .plugin(name: "plug", capability: .buildTool()),
        .macro(name: "Mac"),
    ],
    swiftLanguageModes: [.v5],
    cLanguageStandard: .c11,
    cxxLanguageStandard: "c++17",
)
"""

def _parses_the_bigint_manifest_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", _BIGINT)
    asserts.true(env, parsed.ok)
    asserts.equals(env, "", parsed.error)
    asserts.equals(env, 6, parsed.model.tools_major)
    asserts.equals(env, 0, parsed.model.tools_minor)
    asserts.equals(env, 1, len(parsed.model.products))
    asserts.equals(env, "BigInt", parsed.model.products[0].name)
    asserts.equals(env, ["BigInt"], parsed.model.products[0].targets)
    asserts.equals(env, 2, len(parsed.model.targets))
    asserts.equals(env, "Sources", parsed.model.targets[0].path)
    asserts.equals(env, "testTarget", parsed.model.targets[1].kind)
    asserts.equals(env, [], parsed.model.pkg_deps)
    asserts.equals(env, [], parsed.model.modes)
    return unittest.end(env)

def _parses_every_supported_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("kitchensink", _KITCHEN_SINK)
    asserts.true(env, parsed.ok)
    asserts.equals(env, "", parsed.error)
    asserts.equals(env, 5, parsed.model.tools_major)
    asserts.equals(env, 9, parsed.model.tools_minor)

    # Only the `.library` product survives; executables and plugins drop.
    asserts.equals(env, 1, len(parsed.model.products))
    asserts.equals(env, ["KitchenSink", "Helper"], parsed.model.products[0].targets)

    asserts.equals(env, 4, len(parsed.model.pkg_deps))
    asserts.equals(env, "https://github.com/apple/swift-argument-parser", parsed.model.pkg_deps[0].ref)
    asserts.equals(env, "url", parsed.model.pkg_deps[0].ref_kind)
    asserts.equals(env, "tool-registry-id", parsed.model.pkg_deps[1].ref)
    asserts.equals(env, "id", parsed.model.pkg_deps[1].ref_kind)
    asserts.equals(env, "Local", parsed.model.pkg_deps[2].name)
    asserts.equals(env, "path", parsed.model.pkg_deps[2].ref_kind)
    asserts.equals(env, "Named", parsed.model.pkg_deps[3].name)

    asserts.equals(env, 1, len(parsed.model.modes))
    asserts.equals(env, 5, parsed.model.modes[0].major)
    asserts.equals(env, 0, parsed.model.modes[0].minor)

    main = parsed.model.targets[0]
    asserts.equals(env, 4, len(main.deps))
    asserts.equals(env, "product", main.deps[0].kind)
    asserts.equals(env, "ArgumentParser", main.deps[0].name)
    asserts.equals(env, "swift-argument-parser", main.deps[0].package)
    asserts.equals(env, "same", main.deps[1].kind)
    asserts.equals(env, "Helper", main.deps[1].name)
    asserts.equals(env, "same", main.deps[2].kind)
    asserts.equals(env, "Helper2", main.deps[2].name)
    asserts.equals(env, ["skip"], main.exclude)
    asserts.equals(env, ["main"], main.sources)

    # Special kinds keep their kind and name for the translator's refusal.
    by_kind = {target.name: target.kind for target in parsed.model.targets}
    asserts.equals(env, "binaryTarget", by_kind["Blob"])
    asserts.equals(env, "systemLibrary", by_kind["Sys"])
    asserts.equals(env, "plugin", by_kind["plug"])
    asserts.equals(env, "macro", by_kind["Mac"])
    return unittest.end(env)

def _refusal_names_identity_file_and_line_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", "let package = Package(name: \"x\")\n")
    asserts.true(env, not parsed.ok)
    asserts.true(env, parsed.error.startswith("SwiftPM package \"bigint\" (Package.swift line 1):"))
    return unittest.end(env)

def _tools_line_refusals_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", "import PackageDescription\nlet package = Package(name: \"x\")\n")
    asserts.true(env, not parsed.ok)
    asserts.true(env, "swift-tools-version" in parsed.error)
    parsed = parse_swiftpm_package("bigint", "// swift-tools-version:3.1\nimport PackageDescription\nlet package = Package(name: \"x\")\n")
    asserts.true(env, not parsed.ok)
    asserts.true(env, "older than the supported 4.0" in parsed.error)
    parsed = parse_swiftpm_package("bigint", "// swift-tools-version:abc\nimport PackageDescription\nlet package = Package(name: \"x\")\n")
    asserts.true(env, not parsed.ok)
    return unittest.end(env)

def _statement_refusals_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        ("// swift-tools-version:5.9\n#if os(macOS)\nlet package = Package(name: \"x\")\n#endif\n", "conditional compilation"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"\\(x)\")\n", "interpolation"),
        ("// swift-tools-version:5.9\nimport Foundation\n", "only `import PackageDescription`"),
        ("// swift-tools-version:5.9\nlet other = 1\n", "not supported"),
        ("// swift-tools-version:5.9\nvar package = Package(name: \"x\")\npackage.targets = []\n", "must not be mutated"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\")\nlet package = Package(name: \"y\")\n", "duplicate `let package`"),
        ("// swift-tools-version:5.9\nimport PackageDescription\n", "no `let package"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", bogus: 1)\n", "unknown `Package(...)` argument `bogus`"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", products: [.library(name: \"a\")])\n", "needs `name:` and `targets:`"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", products: [.weird(name: \"a\")])\n", "unknown product kind"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", targets: [.target(name: \"a\", resources: [])])\n", "no Bazel translation"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", targets: [.weird(name: \"a\")])\n", "unknown target kind"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", products: [.library(name: \"a\", targets: [\"a\"]), .library(name: \"a\", targets: [\"a\"])], targets: [.target(name: \"a\")])\n", "duplicate product"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", products: [.library(name: \"a\", targets: [\"a\"])], targets: [.target(name: \"a\"), .target(name: \"a\")])\n", "duplicate target"),
    ]
    for case in cases:
        parsed = parse_swiftpm_package("pkg", case[0])
        asserts.true(env, not parsed.ok)
        asserts.true(env, case[1] in parsed.error)
    return unittest.end(env)

_PLUGIN_TEMPLATE = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ios_greeting",
    platforms: [
        .iOS("12.0")
    ],
    products: [
        .library(name: "ios-greeting", targets: ["ios_greeting"])
    ],
    targets: [
        .target(name: "ios_greeting", path: "Classes")
    ],
    swiftLanguageVersions: [.v5]
)
"""

def _parses_a_plugin_template_manifest_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("ios-greeting", _PLUGIN_TEMPLATE)
    asserts.true(env, parsed.ok)
    asserts.equals(env, "", parsed.error)
    asserts.equals(env, 1, len(parsed.model.products))
    asserts.equals(env, "ios-greeting", parsed.model.products[0].name)
    asserts.equals(env, ["ios_greeting"], parsed.model.products[0].targets)
    asserts.equals(env, 1, len(parsed.model.targets))
    asserts.equals(env, "target", parsed.model.targets[0].kind)
    asserts.equals(env, "ios_greeting", parsed.model.targets[0].name)
    asserts.equals(env, "Classes", parsed.model.targets[0].path)
    asserts.equals(env, [], parsed.model.pkg_deps)
    return unittest.end(env)

def _plugin_parser_skips_target_settings_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", products: [.library(name: \"P\", targets: [\"P\"])], dependencies: [.package(url: \"https://example.com/Dep.git\", exact: \"1.0.0\")], targets: [.target(name: \"P\", dependencies: [.product(name: \"D\", package: \"Dep\")], resources: [.process(\"PrivacyInfo.xcprivacy\")], swiftSettings: [.define(\"FOO\")], cSettings: [.define(\"BAR\")], cxxSettings: [.define(\"BAZ\")], linkerSettings: [.linkedLibrary(\"z\")], plugins: [.plugin(name: \"Pl\", package: \"Dep\")])])\n"
    strict = parse_swiftpm_package("plugin", manifest)
    asserts.true(env, not strict.ok)
    asserts.true(env, "no Bazel translation" in strict.error)
    lenient = parse_swiftpm_plugin_package("plugin", manifest)
    asserts.true(env, lenient.ok)
    asserts.equals(env, 1, len(lenient.model.targets[0].deps))
    asserts.equals(env, "D", lenient.model.targets[0].deps[0].name)
    return unittest.end(env)

_OBJC_PLUGIN_TARGET = "[.target(name: \"P\", publicHeadersPath: \"include\", packageAccess: false, dependencies: [.product(name: \"D\", package: \"Dep\")])]"

def _plugin_parser_accepts_objc_target_settings_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", products: [.library(name: \"P\", targets: [\"P\"])], dependencies: [.package(url: \"https://example.com/Dep.git\", exact: \"1.0.0\")], targets: " + _OBJC_PLUGIN_TARGET + ")\n"
    strict = parse_swiftpm_package("plugin", manifest)
    asserts.true(env, not strict.ok)
    asserts.true(env, "unknown `.target(...)` argument `packageAccess`" in strict.error)
    lenient = parse_swiftpm_plugin_package("plugin", manifest)
    asserts.true(env, lenient.ok)
    asserts.equals(env, 1, len(lenient.model.targets[0].deps))
    asserts.equals(env, "D", lenient.model.targets[0].deps[0].name)
    return unittest.end(env)

_SETTINGS_TARGET = ".target(name: \"C\", publicHeadersPath: \"include\", cSettings: [.define(\"CLANG\"), .define(\"VER\", to: \"2\"), .headerSearchPath(\"detail\"), .define(\"IOS_ONLY\", .when(platforms: [.iOS]))], cxxSettings: [.define(\"CXX\")], swiftSettings: [.define(\"SWIFT\"), .enableUpcomingFeature(\"Existentials\"), .enableExperimentalFeature(\"X\", .when(platforms: [.macOS]))], linkerSettings: [.linkedLibrary(\"z\"), .linkedFramework(\"CoreGraphics\", condition: .when(platforms: [.iOS, .macOS]))])"

def _parses_target_settings_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", products: [.library(name: \"P\", targets: [\"C\"])], targets: [" + _SETTINGS_TARGET + "])\n"
    parsed = parse_swiftpm_package("settings", manifest)
    asserts.true(env, parsed.ok)
    target = parsed.model.targets[0]
    asserts.equals(env, "include", target.public_headers_path)
    asserts.equals(env, 4, len(target.c_settings))
    asserts.equals(env, ("define", "CLANG", "", None), (target.c_settings[0].kind, target.c_settings[0].name, target.c_settings[0].value, target.c_settings[0].condition))
    asserts.equals(env, ("define", "VER", "2"), (target.c_settings[1].kind, target.c_settings[1].name, target.c_settings[1].value))
    asserts.equals(env, ("headerSearchPath", "detail"), (target.c_settings[2].kind, target.c_settings[2].name))
    asserts.equals(env, ["ios"], target.c_settings[3].condition.platforms)
    asserts.equals(env, 1, len(target.cxx_settings))
    asserts.equals(env, "CXX", target.cxx_settings[0].name)
    asserts.equals(env, 3, len(target.swift_settings))
    asserts.equals(env, "SWIFT", target.swift_settings[0].name)
    asserts.equals(env, "enableUpcomingFeature", target.swift_settings[1].kind)
    asserts.equals(env, None, target.swift_settings[1].condition)
    asserts.equals(env, ["macos"], target.swift_settings[2].condition.platforms)
    asserts.equals(env, 2, len(target.linker_settings))
    asserts.equals(env, ("linkedLibrary", "z", None), (target.linker_settings[0].kind, target.linker_settings[0].name, target.linker_settings[0].condition))
    asserts.equals(env, ["ios", "macos"], target.linker_settings[1].condition.platforms)
    return unittest.end(env)

def _target_setting_refusals_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        (".target(name: \"C\", cSettings: [.unsafeFlags([\"-Xcc\", \"-x\"])])", "target \"C\" uses `.unsafeFlags(...)` in `cSettings`"),
        (".target(name: \"C\", cxxSettings: [.weird(\"x\")])", "target \"C\" uses `.weird(...)` in `cxxSettings`"),
        (".target(name: \"C\", swiftSettings: [.define(\"X\", to: \"1\")])", "unexpected `.define(...)` argument `to`"),
        (".target(name: \"C\", swiftSettings: [.define(\"X\", .when(configuration: .debug))])", "target \"C\" uses a build condition on `configuration:`"),
        (".target(name: \"C\", linkerSettings: [.linkedLibrary(\"z\", .when(traits: [\"T\"]))])", "target \"C\" uses a build condition on `traits:`"),
        (".target(name: \"C\", cSettings: [.define(\"X\", .define(\"Y\"))])", "target \"C\": expected a build condition"),
    ]
    for target_decl, detail in cases:
        manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", products: [.library(name: \"P\", targets: [\"C\"])], targets: [" + target_decl + "])\n"
        parsed = parse_swiftpm_package("settings", manifest)
        asserts.true(env, not parsed.ok)
        asserts.true(env, detail in parsed.error)
        asserts.true(env, "SwiftPM package \"settings\" (Package.swift line " in parsed.error)
    return unittest.end(env)

def _condition_refusal_names_target_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Cond\", products: [.library(name: \"Cond\", targets: [\"C\"])], dependencies: [.package(url: \"https://example.com/Dep.git\", from: \"1.0.0\")], targets: [.target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", condition: .when(configuration: .debug))])])\n"
    parsed = parse_swiftpm_package("cond", manifest)
    asserts.true(env, not parsed.ok)
    asserts.true(env, "target \"C\":" in parsed.error)
    asserts.true(env, "build condition on `configuration:`" in parsed.error)
    asserts.true(env, "SwiftPM package \"cond\" (Package.swift line " in parsed.error)
    return unittest.end(env)

def _other_platforms_are_ignored_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", products: [.library(name: \"P\", targets: [\"C\"])], targets: [.target(name: \"C\", cSettings: [.define(\"X\", .when(platforms: [.linux]))], linkerSettings: [.linkedFramework(\"CFNetwork\", .when(platforms: [.iOS, .macOS, .tvOS, .watchOS]))])])\n"
    parsed = parse_swiftpm_package("platforms", manifest)
    asserts.true(env, parsed.ok)
    target = parsed.model.targets[0]
    asserts.equals(env, [], target.c_settings[0].condition.platforms)
    asserts.equals(env, ["ios", "macos"], target.linker_settings[0].condition.platforms)
    return unittest.end(env)

_PLUGIN_PACKAGE_SETTINGS = ', defaultLocalization: "en", pkgConfig: "libfoo", providers: [.apt(["libfoo-dev"]), .brew(["libfoo"])]'

def _plugin_parser_accepts_package_settings_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\"" + _PLUGIN_PACKAGE_SETTINGS + ", products: [.library(name: \"P\", targets: [\"P\"])], targets: [.target(name: \"P\")])\n"
    strict = parse_swiftpm_package("plugin", manifest)
    asserts.true(env, not strict.ok)
    asserts.true(env, "unknown `Package(...)` argument `defaultLocalization`" in strict.error)
    lenient = parse_swiftpm_plugin_package("plugin", manifest)
    asserts.true(env, lenient.ok)
    asserts.equals(env, "", lenient.error)
    asserts.equals(env, "P", lenient.model.targets[0].name)
    return unittest.end(env)

_REQUIREMENT_FORMS = [
    '"6.0.0"..<"7.0.0"',
    '"1.0.0"..."1.9.0"',
    '.upToNextMajor(from: "6.0.0")',
    '.upToNextMinor(from: "6.0.0")',
    '.exact("6.0.1")',
    '.branch("main")',
    '.revision("abc123")',
]

def _package_dep_accepts_any_requirement_form_test_impl(ctx):
    env = unittest.begin(ctx)
    for requirement in _REQUIREMENT_FORMS:
        manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", products: [.library(name: \"P\", targets: [\"P\"])], dependencies: [.package(url: \"https://github.com/attaswift/BigInt.git\", " + requirement + ")], targets: [.target(name: \"P\", dependencies: [.product(name: \"BigInt\", package: \"BigInt\")])])\n"
        strict = parse_swiftpm_package("pkg", manifest)
        asserts.true(env, strict.ok)
        asserts.equals(env, 1, len(strict.model.pkg_deps))
        asserts.equals(env, "https://github.com/attaswift/BigInt.git", strict.model.pkg_deps[0].ref)
        asserts.equals(env, "url", strict.model.pkg_deps[0].ref_kind)
        lenient = parse_swiftpm_plugin_package("pkg", manifest)
        asserts.true(env, lenient.ok)
        asserts.equals(env, 1, len(lenient.model.pkg_deps))
    return unittest.end(env)

def _package_dep_still_refuses_unlocatable_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        ("// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", products: [.library(name: \"P\", targets: [\"P\"])], dependencies: [.package(from: \"1.0.0\")], targets: [.target(name: \"P\")])\n", "needs one of `url:`, `id:` or `path:`"),
        ("// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", products: [.library(name: \"P\", targets: [\"P\"])], dependencies: [.package(url: bigIntUrl, from: \"1.0.0\")], targets: [.target(name: \"P\")])\n", "expected one string literal"),
        ("// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", products: [.library(name: \"P\", targets: [\"P\"])], dependencies: [.package(url: \"https://example.com/Dep.git\", bogus: 1)], targets: [.target(name: \"P\")])\n", "unknown `.package(...)` argument `bogus`"),
    ]
    for case in cases:
        strict = parse_swiftpm_package("pkg", case[0])
        asserts.true(env, not strict.ok)
        asserts.true(env, case[1] in strict.error)
        lenient = parse_swiftpm_plugin_package("pkg", case[0])
        asserts.true(env, not lenient.ok)
        asserts.true(env, case[1] in lenient.error)
    return unittest.end(env)

_parses_target_settings_test = unittest.make(_parses_target_settings_test_impl)
_target_setting_refusals_test = unittest.make(_target_setting_refusals_test_impl)
_condition_refusal_names_target_test = unittest.make(_condition_refusal_names_target_test_impl)
_parses_the_bigint_manifest_test = unittest.make(_parses_the_bigint_manifest_test_impl)
_parses_every_supported_shape_test = unittest.make(_parses_every_supported_shape_test_impl)
_parses_a_plugin_template_manifest_test = unittest.make(_parses_a_plugin_template_manifest_test_impl)
_plugin_parser_skips_target_settings_test = unittest.make(_plugin_parser_skips_target_settings_test_impl)
_plugin_parser_accepts_objc_target_settings_test = unittest.make(_plugin_parser_accepts_objc_target_settings_test_impl)
_plugin_parser_accepts_package_settings_test = unittest.make(_plugin_parser_accepts_package_settings_test_impl)
_package_dep_accepts_any_requirement_form_test = unittest.make(_package_dep_accepts_any_requirement_form_test_impl)
_package_dep_still_refuses_unlocatable_test = unittest.make(_package_dep_still_refuses_unlocatable_test_impl)
_refusal_names_identity_file_and_line_test = unittest.make(_refusal_names_identity_file_and_line_test_impl)
_tools_line_refusals_test = unittest.make(_tools_line_refusals_test_impl)
_statement_refusals_test = unittest.make(_statement_refusals_test_impl)

def swiftpm_manifest_test_suite(name):
    """Registers the `Package.swift` parser unit tests."""
    small_unittest_suite(
        name + "_unit",
        _parses_the_bigint_manifest_test,
        _parses_every_supported_shape_test,
        _parses_a_plugin_template_manifest_test,
        _plugin_parser_skips_target_settings_test,
        _plugin_parser_accepts_objc_target_settings_test,
        _plugin_parser_accepts_package_settings_test,
        _package_dep_accepts_any_requirement_form_test,
        _package_dep_still_refuses_unlocatable_test,
        _parses_condition_arguments_test,
        _condition_refusals_test,
        _dropped_platform_dep_parses_test,
        _other_platforms_are_ignored_test,
        _parses_target_settings_test,
        _target_setting_refusals_test,
        _condition_refusal_names_target_test,
        _refusal_names_identity_file_and_line_test,
        _tools_line_refusals_test,
        _statement_refusals_test,
        _folds_firebase_auth_manifest_test,
        _folds_firebase_auth_package_manifest_test,
        _folds_url_interpolation_test,
        _manifest_constant_refusals_test,
        _manifest_constant_hints_test,
        _constant_before_declaration_test,
        _other_interpolations_still_refused_test,
        _declares_package_fallback_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )

_CONDITIONED = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Cond",
    products: [.library(name: "Cond", targets: ["Cond"])],
    dependencies: [.package(url: "https://example.com/Dep.git", from: "1.0.0")],
    targets: [.target(name: "Cond", dependencies: [.product(name: "Dp", package: "Dep", condition: .when(platforms: [.iOS, .macOS])), .target(name: "Help", condition: .when(platforms: [.iOS])), "Plain"])],
)
"""

def _parses_condition_arguments_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("cond", _CONDITIONED)
    asserts.true(env, parsed.ok)
    deps = parsed.model.targets[0].deps
    asserts.equals(env, 3, len(deps))
    asserts.equals(env, ["ios", "macos"], deps[0].condition.platforms)
    asserts.equals(env, ["ios"], deps[1].condition.platforms)
    asserts.equals(env, None, deps[2].condition)
    return unittest.end(env)

def _condition_refusals_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        (".target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", condition: .when(traits: [\"Trait\"]))])", "build condition on `traits:`"),
        (".target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", condition: .when(configuration: .debug))])", "build condition on `configuration:`"),
        (".target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", condition: .when(platforms: [.iOS], configuration: .debug))])", "build condition on `configuration:`"),
        (".target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", condition: \"ios\")])", "expected a build condition"),
        (".target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", extra: 1)])", "unknown `.product(...)` argument"),
    ]
    for target_decl, detail in cases:
        manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Cond\", products: [.library(name: \"Cond\", targets: [\"C\"])], dependencies: [.package(url: \"https://example.com/Dep.git\", from: \"1.0.0\")], targets: [" + target_decl + "])\n"
        parsed = parse_swiftpm_package("cond", manifest)
        asserts.true(env, not parsed.ok)
        asserts.true(env, detail in parsed.error)
    return unittest.end(env)

def _dropped_platform_dep_parses_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Cond\", products: [.library(name: \"Cond\", targets: [\"C\"])], dependencies: [.package(url: \"https://example.com/Dep.git\", from: \"1.0.0\")], targets: [.target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", condition: .when(platforms: [.watchOS])), .target(name: \"Help\", condition: .when(platforms: [.tvOS, .macOS]))])])\n"
    parsed = parse_swiftpm_package("cond", manifest)
    asserts.true(env, parsed.ok)
    deps = parsed.model.targets[0].deps
    asserts.equals(env, [], deps[0].condition.platforms)
    asserts.equals(env, ["macos"], deps[1].condition.platforms)
    return unittest.end(env)

_FIREBASE_AUTH_MANIFEST = """// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

// Copyright 2024, the Chromium project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import PackageDescription

let libraryVersion = "7.0.1"
let firebaseSdkVersion: Version = "13.1.1"

let package = Package(
  name: "firebase_auth",
  platforms: [
    .iOS("15.0")
  ],
  products: [
    .library(name: "firebase-auth", targets: ["firebase_auth"])
  ],
  dependencies: [
    .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: firebaseSdkVersion),
    .package(name: "firebase_core", path: "../firebase_core"),
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "firebase_auth",
      dependencies: [
        .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
        .product(name: "firebase-core", package: "firebase_core"),
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      resources: [
        .process("Resources")
      ],
      cSettings: [
        .define("LIBRARY_VERSION", to: "\\\"\\(libraryVersion)\\\""),
        .define("LIBRARY_NAME", to: "\\\"flutter-fire-auth\\\""),
      ]
    )
  ]
)
"""

# The strict (package) entry point refuses `resources:`, so the same manifest
# drops that one target argument and keeps the C settings.
_FIREBASE_AUTH_PACKAGE_MANIFEST = _FIREBASE_AUTH_MANIFEST.replace("""      resources: [
        .process("Resources")
      ],
""", "")

def _folds_firebase_auth_manifest_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_plugin_package("firebase_auth", _FIREBASE_AUTH_MANIFEST)
    asserts.true(env, parsed.ok)
    asserts.equals(env, "", parsed.error)
    asserts.equals(env, 3, len(parsed.model.pkg_deps))
    asserts.equals(env, "https://github.com/firebase/firebase-ios-sdk", parsed.model.pkg_deps[0].ref)
    asserts.equals(env, "url", parsed.model.pkg_deps[0].ref_kind)
    asserts.equals(env, "firebase_auth", parsed.model.targets[0].name)
    asserts.equals(env, 3, len(parsed.model.targets[0].deps))
    return unittest.end(env)

def _folds_firebase_auth_package_manifest_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("firebase_auth", _FIREBASE_AUTH_PACKAGE_MANIFEST)
    asserts.true(env, parsed.ok)
    asserts.equals(env, "", parsed.error)
    settings = parsed.model.targets[0].c_settings
    asserts.equals(env, 2, len(settings))
    asserts.equals(env, ("define", "LIBRARY_VERSION", "\\\"7.0.1\\\""), (settings[0].kind, settings[0].name, settings[0].value))
    asserts.equals(env, ("define", "LIBRARY_NAME", "\\\"flutter-fire-auth\\\""), (settings[1].kind, settings[1].name, settings[1].value))
    return unittest.end(env)

_MAPBOX_CONSTANT_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let mapboxMapsPackage: String = "mapbox-maps-ios"
let mapboxMapsVersion: Version = "11.0.0"

let package = Package(
    name: "mapbox",
    products: [.library(name: "mapbox", targets: ["mapbox"])],
    dependencies: [
        .package(url: "https://github.com/mapbox/\\(mapboxMapsPackage).git", exact: mapboxMapsVersion),
    ],
    targets: [.target(name: "mapbox")],
)
"""

def _folds_url_interpolation_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("mapbox", _MAPBOX_CONSTANT_MANIFEST)
    asserts.true(env, parsed.ok)
    asserts.equals(env, "", parsed.error)
    asserts.equals(env, 1, len(parsed.model.pkg_deps))
    asserts.equals(env, "https://github.com/mapbox/mapbox-maps-ios.git", parsed.model.pkg_deps[0].ref)
    return unittest.end(env)

_REFUSAL_PREFIX = """// swift-tools-version: 5.9
import PackageDescription
"""

_REFUSAL_PACKAGE = """let package = Package(name: "P", targets: [.target(name: "P")])
"""

def _manifest_constant_refusals_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        ("var version = \"1\"\n", "variables are not supported"),
        ("func helper() {}\n", "unsupported top-level statement"),
        ("let versions = [\"1\"]\n", "variables are not supported"),
        ("let version = enabled ? \"1\" : \"2\"\n", "variables are not supported"),
        ("let version = ProcessInfo.processInfo.environment[\"V\"]\n", "variables are not supported"),
        ("let version: Int = 1\n", "variables are not supported"),
    ]
    for case in cases:
        parsed = parse_swiftpm_plugin_package("firebase_auth", _REFUSAL_PREFIX + case[0] + _REFUSAL_PACKAGE)
        asserts.true(env, not parsed.ok)
        asserts.true(env, case[1] in parsed.error)
    folded = parse_swiftpm_plugin_package("firebase_auth", _REFUSAL_PREFIX + """let version = "1.0.0"
let package = Package(name: "P", dependencies: [.package(url: "https://example.com/Dep.git", exact: version)], targets: [.target(name: "P")])
""")
    asserts.true(env, folded.ok)
    asserts.equals(env, "https://example.com/Dep.git", folded.model.pkg_deps[0].ref)
    return unittest.end(env)

def _manifest_constant_hints_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = _REFUSAL_PREFIX + "var version = \"1\"\n" + _REFUSAL_PACKAGE
    plugin = parse_swiftpm_plugin_package("firebase_auth", manifest)
    asserts.true(env, not plugin.ok)
    asserts.true(env, "variables are not supported" in plugin.error)
    asserts.true(env, "flutter.pub(ios_plugin_deps = {\"firebase_auth\": \"<label>\"})" in plugin.error)
    package = parse_swiftpm_package("firebase_auth", manifest)
    asserts.true(env, not package.ok)
    asserts.true(env, "variables are not supported" in package.error)
    asserts.true(env, "flutter.pub(swift_package_build_files = {\"firebase_auth\": \"<label>\"})" in package.error)
    return unittest.end(env)

_BEFORE_DECLARATION = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "P", dependencies: [.package(url: "https://example.com/Dep.git", exact: laterVersion)], targets: [.target(name: "P")])
let laterVersion = "1.0.0"
"""

_UNKNOWN_USE = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "P", dependencies: [.package(url: "https://example.com/Dep.git", exact: missingVersion)], targets: [.target(name: "P")])
"""

def _constant_before_declaration_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("pkg", _BEFORE_DECLARATION)
    asserts.true(env, not parsed.ok)
    asserts.true(env, "laterVersion" in parsed.error)
    asserts.true(env, "Package.swift line 3" in parsed.error)
    asserts.true(env, "a constant must be declared before use" in parsed.error)
    unknown = parse_swiftpm_package("pkg", _UNKNOWN_USE)
    asserts.true(env, not unknown.ok)
    asserts.true(env, "missingVersion" in unknown.error)
    asserts.true(env, "Package.swift line 3" in unknown.error)
    asserts.true(env, "a constant must be declared before use" in unknown.error)
    return unittest.end(env)

def _other_interpolations_still_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        ".package(url: \"https://example.com/\\(foo.bar).git\", exact: \"1.0.0\")",
        ".package(url: \"https://example.com/\\(unknownName).git\", exact: \"1.0.0\")",
        ".package(url: \"https://example.com/\\(helper()).git\", exact: \"1.0.0\")",
    ]
    for case in cases:
        manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"P\", dependencies: [" + case + "], targets: [.target(name: \"P\")])\n"
        parsed = parse_swiftpm_plugin_package("pkg", manifest)
        asserts.true(env, not parsed.ok)
        asserts.true(env, "string interpolation is not supported" in parsed.error)
    folded = parse_swiftpm_plugin_package("pkg", "// swift-tools-version: 5.9\nimport PackageDescription\nlet name = \"Dep\"\nlet package = Package(name: \"P\", dependencies: [.package(url: \"https://example.com/\\(name).git\", exact: \"1.0.0\")], targets: [.target(name: \"P\")])\n")
    asserts.true(env, folded.ok)
    asserts.equals(env, "https://example.com/Dep.git", folded.model.pkg_deps[0].ref)
    return unittest.end(env)

_parses_condition_arguments_test = unittest.make(_parses_condition_arguments_test_impl)
_condition_refusals_test = unittest.make(_condition_refusals_test_impl)
_dropped_platform_dep_parses_test = unittest.make(_dropped_platform_dep_parses_test_impl)
_other_platforms_are_ignored_test = unittest.make(_other_platforms_are_ignored_test_impl)
_folds_firebase_auth_manifest_test = unittest.make(_folds_firebase_auth_manifest_test_impl)
_folds_firebase_auth_package_manifest_test = unittest.make(_folds_firebase_auth_package_manifest_test_impl)
_folds_url_interpolation_test = unittest.make(_folds_url_interpolation_test_impl)
_manifest_constant_refusals_test = unittest.make(_manifest_constant_refusals_test_impl)
_manifest_constant_hints_test = unittest.make(_manifest_constant_hints_test_impl)
_constant_before_declaration_test = unittest.make(_constant_before_declaration_test_impl)
_other_interpolations_still_refused_test = unittest.make(_other_interpolations_still_refused_test_impl)

def _declares_package_fallback_test_impl(ctx):
    """Verifies apple_swiftpm_declares_package fallback when lexing fails."""
    env = unittest.begin(ctx)
    asserts.true(env, apple_swiftpm_declares_package('let x = "\n.package(url: "https://example.com/a.git")'))
    asserts.true(env, apple_swiftpm_declares_package('let x = "\n. \t\r\npackage(url: "https://example.com/b.git")'))
    asserts.false(env, apple_swiftpm_declares_package('let x = "\nlet y = 1'))
    return unittest.end(env)

_declares_package_fallback_test = unittest.make(_declares_package_fallback_test_impl)
