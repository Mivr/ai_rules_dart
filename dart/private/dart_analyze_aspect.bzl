"""The `dart_analyze` aspect: `dart analyze`, `dart format` and `dart fix` over one staged project.

Applied from the command line, in `.bazelrc`:

    test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
    test --output_groups=+dart_analyze
    test --output_groups=+dart_format
    common --@rules_dart//dart:analysis_config=//:analysis_config

it checks each Dart target named on the command line (it does not propagate
along `deps`), and only that target's *own* files: its `DefaultInfo` `.dart`
files plus its `DartAnalyzableInfo.srcs`. Each check is its own output group
and its own action — `dart_analyze` for the analyzer, `dart_format` for
`dart format --set-exit-if-changed` — so a project runs whichever of the two
its `--output_groups` names, and only that one. Its in-repository dependencies are
staged so their imports resolve and excluded so they are not re-checked — each
is checked when it is itself a target of the build. Targets in other
repositories (pub packages, other Bazel modules) are never checked here: the
module that owns them checks them under its own options. Generated files
(anything not `is_source`) are never checked. The `no-dart-analyze` tag opts a
target out of analysis (its fixes stay available to `dart_fix`), and
`no-dart-format` out of the format check; each leaves the other in place.

Options come from the `dart_analysis_config` the `analysis_config` flag names.
Every `analysis_options.yaml` it lists is staged at its real workspace path,
and the SDK's own rule picks the nearest one for each file — exactly what the
IDE does with the same tree. Nothing on the Bazel side decides which options
govern which file. A relative `include:` resolves against the staged copy, so
it can only reach what is staged; the one way to share a yaml that governs no
directory is a `package:` include of a package in the options target's `deps`.
The formatter finds its `formatter:` section by the same walk, so both checks
read one file's options from the same place, and
`dart_format` stages the same options the same way (`stage_config_project`) for
`bazel run`, so a run cannot format to settings the check does not apply. The
one difference is layout: the check names pub packages where they sit in the
exec root, while `dart_format` copies them, because its project is read from
runfiles.

Options may be paired with a baseline: a JSON object of workspace-relative
file paths, each mapping a diagnostic code to a non-negative ceiling. Each
target receives only its own files' entries, sliced by a separate action, so an
entry for another target's file cannot exempt a diagnostic here and does not
enter this target's analyze action key. A group at or below its ceiling is
printed but does not fail; one above it fails. Without a baseline, every
non-ignored diagnostic fails as before.

The format check names the target's own files individually and passes the
language version of the target's own package on the command line. That version
selects the formatting style (below 3.7 the old short one), and passing it
keeps the verdict off whatever `package_config.json` entry happens to cover a
staged file — an entrypoint outside `lib/`, say. An executable that states no
package of its own takes the version of the in-repo package whose root contains
its entrypoint, and one containing no such package is formatted at `latest`, as
`dart format` would with nothing to go on.

`dart_analysis_test` applies this aspect to targets a wildcard cannot reach.

The same staged project also feeds a `dart fix` action whose products sit in
the `dart_fix_fixes` and `dart_fix_manifest` output groups, built only when
asked for. `dart_fix` applies the aspect to its `target` and writes those
products into the workspace, so a fix and the analysis it answers can never see
different projects.

With `//dart:analyzer_summaries` on (the default), the analysis action changes
and nothing else does. It stages only the target's own files and checks them with
`analyzer_summary analyze` against the summaries of its dependencies, which
`dart_analyzer_summary` builds (see that file). A target keeps the staged closure
and `dart analyze` when its flag is off, when the analyzing SDK is newer than the
pinned analyzer supports, when its closure holds an unbacked embedder
(`unbacked_embedder_in_closure`), or when a dependency lacks a summary.
`DartAnalysisModeInfo` says which mode a target was checked in.
The format check and the fix action are the same in both modes. In this mode
the diagnostics come from the pinned `package:analyzer` with the SDK linter
vendored in `//third_party/dart_linter`, so they can drift from `dart analyze`
(see the flag's comment in `//dart/BUILD.bazel`).
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartAnalysisOptionsInfo", "DartAnalyzableInfo", "DartInfo")
load("//dart/private:common.bzl", "kernel_sdk_mismatch_error", "merge_package_records", "owned_package_records", "writable_home_env")
load("//dart/private:dart_analyzer_summary.bzl", "CONFLICT_PREFIX", "DartAnalyzerSummaryInfo", "analyzer_summaries_supported", "closure_attrs", "dart_analyzer_summary", "own_lib_sources", "package_key", "sdk_root_path", "unbacked_embedder_in_closure")
load("//dart/private:project_staging.bzl", "pubspec_stub", "stage_dart_project")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")
load("//dart/private/tools:analyze_targets.bzl", "analyze_own_files", "analyze_target_info")
load("//dart/private/tools:format_mode.bzl", _resolve_format_mode = "resolve_format_mode")

# Analysis and formatting run on the build machine and produce nothing for the
# target, so the SDK is chosen by the execution platform alone — the type the
# codegen rules use, for the same reason. With the target-platform type, a
# target that transitions to a platform no Dart SDK is registered for (an
# Android bundle, say) failed toolchain resolution before the aspect could even
# see it was not Dart.
_TOOLCHAIN = "//dart:exec_tools_toolchain_type"

_OPTIONS_BASENAME = "analysis_options.yaml"

# A target carrying this tag is not analyzed; `dart_fix` can still fix it.
NO_ANALYZE_TAG = "no-dart-analyze"

# A target carrying this tag is not format-checked; analysis is unaffected.
NO_FORMAT_TAG = "no-dart-format"

DartAnalysisConfigInfo = provider(
    doc = "Every `analysis_options.yaml` in a repository, for the `dart_analyze` aspect and `dart_format`.",
    fields = {
        "options_files": "list[File]: every listed `analysis_options.yaml`, staged at its workspace path.",
        "packages": "list[DartPackageInfo]: packages the listed files `include:` by `package:` URI.",
        "files": "list[File]: those packages' sources and resources, staged for resolution only.",
        "baseline": "File | None: the optional whole per-file, per-rule diagnostic baseline the aspect slices per target.",
    },
)

DartAnalysisModeInfo = provider(
    doc = "How the `dart_analyze` aspect checked one target: against its dependencies' summaries, or from their source.",
    fields = {
        "summaries": "bool: True when the analysis read dependency summaries. False when it analyzed the staged closure from source, or did not analyze the target.",
        "format_checks": "list[struct]: Each `DartFormat` check's resolved `mode`, `sdk_inputs`, and `env`.",
    },
)

DartFixOutputsInfo = provider(
    doc = "The `dart fix` products the `dart_analyze` aspect computed for one target.",
    fields = {
        "fixes": "File: directory of changed files at their workspace-relative paths.",
        "manifest": "File: JSON naming the fixed files and any discarded changes.",
    },
)

def _dart_analysis_config_impl(ctx):
    options_files = []
    packages = []
    files = []
    seen = {}
    for t in ctx.attr.options:
        opts = t[DartAnalysisOptionsInfo]
        f = opts.file

        # Options govern the files beneath them, and only this repository's
        # files are analyzed here. A shared ruleset from another module is used
        # the Dart way: `include:` it from an options file of this repository,
        # with the ruleset's package in that target's `deps`.
        if t.label.repo_name != ctx.label.repo_name or f.short_path.startswith("../"):
            fail(("%s: %s is in another repository, so the directory it would " +
                  "govern is never analyzed here. Include its ruleset from a " +
                  "`dart_analysis_options` in this repository instead.") % (ctx.label, t.label))

        # The analyzer finds options by name, walking up from each file. A file
        # named anything else would be staged and never read.
        if f.basename != _OPTIONS_BASENAME:
            fail(("%s: %s names `%s`. The analyzer only finds options files " +
                  "named `%s`, in the directory whose files they govern.") %
                 (ctx.label, t.label, f.short_path, _OPTIONS_BASENAME))
        if f.short_path in seen:
            fail("%s: `%s` is listed twice, by %s and %s." % (ctx.label, f.short_path, seen[f.short_path], t.label))
        seen[f.short_path] = t.label

        options_files.append(f)
        packages.extend(opts.packages)
        files.extend(opts.transitive_srcs.to_list() + opts.transitive_resources.to_list())

    return [DartAnalysisConfigInfo(
        options_files = options_files,
        packages = packages,
        files = files,
        baseline = ctx.file.baseline,
    )]

dart_analysis_config = rule(
    implementation = _dart_analysis_config_impl,
    attrs = {
        "options": attr.label_list(
            doc = (
                "Every `dart_analysis_options` in this repository. Each file " +
                "must be named `analysis_options.yaml`; it governs the files " +
                "below its directory up to the next listed one, as in the IDE."
            ),
            providers = [DartAnalysisOptionsInfo],
        ),
        "baseline": attr.label(
            doc = (
                "Optional JSON baseline of per-file, per-code diagnostic " +
                "ceilings. Keys are workspace-relative POSIX file paths; each " +
                "value maps a diagnostic code to a non-negative integer. A " +
                "group at or below its ceiling is printed but does not fail; " +
                "one above it fails, and an unkeyed group has ceiling zero. " +
                "The aspect slices the file per target. When absent or empty, " +
                "every diagnostic fails as before."
            ),
            allow_single_file = True,
        ),
    },
    provides = [DartAnalysisConfigInfo],
    doc = (
        "Lists a repository's analysis options for the `dart_analyze` aspect, " +
        "`dart_fix` and `dart_format`. Point " +
        "`@rules_dart//dart:analysis_config` at it under `common` in " +
        "`.bazelrc`."
    ),
)

def _is_under(path, directory):
    return directory == "" or path.startswith(directory + "/")

def _wrapper_options(excluded):
    """The `analysis_options.yaml` at the staged project root.

    It governs nothing the user wrote: every checked file sits under `src/`,
    where the nearest listed options file applies (or none, meaning the SDK
    defaults — it has no `formatter:` section either). What it contributes is
    its `exclude` list, which the analyzer applies across the nested options
    files below it, and a stop for the analyzer's and the formatter's otherwise
    unbounded walk up for options: without it, a file no listed options govern
    would be judged by whatever `analysis_options.yaml` sits above the staged
    project — nothing under a sandbox, the workspace's own in the execroot.
    """
    lines = ["# rules_dart: staged project root"]
    if excluded:
        lines.append("analyzer:")
        lines.append("  exclude:")
        for path in excluded:
            lines.append('    - "%s"' % path)
    return "\n".join(lines) + "\n"

def stage_config_project(ctx, config, packages, files, own, name, sdk_version, opts = None):
    """Stages a project holding every options file `config` lists.

    The one place a project is laid out for options to be found in: the
    `dart_analyze` aspect stages its target here, and `dart_format` stages the
    same options here for `bazel run`, so a check and a run cannot see
    different settings for the same file. Every listed `analysis_options.yaml`
    sits at its workspace path under `src/`, with the packages its `include:`s
    resolve against, and the wrapper above them all ends the walk up for
    options inside the project.

    Args:
      ctx: The rule or aspect context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      config: The `DartAnalysisConfigInfo` to stage.
      packages: `DartPackageInfo` records the staged files need, besides the
        config's own.
      files: Files to stage besides the config's.
      own: The Files being checked; everything else staged is excluded from
        analysis, but for the options files above one of them.
      name: Prefix for the staged paths.
      sdk_version: The toolchain SDK's version, the staged SDK constraint of a
        package that states no `language_version`.
      opts: `struct(copy_external, all_packages_named)` forwarded to
        `stage_dart_project`. The aspect's actions pass
        `(False, ...)`; `dart_format` keeps the `(True, False)` default by
        passing None, since its project is read from runfiles. The
        summary-mode analysis passes `all_packages_named = True`, whose
        staged config must name every package of the closure even though
        only the target's own files are staged.

    Returns:
      The `stage_dart_project` struct.
    """
    copy_external = opts.copy_external if opts else True
    all_packages_named = opts.all_packages_named if opts else False
    packages = merge_package_records(packages + config.packages)
    staged_files = files + config.files + config.options_files
    own_paths = [f.short_path for f in own]
    own_set = {f.path: True for f in own}

    staged = stage_dart_project(
        ctx,
        packages,
        staged_files,
        staging = struct(
            extra_proj_files = {
                "pubspec.yaml": pubspec_stub(packages, sdk_version = sdk_version),
            },
            name = name,
            sdk_version = sdk_version,
        ),
        copy_external = copy_external,
        all_packages_named = all_packages_named,
    )

    # Everything else under `src/` is there to resolve against, and excluded —
    # except the options files above one of the own files. Their own
    # diagnostics (an `include:` that does not resolve, an unknown lint)
    # belong to every target whose files they may govern, and to no other.
    governing = {
        f.path: True
        for f in config.options_files
        if [p for p in own_paths if _is_under(p, f.short_path.rpartition("/")[0])]
    }
    excluded = {}
    for f in staged.src_files:
        if f.short_path.startswith("../") or f.path in own_set or f.path in governing:
            continue
        excluded["src/" + f.short_path] = True
    excluded = sorted(excluded.keys()) + staged.stub_paths

    options_file = ctx.actions.declare_file(name + ".proj/" + _OPTIONS_BASENAME)
    ctx.actions.write(output = options_file, content = _wrapper_options(excluded))
    staged.inputs.append(options_file)
    staged.proj_files[_OPTIONS_BASENAME] = options_file
    return staged

def _baseline_slice(ctx, name, config, own_paths):
    """Declares the action slicing `config`'s baseline to `own_paths`; returns it, or None.

    The slice is the only baseline input the analyze action reads. It depends
    on the whole baseline, but its bytes hold only entries for the target's own
    files, sorted by path and code, so an edit to another target's entry leaves
    this target's analyze action key unchanged.
    """
    baseline = config.baseline
    if baseline == None:
        return None
    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    mismatch = kernel_sdk_mismatch_error(ctx.label, "_baseline_tool", ctx.attr._baseline_tool, dart_sdk_info.version)
    if mismatch != None:
        fail(mismatch)
    slice = ctx.actions.declare_file(name + ".baseline.json")
    args = ctx.actions.args()
    args.add("--config", str(ctx.attr._config.label))
    args.add("--baseline", baseline)
    args.add("--out", slice)
    args.add_all(own_paths, before_each = "--file")
    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [ctx.executable._baseline_tool.path, args],
        inputs = depset(direct = [ctx.executable._baseline_tool, baseline]),
        tools = depset(
            direct = [ctx.executable._baseline_tool, dart_sdk_info.dart],
            transitive = [dart_sdk_info.runtime_files],
        ),
        outputs = [slice],
        mnemonic = "DartBaselineSlice",
        progress_message = "Slicing Dart analysis baseline for %{label}",
        env = writable_home_env(dart_sdk_info.dart, slice),
    )
    return slice

def _analyze(ctx, name, staged, sdk_inputs, own_paths, baseline):
    """Declares the `dart analyze` action; returns the stamp it writes on success."""
    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    mismatch = kernel_sdk_mismatch_error(ctx.label, "_analyze_tool", ctx.attr._analyze_tool, dart_sdk_info.version)
    if mismatch != None:
        fail(mismatch)
    stamp = ctx.actions.declare_file(name + ".analyzed")
    args = ctx.actions.args()
    args.add("--dart", dart_sdk_info.dart)
    args.add("--project", staged.proj_path)
    args.add("--stamp", stamp)
    if baseline == None:
        args.add("--fatal-infos")
    else:
        args.add("--baseline", baseline)
    args.add_all(own_paths, format_each = "src/%s", before_each = "--source")
    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [ctx.executable._analyze_tool.path, args],
        inputs = depset(
            direct = [ctx.executable._analyze_tool] + staged.inputs + ([baseline] if baseline != None else []),
            transitive = [sdk_inputs],
        ),
        tools = depset(
            direct = [ctx.executable._analyze_tool, dart_sdk_info.dart],
            transitive = [dart_sdk_info.runtime_files],
        ),
        outputs = [stamp],
        mnemonic = "DartAnalyze",
        progress_message = "Analyzing Dart sources of %{label}",
        env = writable_home_env(dart_sdk_info.dart, stamp),
    )
    return stamp

def _analyze_summaries(ctx, name, staged, summaries, sdk_summary, sdk_inputs, own_paths, baseline):
    """Declares the summary-mode `dart analyze`; returns the stamp it writes on success.

    `staged` holds the target's own files and the options alone, and
    `summaries` the summaries of everything they import, which take the place
    of the closure's source the `dart analyze` action reads.
    """
    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    mismatch = kernel_sdk_mismatch_error(ctx.label, "_summary_tool", ctx.attr._summary_tool, dart_sdk_info.version)
    if mismatch != None:
        fail(mismatch)
    stamp = ctx.actions.declare_file(name + ".analyzed")
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("analyze")
    args.add("--sdk", sdk_root_path(dart_sdk_info))
    args.add("--project", staged.proj_path)
    args.add("--stamp", stamp)
    args.add("--fatal-infos")
    if baseline != None:
        args.add("--baseline", baseline)
    args.add("--sdk-summary", sdk_summary)
    args.add_all(own_paths, format_each = "src/%s", before_each = "--source")
    args.add_all(summaries, before_each = "--summary")
    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [ctx.executable._summary_tool.path, args],
        inputs = depset(
            direct = [ctx.executable._summary_tool, sdk_summary] + staged.inputs +
                     ([baseline] if baseline != None else []),
            transitive = [summaries, sdk_inputs],
        ),
        tools = depset(
            direct = [ctx.executable._summary_tool, dart_sdk_info.dart],
            transitive = [dart_sdk_info.runtime_files],
        ),
        outputs = [stamp],
        mnemonic = "DartAnalyze",
        progress_message = "Analyzing Dart sources of %{label} against summaries",
        env = writable_home_env(dart_sdk_info.dart, stamp),
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
    )
    return stamp

def _embedder_sdk_summary(ctx):
    """Returns the single embedder SDK summary in `ctx`'s closure, or None."""
    summaries = depset(transitive = [
        d[DartAnalyzerSummaryInfo].embedder_sdk_summaries
        for d in closure_attrs(ctx)
        if DartAnalyzerSummaryInfo in d
    ]).to_list()
    return summaries[0] if len(summaries) == 1 else None

def _collect_covered(ctx):
    """Collects covered package keys, names and lib prefixes, or None on conflict."""
    covered = {}
    covered_names = {}
    covered_lib_prefixes = {}
    for d in closure_attrs(ctx):
        if DartAnalyzerSummaryInfo in d:
            for key in d[DartAnalyzerSummaryInfo].packages.to_list():
                if key.startswith(CONFLICT_PREFIX):
                    return None
                covered[key] = True
                pkg_name, _, pkg_root = key.partition("|")
                if pkg_name:
                    covered_names[pkg_name] = True
                if not pkg_root.startswith("../"):
                    prefix = (pkg_root + "/lib/") if pkg_root else "lib/"
                    covered_lib_prefixes[prefix] = True
    return covered, covered_names, covered_lib_prefixes

def _own_keys_conflict(own_keys, own_names, covered, covered_names, has_own_lib):
    """Whether the target's own package keys clash with a dependency's summary."""
    return (any([k in covered for k in own_keys]) or any([n and n in covered_names for n in own_names])) and has_own_lib

def _staged_files_conflict(staged_files, covered_lib_prefixes):
    """Whether a staged Dart file sits under a covered package's `lib/`."""
    if covered_lib_prefixes:
        for f in staged_files:
            if f.extension == "dart" or f.is_directory:
                for prefix in covered_lib_prefixes.keys():
                    if f.short_path.startswith(prefix):
                        return True
    return False

def _summaries_ready(ctx, info, has_own_lib, staged_files = []):
    """Whether the target can be analyzed from summaries.

    That is so when every package in its closure, but its own, has a summary,
    and any Flutter embedder in its closure is backed by an embedder SDK
    summary. Each target's summary provider names the packages its summaries
    cover, so a package the summary aspect never reached, one a rule keeps
    outside `deps`, `library`, and `_sky_engine`, is absent from them. The
    target then analyzes from source, which is slower and never wrong.

    Args:
      ctx: The aspect context.
      info: The target's `DartInfo` closure.
      has_own_lib: Whether the target stages `lib/` files of its own package.
      staged_files: The target's own and generated files staged in summary mode.

    Returns:
      True when the closure can be analyzed from summaries.
    """
    if unbacked_embedder_in_closure(info, _embedder_sdk_summary(ctx)):
        return False
    collected = _collect_covered(ctx)
    if collected == None:
        return False
    covered, covered_names, covered_lib_prefixes = collected
    own_records = owned_package_records(info)
    own_keys = [package_key(record) for record in own_records] or [package_key(info)]
    own_names = [record.package_name for record in own_records]

    # A package split across targets is analyzed from source when the target
    # stages `lib/` files of a covered package: a dependency's summary defines
    # libraries those files define or share a package with (see
    # `dart_analyzer_summary`), and an executable without `package_name` has an
    # empty `own` key even when its `srcs` stage `lib/` files of a dependency's
    # package. A test or executable that stages only `test/` or `bin/` files
    # conflicts with no summary.
    if _own_keys_conflict(own_keys, own_names, covered, covered_names, has_own_lib):
        return False
    if _staged_files_conflict(staged_files, covered_lib_prefixes):
        return False
    for pkg in info.transitive_packages.to_list():
        key = package_key(pkg)
        if key not in own_keys and key not in covered:
            return False
    return True

def _dependency_summaries(ctx):
    """The transitive summaries of each of the target's dependencies."""
    return depset(transitive = [
        d[DartAnalyzerSummaryInfo].transitive_summaries
        for d in closure_attrs(ctx)
        if DartAnalyzerSummaryInfo in d
    ])

def _merged_path_version(own_records, path):
    """The language version of the member package whose root contains `path`."""
    for record in own_records:
        root = record.lib_root
        if root and (path == root or path.startswith(root + "/")):
            return getattr(record, "language_version", "")
    for record in own_records:
        if not record.lib_root:
            return getattr(record, "language_version", "")
    return ""

def _merged_version_groups(own_records, own_paths):
    """Groups paths by their containing member package's language version."""
    groups = {}
    for path in own_paths:
        groups.setdefault(_merged_path_version(own_records, path), []).append(path)
    return groups

def _closure_version_groups(roots, own_paths):
    """Groups paths by the innermost containing closure package's language version."""
    groups = {}
    for path in own_paths:
        best = None
        for p in roots:
            if p.lib_root == "" or path.startswith(p.lib_root + "/"):
                if best == None or len(p.lib_root) > len(best.lib_root):
                    best = p
        version = getattr(best, "language_version", "") if best else ""
        groups.setdefault(version, []).append(path)
    return groups

def _format_language_versions(info, own_paths):
    """Groups a target's own files by the language version to format them at.

    The version is the one Dart itself would use: the version of the package
    whose root directory contains the file, `test/` and `bin/` included, not
    only `lib/`. A library states its package; an executable's entrypoint
    belongs to whichever in-repo package's root contains it — the package it
    sits in, not a dependency's — unless the executable states its own package,
    which then has a record like a library's. Formatting it at the SDK's newest version
    instead would demand a style the package's own `dart format` never produces
    once a package states a version below 3.7.

    Args:
      info: The target's `DartInfo` closure.
      own_paths: `short_path`s of the target's own files.

    Returns:
      Dict of language version ("" when none is stated) to the paths to format
      at it.
    """
    own_records = owned_package_records(info)
    if len(own_records) == 1:
        return {getattr(own_records[0], "language_version", ""): own_paths}
    if own_records:
        # A merged multi-package target: each file formats at the version of
        # the member package whose root directory contains it.
        return _merged_version_groups(own_records, own_paths)
    roots = [
        p
        for p in info.transitive_packages.to_list()
        if not p.lib_root.startswith("../")
    ]
    return _closure_version_groups(roots, own_paths)

# The formatter's version table lives in `dart/private/tools/format_mode.bzl`;
# `resolve_format_mode` is re-exported here for `dart/tests/analyze_test.bzl`.
resolve_format_mode = _resolve_format_mode

def _format(ctx, name, staged, own_paths, language_version):
    """Declares the `dart format` check; returns the stamp it writes on success.

    Files are named individually rather than by handing the formatter the
    project: the staged tree also holds the rulesets the options include,
    none of which are this target's to format.

    `staged` is a project of its own, holding the target's files and the
    options alone — what `dart_format` stages for `bazel run`. The formatter
    reads nothing else: its options come from the walk up from each file, and
    its language version from the command line. Staging the dependencies too,
    as the analyzer needs, would make every edit to one of them re-run this
    check on every target above it, with nothing it reads changed.

    When `resolve_format_mode` selects in-process formatting, only
    `runtime_files` are declared in `sdk_inputs`; when falling back to the
    SDK's `dart format` CLI, `compile_files` are included as well.
    """
    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    mismatch = kernel_sdk_mismatch_error(ctx.label, "_format_tool", ctx.attr._format_tool, dart_sdk_info.version)
    if mismatch != None:
        fail(mismatch)
    mode = resolve_format_mode(dart_sdk_info.version, language_version)
    sdk_inputs = (
        depset(direct = [dart_sdk_info.dart], transitive = [dart_sdk_info.runtime_files]) if mode.in_process else depset(direct = [dart_sdk_info.dart], transitive = [dart_sdk_info.compile_files, dart_sdk_info.runtime_files])
    )
    manifest = ctx.actions.declare_file(name + ".format_manifest")
    ctx.actions.write(
        output = manifest,
        content = "".join(["src/%s\n" % p for p in own_paths]),
    )
    stamp = ctx.actions.declare_file(name + ".formatted")
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--dart", dart_sdk_info.dart)
    args.add("--sdk-version", dart_sdk_info.version)
    args.add("--project", staged.proj_path)
    args.add("--manifest", manifest)
    args.add("--stamp", stamp)

    # Always explicit — `resolve_format_mode` resolves `""`/`"latest"` to the
    # toolchain SDK's `<major>.<minor>`, said out loud so neither the vendored
    # formatter's `latestLanguageVersion` nor a staged config can answer instead.
    args.add("--language-version", mode.language_version)
    env = writable_home_env(dart_sdk_info.dart, stamp)
    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [ctx.executable._format_tool.path, args],
        inputs = depset(direct = [ctx.executable._format_tool, manifest] + staged.inputs, transitive = [sdk_inputs]),
        tools = depset(direct = [ctx.executable._format_tool, dart_sdk_info.dart], transitive = [dart_sdk_info.runtime_files]),
        outputs = [stamp],
        mnemonic = "DartFormat",
        progress_message = "Checking Dart formatting of %{label}",
        env = env,
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
    )
    return struct(
        stamp = stamp,
        mode = mode,
        sdk_inputs = sdk_inputs,
        env = env,
    )

def _closure_summary_outputs(target, ctx):
    sets = []
    if DartAnalyzerSummaryInfo in target:
        sets.append(target[DartAnalyzerSummaryInfo].transitive_summaries)
        sets.append(target[DartAnalyzerSummaryInfo].embedder_sdk_summaries)
    for d in closure_attrs(ctx):
        if DartAnalyzerSummaryInfo in d:
            sets.append(d[DartAnalyzerSummaryInfo].transitive_summaries)
            sets.append(d[DartAnalyzerSummaryInfo].embedder_sdk_summaries)
    return depset(transitive = sets)

def _analyze_summary_or_source(ctx, info, srcs, opts):
    """Runs the summary-mode or source-mode analyze action. Returns (output, summary_mode, summary_staged).

    Args:
      ctx: The aspect context.
      info: The target's `DartInfo` closure.
      srcs: `struct(name, staged, all_pkgs, own, generated, own_paths)`: the
        staged full-closure project and the target's own files, built once by
        `_dart_analyze_aspect_impl`.
      opts: `struct(sdk_inputs, sdk_version, config, is_leaf_own_only)`: the
        SDK inputs, toolchain version, analysis config, and leaf shape flag.
    """

    # The SDK check is the analyzing toolchain's own: the same one the
    # summary aspect and the codegen rules read.
    summary_files = srcs.own.values() + srcs.generated
    has_own_lib = bool(own_lib_sources(info, summary_files))
    summary_mode = ctx.attr._summaries[BuildSettingInfo].value and analyzer_summaries_supported(opts.sdk_version) and _summaries_ready(ctx, info, has_own_lib, summary_files)
    baseline = _baseline_slice(ctx, srcs.name, opts.config, srcs.own_paths)
    if not summary_mode:
        return depset([_analyze(ctx, srcs.name, srcs.staged, opts.sdk_inputs, srcs.own_paths, baseline)]), False, None

    # Only the target's own files are staged: its dependencies come from
    # their summaries, so no closure is read and no closure edit reaches
    # this action. The fix action below keeps the full staging.
    # The target's generated `.dart` sources are staged too, to resolve
    # its imports against, but are excluded from analysis, as the
    # default path excludes them. A generated source is in the closure
    # there, but in no dependency's summary.
    if opts.is_leaf_own_only and not srcs.generated:
        summary_staged = srcs.staged
    else:
        summary_staged = stage_config_project(
            ctx,
            opts.config,
            srcs.all_pkgs,
            summary_files,
            srcs.own.values(),
            srcs.name + ".summary",
            opts.sdk_version,
            struct(copy_external = False, all_packages_named = True),
        )
    sdk_summary = _embedder_sdk_summary(ctx) or ctx.file._sdk_summary
    return depset([_analyze_summaries(
        ctx,
        srcs.name,
        summary_staged,
        _dependency_summaries(ctx),
        sdk_summary,
        opts.sdk_inputs,
        srcs.own_paths,
        baseline,
    )]), True, summary_staged

def _analyze_format_checks(ctx, info, srcs, opts, summary_staged):
    """Runs one format check per language version. Returns the `DartFormat` list.

    Args:
      ctx: The aspect context.
      info: The target's `DartInfo` closure.
      srcs: `struct(name, staged, own, own_paths, generated, ...)`: the staged
        full-closure project and the target's own files, built once by
        `_dart_analyze_aspect_impl` (extra fields are ignored).
      opts: `struct(sdk_version, config, is_leaf_own_only, ...)`: the toolchain
        version, analysis config, and leaf shape flag (extra fields ignored).
      summary_staged: The summary-mode staged project, or None.
    """
    by_version = _format_language_versions(info, srcs.own_paths)
    if summary_staged != None and not srcs.generated:
        format_staged = summary_staged
    elif opts.is_leaf_own_only:
        format_staged = srcs.staged
    else:
        format_staged = stage_config_project(
            ctx,
            opts.config,
            [],
            srcs.own.values(),
            srcs.own.values(),
            srcs.name + ".format",
            opts.sdk_version,
            struct(copy_external = False, all_packages_named = False),
        )
    return [
        _format(
            ctx,
            srcs.name if len(by_version) == 1 else "%s.%s" % (srcs.name, version or "latest"),
            format_staged,
            paths,
            version,
        )
        for version, paths in sorted(by_version.items())
    ]

def _analyze_fix_outputs(ctx, name, staged, own_paths, sdk_inputs, dart_sdk_info):
    """Runs the fix action over the staged project. Returns (fixes, manifest)."""
    eligible = ctx.actions.declare_file(name + ".eligible")
    ctx.actions.write(
        output = eligible,
        content = "".join(["src/%s\t%s\n" % (p, p) for p in own_paths]),
    )
    fixes = ctx.actions.declare_directory(name + ".fixes")
    manifest = ctx.actions.declare_file(name + ".fix_manifest.json")
    scratch = ctx.actions.declare_directory(name + ".scratch")
    fix_args = ctx.actions.args()
    fix_args.add("--dart", dart_sdk_info.dart)
    fix_args.add("--project", staged.proj_path)
    fix_args.add("--scratch", scratch.path)
    fix_args.add("--fixes", fixes.path)
    fix_args.add("--manifest", manifest)
    fix_args.add("--eligible", eligible)
    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [ctx.executable._fix_tool.path, fix_args],
        inputs = depset(direct = [ctx.executable._fix_tool, eligible] + staged.inputs, transitive = [sdk_inputs]),
        tools = depset(direct = [ctx.executable._fix_tool, dart_sdk_info.dart], transitive = [dart_sdk_info.runtime_files]),
        outputs = [fixes, manifest, scratch],
        mnemonic = "DartFix",
        progress_message = "Computing Dart fixes for %{label}",
        env = writable_home_env(dart_sdk_info.dart, manifest),
    )
    return fixes, manifest

def _analyze_stage_all(ctx, info, entry, own, generated, name, sdk_version, config):
    """Stages the full closure project. Returns (all_pkgs, is_leaf_own_only, staged)."""
    all_pkgs = info.transitive_packages.to_list()
    all_closure_srcs = info.transitive_srcs.to_list() + info.transitive_resources.to_list() + entry + own.values() + generated
    has_non_own_closure_srcs = any([f.path not in own for f in all_closure_srcs])
    has_non_own_pkgs = any([p.package_name != info.package_name for p in all_pkgs])
    is_leaf_own_only = not has_non_own_closure_srcs and not has_non_own_pkgs
    staged = stage_config_project(
        ctx,
        config,
        all_pkgs,
        all_closure_srcs,
        own.values(),
        name,
        sdk_version,
        struct(copy_external = False, all_packages_named = is_leaf_own_only),
    )
    return all_pkgs, is_leaf_own_only, staged

def _dart_analyze_aspect_impl(target, ctx):
    # Checked here, not with `required_providers`: that matches only rules that
    # advertise the provider via `provides`, which dart_library and downstream
    # producers do not.
    if DartInfo not in target and DartAnalyzableInfo not in target:
        return []
    if ctx.label.repo_name:
        return []

    default_outputs = _closure_summary_outputs(target, ctx)

    # A target's own files are its `DefaultInfo` Dart files — a library's
    # sources, which for a `flutter_library` are its package's `lib/` — plus an
    # executable's entrypoints, which no package can name. Generated and
    # external files are never checked.
    info, entry, package_srcs = analyze_target_info(target)
    own, generated_by_path = analyze_own_files(target, entry, package_srcs)
    if own == None:
        return [OutputGroupInfo(default = default_outputs)]
    own_paths = sorted([f.short_path for f in own.values()])
    generated = generated_by_path.values()

    name = ctx.label.name + ".dart_analyze"
    config = ctx.attr._config[DartAnalysisConfigInfo]
    sdk_version = ctx.toolchains[_TOOLCHAIN].dart_sdk_info.version
    all_pkgs, is_leaf_own_only, staged = _analyze_stage_all(ctx, info, entry, own, generated, name, sdk_version, config)

    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info

    # The analyzer and `dart fix` read the SDK's launcher, its analysis snapshots
    # and its `lib/` sources, which is the analyze subset, plus `runtime_files`
    # so the launcher can run the `.dill` runner tools (`analyze_runner`,
    # `analyzer_summary`, `fix_runner`).
    sdk_inputs = depset(direct = [dart_sdk_info.dart], transitive = [dart_sdk_info.analyze_files, dart_sdk_info.runtime_files])

    tags = getattr(ctx.rule.attr, "tags", [])
    groups = {}
    summary_mode = False
    summary_staged = None

    # The values the analyze and format branches read travel together, so they
    # are structs built once here and passed down, rather than a parameter
    # per value.
    analyze_srcs = struct(
        name = name,
        staged = staged,
        all_pkgs = all_pkgs,
        own = own,
        generated = generated,
        own_paths = own_paths,
    )
    analyze_opts = struct(
        sdk_inputs = sdk_inputs,
        sdk_version = sdk_version,
        config = config,
        is_leaf_own_only = is_leaf_own_only,
    )
    if NO_ANALYZE_TAG not in tags:
        groups["dart_analyze"], summary_mode, summary_staged = _analyze_summary_or_source(
            ctx,
            info,
            analyze_srcs,
            analyze_opts,
        )
    format_checks = []
    if NO_FORMAT_TAG not in tags:
        format_checks = _analyze_format_checks(
            ctx,
            info,
            analyze_srcs,
            analyze_opts,
            summary_staged,
        )
        groups["dart_format"] = depset([c.stamp for c in format_checks])

    # Write-back is limited to the target's own hand-written files, decided
    # from Bazel's record of what each file is rather than from its name:
    # `dart fix`'s built-in generated-file skip matches `*.g.dart` and nothing
    # else, so a `.freezed.dart` part would otherwise be rewritten.
    fix_mismatch = kernel_sdk_mismatch_error(ctx.label, "_fix_tool", ctx.attr._fix_tool, dart_sdk_info.version)
    if fix_mismatch != None:
        fail(fix_mismatch)
    fixes, manifest = _analyze_fix_outputs(ctx, name, staged, own_paths, sdk_inputs, dart_sdk_info)

    return [
        OutputGroupInfo(
            default = default_outputs,
            dart_fix_fixes = depset([fixes]),
            dart_fix_manifest = depset([manifest]),
            **groups
        ),
        DartFixOutputsInfo(fixes = fixes, manifest = manifest),
        DartAnalysisModeInfo(
            summaries = summary_mode,
            format_checks = format_checks,
        ),
    ]

dart_analyze = aspect(
    implementation = _dart_analyze_aspect_impl,
    # The summaries of the target's dependencies, for the analyzer-summary mode.
    requires = [dart_analyzer_summary],
    attrs = {
        "_config": attr.label(
            doc = "Analysis configuration (options files and language versions) every analyze, fix and format action reads. Defaults to `//dart:analysis_config`.",
            default = "//dart:analysis_config",
            providers = [DartAnalysisConfigInfo],
        ),
        "_summaries": attr.label(
            doc = "Build setting switching the aspect between source mode and analyzer-summary mode. Defaults to `//dart:analyzer_summaries`.",
            default = "//dart:analyzer_summaries",
            providers = [BuildSettingInfo],
        ),
        "_sdk_summary": attr.label(
            doc = "Prebuilt summary of the SDK's own libraries, read by every summary-mode action alongside the package summaries. Defaults to `//dart/private:analyzer_sdk_summary_input`.",
            default = "//dart/private:analyzer_sdk_summary_input",
            allow_single_file = True,
        ),
        "_summary_tool": attr.label(
            doc = "Executable writing a package summary consumed by summary-mode analysis. Defaults to `//dart/private:analyzer_summary_tool`.",
            default = "//dart/private:analyzer_summary_tool",
            executable = True,
            cfg = "exec",
        ),
        "_analyze_tool": attr.label(
            doc = "Executable running `dart analyze` over the staged project. Defaults to `//dart/private/tools:analyze_runner`.",
            default = "//dart/private/tools:analyze_runner",
            executable = True,
            cfg = "exec",
        ),
        "_baseline_tool": attr.label(
            doc = "Executable slicing the analysis baseline to one target's own files. Defaults to `//dart/private/tools:baseline_slice`.",
            default = "//dart/private/tools:baseline_slice",
            executable = True,
            cfg = "exec",
        ),
        "_fix_tool": attr.label(
            doc = "Executable computing `dart fix` edits for the staged project. Defaults to `//dart/private/tools:fix_runner`.",
            default = "//dart/private/tools:fix_runner",
            executable = True,
            cfg = "exec",
        ),
        "_format_tool": attr.label(
            doc = "Executable checking `dart format` output for the staged project. Defaults to `//dart/private/tools:format_runner`.",
            default = "//dart/private/tools:format_runner",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [_TOOLCHAIN] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Runs `dart analyze` and `dart format` on a Dart target's own files; see `@rules_dart//dart:analyze.bzl`.",
)
