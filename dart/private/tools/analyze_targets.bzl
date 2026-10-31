"""Target-file discovery and baseline actions for the `dart_analyze` aspect.

Kept apart from `dart_analyze_aspect.bzl`, which declares the aspect and
`dart_analysis_config`, so that file holds the staging and analysis plumbing.
"""

load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("//dart/private:common.bzl", "kernel_sdk_mismatch_error", "writable_home_env")

_TOOLCHAIN = "//dart:exec_tools_toolchain_type"

def analyze_own_files(target, entry, package_srcs):
    """Splits a target's checkable Dart files into own and generated.

    Args:
      target: The target under the aspect.
      entry: The target's `DartAnalyzableInfo.srcs`, or an empty list.
      package_srcs: The target's `DartAnalyzableInfo.package_srcs`, or an
        empty list.

    Returns:
      `(own, generated_by_path)`: dicts keyed by file path, or `(None, None)`
      when the target has no source Dart file of its own to check.
    """
    own = {}
    generated_by_path = {}
    for f in [f for f in target[DefaultInfo].files.to_list() + entry + package_srcs if f.extension == "dart"]:
        if f.short_path.startswith("../"):
            continue
        if f.is_source:
            own[f.path] = f
        else:
            generated_by_path[f.path] = f
    if not own:
        return None, None
    return own, generated_by_path

def analyze_target_info(target):
    """Returns `(info, entry, package_srcs)` for an analyzable target.

    Args:
      target: The target under the aspect.

    Returns:
      The target's `DartInfo` closure, its `DartAnalyzableInfo.srcs` (empty
      when the target is not analyzable), and its package's own `lib/` files
      from `DartAnalyzableInfo.package_srcs` (empty too in that case).
    """
    if DartAnalyzableInfo in target:
        info = target[DartAnalyzableInfo].dart_info
        entry = target[DartAnalyzableInfo].srcs.to_list()

        # A package's own `lib/` files, which a target's `DefaultInfo` (a web
        # bundle, a test executable) need not list. Absent from records built
        # against an older rules_dart.
        package_srcs = getattr(target[DartAnalyzableInfo], "package_srcs", depset()).to_list()
    else:
        info = target[DartInfo]
        entry = []
        package_srcs = []
    return info, entry, package_srcs

def _run_baseline_tool(ctx, dart_sdk_info, config_label, baseline, out, args, action):
    """Declares a `baseline_slice` action writing `out`."""
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
    _run_baseline_tool(
        ctx,
        toolchain.dart_sdk_info,
        ctx.label,
        baseline,
        validated,
        args,
        struct(
            mnemonic = "DartBaselineValidate",
            progress_message = "Validating Dart analysis baseline for %{label}",
        ),
    )
    return validated

def slice_target_baseline(ctx, name, config, own_paths):
    """Declares the action slicing `config`'s baseline to `own_paths`; returns it, or None.

    The slice is the only baseline input the analyze action reads. Its bytes
    hold only entries for the target's own files, sorted by path and code, so
    an edit to another target's entry leaves this target's `DartAnalyze` action
    key unchanged.

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
    args = ctx.actions.args()
    args.add_all(own_paths, before_each = "--file")
    _run_baseline_tool(
        ctx,
        ctx.toolchains[_TOOLCHAIN].dart_sdk_info,
        ctx.attr._config.label,
        baseline,
        slice,
        args,
        struct(
            mnemonic = "DartBaselineSlice",
            progress_message = "Slicing Dart analysis baseline for %{label}",
        ),
    )
    return slice
