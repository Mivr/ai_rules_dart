"""Test-enabled dart_library for baseline test targets."""

load("@rules_dart//dart:utils.bzl", "dart_analyzable_info_with_package", "dart_package_identity")
load("@rules_dart//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "create_test_executable")

def _dart_library_test_impl(ctx):
    """Implementation for the _dart_library_test rule."""
    executable, env_info, tool_runfiles = create_test_executable(
        ctx,
        ctx.attr._tool,
        {},
    )
    package_name = ctx.attr.package_name if ctx.attr.package_name else ctx.label.name
    analyzable = dart_analyzable_info_with_package(
        label = ctx.label,
        package = dart_package_identity(
            package_name = package_name,
            lib_root = ctx.label.package,
            language_version = "",
        ),
        package_srcs = ctx.files.srcs,
    )
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs),
            executable = executable,
            runfiles = tool_runfiles,
        ),
        env_info,
        analyzable,
        analyzable.dart_info,
    ]

_dart_library_test = rule(
    implementation = _dart_library_test_impl,
    attrs = dict(
        {
            "srcs": attr.label_list(allow_files = [".dart"]),
            "package_name": attr.string(default = ""),
            "_tool": attr.label(
                default = "@rules_dart//dart/private/tools:noop",
                executable = True,
                cfg = "exec",
            ),
        },
        **WINDOWS_CONSTRAINT_ATTR
    ),
    test = True,
    doc = "A test target shaped as a dart_library.",
)

def dart_library(**kwargs):
    """Declares a baseline dart_library target that can be tested with bazel test."""
    _dart_library_test(**kwargs)
