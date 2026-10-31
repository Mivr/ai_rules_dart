"""Test-enabled dart_library wrapper for the baseline e2e fixture."""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "dart_info",
    "dart_package_identity",
    "derive_lib_root",
    "derive_package_name",
)

def _dart_library_test_impl(ctx):
    """Implements a test-runnable `dart_library` target for `bazel test`."""
    tool_exe = ctx.executable._noop
    ext = ".exe" if tool_exe.extension == "exe" else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = tool_exe,
        is_executable = True,
    )
    package_name = derive_package_name(
        ctx.attr.package_name,
        ctx.label.package,
        ctx.label.name,
    )
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    info = dart_info(
        label = ctx.label,
        package = dart_package_identity(
            package_name = package_name,
            lib_root = lib_root,
            language_version = ctx.attr.language_version,
        ),
        deps = ctx.attr.deps,
        srcs = ctx.files.srcs,
    )
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs),
            executable = executable,
            runfiles = ctx.attr._noop[DefaultInfo].default_runfiles,
        ),
        info,
    ]

dart_library_test = rule(
    implementation = _dart_library_test_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "Dependencies providing `DartInfo`.",
            providers = [DartInfo],
        ),
        "language_version": attr.string(
            default = "",
            doc = "Optional `<major>.<minor>` Dart language version.",
        ),
        "package_name": attr.string(
            default = "",
            doc = "Explicit Dart package name; defaults to the Bazel package basename.",
        ),
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Dart source files checked by the `dart_analyze` aspect.",
        ),
        "_noop": attr.label(
            cfg = "exec",
            default = ":_noop",
            doc = "Do-nothing Dart binary executed when `bazel test` runs the target.",
            executable = True,
        ),
    },
    test = True,
    doc = "A `dart_library`-shaped test target so `bazel test` exits 0 when analysis passes.",
)

def dart_library(name, srcs, deps = [], package_name = "", language_version = "", visibility = None):
    """Declares a baseline `dart_library` target runnable directly under `bazel test`."""
    dart_library_test(
        name = name,
        srcs = srcs,
        deps = deps,
        package_name = package_name,
        language_version = language_version,
        visibility = visibility,
    )
