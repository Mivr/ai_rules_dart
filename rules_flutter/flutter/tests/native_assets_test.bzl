"""Analysis tests for the code and data assets of Flutter targets.

A package's build hook runs through rules_dart's hook runner from a
`flutter_library` or `flutter_plugin` as from a `dart_library`, and an
application or test turns its closure's hook outputs and `dart_code_asset`s
into the native-assets manifest and one bundle directory (`code_assets.bzl`).
These tests state what each rule registers for that, and the analysis-time
failures a wrong declaration gets.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_dart//dart:providers.bzl", "DartInfo", "DartPackageInfo")
load("//flutter:native_assets.bzl", "flutter_data_asset")
load("//flutter/private:code_assets.bzl", "native_asset_framework_name", "runfiles_relative")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _legacy_dart_library_impl(ctx):
    # The minimal record shape, matching rules_dart's own
    # `//dart/tests/no_lv_fixture`: `package_name` and `lib_root` and nothing
    # else. Built by hand on purpose — a fixture asserting that older producers
    # still work cannot be written through a constructor that makes them
    # current.
    pkg = DartPackageInfo(
        package_name = ctx.attr.package_name,
        lib_root = ctx.label.package,
    )
    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        DartInfo(
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            transitive_srcs = depset(ctx.files.srcs),
            transitive_resources = depset(),
            transitive_packages = depset([pkg]),
        ),
    ]

legacy_dart_library = rule(
    implementation = _legacy_dart_library_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "srcs": attr.label_list(allow_files = [".dart"]),
    },
    doc = "Emits a `DartPackageInfo` with only `package_name` and `lib_root`, as a producer predating its optional fields does.",
)

def _framework_name_impl(ctx):
    env = unittest.begin(ctx)

    # Strips the `.dylib` extension; sanitizes nothing it doesn't need to.
    asserts.equals(env, "objective_c", native_asset_framework_name("objective_c.dylib"))

    # Strips a leading `lib` only when it's a dylib (matches frameworkUri).
    asserts.equals(env, "sqlite3", native_asset_framework_name("libsqlite3.dylib"))

    # Sanitizes characters outside [A-Za-z0-9_-].
    asserts.equals(env, "my-lib_2", native_asset_framework_name("my-lib_2.dylib"))
    asserts.equals(env, "foobar", native_asset_framework_name("foo.bar.dylib"))

    # A `lib` prefix is kept when there is no `.dylib` extension to strip.
    asserts.equals(env, "libfoo", native_asset_framework_name("libfoo"))
    return unittest.end(env)

_framework_name_test = unittest.make(_framework_name_impl)

def _runfiles_relative_impl(ctx):
    env = unittest.begin(ctx)

    # A test's libraries, seen from the project directory it runs in.
    asserts.equals(env, "t.native_assets/", runfiles_relative("_main/app", "_main/app/t.native_assets"))
    asserts.equals(env, "app/t.native_assets/", runfiles_relative("_main", "_main/app/t.native_assets"))
    asserts.equals(env, "../b/t.native_assets/", runfiles_relative("_main/a", "_main/b/t.native_assets"))

    # Another repository's, from the main one, and the other way round.
    asserts.equals(env, "../repo/pkg/t.native_assets/", runfiles_relative("_main", "repo/pkg/t.native_assets"))
    asserts.equals(env, "../../_main/t.native_assets/", runfiles_relative("_main/../repo/pkg", "_main/t.native_assets"))
    asserts.equals(env, "", runfiles_relative("_main/a/", "_main/a"))
    return unittest.end(env)

_runfiles_relative_test = unittest.make(_runfiles_relative_impl)

def _actions(env, mnemonic):
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _flag_value(argv, flag):
    for i, arg in enumerate(argv):
        if arg == flag and i + 1 < len(argv):
            return argv[i + 1]
    return None

def _hook_library_impl(ctx):
    """A `flutter_library` with a build hook compiles it once and runs it once."""
    env = analysistest.begin(ctx)
    asserts.equals(env, 1, len(_actions(env, "DartHookCompile")), "one DartHookCompile")
    runs = _actions(env, "DartBuildHook")
    asserts.equals(env, 1, len(runs), "one DartBuildHook")
    for action in runs:
        asserts.true(env, "build" in action.argv, "the runner's build command: %s" % action.argv)
        outputs = [f.basename for f in action.outputs.to_list()]
        asserts.equals(env, ["hook_library.hook"], outputs, "the hook output directory")
    return analysistest.end(env)

_hook_library_test = analysistest.make(_hook_library_impl)

def _apple_hook_refused_impl(ctx):
    """On macOS a package's build hook neither compiles nor runs: its action fails, naming it."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _actions(env, "DartHookCompile"), "no DartHookCompile on macOS")
    runs = _actions(env, "DartBuildHook")
    asserts.equals(env, 1, len(runs), "one DartBuildHook")
    message = runs[0].argv[-1] if runs else ""
    asserts.true(env, "package:hook_library" in message, message)
    asserts.true(env, "build hooks are not yet supported on Apple targets" in message, message)
    return analysistest.end(env)

_apple_hook_refused_test = analysistest.make(
    _apple_hook_refused_impl,
    config_settings = {"//command_line_option:platforms": str(Label("//flutter/platforms:macos_arm64"))},
)

def _manifest_impl(ctx):
    """An app or test writes one manifest over the closure's hook outputs and code assets."""
    env = analysistest.begin(ctx)
    manifests = _actions(env, "DartNativeAssets")
    asserts.equals(env, 1, len(manifests), "one DartNativeAssets")
    for action in manifests:
        argv = action.argv
        asserts.equals(env, ctx.attr.style, _flag_value(argv, "--style"), "--style in %s" % argv)
        assets = [argv[i + 1] for i, a in enumerate(argv) if a == "--assets"]
        basenames = sorted([a.split("/")[-1] for a in assets])
        asserts.equals(env, ["code_asset.assets.json", "hook_library.hook"], basenames, "--assets in %s" % argv)
        if ctx.attr.runfiles_prefix:
            asserts.equals(env, ctx.attr.runfiles_prefix, _flag_value(argv, "--runfiles-prefix"), "--runfiles-prefix in %s" % argv)
        bundles = [f for f in action.outputs.to_list() if f.is_directory]
        asserts.equals(env, 1, len(bundles), "the bundle directory is an output")
    return analysistest.end(env)

_manifest_test = analysistest.make(
    _manifest_impl,
    attrs = {
        "style": attr.string(mandatory = True),
        "runfiles_prefix": attr.string(),
    },
)

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_substring)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_substring": attr.string(mandatory = True),
    },
)

def native_assets_test_suite(name):
    """Defines the analysis tests and pure-function tests for Flutter assets.

    Args:
      name: The test_suite target name.
    """
    flutter_data_asset(
        name = "_data_bad_id",
        asset_id = "not-a-package-id",
        file = "BUILD.bazel",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_data_asset_id_format",
        target_under_test = ":_data_bad_id",
        expected_substring = "must start with `package:`",
    )

    # Ownership is checked where the asset is declared, not where it is
    # reached — so a `flutter_library` naming an id namespaced to some other
    # package fails on its own analysis, with no application involved.
    _expect_failure_test(
        name = name + "_misowned_code_asset",
        target_under_test = "//flutter/tests/dart_asset_fixture:misowned_asset_fixture",
        expected_substring = "is not namespaced to this package",
        target_compatible_with = HOST_COMPATIBLE,
    )

    _hook_library_test(
        name = name + "_hook_library",
        target_under_test = "//flutter/tests/dart_asset_fixture/hook_library",
        target_compatible_with = HOST_COMPATIBLE,
    )

    # Build hooks do not run on Apple OSes until proven on macOS CI.
    _apple_hook_refused_test(
        name = name + "_apple_hook_refused",
        target_under_test = "//flutter/tests/dart_asset_fixture/hook_library",
        target_compatible_with = HOST_COMPATIBLE,
    )

    # An application's bundle slot holds the libraries, so the manifest names
    # each by its file name, as flutter_tools does on Android and Linux.
    _manifest_test(
        name = name + "_app_manifest",
        target_under_test = "//flutter/tests/dart_asset_fixture/app:assets_app",
        style = "basename",
        target_compatible_with = HOST_COMPATIBLE,
    )

    # A test runs out of runfiles, in its project's directory (its package's,
    # without a `pubspec`), so the manifest names each library by its path in
    # runfiles relative to that directory.
    _manifest_test(
        name = name + "_test_manifest",
        target_under_test = "//flutter/tests/dart_asset_fixture/app:assets_test",
        style = "runfiles",
        runfiles_prefix = "assets_test.native_assets/",
        target_compatible_with = HOST_COMPATIBLE,
    )

    small_unittest_suite(
        name + "_pure",
        _framework_name_test,
        _runfiles_relative_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_data_asset_id_format",
            ":" + name + "_misowned_code_asset",
            ":" + name + "_hook_library",
            ":" + name + "_apple_hook_refused",
            ":" + name + "_app_manifest",
            ":" + name + "_test_manifest",
            ":" + name + "_pure",
        ],
    )
