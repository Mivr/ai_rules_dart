"""Tests for application flavor selection, define injection, and asset/shader filtering."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "flutter_application", "flutter_library")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load(":action_content.bzl", "written_json")

visibility(["//flutter/tests/..."])

_PACKAGE = "flavor_test_fixture"
_MAIN = "lib/language_version_main.dart"

def _kernel_compile_action(env):
    """The action that compiles the target's own sources: the whole-program compile, or a debug entry module."""
    actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "FlutterKernelCompile" or (action.mnemonic == "DartKernel" and "--no-drop" in action.argv)
    ]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected one kernel compile of the app's sources, got: %s" % [a.mnemonic for a in actions],
    )
    return actions[0] if actions else None

def _flavored_compile_defines_test_impl(ctx):
    """Flavored application compiles with FLUTTER_APP_FLAVOR=<flavor>."""
    env = analysistest.begin(ctx)
    action = _kernel_compile_action(env)
    argv = action.argv if action else []
    expected_define = "-DFLUTTER_APP_FLAVOR=" + ctx.attr.expected_flavor
    asserts.true(
        env,
        expected_define in argv,
        "expected %s in kernel compile argv, got: %s" % (expected_define, argv),
    )
    if ctx.attr.check_dev_config:
        config = written_json(env, "_dev_config.json")
        if config != None:
            dart_defines = config.get("dartDefines", [])
            asserts.true(
                env,
                "FLUTTER_APP_FLAVOR=" + ctx.attr.expected_flavor in dart_defines,
                "expected FLUTTER_APP_FLAVOR=%s in dev-config dartDefines, got: %s" % (
                    ctx.attr.expected_flavor,
                    dart_defines,
                ),
            )
    return analysistest.end(env)

def _unflavored_compile_defines_test_impl(ctx):
    """Unflavored application compiles without FLUTTER_APP_FLAVOR."""
    env = analysistest.begin(ctx)
    action = _kernel_compile_action(env)
    argv = action.argv if action else []
    flavor_args = [arg for arg in argv if "FLUTTER_APP_FLAVOR" in arg]
    asserts.equals(
        env,
        [],
        flavor_args,
        "unflavored application must not carry FLUTTER_APP_FLAVOR, got: %s" % flavor_args,
    )
    config = written_json(env, "_dev_config.json")
    if config != None:
        dart_defines = config.get("dartDefines", [])
        flavor_defines = [d for d in dart_defines if "FLUTTER_APP_FLAVOR" in d]
        asserts.equals(
            env,
            [],
            flavor_defines,
            "unflavored application dev-config must not carry FLUTTER_APP_FLAVOR, got: %s" % flavor_defines,
        )
    return analysistest.end(env)

def _expect_failure_test_impl(ctx):
    """Failure test asserting expected failure message substrings."""
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_messages:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

_OPT = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): False,
}

_PROFILE = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): True,
}

_flavored_compile_defines_test = analysistest.make(
    _flavored_compile_defines_test_impl,
    attrs = {
        "expected_flavor": attr.string(mandatory = True),
        "check_dev_config": attr.bool(default = True),
    },
    config_settings = _DBG,
)

_flavored_opt_defines_test = analysistest.make(
    _flavored_compile_defines_test_impl,
    attrs = {
        "expected_flavor": attr.string(mandatory = True),
        "check_dev_config": attr.bool(default = False),
    },
    config_settings = _OPT,
)

_flavored_profile_defines_test = analysistest.make(
    _flavored_compile_defines_test_impl,
    attrs = {
        "expected_flavor": attr.string(mandatory = True),
        "check_dev_config": attr.bool(default = False),
    },
    config_settings = _PROFILE,
)

_unflavored_compile_defines_test = analysistest.make(
    _unflavored_compile_defines_test_impl,
    config_settings = _DBG,
)

_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_messages": attr.string_list(mandatory = True)},
)

_extra_defines_dev_flag_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_messages": attr.string_list(mandatory = True)},
    config_settings = {str(Label("//flutter:extra_dart_defines")): ["FLUTTER_APP_FLAVOR=dev"]},
)

_extra_defines_prod_flag_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_messages": attr.string_list(mandatory = True)},
    config_settings = {str(Label("//flutter:extra_dart_defines")): ["FLUTTER_APP_FLAVOR=prod"]},
)

def _declare_compile_defines_targets(name):
    """Declares application targets for compile defines testing."""
    flutter_application(
        name = name + "_app_flavored",
        flavor = "prod",
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )

    _flavored_compile_defines_test(
        name = name + "_flavored_dbg_test",
        size = "small",
        target_under_test = ":" + name + "_app_flavored",
        expected_flavor = "prod",
    )

    _flavored_opt_defines_test(
        name = name + "_flavored_opt_test",
        size = "small",
        target_under_test = ":" + name + "_app_flavored",
        expected_flavor = "prod",
    )

    _flavored_profile_defines_test(
        name = name + "_flavored_profile_test",
        size = "small",
        target_under_test = ":" + name + "_app_flavored",
        expected_flavor = "prod",
    )

    flutter_application(
        name = name + "_app_unflavored",
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )

    _unflavored_compile_defines_test(
        name = name + "_unflavored_dbg_test",
        size = "small",
        target_under_test = ":" + name + "_app_unflavored",
    )

def _declare_conflict_targets(name):
    """Declares targets that violate flavor rules and must fail analysis."""

    # 1. Unflavored target with FLUTTER_APP_FLAVOR in defines attribute.
    flutter_application(
        name = name + "_unflavored_defines_conflict",
        defines = ["FLUTTER_APP_FLAVOR=prod"],
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )

    _failure_test(
        name = name + "_unflavored_defines_conflict_test",
        size = "small",
        target_under_test = ":" + name + "_unflavored_defines_conflict",
        expected_messages = [
            name + "_unflavored_defines_conflict",
            "\"prod\"",
            "\"\"",
            "the flavor is set by the flavor attribute only",
        ],
    )

    # 2. Unflavored target with FLUTTER_APP_FLAVOR in extra_dart_defines flag.
    _extra_defines_dev_flag_test(
        name = name + "_unflavored_extra_flag_conflict_test",
        size = "small",
        target_under_test = ":" + name + "_app_unflavored",
        expected_messages = [
            name + "_app_unflavored",
            "\"dev\"",
            "\"\"",
            "the flavor is set by the flavor attribute only",
        ],
    )

    # 3. Flavored target with conflicting FLUTTER_APP_FLAVOR in defines attribute.
    flutter_application(
        name = name + "_flavored_defines_conflict",
        flavor = "dev",
        defines = ["FLUTTER_APP_FLAVOR=prod"],
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )

    _failure_test(
        name = name + "_flavored_defines_conflict_test",
        size = "small",
        target_under_test = ":" + name + "_flavored_defines_conflict",
        expected_messages = [
            name + "_flavored_defines_conflict",
            "\"prod\"",
            "\"dev\"",
            "the flavor is set by the flavor attribute only",
        ],
    )

    # 4. Flavored target with conflicting FLUTTER_APP_FLAVOR in extra_dart_defines flag.
    flutter_application(
        name = name + "_app_dev_for_flag",
        flavor = "dev",
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )

    _extra_defines_prod_flag_test(
        name = name + "_flavored_extra_flag_conflict_test",
        size = "small",
        target_under_test = ":" + name + "_app_dev_for_flag",
        expected_messages = [
            name + "_app_dev_for_flag",
            "\"prod\"",
            "\"dev\"",
            "the flavor is set by the flavor attribute only",
        ],
    )

def _declare_invalid_flavor_targets(name):
    """Declares targets with invalid flavor strings."""

    # Whitespace
    flutter_application(
        name = name + "_invalid_whitespace",
        flavor = "dev flavor",
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _failure_test(
        name = name + "_invalid_whitespace_test",
        size = "small",
        target_under_test = ":" + name + "_invalid_whitespace",
        expected_messages = [
            name + "_invalid_whitespace",
            "\"dev flavor\"",
            "whitespace, '=' or ','",
        ],
    )

    # Equals '='
    flutter_application(
        name = name + "_invalid_equals",
        flavor = "dev=prod",
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _failure_test(
        name = name + "_invalid_equals_test",
        size = "small",
        target_under_test = ":" + name + "_invalid_equals",
        expected_messages = [
            name + "_invalid_equals",
            "\"dev=prod\"",
            "whitespace, '=' or ','",
        ],
    )

    # Comma ','
    flutter_application(
        name = name + "_invalid_comma",
        flavor = "dev,prod",
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _failure_test(
        name = name + "_invalid_comma_test",
        size = "small",
        target_under_test = ":" + name + "_invalid_comma",
        expected_messages = [
            name + "_invalid_comma",
            "\"dev,prod\"",
            "whitespace, '=' or ','",
        ],
    )

def _declare_default_flavor_targets(name):
    """Declares applications whose flavor comes from `default_flavor`."""
    flutter_application(
        name = name + "_app_default_flavor",
        default_flavor = "prod",
        main = _MAIN,
        package_name = _PACKAGE,
        deps = [":" + name + "_fixture_lib"],
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    flutter_application(
        name = name + "_app_both_flavors",
        flavor = "dev",
        default_flavor = "prod",
        main = _MAIN,
        package_name = _PACKAGE,
        deps = [":" + name + "_fixture_lib"],
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    for suffix, test in (("dbg", _flavored_compile_defines_test), ("opt", _flavored_opt_defines_test), ("profile", _flavored_profile_defines_test)):
        test(
            name = name + "_default_flavor_" + suffix + "_test",
            size = "small",
            target_under_test = ":" + name + "_app_default_flavor",
            expected_flavor = "prod",
        )
    _flavored_compile_defines_test(
        name = name + "_both_flavors_defines_test",
        size = "small",
        target_under_test = ":" + name + "_app_both_flavors",
        expected_flavor = "dev",
    )
    flutter_application(
        name = name + "_default_flavor_invalid",
        default_flavor = "dev flavor",
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _failure_test(
        name = name + "_default_flavor_invalid_test",
        size = "small",
        target_under_test = ":" + name + "_default_flavor_invalid",
        expected_messages = [name + "_default_flavor_invalid", "\"dev flavor\"", "whitespace, '=' or ','"],
    )
    flutter_application(
        name = name + "_default_flavor_conflict",
        default_flavor = "dev",
        defines = ["FLUTTER_APP_FLAVOR=prod"],
        main = _MAIN,
        package_name = _PACKAGE,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _failure_test(
        name = name + "_default_flavor_conflict_test",
        size = "small",
        target_under_test = ":" + name + "_default_flavor_conflict",
        expected_messages = [name + "_default_flavor_conflict", "\"prod\"", "\"dev\"", "does not match"],
    )

def _declare_fixture_lib(name):
    """Declares the library the default-flavor applications depend on."""
    flutter_library(
        name = name + "_fixture_lib",
        package_name = _PACKAGE,
        # Not the applications' `main`: one source belongs to one target.
        srcs = ["lib/web_fixture_main.dart"],
        tags = ["manual"],
    )

def flavor_test_suite(name):
    """Declares all flavor test targets and suites.

    Args:
        name: Common name prefix for test targets.
    """
    _declare_compile_defines_targets(name)
    _declare_conflict_targets(name)
    _declare_invalid_flavor_targets(name)
    _declare_fixture_lib(name)
    _declare_default_flavor_targets(name)

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_flavored_dbg_test",
            ":" + name + "_flavored_opt_test",
            ":" + name + "_flavored_profile_test",
            ":" + name + "_unflavored_dbg_test",
            ":" + name + "_unflavored_defines_conflict_test",
            ":" + name + "_unflavored_extra_flag_conflict_test",
            ":" + name + "_flavored_defines_conflict_test",
            ":" + name + "_flavored_extra_flag_conflict_test",
            ":" + name + "_invalid_whitespace_test",
            ":" + name + "_invalid_equals_test",
            ":" + name + "_invalid_comma_test",
            ":" + name + "_default_flavor_dbg_test",
            ":" + name + "_default_flavor_opt_test",
            ":" + name + "_default_flavor_profile_test",
            ":" + name + "_both_flavors_defines_test",
            ":" + name + "_default_flavor_invalid_test",
            ":" + name + "_default_flavor_conflict_test",
        ],
    )
