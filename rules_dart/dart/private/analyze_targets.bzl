"""Target-file discovery, project staging and baseline actions for the `dart_analyze` aspect.

The aspect and `dart_analysis_config` live in `dart_analyze_aspect.bzl`; this
module holds the helpers they call, including the project staging that
`dart_format` shares for `bazel run`.
"""

load("//dart/private:common.bzl", "kernel_sdk_mismatch_error", "merge_package_records", "writable_home_env")
load("//dart/private:dart_analyzer_summary.bzl", "DartAnalyzerSummaryInfo", "closure_attrs")
load("//dart/private:project_staging.bzl", "pubspec_stub", "stage_dart_project")

visibility(["//dart/..."])

_TOOLCHAIN = "//dart:exec_tools_toolchain_type"

_OPTIONS_BASENAME = "analysis_options.yaml"

def closure_summary_outputs(target, ctx):
    """Collects transitive analyzer and embedder SDK summaries across the closure.

    Args:
      target: The target under the `dart_analyze` aspect.
      ctx: The `dart_analyze` aspect context.

    Returns:
      A `depset` of transitive summary files across `target` and `closure_attrs(ctx)`.
    """
    sets = []
    if DartAnalyzerSummaryInfo in target:
        sets.append(target[DartAnalyzerSummaryInfo].transitive_summaries)
        sets.append(target[DartAnalyzerSummaryInfo].embedder_sdk_summaries)
    for d in closure_attrs(ctx):
        if DartAnalyzerSummaryInfo in d:
            sets.append(d[DartAnalyzerSummaryInfo].transitive_summaries)
            sets.append(d[DartAnalyzerSummaryInfo].embedder_sdk_summaries)
    return depset(transitive = sets)

def _is_under_dir(path, directory):
    """Returns whether `path` sits inside `directory` (or anywhere when empty).

    Args:
      path: The workspace-relative `short_path` to test.
      directory: The directory `short_path`, or the empty string for the
        workspace root.

    Returns:
      True when `path` is `directory` itself or sits below it.
    """
    return directory == "" or path.startswith(directory + "/")

def governing_options_paths(config, own_paths):
    """Returns `short_path`s of `config.options_files` governing any `own_paths`.

    Args:
      config: The `DartAnalysisConfigInfo` provider, whose `options_files` are
        checked for a directory above one of `own_paths`.
      own_paths: The target's checked file `short_path`s.

    Returns:
      The `short_path`s of every listed `analysis_options.yaml` whose directory
      contains at least one of `own_paths`, in the config's own order.
    """
    return [
        f.short_path
        for f in config.options_files
        if any([_is_under_dir(p, f.short_path.rpartition("/")[0]) for p in own_paths])
    ]

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

    Args:
      excluded: The staged paths to exclude from analysis, or an empty list
        when nothing else is staged.

    Returns:
      The wrapper options file's contents as a string.
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
        if [p for p in own_paths if _is_under_dir(p, f.short_path.rpartition("/")[0])]
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

def _run_baseline_tool(ctx, dart_sdk_info, config_label, baseline, out, args, action):
    """Declares a `baseline_slice` action writing `out`.

    Args:
      ctx: The rule or aspect context carrying `_baseline_tool`.
      dart_sdk_info: The exec toolchain's Dart SDK info.
      config_label: The `dart_analysis_config` label named in the arguments.
      baseline: The whole baseline file to read.
      out: The output file the action writes.
      args: The `Args` carrying the action's remaining flags.
      action: `struct(mnemonic, progress_message)` naming the action.

    Returns:
      None.
    """
    mismatch = kernel_sdk_mismatch_error(
        ctx.label,
        "_baseline_tool",
        ctx.attr._baseline_tool,
        dart_sdk_info.version,
    )
    if mismatch != None:
        fail(mismatch)
    args.add("--config", str(config_label))
    args.add("--baseline", baseline)
    args.add("--baseline-display", baseline.short_path)
    args.add("--out", out)
    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [ctx.executable._baseline_tool.path, args],
        inputs = depset(direct = [ctx.executable._baseline_tool, baseline]),
        tools = depset(
            direct = [ctx.executable._baseline_tool, dart_sdk_info.dart],
            transitive = [dart_sdk_info.runtime_files],
        ),
        outputs = [out],
        mnemonic = action.mnemonic,
        progress_message = action.progress_message,
        env = writable_home_env(dart_sdk_info.dart, out),
        toolchain = _TOOLCHAIN,
    )

def validate_config_baseline(ctx):
    """Declares the action validating `dart_analysis_config.baseline`, or returns None.

    Args:
      ctx: The `dart_analysis_config` rule context.

    Returns:
      The validated normalized baseline `File`, or `None` when no baseline is
      configured (or no exec toolchain is registered).
    """
    baseline = ctx.file.baseline
    if baseline == None:
        return None
    toolchain = ctx.toolchains[_TOOLCHAIN]
    if toolchain == None:
        return None
    validated = ctx.actions.declare_file(ctx.label.name + ".baseline.json")
    args = ctx.actions.args()
    args.add("--validate-only")
    msg = "Validating Dart analysis baseline `%s` for %s" % (
        baseline.short_path,
        ctx.label,
    )
    _run_baseline_tool(
        ctx,
        toolchain.dart_sdk_info,
        ctx.label,
        baseline,
        validated,
        args,
        struct(mnemonic = "DartBaselineValidate", progress_message = msg),
    )
    return validated

def slice_target_baseline(ctx, name, config, own_paths):
    """Declares the action slicing `config`'s baseline to `own_paths`; returns it, or None.

    The slice is the only baseline input the analyze action reads. Its bytes
    hold only entries for the target's checked files, sorted by path and code,
    so an edit to another target's entry leaves this target's `DartAnalyze`
    action key unchanged.

    Args:
      ctx: The `dart_analyze` aspect context.
      name: Action output name prefix for this target.
      config: The `DartAnalysisConfigInfo` provider.
      own_paths: Sorted `short_path`s of the target's own checked files.

    Returns:
      The per-target slice `File`, or `None` when `config.baseline` is `None`.
    """
    baseline = config.baseline
    if baseline == None:
        return None
    slice = ctx.actions.declare_file(name + ".baseline.json")
    checked = own_paths + governing_options_paths(config, own_paths)
    args = ctx.actions.args()
    args.add_all(checked, before_each = "--file")
    msg = "Slicing Dart analysis baseline `%s` (%s) for %%{label}" % (
        baseline.short_path,
        ctx.attr._config.label,
    )
    _run_baseline_tool(
        ctx,
        ctx.toolchains[_TOOLCHAIN].dart_sdk_info,
        ctx.attr._config.label,
        baseline,
        slice,
        args,
        struct(mnemonic = "DartBaselineSlice", progress_message = msg),
    )
    return slice
