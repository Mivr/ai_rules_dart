"""A test-only executable rule defined outside `//dart`, using the exported import check."""

load(
    "@rules_dart//dart:import_check.bzl",
    "EXECUTABLE_IMPORT_CHECK_ATTRS",
    "EXECUTABLE_IMPORT_CHECK_TOOLCHAINS",
    "dart_import_check_aspect",
    "executable_import_check",
)
load("@rules_dart//dart:providers.bzl", "DartInfo")

def _outside_exe_impl(ctx):
    """Declares a placeholder executable and returns the import check as its validation."""
    exe = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(exe, "#!/bin/sh\n", is_executable = True)
    return [
        DefaultInfo(executable = exe),
        OutputGroupInfo(_validation = executable_import_check(ctx, None)),
    ]

outside_exe = rule(
    implementation = _outside_exe_impl,
    executable = True,
    attrs = {
        "main": attr.label(
            doc = "The Dart entrypoint.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Further Dart sources of the executable.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "Libraries the executable may import.",
            providers = [DartInfo],
            aspects = [dart_import_check_aspect],
        ),
    } | EXECUTABLE_IMPORT_CHECK_ATTRS,
    toolchains = EXECUTABLE_IMPORT_CHECK_TOOLCHAINS,
    doc = "An executable whose build runs the strict-layering check on its own sources.",
)
