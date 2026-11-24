"""The strict-layering check, for rules outside rules_dart that define executables.

`dart_binary` and `dart_test` check that their sources import only the packages
their `deps` provide (see the `dart_layering_check` feature). A rule set that
defines its own executable rule runs the same check with this file:

```starlark
load("@rules_dart//dart:import_check.bzl", "EXECUTABLE_IMPORT_CHECK_ATTRS", "EXECUTABLE_IMPORT_CHECK_TOOLCHAINS", "dart_import_check_aspect", "executable_import_check")

def _impl(ctx):
    validation = executable_import_check(ctx, None)
    ...
    return [DefaultInfo(executable = exe), OutputGroupInfo(_validation = validation)]

my_exe = rule(
    implementation = _impl,
    executable = True,
    attrs = {
        "main": attr.label(allow_single_file = [".dart"], mandatory = True),
        "srcs": attr.label_list(allow_files = [".dart"]),
        "deps": attr.label_list(providers = [DartInfo], aspects = [dart_import_check_aspect]),
    } | EXECUTABLE_IMPORT_CHECK_ATTRS,
    toolchains = EXECUTABLE_IMPORT_CHECK_TOOLCHAINS,
)
```

Declare the dict in `attrs`, the toolchains in `toolchains` and the aspect on
`deps`; call `executable_import_check` and return its result in the
`_validation` output group, so building the executable runs every check.
"""

load(
    "//dart/private:build_settings.bzl",
    _REFUSED_DART_LIBRARIES_ATTR = "REFUSED_DART_LIBRARIES_ATTR",
)
load(
    "//dart/private:dart_import_check.bzl",
    _dart_import_check_aspect = "dart_import_check_aspect",
    _executable_import_check = "executable_import_check",
)
load("//dart/private:dart_kernel.bzl", _MODULAR_KERNEL_TOOLCHAINS = "MODULAR_KERNEL_TOOLCHAINS")

visibility("public")

# The attributes `executable_import_check` reads beyond `main`, `srcs` and `deps`.
EXECUTABLE_IMPORT_CHECK_ATTRS = {
    "_import_check": attr.label(
        doc = "The tool that checks the executable's imports against its direct `deps`.",
        default = Label("//dart:import_check"),
        executable = True,
        cfg = "exec",
    ),
} | _REFUSED_DART_LIBRARIES_ATTR

# The toolchains the rule declares so the check can find the SDK runtime (optional).
EXECUTABLE_IMPORT_CHECK_TOOLCHAINS = _MODULAR_KERNEL_TOOLCHAINS

dart_import_check_aspect = _dart_import_check_aspect

def executable_import_check(ctx, own_record):
    """Checks an executable's own sources and gathers the stamps below it.

    Args:
      ctx: The executable rule's context, carrying `EXECUTABLE_IMPORT_CHECK_ATTRS`,
        `main`, `srcs` and `deps`, and `EXECUTABLE_IMPORT_CHECK_TOOLCHAINS`.
      own_record: The executable's own `DartPackageInfo`, or `None` when it
        states no package.

    Returns:
      A depset of the check stamps for the `_validation` output group.
    """
    return _executable_import_check(ctx, own_record)
