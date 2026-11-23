"""Analysis tests for `flutter_apple_xcframework_import`.

The Linux cases use the xtool backend with the iOS platform transition, so
they prove the import carries `FlutterDarwinFrameworkInfo` and `CcInfo` and
that a consumer analyzes without an Apple SDK. The `rules_apple` provider
shape is asserted on macOS only, where the Apple toolchain exists.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_apple//apple:providers.bzl", "AppleDynamicFrameworkInfo", "AppleFrameworkImportInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:ios.bzl", "flutter_apple_xcframework_import")
load("//flutter:providers.bzl", "FlutterDarwinFrameworkInfo")

visibility(["//flutter/tests/..."])

_XCFRAMEWORK = "//flutter/tests:TinyKit.xcframework"
_FRAMEWORK = "//flutter/tests:TinyKit.framework"

def _xtool_config(platform):
    """The config settings that analyze an import on xtool without a Mac.

    Args:
        platform: `"ios"` or `"macos"`.

    Returns:
        The `config_settings` dict for `analysistest.make`.
    """
    return {
        "//command_line_option:platforms": str(Label("//flutter/platforms:%s_arm64" % platform)),
        str(Label("//flutter/settings:apple_backend")): "xtool",
    }

_XTOOL_IOS = _xtool_config("ios")

_MACOS_RULES_APPLE = {
    "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
    "//command_line_option:platforms": str(Label("//flutter/platforms:macos_arm64")),
    "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
    str(Label("//flutter/settings:apple_backend")): "rules_apple",
}

_ImportedHeadersInfo = provider(
    doc = "Headers a consumer sees through its import's `CcInfo`.",
    fields = {
        "headers": "depset[File]: Compilation headers from the import.",
    },
)

def _consumer_impl(ctx):
    headers = []
    for dep in ctx.attr.deps:
        headers.extend(dep[CcInfo].compilation_context.headers.to_list())
    return [_ImportedHeadersInfo(headers = depset(headers))]

_consumer = rule(
    implementation = _consumer_impl,
    attrs = {
        "deps": attr.label_list(
            mandatory = True,
            providers = [CcInfo],
            doc = "Targets whose `CcInfo` headers the consumer records.",
        ),
    },
    doc = "A target that lists an Apple framework import in `deps` and records its headers.",
)

def _xtool_ios_transition_impl(_settings, _attr):
    return {
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
        "//flutter/settings:apple_backend": "xtool",
    }

_xtool_ios_transition = transition(
    implementation = _xtool_ios_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//flutter/settings:apple_backend",
    ],
)

def _xtool_ios_targets_impl(ctx):
    files = [target[DefaultInfo].files for target in ctx.attr.targets]
    return [DefaultInfo(files = depset(transitive = files))]

_xtool_ios_targets = rule(
    implementation = _xtool_ios_targets_impl,
    attrs = {
        "targets": attr.label_list(
            cfg = _xtool_ios_transition,
            mandatory = True,
            doc = "Targets built in an iOS xtool configuration.",
        ),
    },
    doc = "Builds its targets in the xtool iOS configuration.",
)

def _xtool_import_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.true(
        env,
        FlutterDarwinFrameworkInfo in tut,
        "Expected FlutterDarwinFrameworkInfo on %s" % tut.label,
    )
    asserts.true(
        env,
        CcInfo in tut,
        "Expected CcInfo on %s" % tut.label,
    )
    asserts.equals(
        env,
        ctx.attr.expected_dynamic,
        tut[FlutterDarwinFrameworkInfo].is_dynamic,
        "Expected is_dynamic = %s on %s" % (ctx.attr.expected_dynamic, tut.label),
    )
    return analysistest.end(env)

_xtool_import_test = analysistest.make(
    _xtool_import_test_impl,
    attrs = {
        "expected_dynamic": attr.bool(mandatory = True),
    },
    config_settings = _XTOOL_IOS,
    doc = "Asserts the xtool import's FlutterDarwinFrameworkInfo and linkage.",
)

def _apple_import_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.true(
        env,
        AppleFrameworkImportInfo in tut,
        "Expected AppleFrameworkImportInfo on %s" % tut.label,
    )
    asserts.equals(
        env,
        ctx.attr.expected_dynamic,
        AppleDynamicFrameworkInfo in tut,
        "Expected AppleDynamicFrameworkInfo present = %s on %s" % (
            ctx.attr.expected_dynamic,
            tut.label,
        ),
    )
    asserts.true(env, SwiftInfo in tut, "Expected SwiftInfo on %s" % tut.label)
    paths = [h.path for h in tut[CcInfo].compilation_context.headers.to_list()]
    asserts.true(
        env,
        any([path.endswith("TinyKit.framework/Modules/module.modulemap") for path in paths]),
        "Expected TinyKit.framework/Modules/module.modulemap in CcInfo headers, got %s" % paths,
    )
    return analysistest.end(env)

_apple_import_test = analysistest.make(
    _apple_import_test_impl,
    attrs = {
        "expected_dynamic": attr.bool(mandatory = True),
    },
    config_settings = _MACOS_RULES_APPLE,
    doc = "Asserts the rules_apple import providers for one shape and linkage.",
)

def _consumer_headers_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    headers = [header.basename for header in tut[_ImportedHeadersInfo].headers.to_list()]
    asserts.true(
        env,
        "TinyKit.h" in headers,
        "Expected TinyKit.h in the consumer's headers, got %s" % headers,
    )
    return analysistest.end(env)

_consumer_headers_test = analysistest.make(
    _consumer_headers_test_impl,
    config_settings = _XTOOL_IOS,
    doc = "Asserts a consumer sees the imported fixture's header through CcInfo.",
)

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_substrings": attr.string_list(mandatory = True),
    },
    doc = "Asserts the target fails analysis with each expected substring.",
)

_xtool_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_substrings": attr.string_list(mandatory = True),
    },
    config_settings = _XTOOL_IOS,
    doc = "Asserts the target fails analysis on xtool with each expected substring.",
)

def _bad_shape_message():
    """The exact error for a label that names neither framework shape."""
    return (
        'flutter_apple_xcframework_import: "framework" must name one ' +
        ".xcframework or .framework directory, got " +
        '"//flutter/tests:not_a_framework".'
    )

def _bad_linkage_message():
    """The exact error for a linkage besides static and dynamic."""
    return 'flutter_apple_xcframework_import: "linkage" must be "static" or "dynamic", got "fat".'

def _dynamic_error_message(attribute):
    """The exact rules_apple error for an argument a dynamic import cannot carry.

    Args:
        attribute: The offending attribute name.

    Returns:
        The message text.
    """
    return (
        'flutter_apple_xcframework_import: linkage "dynamic" cannot carry "%s". ' +
        "The rules_apple dynamic imports take neither alwayslink nor an SDK framework " +
        'or dylib list; use linkage = "static", or link them from the target that ' +
        "depends on this one."
    ) % attribute

def _xtool_error_message(attribute):
    """The exact xtool error for an argument the backend cannot carry.

    Args:
        attribute: The offending attribute name.

    Returns:
        The message text.
    """
    return (
        "flutter_apple_xcframework_import: the xtool backend links prebuilt frameworks " +
        'with -F/-framework and cannot carry "%s". Build with backend = "rules_apple" ' +
        "on macOS, or drop the argument."
    ) % attribute

def _declare_xtool_tests(name):
    """Declare the xtool provider, consumer and build cases.

    Args:
        name: Prefix for the targets.

    Returns:
        The test target names.
    """
    tests = []
    flutter_apple_xcframework_import(
        name = name + "_xcframework_static",
        framework = _XCFRAMEWORK,
    )
    flutter_apple_xcframework_import(
        name = name + "_xcframework_dynamic",
        framework = _XCFRAMEWORK,
        linkage = "dynamic",
    )
    flutter_apple_xcframework_import(
        name = name + "_framework_static",
        framework = _FRAMEWORK,
    )
    flutter_apple_xcframework_import(
        name = name + "_framework_dynamic",
        framework = _FRAMEWORK,
        linkage = "dynamic",
    )

    for shape in ("xcframework", "framework"):
        for linkage in ("static", "dynamic"):
            test = "%s_xtool_%s_%s_test" % (name, shape, linkage)
            _xtool_import_test(
                name = test,
                target_under_test = ":%s_%s_%s" % (name, shape, linkage),
                expected_dynamic = linkage == "dynamic",
            )
            tests.append(test)

    consumers = []
    for shape in ("xcframework", "framework"):
        consumer = "%s_%s_consumer" % (name, shape)
        _consumer(
            name = consumer,
            deps = [":%s_%s_static" % (name, shape)],
            tags = ["manual"],
        )
        test = consumer + "_test"
        _consumer_headers_test(
            name = test,
            target_under_test = ":" + consumer,
        )
        tests.append(test)
        consumers.append(consumer)

    _xtool_ios_targets(
        name = name + "_consumer_targets",
        targets = consumers,
        tags = ["manual"],
    )
    test = name + "_consumer_build_test"
    build_test(
        name = test,
        targets = [":" + name + "_consumer_targets"],
    )
    tests.append(test)
    return tests

def _declare_rules_apple_tests(name):
    """Declare the `rules_apple` provider cases, which also run on Linux.

    Args:
        name: Prefix for the targets.

    Returns:
        The test target names.
    """
    tests = []
    for shape in ("xcframework", "framework"):
        for linkage in ("static", "dynamic"):
            target = "%s_%s_%s" % (name, shape, linkage)
            test = target + "_test"
            _apple_import_test(
                name = test,
                target_under_test = ":" + target,
                expected_dynamic = linkage == "dynamic",
            )
            tests.append(test)
    return tests

def _declare_failure_test(name, target, message, xtool = False):
    """Declare one exact-message analysis failure case.

    Args:
        name: Test target name.
        target: Target expected to fail analysis.
        message: The exact substring the failure must contain.
        xtool: Whether to analyze the target on the xtool backend.
    """
    if xtool:
        _xtool_expect_failure_test(
            name = name,
            target_under_test = target,
            expected_substrings = [message],
        )
    else:
        _expect_failure_test(
            name = name,
            target_under_test = target,
            expected_substrings = [message],
        )

def _declare_error_tests(name):
    """Declare the exact-message analysis failure cases.

    Args:
        name: Prefix for the targets.

    Returns:
        The test target names.
    """
    flutter_apple_xcframework_import(
        name = name + "_bad_shape",
        framework = "//flutter/tests:not_a_framework",
    )
    flutter_apple_xcframework_import(
        name = name + "_bad_linkage",
        framework = _XCFRAMEWORK,
        linkage = "fat",
    )
    flutter_apple_xcframework_import(
        name = name + "_dynamic_alwayslink",
        framework = _XCFRAMEWORK,
        linkage = "dynamic",
        alwayslink = True,
    )
    flutter_apple_xcframework_import(
        name = name + "_dynamic_sdk_frameworks",
        framework = _FRAMEWORK,
        linkage = "dynamic",
        sdk_frameworks = ["UIKit"],
    )
    flutter_apple_xcframework_import(
        name = name + "_xtool_alwayslink",
        framework = _XCFRAMEWORK,
        alwayslink = True,
    )
    flutter_apple_xcframework_import(
        name = name + "_xtool_sdk_dylibs",
        framework = _FRAMEWORK,
        sdk_dylibs = ["z"],
    )

    _declare_failure_test(
        name = name + "_bad_shape_test",
        target = ":" + name + "_bad_shape",
        message = _bad_shape_message(),
    )
    _declare_failure_test(
        name = name + "_bad_linkage_test",
        target = ":" + name + "_bad_linkage",
        message = _bad_linkage_message(),
    )
    _declare_failure_test(
        name = name + "_dynamic_alwayslink_test",
        target = ":" + name + "_dynamic_alwayslink",
        message = _dynamic_error_message("alwayslink"),
    )
    _declare_failure_test(
        name = name + "_dynamic_sdk_frameworks_test",
        target = ":" + name + "_dynamic_sdk_frameworks",
        message = _dynamic_error_message("sdk_frameworks"),
    )
    _declare_failure_test(
        name = name + "_dynamic_alwayslink_xtool_test",
        target = ":" + name + "_dynamic_alwayslink",
        message = _xtool_error_message("alwayslink"),
        xtool = True,
    )
    _declare_failure_test(
        name = name + "_xtool_alwayslink_test",
        target = ":" + name + "_xtool_alwayslink",
        message = _xtool_error_message("alwayslink"),
        xtool = True,
    )
    _declare_failure_test(
        name = name + "_xtool_sdk_dylibs_test",
        target = ":" + name + "_xtool_sdk_dylibs",
        message = _xtool_error_message("sdk_dylibs"),
        xtool = True,
    )
    return [
        name + "_bad_shape_test",
        name + "_bad_linkage_test",
        name + "_dynamic_alwayslink_test",
        name + "_dynamic_sdk_frameworks_test",
        name + "_dynamic_alwayslink_xtool_test",
        name + "_xtool_alwayslink_test",
        name + "_xtool_sdk_dylibs_test",
    ]

def flutter_apple_xcframework_import_test_suite(name):
    """Declare the analysis tests for `flutter_apple_xcframework_import`.

    Args:
        name: Prefix for the targets and name of the aggregate test suite.
    """
    tests = _declare_xtool_tests(name)
    tests.extend(_declare_rules_apple_tests(name))
    tests.extend(_declare_error_tests(name))
    native.test_suite(
        name = name,
        tests = tests,
    )
