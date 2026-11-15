"""The strict-layering (import) check for Flutter program rules.

rules_dart's `dart_binary` and `dart_test` refuse a source that imports a
package none of its direct `deps` provides. This file is the one place a
Flutter rule picks that check up, so every checked rule shares one wiring:

  * `LAYERING_CHECK_ASPECT` goes on the rule's `deps`,
  * `LAYERING_CHECK_ATTRS` into its `attrs`,
  * `LAYERING_CHECK_TOOLCHAINS` into its `toolchains`,
  * `layering_check()` returns what its `_validation` output group carries.

Checked rules: `flutter_test`, `flutter_application`, `flutter_web_bundle`, the
web, Linux, Android and iOS integration tests and `flutter_drive_test`. An
integration test resolves its entry from `main` or a single `srcs` file, and
`executable_import_check` reads `ctx.file.main`, so `layering_check_entry`
runs it over a stand-in context that names the resolved entry.

The check is on by default; the `dart_layering_check` feature turns it off per
package or per build, exactly as in rules_dart.
"""

load(
    "@rules_dart//dart:import_check.bzl",
    "EXECUTABLE_IMPORT_CHECK_TOOLCHAINS",
    "dart_import_check_aspect",
    "executable_import_check",
)
load("@rules_dart//dart:utils.bzl", "dart_package_identity", "derive_lib_root")

visibility(["//flutter/..."])

LAYERING_CHECK_ASPECT = dart_import_check_aspect

# These mirror rules_dart's `EXECUTABLE_IMPORT_CHECK_ATTRS`, because
# `executable_import_check` reads both by name. They are spelled out here so
# the rule's attribute surface stays resolvable without loading a dict.
LAYERING_CHECK_ATTRS = {
    "_import_check": attr.label(
        doc = "The import checker, run on the rule's own sources.",
        default = Label("@rules_dart//dart:import_check"),
        executable = True,
        cfg = "exec",
    ),
    "_refused_dart_libraries": attr.label(
        doc = "The Dart libraries a source may not import.",
        default = Label("@rules_dart//dart:refused_dart_libraries"),
    ),
}

LAYERING_CHECK_TOOLCHAINS = EXECUTABLE_IMPORT_CHECK_TOOLCHAINS

def layering_toolchains(taken):
    """The helper's toolchain types that `taken` does not already list.

    Args:
        taken: The toolchain types the rule already declares.

    Returns:
        `LAYERING_CHECK_TOOLCHAINS` without those in `taken`.
    """
    return [t for t in LAYERING_CHECK_TOOLCHAINS if t not in taken]

def layering_check_for(ctx):
    """Checks a rule whose own package is `package_name` under its label.

    Args:
        ctx: The rule context; it declares the helper's attrs and toolchains,
            `package_name` and `language_version`, and has `main`, `srcs`
            and `deps`.

    Returns:
        A depset of check stamps, for the `_validation` output group.
    """
    return layering_check(ctx, dart_package_identity(
        package_name = ctx.attr.package_name,
        lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package),
        language_version = ctx.attr.language_version,
    ))

def layering_output_groups(ctx, name, files):
    """The output groups of a rule that returns one group beside the check.

    Args:
        ctx: The rule context, as for `layering_check_for`.
        name: The name of the rule's own output group.
        files: The list of files that group carries.

    Returns:
        An `OutputGroupInfo` with that group and the check's `_validation`.
    """
    return OutputGroupInfo(**{name: depset(files), "_validation": layering_check_for(ctx)})

def layering_check(ctx, package):
    """Checks a rule's own sources and gathers the stamps of its deps.

    Args:
        ctx: The rule context; it declares `LAYERING_CHECK_ATTRS` and
            `LAYERING_CHECK_TOOLCHAINS` and has `main`, `srcs` and `deps`.
        package: The rule's own package, from `dart_package_identity`. An
            empty `package_name` means the rule states no package.

    Returns:
        A depset of check stamps, for the `_validation` output group.
    """
    return executable_import_check(ctx, package if package.package_name else None)

def layering_check_entry(ctx, check):
    """Checks a rule whose entry is resolved, not declared as `main`.

    `executable_import_check` reads `ctx.file.main` and `ctx.files.srcs`. An
    integration test's `main` is optional and a drive test has `driver`, so the
    check runs over a stand-in context that forwards the rule's own and names
    those two.

    Args:
        ctx: The rule context; it declares the helper's attrs and toolchains
            and has `deps`.
        check: A struct with `entry` (the entry `File`, or `None` for an
            executable driver, which adds nothing to check), `srcs` (the other
            source `File`s) and `package` (from `dart_package_identity`, or
            `None` when the rule states no own package).

    Returns:
        A depset of check stamps, for the `_validation` output group.
    """
    if check.entry == None:
        return depset()
    stand_in = struct(
        actions = ctx.actions,
        attr = struct(deps = ctx.attr.deps, _refused_dart_libraries = ctx.attr._refused_dart_libraries),
        disabled_features = ctx.disabled_features,
        executable = ctx.executable,
        file = struct(main = check.entry),
        files = struct(srcs = check.srcs),
        label = ctx.label,
        toolchains = ctx.toolchains,
    )
    return executable_import_check(stand_in, check.package)

def layering_check_integration(ctx, sources):
    """Checks an integration test's entry, `srcs` and `app_srcs` against its `deps`.

    The test's own package is `package_name`, or the target name.

    Args:
        ctx: The rule context; it declares the helper's attrs and toolchains,
            `package_name` and `language_version`, and has `deps`.
        sources: A struct with `main_file`, `extra_srcs`, `package_name` and
            `lib_root`, as the platform rules resolve them.

    Returns:
        A depset of check stamps, for the `_validation` output group.
    """
    return layering_check_entry(ctx, struct(
        entry = sources.main_file,
        srcs = sources.extra_srcs,
        package = dart_package_identity(
            package_name = sources.package_name,
            lib_root = sources.lib_root,
            language_version = ctx.attr.language_version,
        ),
    ))

def layering_check_drive(ctx, driver):
    """Checks a `.dart` host driver and its `srcs` against the rule's `deps`.

    The driver states no Dart package of its own, so only the packages `deps`
    provide count. A driver that is an executable target adds nothing: its own
    rule checks it.

    Args:
        ctx: The rule context; it declares the helper's attrs and toolchains
            and has `deps` and `srcs`.
        driver: The `.dart` driver `File`, or `None` for an executable driver.

    Returns:
        A depset of check stamps, for the `_validation` output group.
    """
    return layering_check_entry(ctx, struct(entry = driver, srcs = ctx.files.srcs, package = None))
