"""Analysis-only Android C++ toolchain for `flutter_android_registrant`.

`flutter_android_registrant` transitions its `flutter_application` to
`//flutter/platforms:android_arm64` to read `FlutterApplicationInfo.plugins`
and write `GeneratedPluginRegistrant.java`. `shared_preferences_android`
depends on `package:jni`, whose overlay declares `@deps__jni//:dartjni`
(`cc_shared_library`) under `@platforms//os:android`. Analyzing that target
requires a registered C++ toolchain for Android even though generating the
Java registrant runs no C++ compile or link action.
"""

load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "tool_path")
load("@rules_cc//cc:defs.bzl", "CcToolchainConfigInfo", "cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

visibility("private")

def _android_cc_toolchain_config_impl(ctx):
    """Returns a minimal CcToolchainConfigInfo for Android target analysis.

    Args:
        ctx: Rule context for `android_cc_toolchain_config`.

    Returns:
        A `CcToolchainConfigInfo` provider for `ctx.attr.cpu`.
    """
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "android_stub_%s" % ctx.attr.cpu,
        host_system_name = "local",
        target_system_name = "%s-linux-android" % ctx.attr.cpu,
        target_cpu = ctx.attr.cpu,
        target_libc = "bionic",
        compiler = "clang",
        abi_version = "android",
        abi_libc_version = "android",
        tool_paths = [
            tool_path(name = name, path = "/bin/false")
            for name in ("ar", "cpp", "gcc", "gcov", "ld", "nm", "objdump", "strip")
        ],
    )

android_cc_toolchain_config = rule(
    implementation = _android_cc_toolchain_config_impl,
    attrs = {
        "cpu": attr.string(
            mandatory = True,
            doc = "Target Android CPU identifier (for example `aarch64` or `x86_64`).",
        ),
    },
    provides = [CcToolchainConfigInfo],
    doc = "Minimal Android C++ toolchain config so `flutter_android_registrant` analyzes without an installed NDK.",
)

def declare_android_cc_toolchains(name):
    """Declares `cc_toolchain` and `toolchain` targets for Android arm64 and x86_64.

    Args:
        name: Prefix for the generated toolchain targets.
    """
    native.filegroup(
        name = "%s_empty" % name,
        srcs = [],
    )
    for cpu in ("aarch64", "x86_64"):
        android_cc_toolchain_config(
            name = "%s_%s_config" % (name, cpu),
            cpu = cpu,
        )
        cc_toolchain(
            name = "%s_%s_toolchain_impl" % (name, cpu),
            all_files = ":%s_empty" % name,
            ar_files = ":%s_empty" % name,
            as_files = ":%s_empty" % name,
            compiler_files = ":%s_empty" % name,
            dwp_files = ":%s_empty" % name,
            linker_files = ":%s_empty" % name,
            objcopy_files = ":%s_empty" % name,
            strip_files = ":%s_empty" % name,
            supports_param_files = 0,
            toolchain_config = ":%s_%s_config" % (name, cpu),
            toolchain_identifier = "android_stub_%s" % cpu,
        )
        native.toolchain(
            name = "%s_%s_toolchain" % (name, cpu),
            target_compatible_with = [
                "@@platforms//os:android",
                "@@platforms//cpu:%s" % cpu,
            ],
            toolchain = ":%s_%s_toolchain_impl" % (name, cpu),
            toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        )
