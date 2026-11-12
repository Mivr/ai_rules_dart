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
