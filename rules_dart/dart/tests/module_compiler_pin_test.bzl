"""Tests of the module compiler's pinned sources.

An SDK whose version has no pinned source closure has no module compiler, and
an executable that compiles as kernel modules with it fails at analysis with a
message naming the version: nothing falls back to another compile.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:defs.bzl", "dart_binary")
load("//dart:toolchain.bzl", "DartSdkInfo")
load(
    "//dart/private:module_compiler_versions.bzl",
    "MODULE_COMPILER_SOURCES",
    "module_compiler_sources_label",
)
load("//dart/private:versions.bzl", "TOOL_VERSIONS")

visibility(["//dart/..."])

_UNPINNED_VERSION = "9.9.9"

def _unpinned_sdk_toolchain_impl(ctx):
    files = [
        ctx.actions.declare_file(ctx.label.name + "/" + path)
        for path in [
            "bin/dart",
            "bin/dartaotruntime",
            "bin/snapshots/gen_kernel_aot.dart.snapshot",
            "lib/_internal/vm_platform_strong.dill",
            "lib/_internal/vm_platform_product.dill",
        ]
    ]
    for f in files:
        ctx.actions.write(output = f, content = "", is_executable = True)
    sdk_files = depset(files)
    default = DefaultInfo(files = sdk_files)
    template_variables = platform_common.TemplateVariableInfo({"DART_BIN": files[0].path})
    return [
        default,
        template_variables,
        platform_common.ToolchainInfo(
            # What `dart_toolchain` provides for an SDK version that
            # `MODULE_COMPILER_SOURCES` does not list: no module compiler.
            dart_sdk_info = DartSdkInfo(
                dart = files[0],
                sdk_root = None,
                version = _UNPINNED_VERSION,
                tool_files = sdk_files,
                compile_files = sdk_files,
                runtime_files = sdk_files,
                analyze_files = sdk_files,
                target_os = "",
                target_arch = "",
                cross_gen_snapshot = None,
                cross_dartaotruntime = None,
                patched_gen_kernel = None,
                kernel_module_files = None,
                module_compiler = None,
            ),
            template_variables = template_variables,
            default = default,
        ),
    ]

_unpinned_sdk_toolchain = rule(
    implementation = _unpinned_sdk_toolchain_impl,
    doc = "A Dart SDK toolchain of a version with no pinned module compiler sources.",
)

def _unpinned_sdk_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "the module compiler cannot be built for Dart SDK " + _UNPINNED_VERSION)
    asserts.expect_failure(env, "MODULE_COMPILER_SOURCES")
    return analysistest.end(env)

def _pin_table_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, module_compiler_sources_label(_UNPINNED_VERSION), "an unlisted version has no sources")
    for version, pin in MODULE_COMPILER_SOURCES.items():
        asserts.true(env, version in TOOL_VERSIONS, "%s is pinned but is not an SDK version of the rules" % version)
        asserts.true(env, module_compiler_sources_label(version) != None, "%s has a sources label" % version)
        asserts.equals(env, 64, len(pin.sha256), "%s pins a sha256" % version)
        asserts.equals(env, 40, len(pin.revision), "%s pins the SDK commit" % version)
    return unittest.end(env)

_pin_table_test = unittest.make(_pin_table_test_impl)

# The toolchain the suite below declares; the suite's name is fixed by it.
_SUITE = "module_compiler_pin_test"

_unpinned_sdk_fails_test = analysistest.make(
    _unpinned_sdk_fails_test_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:extra_toolchains": [str(Label("//dart/tests:%s_unpinned_exec_toolchain" % _SUITE))],
    },
)

def module_compiler_pin_test_suite(name):
    """Tests of the pinned module compiler sources.

    Args:
      name: Name of the generated `test_suite`; `module_compiler_pin_test`.
    """
    if name != _SUITE:
        fail("module_compiler_pin_test_suite must be named %s" % _SUITE)
    _unpinned_sdk_toolchain(
        name = name + "_unpinned_sdk",
        tags = ["manual"],
    )
    native.toolchain(
        name = name + "_unpinned_exec_toolchain",
        toolchain = ":" + name + "_unpinned_sdk",
        toolchain_type = "//dart:exec_tools_toolchain_type",
        tags = ["manual"],
    )
    dart_binary(
        name = name + "_kernel_binary",
        compile_mode = "kernel",
        main = "bin/direct_main.dart",
        tags = ["manual"],
    )
    _unpinned_sdk_fails_test(
        name = name + "_unpinned_sdk_fails_test",
        target_under_test = ":" + name + "_kernel_binary",
        size = "small",
    )
    unittest.suite(name + "_unit", _pin_table_test)
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unpinned_sdk_fails_test",
            ":" + name + "_unit",
        ],
    )
