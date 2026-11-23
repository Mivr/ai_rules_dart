"""Defines files parsing and flagfile generation for flutter_application."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//flutter/private:validation.bzl", "merge_dart_defines_with_flavor")

visibility(["//flutter/..."])

DEFINES_FILES_DOC = (
    "Files of Dart environment defines in `.json` or `.env` format. " +
    "A `.json` file must define a top-level JSON object whose values are " +
    "strings, numbers, or booleans. A `.env` file defines one `KEY=VALUE` " +
    "per line. Defines are parsed in an action and emitted as a flagfile, " +
    "so the file content never reaches the compiler command line. " +
    "Precedence (lowest to highest): `defines_files` in list order, then " +
    "`defines`, then `//flutter:extra_dart_defines`. Keys defined in " +
    "`defines` or `extra_dart_defines` override matching keys from these " +
    "files. `defines_files` is not read by a custom kernel pipeline."
)

DEFINES_FILES_ATTR = attr.label_list(
    allow_files = [".json", ".env"],
    doc = DEFINES_FILES_DOC,
)

DEFINE_FLAGFILES_DOC = (
    "Files of Dart environment defines, one already-spelled " +
    "`-Dname=value` argument per line. Each file is passed to the " +
    "kernel compile as `@<file>` and declared as an action input, so " +
    "its values stay out of the action command line and `bazel " +
    "aquery` while a change to its content changes the action key. " +
    "Unset, every action is unchanged."
)

DEFINE_FLAGFILES_ATTR = attr.label_list(
    doc = DEFINE_FLAGFILES_DOC,
    allow_files = True,
)

DEFINES_FILES_TOOL_ATTR = attr.label(
    doc = "Tool that parses defines_files and generates a kernel flagfile.",
    default = Label("//flutter/private/tools:defines_files"),
    executable = True,
    cfg = "exec",
)

DEFINES_FILES_APPLICATION_ATTRS = {
    "defines_files": DEFINES_FILES_ATTR,
    "define_flagfiles": DEFINE_FLAGFILES_ATTR,
    "_defines_files_tool": DEFINES_FILES_TOOL_ATTR,
    "default_flavor": attr.string(
        default = "",
        doc = "Repeats the `default-flavor` of the application's `pubspec.yaml`. " +
              "It is not checked against the pubspec. It applies only when " +
              "`flavor` is unset, and then the application behaves exactly as " +
              "if `flavor` were this value; an explicit `flavor` always wins.",
    ),
}

EXTRA_DART_DEFINES_ATTR = {
    "_extra_dart_defines": attr.label(
        doc = "The //flutter:extra_dart_defines build setting, appended after the target's own `defines`.",
        default = Label("//flutter:extra_dart_defines"),
    ),
}

def effective_flavor(ctx):
    """The flavor an application builds with: `flavor`, else `default_flavor`.

    Args:
        ctx: Rule context; either attribute may be undeclared.

    Returns:
        The flavor string (`""` when neither is set), or None when the rule
        declares no `flavor` attribute.
    """
    if not hasattr(ctx.attr, "flavor"):
        return None
    default_flavor = ctx.attr.default_flavor if hasattr(ctx.attr, "default_flavor") else ""
    return ctx.attr.flavor or default_flavor

def merge_dart_defines(ctx):
    """Merge a target's `defines` attr with the extra_dart_defines flag and flavor.

    Flag values come after attr values, so on a duplicated key the command
    line wins (the compilers take the last -D). The flag validates its own
    value in its rule impl; only the attr is validated here.

    Args:
        ctx: Rule context with `defines` and `_extra_dart_defines` attrs.

    Returns:
        The merged list of KEY=VALUE define strings.
    """
    return merge_dart_defines_with_flavor(
        ctx.label,
        ctx.attr.defines,
        ctx.attr._extra_dart_defines[BuildSettingInfo].value,
        effective_flavor(ctx),
    )

def collect_define_flagfiles(ctx, user_defines):
    """Collects user define_flagfiles and prepends a generated flagfile if defines_files is set.

    Args:
        ctx: The rule context.
        user_defines: List of user defines (KEY=VALUE strings) to exclude from
            the generated flagfile when overridden by higher-precedence defines.

    Returns:
        List of File objects representing the define flagfiles to pass to the kernel compile.
    """
    user_flagfiles = getattr(ctx.files, "define_flagfiles", [])
    if not hasattr(ctx.files, "defines_files"):
        return user_flagfiles
    defines_files = ctx.files.defines_files
    if not defines_files:
        return user_flagfiles

    output = ctx.actions.declare_file(ctx.label.name + "_defines_files.defines")
    args = ctx.actions.args()
    args.add("--output", output)
    for define in user_defines:
        args.add("--exclude-define", define)
    args.add_all(defines_files)

    ctx.actions.run(
        executable = ctx.executable._defines_files_tool,
        arguments = [args],
        inputs = defines_files,
        outputs = [output],
        mnemonic = "FlutterDefinesFiles",
        progress_message = "Generating Dart defines flagfile %s" % output.short_path,
        toolchain = None,
    )
    return [output] + user_flagfiles
