"""Analysis tests for the strict-layering check on the Flutter program rules.

The integration-test rules (web, Linux, Android, iOS) and `flutter_drive_test`
are covered by `layering_integration_fixtures` below, which the packages
`layering_integ_fixture/` and its `optout/` call. Their entry comes from a
single `srcs` file with `main` unset.

The fixture in `layering_fixture/` has `:bad_test` import `package:leaf`, which
only its dep `mid` depends on; `layering_app_fixture/` does the same for
`flutter_application` and `flutter_web_bundle`. The tests pin what the check's
action reads and that the `_validation` output group carries it (and carries
nothing when the `dart_layering_check` feature is off). Building the `bad_*`
target with `--output_groups=_validation` is the failing case, and the `good_*`
twin the passing one: an action's exit status is not visible from analysis.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//providers:providers.bzl", "ApkInfo")
load("//flutter:android.bzl", "flutter_drive_test")
load("//flutter:defs.bzl", "flutter_integration_test")
load("//flutter/private:flutter_integration_test_android.bzl", "android_integration_test_rule")
load("//flutter/private:flutter_integration_test_ios.bzl", "flutter_ios_integration_test")
load("//flutter/private:layering_check.bzl", "FlutterRefusedInfo", "LAYERING_CHECK_ASPECT")

visibility(["//flutter/tests/..."])

def _flag_values(argv, flag):
    """The values that follow each occurrence of `flag` in `argv`."""
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == flag]

def _check_actions(env):
    return [a for a in analysistest.target_actions(env) if a.mnemonic == "DartImportCheck"]

def _on_test_impl(ctx):
    """The test runs one check over its own sources and returns it in `_validation`."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    stamps = [f.basename for f in target[OutputGroupInfo]._validation.to_list()]
    asserts.true(
        env,
        "%s.import_check" % target.label.name in stamps,
        "_validation carries the test's own check stamp: %s" % stamps,
    )
    checks = _check_actions(env)
    asserts.equals(env, 1, len(checks), "one DartImportCheck over the test's own sources")
    if len(checks) != 1:
        return analysistest.end(env)
    argv = checks[0].argv
    direct = _flag_values(argv, "--direct-package")
    for name in ctx.attr.expect_direct:
        asserts.true(env, name in direct, "%s is a direct package: %s" % (name, argv))
    for name in ctx.attr.expect_absent:
        asserts.true(env, name not in direct, "%s is not a direct package: %s" % (name, argv))
    own = [ctx.attr.own_package] if ctx.attr.own_package else []
    asserts.equals(env, own, _flag_values(argv, "--own-package"))
    srcs = _flag_values(argv, "--src")
    for path in ctx.attr.expect_srcs:
        asserts.true(env, path in srcs, "%s is checked: %s" % (path, srcs))
    asserts.false(
        env,
        any([s.endswith("_bootstrap.dart") for s in srcs]),
        "the generated bootstrap is not checked: %s" % srcs,
    )
    return analysistest.end(env)

layering_on_test = analysistest.make(
    _on_test_impl,
    attrs = {
        "expect_absent": attr.string_list(doc = "Package names argv must not list as direct."),
        "expect_direct": attr.string_list(doc = "Package names argv must list as direct."),
        "expect_srcs": attr.string_list(doc = "Short paths of the sources the check must read."),
        "own_package": attr.string(
            default = "layering_fixture",
            doc = "The package the check must treat as the target's own; empty when it has none.",
        ),
    },
)

def _off_test_impl(ctx):
    """With the feature off, the test registers no check and its group has no own stamp."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, 0, len(_check_actions(env)), "no DartImportCheck with the feature off")
    stamps = [f.basename for f in target[OutputGroupInfo]._validation.to_list()]
    asserts.false(
        env,
        "%s.import_check" % target.label.name in stamps,
        "_validation has no check stamp of the test's own: %s" % stamps,
    )
    return analysistest.end(env)

layering_off_test = analysistest.make(_off_test_impl)

def _apk_app_impl(ctx):
    """Stands in for `flutter_android_app`: the signed APK, with `ApkInfo`."""
    apk = ctx.file.apk
    return [
        DefaultInfo(files = depset([apk])),
        ApkInfo(
            signed_apk = apk,
            unsigned_apk = apk,
            deploy_jar = None,
            coverage_metadata = None,
            signing_keys = [],
            signing_lineage = None,
            signing_min_v3_rotation_api_version = None,
            keystore = None,
        ),
    ]

_apk_app = rule(
    implementation = _apk_app_impl,
    attrs = {"apk": attr.label(allow_single_file = True, doc = "The stub signed APK.")},
    doc = "A target with a signed `.apk` and `ApkInfo`, standing in for `flutter_android_app`.",
)

_PACKAGE = "layering_integ_fixture"
_ENTRY = "test/entry.dart"
_APP = "lib/app.dart"

def layering_integration_targets(name, deps, package = _PACKAGE, entry = _ENTRY, app = _APP):
    """Declares each integration-test rule and `flutter_drive_test` over the given sources.

    Every target is `manual` (analyzed, and built by name with
    `--output_groups=_validation` for a failing case).

    Args:
        name: The name of the `filegroup` over the declared targets.
        deps: The direct `deps` of every target.
        package: The Dart package name of the integration tests.
        entry: The entry source of the tests and the driver of the drive test.
        app: The application source.
    """
    write_file(name = "stub_apk", out = "stub.apk", content = ["stub"], tags = ["manual"])
    _apk_app(name = "stub_app", apk = ":stub_apk", tags = ["manual"])
    write_file(name = "stub_ipa", out = "stub.ipa", content = ["stub"], tags = ["manual"])
    common = {"deps": deps, "tags": ["manual"]}
    srcs = {"srcs": [entry], "app_srcs": [app]}
    flutter_integration_test(name = "web_it", package_name = package, **(common | srcs))
    flutter_integration_test(
        name = "linux_it",
        package_name = package,
        platform = "linux",
        target_compatible_with = ["@platforms//os:linux"],
        **(common | srcs)
    )
    android_integration_test_rule(
        name = "android_it",
        apk = ":stub_apk",
        android_package = "com.example.layering",
        package_name = package,
        platform = "android",
        **(common | srcs)
    )
    flutter_ios_integration_test(
        name = "ios_it",
        app = ":stub_ipa",
        ios_bundle_id = "com.example.layering",
        package_name = package,
        **(common | srcs)
    )
    flutter_drive_test(
        name = "drive_it",
        app = ":stub_app",
        driver = entry,
        package_name = "com.example.layering",
        srcs = [app],
        **common
    )
    kinds = ["web", "linux", "android", "ios", "drive"]
    native.filegroup(name = name, srcs = [":%s_it" % kind for kind in kinds], tags = ["manual"])

def layering_integration_fixtures(name, deps, optout = False):
    """Declares the integration targets over the fixture sources and an analysis test of each.

    Every target is `manual` (analyzed here, built by name with
    `--output_groups=_validation` for the failing case) and has an analysis
    test: the check stamp and the check's inputs, or none with the feature off.

    Args:
        name: The name of the `test_suite` over the analysis tests.
        deps: The direct `deps` of every target.
        optout: Whether the package turned the feature off, so no check is expected.
    """
    layering_integration_targets(name + "_targets", deps)
    kinds = ("web", "linux", "android", "ios", "drive")
    for kind in kinds:
        _declare_integration_test(kind, optout)
    native.test_suite(name = name, tests = [":%s_%s_test" % (kind, "off" if optout else "on") for kind in kinds])

def _declare_integration_test(kind, optout):
    """Declares the analysis test of one fixture target.

    Args:
        kind: The target prefix: `web`, `linux`, `android`, `ios` or `drive`.
        optout: Whether the check must be absent.
    """
    if optout:
        layering_off_test(name = kind + "_off_test", size = "small", target_under_test = ":%s_it" % kind)
        return
    layering_on_test(
        name = kind + "_on_test",
        size = "small",
        expect_absent = ["leaf"],
        expect_direct = ["mid"],
        expect_srcs = ["flutter/tests/layering_integ_fixture/" + f for f in (_ENTRY, _APP)],
        own_package = "" if kind == "drive" else _PACKAGE,
        target_under_test = ":%s_it" % kind,
    )

def _refusal_test_impl(ctx):
    """The target's check refuses exactly `expect_refused`, and its group carries `expect_below`."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    checks = [a for a in _check_actions(env) if a.outputs.to_list()[0].basename.startswith(ctx.attr.stamp)]
    asserts.equals(env, 1, len(checks), "one check named %s" % ctx.attr.stamp)
    if len(checks) != 1:
        return analysistest.end(env)
    refused = _flag_values(checks[0].argv, "--refused-library")
    asserts.equals(env, ctx.attr.expect_refused, refused, "refused libraries: %s" % checks[0].argv)
    if OutputGroupInfo in target and hasattr(target[OutputGroupInfo], "_validation"):
        stamps = [f.basename for f in target[OutputGroupInfo]._validation.to_list()]
        for name in ctx.attr.expect_below:
            asserts.true(env, name in stamps, "_validation carries %s: %s" % (name, stamps))
    return analysistest.end(env)

_REFUSAL_ATTRS = {
    "expect_below": attr.string_list(doc = "Stamps of libraries below the target that `_validation` carries."),
    "expect_refused": attr.string_list(doc = "The `--refused-library` values the check carries, in order."),
    "stamp": attr.string(doc = "The file name the target's check stamp starts with."),
}
_USER_SETTING = {str(Label("@rules_dart//dart:refused_dart_libraries")): ["dart:io"]}

layering_refusal_test = analysistest.make(_refusal_test_impl, attrs = _REFUSAL_ATTRS)
layering_refusal_user_test = analysistest.make(
    _refusal_test_impl,
    attrs = _REFUSAL_ATTRS,
    config_settings = _USER_SETTING,
)

def _below_impl(ctx):
    """A library's own check refuses exactly `expect_refused` and stamps `stamp`."""
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterRefusedInfo]
    asserts.equals(env, ctx.attr.expect_refused, info.refused)
    stamps = [f.basename for f in info.stamps.to_list()]
    asserts.equals(env, [ctx.attr.stamp] if ctx.attr.stamp else [], stamps)
    return analysistest.end(env)

layering_below_test = analysistest.make(
    _below_impl,
    attrs = _REFUSAL_ATTRS,
    extra_target_under_test_aspects = [LAYERING_CHECK_ASPECT],
)
layering_below_user_test = analysistest.make(
    _below_impl,
    attrs = _REFUSAL_ATTRS,
    config_settings = _USER_SETTING,
    extra_target_under_test_aspects = [LAYERING_CHECK_ASPECT],
)

def _validation_empty_impl(ctx):
    """A program that turned the feature off has an empty `_validation`, whatever lies below it."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    stamps = target[OutputGroupInfo]._validation.to_list() if hasattr(target[OutputGroupInfo], "_validation") else []
    asserts.equals(env, [], [f.path for f in stamps], "no check stamp joins _validation")
    return analysistest.end(env)

layering_validation_empty_test = analysistest.make(_validation_empty_impl)
