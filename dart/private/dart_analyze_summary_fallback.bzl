"""Summary-mode analysis for targets without usable dependency summaries.

When `//dart:analyzer_summaries` is on and the analyzing SDK is supported but a
target cannot be analyzed from dependency summaries — its package is split
across targets, or a dependency has no summary — the target is still checked
by `analyzer_summary`, run over its own staged sources with no summaries, so
the hosted project rules (see `//dart/lints:rules_dart_project_lints`) check
it without `.sum` conflicts. The mode stays source: `DartAnalysisModeInfo`
reports no summary use, only the checker changes.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart/private:common.bzl", "kernel_sdk_mismatch_error", "writable_home_env")
load(
    "//dart/private:dart_analyzer_summary.bzl",
    "analyzer_summaries_supported",
    "sdk_root_path",
    "unbacked_embedder_in_closure",
)

visibility(["//dart/..."])

# The execution-platform SDK toolchain type analysis actions resolve the
# analyzer through. Matches `_TOOLCHAIN` in `dart_analyze_aspect.bzl`, which
# loads this file: one string, two spellings, no import cycle.
_TOOLCHAIN = "//dart:exec_tools_toolchain_type"

def analyze_summaries(ctx, name, staged, summaries, sdk_summary, sdk_inputs, own_paths, baseline):
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
        toolchain = _TOOLCHAIN,
    )
    return stamp

def fallback_summary_ready(ctx, info, sdk_version, embedder_sdk_summary):
    """Whether a target without summaries is still checked by `analyzer_summary`.

    True when summaries are enabled, the analyzing SDK is supported, and the
    closure holds no unbacked embedder: split-package and opaque-dependency
    targets then run `analyze_summaries` over their own staged sources with
    empty summaries instead of stock `dart analyze`, so the hosted project
    rules still check them. Without summaries every other staged file is
    resolution-only, so the worker analyzes only the explicit sources, like
    the `dart analyze` wrapper excludes do.

    Args:
      ctx: The aspect context, carrying the `_summaries` build setting.
      info: The target's `DartInfo` closure.
      sdk_version: The analyzing toolchain's SDK version.
      embedder_sdk_summary: The single embedder SDK summary `File` from the
        closure's `DartAnalyzerSummaryInfo.embedder_sdk_summaries`, or None.

    Returns:
      True when the target is checked by `analyzer_summary` without summaries.
    """
    return (
        ctx.attr._summaries[BuildSettingInfo].value and
        analyzer_summaries_supported(sdk_version) and
        not unbacked_embedder_in_closure(info, embedder_sdk_summary)
    )
