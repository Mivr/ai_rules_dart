"""Strict layering: a target's sources import only the packages its own `deps` provide.

`package_config.json` is generated from the transitive `DartInfo` closure, so a
package that only a dependency's dependency provides resolves in every compile
and analysis action, until that dependency drops it and the consumer's own
import breaks. This check reads each target's `import` and `export`
directives and fails the build when one names a package no direct dependency
provides.

The `//dart:refused_dart_libraries` setting makes the same check refuse named
`dart:` libraries, such as `dart:mirrors`; it is empty by default.

It is on by default. The Bazel feature `dart_layering_check` turns it off per
target (`package(features = ["-dart_layering_check"])`) or per build
(`--features=-dart_layering_check`). The check is a validation: one small
action per target that reads that target's own sources and writes an empty
stamp. It changes no compile or analysis action's inputs or outputs, so an
unchanged target is a cache hit, and it never depends on the modular kernel.
Targets in another repository are not checked: a pub package's dependencies
are its own pubspec's.

`dart_import_check_aspect` checks every library below an executable;
`executable_import_check` checks the executable's own `main` and `srcs` and
gathers the stamps into the `_validation` output group that makes building the
executable run every check.
"""

load("//dart:providers.bzl", "DartImportCheckInfo", "DartInfo", "DartKernelInfo")
load("//dart/private:build_settings.bzl", "REFUSED_DART_LIBRARIES_ATTR", "refused_library_args")
load("//dart/private:dart_kernel.bzl", "MODULAR_KERNEL_TOOLCHAINS", "kernel_tools_for")
load(
    "//dart/private:kernel_library_state.bzl",
    "LAYERING_FEATURE",
    "direct_packages",
    "library_module_inputs",
    "own_packages",
)

_direct_packages = direct_packages
_own_packages = own_packages

IMPORT_CHECK_TOOL = Label("//dart/private/tools:import_check")

def import_check_for_binary(name, deps):
    """The computed default of `dart_binary`'s `_import_check` attribute.

    The check tool is itself a `dart_binary`; naming itself as its own check
    tool would be a dependency cycle, so the tool alone resolves to `None`.

    Args:
      name: The `dart_binary`'s `name`.
      deps: The `dart_binary`'s `deps`.

    Returns:
      The tool's label, or `None` for the tool itself.
    """
    if name == IMPORT_CHECK_TOOL.name and not deps:
        return None
    return IMPORT_CHECK_TOOL

def _checked_sources(files):
    """The files and directories a check reads, from a target's own sources.

    Args:
      files: The target's own source `File`s.

    Returns:
      The Dart files and source directories among them.
    """
    return [f for f in files if f.extension == "dart" or f.is_directory]

def _reached_stamps(deps):
    """The stamps the direct dependencies carry.

    Args:
      deps: The direct dependency targets.

    Returns:
      A list of depsets of stamp files.
    """
    return [dep[DartImportCheckInfo].stamps for dep in deps if DartImportCheckInfo in dep]

def _check_runtime(ctx, tool):
    """The SDK runtime that executes the check tool, or `None` when it cannot run.

    The check does not run when the tool is absent (the tool itself), when
    the `dart_layering_check` feature is disabled for the target, or when the
    build registers no exec tools toolchain.

    Args:
      ctx: The rule or aspect context.
      tool: The check tool's executable `File`, or `None`.

    Returns:
      The `dartaotruntime` `File`, or `None`.
    """
    if tool == None or LAYERING_FEATURE in ctx.disabled_features:
        return None
    tools = kernel_tools_for(ctx)
    if tools == None:
        return None
    return tools.dartaotruntime

def _declare_check(ctx, tool, runtime, request):
    """Declares the one action that checks one target. Returns its stamp.

    The inputs are the target's own sources and the tool, never a dependency's
    sources: a dependency edit must not re-run its consumers' checks.

    Args:
      ctx: The rule or aspect context.
      tool: The check tool's executable `File`.
      runtime: The `dartaotruntime` `File` that runs the tool.
      request: A struct of `srcs` (Files), `own_packages` and `direct_packages`
        (name lists). The `//dart:refused_dart_libraries` entries are passed
        as `--refused-library` when there are any.

    Returns:
      The declared stamp `File`.
    """
    label = "//%s:%s" % (ctx.label.package, ctx.label.name)
    stamp = ctx.actions.declare_file(ctx.label.name + ".import_check")
    args = ctx.actions.args()
    args.use_param_file("@%s")
    args.set_param_file_format("multiline")
    args.add("--label", label)
    args.add_all(request.own_packages, before_each = "--own-package")
    args.add_all(request.direct_packages, before_each = "--direct-package")
    args.add_all(refused_library_args(ctx), before_each = "--refused-library")
    args.add_all(request.srcs, before_each = "--src")
    args.add("--output", stamp)
    ctx.actions.run(
        executable = runtime,
        arguments = [tool.path, args],
        inputs = depset(direct = request.srcs + [tool]),
        outputs = [stamp],
        mnemonic = "DartImportCheck",
        progress_message = "Checking Dart imports of %s" % label,
        use_default_shell_env = False,
        toolchain = "//dart:exec_tools_toolchain_type",
    )
    return stamp

def _library_stamp(target, ctx, inputs, deps):
    """The check stamp of one library, or `None` when it runs no check.

    Library layering checks run inside the module compile worker
    (`kernel_module`), so a modular library registers no `DartImportCheck`
    process of its own and uses its `.kmod` output as the validation stamp.

    Args:
      target: The target the aspect is applied to.
      ctx: The aspect context.
      inputs: The `library_module_inputs` struct of the library.
      deps: The library's direct dependency targets.

    Returns:
      The stamp `File`, or `None`.
    """
    if ctx.label.workspace_name:
        return None
    srcs = _checked_sources(inputs.own_srcs)
    tool = ctx.executable._import_check
    runtime = _check_runtime(ctx, tool) if srcs else None
    if runtime == None:
        return None
    if DartKernelInfo in target and target[DartKernelInfo].kmod != None:
        return target[DartKernelInfo].kmod
    return _declare_check(ctx, tool, runtime, struct(
        srcs = srcs,
        own_packages = _own_packages(inputs.own_records, inputs.package_name),
        direct_packages = _direct_packages(deps),
    ))

def _import_check_aspect_impl(target, ctx):
    """Checks one library's imports and collects the stamps of the targets it reaches.

    Args:
      target: The target the aspect is applied to.
      ctx: The aspect context.

    Returns:
      A `DartImportCheckInfo`, or nothing for a target without `DartInfo`.
    """
    if DartInfo not in target:
        return []
    library = getattr(ctx.rule.attr, "library", None)
    if library != None and type(library) != "list" and DartInfo in library:
        if DartImportCheckInfo in library:
            return [library[DartImportCheckInfo]]
        return [DartImportCheckInfo(stamps = depset())]
    inputs = library_module_inputs(ctx.rule.attr, ctx.rule.files, target[DartInfo])
    stamp = _library_stamp(target, ctx, inputs, inputs.rule_deps)
    return [DartImportCheckInfo(stamps = depset(
        direct = [stamp] if stamp else [],
        transitive = _reached_stamps(inputs.rule_deps),
    ))]

dart_import_check_aspect = aspect(
    implementation = _import_check_aspect_impl,
    attr_aspects = ["deps", "library"],
    attrs = {
        "_import_check": attr.label(
            doc = "The tool that checks one target's imports against its direct dependencies. See `import_check.dart`.",
            default = IMPORT_CHECK_TOOL,
            executable = True,
            cfg = "exec",
        ),
    } | REFUSED_DART_LIBRARIES_ATTR,
    toolchains = MODULAR_KERNEL_TOOLCHAINS,
    doc = """Checks that each library in an executable's closure imports only packages its `deps` provide.

Returns `DartImportCheckInfo` on every `DartInfo` target, carrying the stamp of
that target's `DartImportCheck` action and those of the targets below it. A
target in another repository, one with no sources, one built with the
`dart_layering_check` feature disabled, and one forwarding a `library`
unchanged run no action of their own.""",
)

def executable_import_check(ctx, own_record):
    """Checks an executable's own sources and gathers the stamps below it.

    The result is the executable's `_validation` output group contents, so
    building the executable builds every check in its closure in every compile
    mode.

    Args:
      ctx: The executable rule's context, carrying `_import_check`,
        `_refused_dart_libraries`, `main`, `srcs` and `deps`, and the exec
        tools toolchain.
      own_record: The executable's own `DartPackageInfo` (`executable_package`'s
        `record`), or `None` when it states no package.

    Returns:
      A depset of the check stamps for the `_validation` output group.
    """
    tool = ctx.executable._import_check
    runtime = _check_runtime(ctx, tool)
    stamps = []
    if runtime != None:
        stamps.append(_declare_check(ctx, tool, runtime, struct(
            srcs = _checked_sources([ctx.file.main] + ctx.files.srcs),
            own_packages = _own_packages([own_record] if own_record else [], ""),
            direct_packages = _direct_packages(ctx.attr.deps),
        )))
    return depset(direct = stamps, transitive = _reached_stamps(ctx.attr.deps))
