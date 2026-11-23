"""Analysis tests: a debug app's build record travels in the registrant, not a define.

- a debug `flutter_application` passes no `rules_flutter.build_info` define to
  its `FlutterKernelCompile`, and its registrant hands the record to the agent;
- a release application and a rule without an assets dir carry no record.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "flutter_application", "flutter_kernel_target")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")

visibility(["//flutter/tests/..."])

_PACKAGE = "build_info_registrant_fixture"
_MAIN = "lib/language_version_main.dart"
_DEFINE = "USER_DEFINE=user-value"
_SETTER = "setRulesFlutterBuildInfo"

def _kernel_argv(env):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, 1, len(actions), "expected one FlutterKernelCompile")
    return actions[0].argv if actions else []

def _registrant_source(env, optional = False):
    writes = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename.endswith("plugin_registrant.dart")
    ]
    if optional:
        asserts.true(env, len(writes) <= 1, "expected at most one registrant write")
    else:
        asserts.equals(env, 1, len(writes), "expected exactly one registrant write")
    return writes[0].content if writes else ""

def _no_define_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _kernel_argv(env)
    asserts.equals(env, [], [a for a in argv if "rules_flutter.build_info" in a], "build_info define in argv")
    asserts.true(env, "-D" + _DEFINE in argv, "user define must stay in argv: %s" % argv)
    return analysistest.end(env)

def _registrant_carries_record_test_impl(ctx):
    env = analysistest.begin(ctx)
    source = _registrant_source(env)
    label = str(analysistest.target_under_test(env).label)
    asserts.true(env, "agent." + _SETTER + "('" in source, "registrant must call %s: %s" % (_SETTER, source))
    for expected in [
        '"label":"%s"' % label,
        '"compilationMode":"dbg"',
        '"dartDefines":["%s"]' % _DEFINE,
        '"platformBuildArgs":[]',
        '"assetsDir":"',
        '"targetPlatform":',
    ]:
        asserts.true(env, expected in source, "record misses %s: %s" % (expected, source))
    asserts.true(
        env,
        source.index(_SETTER) < source.index("registerRulesFlutterAgentExtensions"),
        "the record must be handed over before the extensions register",
    )
    return analysistest.end(env)

def _no_record_test_impl(ctx):
    env = analysistest.begin(ctx)
    source = _registrant_source(env, optional = True)
    asserts.false(env, _SETTER in source, "registrant must carry no record: %s" % source)
    asserts.false(env, "assetsDir" in source, "registrant must carry no record: %s" % source)
    return analysistest.end(env)

_DBG = {"//command_line_option:compilation_mode": "dbg", str(Label("//flutter:profile")): False}
_OPT = {"//command_line_option:compilation_mode": "opt", str(Label("//flutter:profile")): False}

_no_define_test = analysistest.make(_no_define_test_impl, config_settings = _DBG)
_record_test = analysistest.make(_registrant_carries_record_test_impl, config_settings = _DBG)
_no_record_dbg_test = analysistest.make(_no_record_test_impl, config_settings = _DBG)
_no_record_opt_test = analysistest.make(_no_record_test_impl, config_settings = _OPT)

def build_info_registrant_test_suite(name):
    """Fixtures and analysis tests for the build record in the registrant.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_build_info_debug_app",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        defines = [_DEFINE],
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_build_info_no_assets_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        tags = ["manual"],
    )
    _no_define_test(name = name + "_no_define", target_under_test = ":_build_info_debug_app", target_compatible_with = HOST_COMPATIBLE)
    _record_test(name = name + "_registrant_record", target_under_test = ":_build_info_debug_app", target_compatible_with = HOST_COMPATIBLE)
    _no_record_opt_test(name = name + "_release_none", target_under_test = ":_build_info_debug_app", target_compatible_with = HOST_COMPATIBLE)
    _no_record_dbg_test(name = name + "_no_assets_none", target_under_test = ":_build_info_no_assets_target", target_compatible_with = HOST_COMPATIBLE)
    native.test_suite(
        name = name,
        tests = [":" + name + "_" + t for t in ["no_define", "registrant_record", "release_none", "no_assets_none"]],
    )
