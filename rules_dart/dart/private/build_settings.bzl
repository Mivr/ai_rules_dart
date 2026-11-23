"""The `//dart:extra_dart_defines` build setting and its plumbing.

A `defines` attribute pins environment declarations to one target. This flag is
the command-line channel for the same thing: a `.bazelrc` config group can point
an entire build at an environment without editing BUILD files, which is what
makes `--config=staging` reach a binary, its tests, and its probes alike.

Flag values are appended *after* a target's own `defines`, so the command line
wins on a key collision — every Dart compiler takes the last `-D` for a
repeated key.

Unlike rules_flutter's equivalent, no define keys are reserved here. That list
exists there because the Flutter build sets `dart.vm.product` and friends itself
from the compilation mode, and a user value would silently fight it. rules_dart
maps compilation mode to `--enable-asserts` and gen-snapshot options only and
sets no define of its own, so it has nothing to protect.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

visibility(["//dart/..."])

def dart_define_error(define, what):
    """Returns an error string if `define` is not a usable `-D` entry.

    Args:
      define: A define string. Normally `KEY=VALUE`; a bare `KEY` is a key with
        no value, which the Dart compilers accept.
      what: Where the define came from, named in the message — a target label
        or the flag name.

    Returns:
      An error string, or None when the entry is usable.
    """
    if not define:
        return (("Empty Dart define in %s. Entries are `KEY` or `KEY=VALUE`; " +
                 "an empty one becomes a bare `-D`, which the compiler rejects.") %
                what)
    if define.startswith("="):
        return (("Dart define %r in %s has an empty key. " +
                 "Entries are `KEY` or `KEY=VALUE`.") % (define, what))
    return None

def validate_dart_defines(defines, what):
    """Fails on the first unusable define.

    Args:
      defines: List of define strings.
      what: Where they came from, named in any failure message.
    """
    for define in defines:
        err = dart_define_error(define, what)
        if err != None:
            fail(err)

def _dart_defines_flag_impl(ctx):
    validate_dart_defines(ctx.build_setting_value, "--%s" % ctx.label)
    return BuildSettingInfo(value = ctx.build_setting_value)

dart_defines_flag = rule(
    implementation = _dart_defines_flag_impl,
    # `repeatable` so each occurrence contributes one whole list element.
    # skylib's `string_list_flag` splits a value on commas, which would turn
    # `-DA=1,2` into two broken entries before the compiler ever sees it.
    build_setting = config.string_list(flag = True, repeatable = True),
    doc = "A repeatable list of Dart environment declarations (`KEY=VALUE`), " +
          "appended after a target's own `defines` so the command line wins " +
          "on a key collision.",
)

EXTRA_DART_DEFINES_ATTR = {
    "_extra_dart_defines": attr.label(
        doc = "The //dart:extra_dart_defines build setting, appended after the target's own `defines`.",
        default = Label("//dart:extra_dart_defines"),
    ),
}

def merge_dart_defines(ctx):
    """Merges a target's `defines` attr with the `extra_dart_defines` flag.

    The flag validates its own value in its rule implementation, so only the
    attr is validated here.

    Args:
      ctx: Rule context carrying `defines` and `_extra_dart_defines`.

    Returns:
      The merged list of define strings, flag values last.
    """
    validate_dart_defines(ctx.attr.defines, "the `defines` attribute of %s" % ctx.label)
    return list(ctx.attr.defines) + ctx.attr._extra_dart_defines[BuildSettingInfo].value

def _is_refusable_library(entry):
    """Whether `entry` is `dart:<name>` with `<name>` made of `[a-z_]+`."""
    if not entry.startswith("dart:"):
        return False
    name = entry[len("dart:"):]
    return len(name) > 0 and not [c for c in name.elems() if c != "_" and not ("a" <= c and c <= "z")]

def _refused_dart_libraries_flag_impl(ctx):
    """Fails on an entry that is not `dart:<name>`; otherwise exposes the list."""
    for entry in ctx.build_setting_value:
        if not _is_refusable_library(entry):
            fail(("Bad entry %r in --%s. Entries are `dart:<name>` with `<name>` " +
                  "made of lowercase letters and underscores, such as `dart:mirrors`.") %
                 (entry, ctx.label))
    return BuildSettingInfo(value = ctx.build_setting_value)

refused_dart_libraries_flag = rule(
    implementation = _refused_dart_libraries_flag_impl,
    # `repeatable` for the same reason as `dart_defines_flag`: one whole entry
    # per occurrence, never split on commas.
    build_setting = config.string_list(flag = True, repeatable = True),
    doc = "A repeatable list of `dart:` libraries (`dart:<name>`) that the " +
          "import check refuses in `import` and `export` directives.",
)

REFUSED_DART_LIBRARIES_ATTR = {
    "_refused_dart_libraries": attr.label(
        doc = "The //dart:refused_dart_libraries build setting, passed to the import check.",
        default = Label("//dart:refused_dart_libraries"),
    ),
}

def refused_library_args(ctx):
    """The `dart:` libraries the import check refuses.

    Args:
      ctx: Rule or aspect context carrying `_refused_dart_libraries`.

    Returns:
      The list of `dart:<name>` entries, empty by default.
    """
    return ctx.attr._refused_dart_libraries[BuildSettingInfo].value

def global_dart_defines(ctx):
    """The `//dart:extra_dart_defines` flag's values, shared by every module of a build.

    Args:
      ctx: A rule context carrying `_extra_dart_defines` (`EXTRA_DART_DEFINES_ATTR`).

    Returns:
      The list of `KEY` or `KEY=VALUE` strings.
    """
    if not hasattr(ctx.attr, "_extra_dart_defines"):
        return []
    return ctx.attr._extra_dart_defines[BuildSettingInfo].value

# An executable's own environment is configuration.
#
# A test, a kernel binary or a Flutter app with its own `defines` (a Flutter app
# also with a flavor and a defines file) sets these two private settings on its
# `deps` edge. Every module of its closure then compiles with that environment
# and the executable's entry compiles with the same one, so the executable stays
# modular; two executables with equal settings land in one configuration and
# share every module. Both rule sets use these settings, so a reset on an edge
# that leaves Dart (`native_defines_reset`) covers both. The global
# `extra_dart_defines` flags are never written: modules take them after these.
EXECUTABLE_DEFINES_SETTING = str(Label("//dart/private:executable_dart_defines"))
EXECUTABLE_DEFINES_FILE_SETTING = str(Label("//dart/private:executable_dart_defines_file"))
_NO_DEFINES_FILE = str(Label("//dart/private:no_dart_defines_file"))

DartDefinesInfo = provider(
    doc = "A set of Dart environment declarations, written by an action as one `-DKEY=VALUE` line each.",
    fields = {
        "flagfile": "The File of `-DKEY=VALUE` lines, or None for no declarations.",
    },
)

def _no_dart_defines_impl(_ctx):
    return [DartDefinesInfo(flagfile = None)]

no_dart_defines = rule(
    implementation = _no_dart_defines_impl,
    doc = "No Dart environment declarations: the default of `//dart/private:executable_dart_defines_file`.",
)

def canonical_dart_defines(defines):
    """One entry per key, the last one written winning as with `-D`, sorted by key.

    Sorting makes the configuration independent of the order the defines were
    written in, so equal environments share every module.

    Args:
      defines: `KEY` or `KEY=VALUE` strings.

    Returns:
      The sorted list.
    """
    by_key = {}
    for d in defines:
        by_key[d.partition("=")[0]] = d
    return [by_key[k] for k in sorted(by_key.keys())]

def executable_defines_settings(defines = [], defines_file = None):
    """The settings an executable's `deps` edge writes.

    Args:
      defines: The executable's own `KEY=VALUE` defines (a Flutter app adds its
        flavor define); canonicalized here.
      defines_file: The Label of a target providing `DartDefinesInfo`, or None.

    Returns:
      A dict from setting label to value, for a transition to return. With no
      arguments it holds the defaults, which Bazel drops from the configuration.
    """
    return {
        EXECUTABLE_DEFINES_SETTING: canonical_dart_defines(defines),
        EXECUTABLE_DEFINES_FILE_SETTING: str(defines_file) if defines_file != None else _NO_DEFINES_FILE,
    }

def _native_defines_reset_impl(_settings, _attr):
    return executable_defines_settings()

# The transition on every edge that leaves Dart for native code (code assets,
# plugin libraries, native assets): back to the defaults, so native code is
# configured once whatever environment the Dart closure above it compiles with.
native_defines_reset = transition(
    implementation = _native_defines_reset_impl,
    inputs = [],
    outputs = [EXECUTABLE_DEFINES_SETTING, EXECUTABLE_DEFINES_FILE_SETTING],
)

EXECUTABLE_DEFINES_ATTRS = {
    "_executable_dart_defines": attr.label(
        doc = "The private //dart/private:executable_dart_defines setting: the environment of the executable whose closure this is.",
        default = Label("//dart/private:executable_dart_defines"),
        providers = [BuildSettingInfo],
    ),
    "_executable_dart_defines_file": attr.label(
        doc = "The private //dart/private:executable_dart_defines_file setting: the defines file of the executable whose closure this is.",
        default = Label("//dart/private:executable_dart_defines_file"),
        providers = [DartDefinesInfo],
    ),
}

def executable_dart_defines(ctx):
    """The executable environment this configuration carries.

    Args:
      ctx: A rule or aspect context carrying `EXECUTABLE_DEFINES_ATTRS`.

    Returns:
      struct(defines, flagfile): the canonical defines and the defines File (or None).
    """
    if not hasattr(ctx.attr, "_executable_dart_defines"):
        return struct(defines = [], flagfile = None)
    return struct(
        defines = ctx.attr._executable_dart_defines[BuildSettingInfo].value,
        flagfile = ctx.attr._executable_dart_defines_file[DartDefinesInfo].flagfile,
    )
