"""Analysis tests: a Flutter toolchain whose Dart SDK has no module compiler fails at analysis, naming the version.

A debug program compiles each library of its closure as a kernel module and
links them; there is no other way to build its kernel. Under a Flutter
toolchain whose Dart SDK version has no pinned module compiler, a debug
`flutter_kernel_target` fails, and so does a `flutter_library`, each naming the
Flutter and Dart versions.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "flutter_library")
load("//flutter:providers.bzl", "FlutterSdkInfo")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")

visibility(["//flutter/tests/..."])

_FLUTTER_VERSION = "9.9.9-unpinned"
_DART_VERSION = "9.8.7"

def _unpinned_flutter_toolchain_impl(ctx):
    def stub(name, executable = False):
        f = ctx.actions.declare_file(ctx.label.name + "/" + name)
        ctx.actions.write(f, "", is_executable = executable)
        return f

    files = depset([])
    info = FlutterSdkInfo(
        version = _FLUTTER_VERSION,
        engine_revision = "unpinned",
        dart = stub("dart", True),
        dartaotruntime = stub("dartaotruntime", True),
        dart_module_compiler = None,
        dart_sdk_version = _DART_VERSION,
        gen_snapshot = stub("gen_snapshot", True),
        flutter_tester = stub("flutter_tester", True),
        frontend_server = stub("frontend_server.snapshot"),
        platform_kernel_dill = stub("platform_strong.dill"),
        platform_kernel_dill_product = stub("platform_strong_product.dill"),
        patched_sdk = None,
        icu_data = stub("icudtl.dat"),
        tool_files = files,
        dart_vm_files = files,
        dart_pub_files = files,
        dart2wasm_files = files,
        dart2js_files = files,
        engine_library = None,
        font_subset = None,
        impellerc = None,
        shader_lib = None,
        material_icons_font = None,
        vm_isolate_snapshot = None,
        isolate_snapshot = None,
        target_os = "linux",
        target_arch = "x64",
        linux_sysroot = None,
    )
    return [platform_common.ToolchainInfo(flutter_sdk_info = info)]

unpinned_flutter_toolchain = rule(
    implementation = _unpinned_flutter_toolchain_impl,
    doc = "A Flutter toolchain whose Dart SDK version has no pinned module compiler.",
)

_CONFIG = {
    "//command_line_option:compilation_mode": "dbg",
    "//command_line_option:extra_toolchains": [str(Label("//flutter/tests:_unpinned_flutter_toolchain"))],
    str(Label("//flutter:profile")): False,
}

def _refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "compiles Flutter kernel modules, but the module compiler cannot be built")
    asserts.expect_failure(env, "Flutter %s (Dart %s)" % (_FLUTTER_VERSION, _DART_VERSION))
    return analysistest.end(env)

_refused_test = analysistest.make(_refused_impl, expect_failure = True, config_settings = _CONFIG)

def unpinned_sdk_test_suite(name):
    """Fixtures and analysis tests for a Flutter toolchain without a module compiler.

    Args:
        name: The test suite name.
    """
    unpinned_flutter_toolchain(name = "_unpinned_flutter_sdk", tags = ["manual"])
    native.toolchain(
        name = "_unpinned_flutter_toolchain",
        toolchain = ":_unpinned_flutter_sdk",
        toolchain_type = "//flutter:toolchain_type",
    )
    flutter_library(
        name = "_unpinned_sdk_library",
        package_name = "unpinned_sdk_library",
        srcs = ["lib/web_fixture_main.dart"],
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_unpinned_sdk_kernel",
        package_name = "unpinned_sdk_kernel",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
    )
    _refused_test(name = name + "_library", target_under_test = ":_unpinned_sdk_library")
    _refused_test(name = name + "_kernel", target_under_test = ":_unpinned_sdk_kernel")
    native.test_suite(name = name, tests = [name + "_library", name + "_kernel"])
