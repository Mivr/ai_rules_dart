# Bazel-native replacement for `package:objective_c` 9.x's build hook, on
# Apple OSes only.
#
# Build hooks run through the SDK's hook runner on Linux, Android and
# Windows, where objective_c's own `hook/build.dart` runs (and builds
# nothing: it targets macOS and iOS only). On macOS and iOS hooks are not
# proven yet, so there this overlay keeps what served objective_c before:
# every `.c`/`.m` under `src/` (plus, up to 9.4, the macOS `test/util.c`
# memory helper) compiled into `objective_c.dylib`, bound to the asset id
# `package:objective_c/objective_c.dylib` that its `DynamicLibrary` lookup
# uses. rules_dart's `apple_hook_replacements.bzl` does the same for sqlite3
# and webcrypto.
#
# Goes when build hooks are proven on macOS CI.
#
# Placeholders (HUB_NAME, PKG, VERSION, LANGUAGE_VERSION, DEPS — written
# in braces below, and deliberately not in this comment, because
# substitution rewrites comment text too) are injected by
# `flutter_pub_package`'s `_resolve_overlay`. The overlay sits under `9/`,
# so any 9.x routes to it, and everything that varies across 9.x is either
# substituted or globbed rather than written out.

load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_dart//dart:defs.bzl", "dart_code_asset")
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")

# `objective_c` is a pure-Dart support library — there's no
# `flutter.plugin` block in pubspec.yaml; `flutter_plugin` with an empty
# `platforms` list carries the code asset and the hook alike.
flutter_plugin(
    name = "{PKG}",
    # The package's own hook, off Apple OSes.
    build_hook = select({
        "@platforms//os:macos": None,
        "@platforms//os:ios": None,
        "//conditions:default": "hook/build.dart",
    }),
    # The replacement, on them.
    code_assets = select({
        "@platforms//os:macos": [":{PKG}_code_asset"],
        "@platforms//os:ios": [":{PKG}_code_asset"],
        "//conditions:default": [],
    }),
    # The files the asset tool reads: the pubspec, and the licence NOTICES collects.
    data = glob(
        ["pubspec.yaml", "LICENSE*", "NOTICES"],
        allow_empty = True,
    ),
    hook_srcs = select({
        "@platforms//os:macos": [],
        "@platforms//os:ios": [],
        "//conditions:default": glob(
            ["**"],
            exclude = ["lib/**", "BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "REPO.bazel", "MODULE.bazel"],
            allow_empty = True,
        ),
    }),
    language_version = "{LANGUAGE_VERSION}",
    package_name = "{PKG}",
    platforms = [],
    srcs = glob(
        ["lib/**/*.dart"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
    deps = [
        {DEPS}
    ],
)

# Every C / Objective-C file under src/ in one archive, `-fobjc-arc` for
# `.m` files as the hook sets it.
objc_library(
    name = "_{PKG}_objc",
    srcs = glob(
        [
            "src/**/*.c",
            "src/**/*.m",
        ],
        allow_empty = False,
    ) + select({
        # Up to 9.4 the hook compiled test/util.c on macOS only — iOS skips
        # it because mach_vm_region, which util.c calls, is unavailable
        # there. 9.5.0 deleted the file and moved its replacements behind
        # the `include_test_utils` user define, which only objective_c's own
        # test suite sets; a consumer never gets them. A glob spans both:
        # named literally, the label would not resolve on 9.5+.
        "@platforms//os:macos": glob(
            ["test/util.c"],
            allow_empty = True,
        ),
        "//conditions:default": [],
    }),
    hdrs = glob(
        [
            "src/**/*.h",
            "src/include/**/*.h",
        ],
        allow_empty = True,
    ),
    copts = [
        "-fobjc-arc",
    ],
    includes = ["src"],
    target_compatible_with = select({
        "@platforms//os:macos": [],
        "@platforms//os:ios": [],
        "//conditions:default": ["@platforms//:incompatible"],
    }),
    visibility = ["//visibility:private"],
)

cc_shared_library(
    name = "_{PKG}_dylib",
    shared_lib_name = "objective_c.dylib",
    target_compatible_with = select({
        "@platforms//os:macos": [],
        "@platforms//os:ios": [],
        "//conditions:default": ["@platforms//:incompatible"],
    }),
    user_link_flags = [
        # The install name the engine looks up: the manifest's
        # `["absolute", "objective_c.dylib"]` entry resolves the basename, and
        # `@rpath/objective_c.dylib` lets the loader find it wherever it is
        # bundled in the .app (iOS rewrites it into its framework).
        "-Wl,-install_name,@rpath/objective_c.dylib",
        # Foundation, rather than the `-undefined dynamic_lookup` the
        # package's own hook passes: every symbol this dylib leaves undefined
        # is a system one (libobjc, Foundation, libSystem), checked with
        # `nm -u` on the macOS and iOS-simulator slices (72, no `Dart_*`).
        # A dropped symbol is then a link error here rather than a crash at
        # `dlopen`, and Apple deprecates `dynamic_lookup` on iOS-simulator.
        "-Wl,-framework,Foundation",
    ],
    visibility = ["//visibility:private"],
    deps = [":_{PKG}_objc"],
)

dart_code_asset(
    name = "{PKG}_code_asset",
    asset_id = "package:{PKG}/objective_c.dylib",
    shared_library = ":_{PKG}_dylib",
    target_compatible_with = select({
        "@platforms//os:macos": [],
        "@platforms//os:ios": [],
        "//conditions:default": ["@platforms//:incompatible"],
    }),
    visibility = ["//visibility:private"],
)
