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

A Flutter program also refuses `dart:mirrors`, and any library the user sets in
`@rules_dart//dart:refused_dart_libraries`, in its own sources and in every library below it. The
program keeps one configuration, so no library compiles twice: `LAYERING_CHECK_ASPECT` adds one
small source check per library, and `layering_check()` adds the refused set to the program's own.

The check is on by default; the `dart_layering_check` feature turns it off per
package or per build, exactly as in rules_dart.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(
    "@rules_dart//dart:import_check.bzl",
    "EXECUTABLE_IMPORT_CHECK_TOOLCHAINS",
    "dart_import_check_aspect",
    "executable_import_check",
)
load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "dart_package_identity",
    "derive_lib_root",
    "kernel_tools_for",
    "owned_package_records",
)

visibility(["//flutter/..."])

# Flutter has no `dart:mirrors`: a Flutter program, and every library below it, may not import it.
_FLUTTER_REFUSED = ["dart:mirrors"]
_EXEC_TOOLS = Label("@rules_dart//dart:exec_tools_toolchain_type")

FlutterRefusedInfo = provider(
    doc = "The stamps of the `dart:` library refusals of a target and every library below it.",
    fields = {
        "refused": "list[str]: The `dart:` libraries this target's own check refuses; empty when it runs none.",
        "stamps": "depset[File]: One stamp per checked library.",
    },
)

def _refused(setting):
    """The libraries a Flutter program refuses: Flutter's own and the user's setting.

    Args:
        setting: The list in `@rules_dart//dart:refused_dart_libraries`.

    Returns:
        The sorted union.
    """
    return sorted({lib: True for lib in _FLUTTER_REFUSED + list(setting)}.keys())

def _own_srcs(ctx):
    """The library's own Dart files and directories, `members` included."""
    files = list(ctx.rule.files.srcs) if hasattr(ctx.rule.files, "srcs") else []
    for member in getattr(ctx.rule.attr, "members", []):
        # lint-allow: depset-flatten a merged library's own members' files, not its closure
        files.extend(member[DefaultInfo].files.to_list())
    return [f for f in files if f.extension == "dart" or f.is_directory]

def _direct_packages(deps):
    """The package names a library may import through its direct `deps`."""
    names = {}
    for dep in deps:
        if DartInfo not in dep:
            continue
        owned = owned_package_records(dep[DartInfo])
        # A depset is true when it is not empty; asking does not flatten it. A dependency with no files of its own
        # (a façade) names the packages it re-exports, which are its closure's, as rules_dart's layering check does.
        # lint-allow: depset-flatten a façade dependency only: the packages it re-exports, bounded by its closure
        records = owned if owned and dep[DefaultInfo].files else dep[DartInfo].transitive_packages.to_list()
        for record in records:
            names[record.package_name] = True
    return sorted(names)

def _refusal_stamp(ctx, srcs, deps, dart_info, refused):
    """Declares the check of one library's `import`s and `export`s against the refused set.

    The package arguments match rules_dart's own check, so only `dart:` refusals can fail.
    """
    tools = kernel_tools_for(ctx)
    tool = ctx.executable._import_check
    stamp = ctx.actions.declare_file(ctx.label.name + ".flutter_import_check")
    own = {r.package_name: True for r in owned_package_records(dart_info)}
    if dart_info.package_name:
        own[dart_info.package_name] = True
    args = ctx.actions.args()
    args.use_param_file("@%s")
    args.set_param_file_format("multiline")
    args.add("--label", "//%s:%s" % (ctx.label.package, ctx.label.name))
    args.add_all(sorted(own), before_each = "--own-package")
    args.add_all(_direct_packages(deps), before_each = "--direct-package")
    args.add_all(refused, before_each = "--refused-library")
    args.add_all(srcs, before_each = "--src")
    args.add("--output", stamp)
    ctx.actions.run(
        executable = tools.dartaotruntime,
        arguments = [tool.path, args],
        inputs = depset(direct = srcs + [tool]),
        outputs = [stamp],
        mnemonic = "DartImportCheck",
        progress_message = "Checking Dart library imports of %s" % ctx.label,
        use_default_shell_env = False,
        toolchain = _EXEC_TOOLS,
    )
    return stamp

def _refusal_aspect_impl(target, ctx):
    """Refuses Flutter's `dart:` libraries in one library and gathers those below it."""
    if DartInfo not in target:
        return []
    deps = getattr(ctx.rule.attr, "deps", [])
    library = getattr(ctx.rule.attr, "library", None)
    below = deps + ([library] if library != None and type(library) != "list" else [])
    srcs = _own_srcs(ctx)
    off = ctx.label.workspace_name or "dart_layering_check" in ctx.disabled_features
    refused = _refused(ctx.attr._refused_dart_libraries[BuildSettingInfo].value)
    checked = srcs and not off and kernel_tools_for(ctx)
    stamps = [_refusal_stamp(ctx, srcs, deps, target[DartInfo], refused)] if checked else []
    return [FlutterRefusedInfo(refused = refused if stamps else [], stamps = depset(
        stamps,
        transitive = [d[FlutterRefusedInfo].stamps for d in below if FlutterRefusedInfo in d],
    ))]

_refusal_aspect = aspect(
    implementation = _refusal_aspect_impl,
    attr_aspects = ["deps", "library"],
    attrs = {
        "_import_check": attr.label(
            default = Label("@rules_dart//dart:import_check"),
            executable = True,
            cfg = "exec",
            doc = "The import checker, run on each library's own sources.",
        ),
        "_refused_dart_libraries": attr.label(
            default = Label("@rules_dart//dart:refused_dart_libraries"),
            doc = "The Dart libraries the user refuses beside Flutter's own.",
        ),
    },
    requires = [dart_import_check_aspect],
    toolchains = EXECUTABLE_IMPORT_CHECK_TOOLCHAINS,
    doc = "Refuses `dart:mirrors` in every library below a Flutter program, in the program's configuration.",
)

LAYERING_CHECK_ASPECT = _refusal_aspect

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

def _checked(ctx, check):
    """Runs rules_dart's check over `check.entry` and `check.srcs`, with Flutter's refused libraries.

    The stand-in context carries the refused set as the build setting's own provider, so the
    program keeps one configuration and no library compiles twice. The libraries below the
    program are refused by `LAYERING_CHECK_ASPECT`, whose stamps join the result. A program that turns
    the `dart_layering_check` feature off gets nothing: the aspect cannot see the program's features, so
    the program leaves out the stamps below it.

    Args:
        ctx: The rule context, as for `layering_check`.
        check: A struct with `entry`, `srcs` and `package`, as for `layering_check_entry`.

    Returns:
        A depset of check stamps, for the `_validation` output group.
    """
    if "dart_layering_check" in ctx.disabled_features:
        return depset()
    refused = _refused(ctx.attr._refused_dart_libraries[BuildSettingInfo].value)
    stand_in = struct(
        actions = ctx.actions,
        attr = struct(deps = ctx.attr.deps, _refused_dart_libraries = {BuildSettingInfo: struct(value = refused)}),
        disabled_features = ctx.disabled_features,
        executable = ctx.executable,
        file = struct(main = check.entry),
        files = struct(srcs = check.srcs),
        label = ctx.label,
        toolchains = ctx.toolchains,
    )
    below = [d[FlutterRefusedInfo].stamps for d in ctx.attr.deps if FlutterRefusedInfo in d]
    return depset(transitive = [executable_import_check(stand_in, check.package)] + below)

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
    return _checked(ctx, struct(
        entry = ctx.file.main,
        srcs = ctx.files.srcs,
        package = package if package.package_name else None,
    ))

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
    return _checked(ctx, check)

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
