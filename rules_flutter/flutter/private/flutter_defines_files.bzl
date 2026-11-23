"""Dart environment defines of Flutter targets: defines files, `dart_defines`, and defines as configuration.

A debug build compiles Dart as kernel modules. So that a target with its own
environment (its `defines`, its flavor, its `dart_defines` file) stays modular,
that environment is configuration: the target's `deps` edge writes it into the
private rules_dart settings `executable_dart_defines` and
`executable_dart_defines_file`, every module of the closure compiles with it,
and the target's entry module compiles with the same one. Two targets with equal
settings share every module. The global `//flutter:extra_dart_defines` flag is
never written; modules take it after the target's own environment, as the
whole-program compile does.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "DartDefinesInfo",
    "EXECUTABLE_DEFINES_FILE_SETTING",
    "EXECUTABLE_DEFINES_SETTING",
    "canonical_dart_defines",
    "executable_dart_defines",
    "executable_defines_settings",
)
load("//flutter/private:validation.bzl", "merge_dart_defines_with_flavor", "validate_dart_defines")

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
    "files."
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

DEFAULT_FLAVOR_ATTR = attr.string(
    default = "",
    doc = "Repeats the `default-flavor` of the application's `pubspec.yaml`. " +
          "It is not checked against the pubspec. It applies only when " +
          "`flavor` is unset, and then the application behaves exactly as " +
          "if `flavor` were this value; an explicit `flavor` always wins.",
)

# The defines-file attributes of a rule that compiles whole-program only (the
# Android integration-test app). `flutter_application` takes `dart_defines`
# instead; its macro turns `defines_files` and `define_flagfiles` into one.
DEFINES_FILES_APPLICATION_ATTRS = {
    "defines_files": DEFINES_FILES_ATTR,
    "define_flagfiles": DEFINE_FLAGFILES_ATTR,
    "_defines_files_tool": DEFINES_FILES_TOOL_ATTR,
    "default_flavor": DEFAULT_FLAVOR_ATTR,
}

DART_DEFINES_DOC = (
    "A `dart_defines` target: Dart environment defines from files and values, " +
    "parsed once per configuration. Precedence (lowest to highest): its " +
    "defines, then `defines`, then the flavor, then " +
    "`//flutter:extra_dart_defines`. In a debug build every dependency module " +
    "compiles with it, so applications naming the same target (with equal " +
    "`defines` and flavor) share their modules. `flutter_application`'s " +
    "`defines_files` and `define_flagfiles` arguments are a spelling of it."
)

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

def _dart_defines_impl(ctx):
    validate_dart_defines(ctx.attr.values, "the `values` attribute of %s" % ctx.label)
    output = ctx.actions.declare_file(ctx.label.name + ".dart_defines")
    if not ctx.files.srcs and not ctx.files.flagfiles:
        ctx.actions.write(output, "".join(["-D%s\n" % v for v in ctx.attr.values]))
        return [DefaultInfo(files = depset([output])), DartDefinesInfo(flagfile = output)]
    args = ctx.actions.args()
    args.add("--output", output)
    args.add_all(ctx.files.flagfiles, before_each = "--flagfile")
    args.add_all(ctx.attr.values, before_each = "--define")
    args.add_all(ctx.files.srcs)
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [args],
        inputs = ctx.files.srcs + ctx.files.flagfiles,
        outputs = [output],
        mnemonic = "FlutterDartDefines",
        progress_message = "Collecting Dart defines %{label}",
        toolchain = None,
    )
    return [DefaultInfo(files = depset([output])), DartDefinesInfo(flagfile = output)]

dart_defines = rule(
    implementation = _dart_defines_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".json", ".env"],
            doc = "Files of Dart environment defines in `.json` or `.env` format. A `.json` file defines a " +
                  "top-level JSON object whose values are strings, numbers, or booleans; a `.env` file defines " +
                  "one `KEY=VALUE` per line. A key may appear in only one of `srcs` and `flagfiles`.",
        ),
        "flagfiles": attr.label_list(
            allow_files = True,
            doc = "Files of already-spelled `-DKEY=VALUE` lines, one per line.",
        ),
        "values": attr.string_list(
            doc = "`KEY=VALUE` defines, applied after `srcs` and `flagfiles`, so a key here wins.",
        ),
        "_tool": DEFINES_FILES_TOOL_ATTR,
    },
    doc = "Dart environment defines from files and values, written as one `-DKEY=VALUE` line each. Name it " +
          "in `flutter_application.dart_defines`; applications naming the same target share their debug modules.",
)

# Defines as configuration.

_MODE = "//command_line_option:compilation_mode"
_MODULAR_APP = str(Label("//flutter/private:debug_modular_app"))
_SETTINGS = [EXECUTABLE_DEFINES_SETTING, EXECUTABLE_DEFINES_FILE_SETTING]

def own_dart_env(defines, flavor):
    """A target's own environment as its `deps` configuration carries it.

    Args:
        defines: The target's `defines`.
        flavor: The effective flavor, `""` when none.

    Returns:
        The defines, then the flavor define, one per key (the last one written
        wins, as with `-D`), sorted by key.
    """
    env = list(defines)
    if flavor:
        env.append("FLUTTER_APP_FLAVOR=" + flavor)
    return canonical_dart_defines(env)

def _attr_flavor(attr):
    return getattr(attr, "flavor", "") or getattr(attr, "default_flavor", "")

def _target_settings(attr):
    dart_defines = getattr(attr, "dart_defines", None)
    return executable_defines_settings(own_dart_env(attr.defines, _attr_flavor(attr)), dart_defines)

def _app_defines_impl(settings, attr):
    # An application compiles modules only in a debug build with the modular flag on; otherwise its `deps`
    # keep the default configuration and the whole-program compile reads the attributes itself.
    if str(settings[_MODE]) == "dbg" and settings[_MODULAR_APP]:
        return _target_settings(attr)
    return executable_defines_settings()

app_defines_transition = transition(
    implementation = _app_defines_impl,
    inputs = [_MODE, _MODULAR_APP],
    outputs = _SETTINGS,
)

def _debug_defines_impl(settings, attr):
    if str(settings[_MODE]) == "dbg":
        return _target_settings(attr)
    return executable_defines_settings()

# `flutter_kernel_target`: modular in a debug build.
debug_defines_transition = transition(
    implementation = _debug_defines_impl,
    inputs = [_MODE],
    outputs = _SETTINGS,
)

def _defines_impl(_settings, attr):
    return _target_settings(attr)

# `flutter_test` and custom modular kernels: always modular.
defines_transition = transition(
    implementation = _defines_impl,
    inputs = [],
    outputs = _SETTINGS,
)

def entry_dart_env(ctx):
    """The environment a target's entry module compiles with: what its `deps` were configured with.

    Mirrors the `deps` transitions: the target's own environment, then the
    global `//flutter:extra_dart_defines`, and the `dart_defines` file.

    Args:
        ctx: The rule context (`defines` and `_extra_dart_defines`, optionally
            `flavor`, `default_flavor` and `dart_defines`).

    Returns:
        struct(defines, flagfile).
    """
    flavor = effective_flavor(ctx) or ""
    dart_defines = getattr(ctx.attr, "dart_defines", None)
    if type(dart_defines) == "list":
        dart_defines = dart_defines[0] if dart_defines else None
    return struct(
        defines = own_dart_env(ctx.attr.defines, flavor) + _global_extra_defines(ctx),
        flagfile = dart_defines[DartDefinesInfo].flagfile if dart_defines != None else None,
    )

def module_dart_env(ctx):
    """The environment a dependency module compiles with, from its configuration.

    Args:
        ctx: The aspect context (`EXECUTABLE_DEFINES_ATTRS` and `_extra_dart_defines`).

    Returns:
        struct(defines, flagfile).
    """
    own = executable_dart_defines(ctx)
    return struct(defines = own.defines + _global_extra_defines(ctx), flagfile = own.flagfile)

def _global_extra_defines(ctx):
    if getattr(ctx.attr, "_extra_dart_defines", None) == None:
        return []
    return ctx.attr._extra_dart_defines[BuildSettingInfo].value

def refuse_comma_defines(ctx, defines):
    """Fails when a define a modular compile would take holds a comma.

    `kernel_worker` splits `-D` values at commas, and the module compiler is
    replaced only later, so such a value cannot reach a module compile yet.
    Rather than build whole-program silently, the build stops and says so.

    Args:
        ctx: The rule context, for its label.
        defines: The `KEY=VALUE` defines the entry and the modules compile with.
    """
    for d in defines:
        if "," in d.partition("=")[2]:
            fail(("%s: the Dart define %r has a comma in its value. A debug build compiles Dart as kernel " +
                  "modules, and the module compiler cannot take a comma in a define value yet. Remove the " +
                  "comma.") % (ctx.label, d))
