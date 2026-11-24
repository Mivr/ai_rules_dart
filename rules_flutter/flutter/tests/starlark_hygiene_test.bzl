"""Tests that xtool actions carry progress messages and output-scoped `TMPDIR`s."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:flutter_xtool_bundle.bzl", "flutter_xtool_ios_bundle", "flutter_xtool_macos_bundle")
load("//flutter/private:xtool_version.bzl", "bundle_version_progress_message", "flutter_xtool_bundle_version")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _progress_message_test_impl(ctx):
    """Checks the bundle-version progress message names the label."""
    env = unittest.begin(ctx)
    message = bundle_version_progress_message(Label("//pkg:ver"))
    asserts.true(env, message != "")
    asserts.true(env, "//pkg:ver" in message, message)
    asserts.true(env, "%s" not in message, message)
    return unittest.end(env)

_progress_message_test = unittest.make(_progress_message_test_impl)

def _action_by_mnemonic(env, mnemonic):
    """The one action with `mnemonic` registered by the target under test."""
    matches = [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]
    asserts.equals(env, 1, len(matches), "expected one %s action" % mnemonic)
    return matches[0] if matches else None

def _version_tmpdir_test_impl(ctx):
    """Checks the version action's `TMPDIR` is the output parent directory."""
    env = analysistest.begin(ctx)
    action = _action_by_mnemonic(env, "FlutterXtoolBundleVersion")
    out = action.outputs.to_list()[0]
    asserts.equals(env, out.dirname, action.env["TMPDIR"])
    asserts.true(env, not action.env["TMPDIR"].startswith("/tmp"))
    return analysistest.end(env)

_version_tmpdir_test = analysistest.make(_version_tmpdir_test_impl)

def _bundle_tmpdir_test_impl(ctx):
    """Checks the runner and bundle actions' `TMPDIR` bindings."""
    env = analysistest.begin(ctx)
    runner = _action_by_mnemonic(env, "FlutterXtoolRunner")
    bundle = _action_by_mnemonic(env, ctx.attr.bundle_mnemonic)
    asserts.equals(env, runner.outputs.to_list()[0].dirname, runner.env["TMPDIR"])
    archive = [o for o in bundle.outputs.to_list() if not o.is_directory][0]
    expected = ctx.attr.expected_tmpdir or archive.dirname
    asserts.equals(env, expected, bundle.env["TMPDIR"])
    asserts.true(env, bundle.env["TMPDIR"] != "/tmp")
    return analysistest.end(env)

_bundle_tmpdir_test = analysistest.make(
    _bundle_tmpdir_test_impl,
    attrs = {
        "bundle_mnemonic": attr.string(mandatory = True),
        "expected_tmpdir": attr.string(),
    },
)

def starlark_hygiene_test_suite(name):
    """Declares the hygiene tests and their targets under test.

    Args:
        name: Name of the test suite and prefix of its targets.
    """
    flutter_xtool_bundle_version(
        name = name + "_ver",
        build_version = "{n}",
        build_label_pattern = "app_{n}",
        capture_groups = {"n": "n"},
        tags = ["manual"],
    )
    native.genrule(
        name = name + "_runner_src",
        outs = [name + "_AppDelegate.swift"],
        cmd = "echo 'import Foundation' > $@",
        tags = ["manual"],
    )
    for kind, rule, mnemonic in [
        ("ios", flutter_xtool_ios_bundle, "FlutterXtoolIosBundle"),
        ("macos", flutter_xtool_macos_bundle, "FlutterXtoolMacosBundle"),
    ]:
        for variant, env in [("default", {}), ("custom", {"TMPDIR": "custom/scratch"})]:
            target = "%s_%s_%s" % (name, kind, variant)
            rule(
                name = target,
                app_name = "Runner",
                bundle_id = "com.example.runner",
                srcs = [":" + name + "_runner_src"],
                env = env,
                tags = ["manual"],
            )
            _bundle_tmpdir_test(
                name = target + "_check",
                target_under_test = ":" + target,
                bundle_mnemonic = mnemonic,
                expected_tmpdir = env.get("TMPDIR", ""),
            )
    _version_tmpdir_test(name = name + "_ver_check", target_under_test = ":" + name + "_ver")
    small_unittest_suite(name + "_unit", _progress_message_test)
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_ver_check",
        ] + [
            ":%s_%s_%s_check" % (name, kind, variant)
            for kind in ["ios", "macos"]
            for variant in ["default", "custom"]
        ],
    )
