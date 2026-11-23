"""Summary-mode and full-source fallback analysis via `analyzer_summary`.

On every supported Dart SDK (3.13 to 3.14, bounded by
`ANALYZER_MIN_LANGUAGE_VERSION` and `ANALYZER_MAX_LANGUAGE_VERSION` in
`dart/private/dart_analyzer_summary.bzl`) whose closure holds no unbacked
embedder, `analyzer_summary` is the sole analysis engine. When dependency
summaries are unavailable — under `--//dart:analyzer_summaries=false`, when
a package is split across targets, or when an opaque dependency lacks a
summary — the target is checked by `analyzer_summary` over staged transitive
sources with zero `--summary` flags, reporting source mode
(`DartAnalysisModeInfo.summaries == False`). Stock SDK `dart analyze` via
`analyze_runner` is used only as fallback for SDKs outside that range
(< 3.13 or > 3.14) or closures with an unbacked `_embedder.yaml`.
"""

load("//dart/private:aot_tool.bzl", "aot_tool_launch")
load("//dart/private:common.bzl", "writable_home_env")
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

    Args:
      ctx: The aspect context.
      name: Action output name prefix for this target.
      staged: The staged project holding the target's own files and options.
      summaries: The dependency summaries the target is checked against.
      sdk_summary: The SDK summary every summary-mode action reads.
      sdk_inputs: The analyzing SDK's input files.
      own_paths: The target's own `src/`-relative file paths being checked.
      baseline: The sliced per-target baseline, or None.

    Returns:
      The stamp the analyze action writes on success.
    """
    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    launch = aot_tool_launch(ctx, "_summary_tool", dart_sdk_info, dart_sdk_info.analyze_files)
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
        executable = launch.executable,
        arguments = launch.prefix + [args],
        inputs = depset(
            direct = launch.inputs + [sdk_summary] + staged.inputs +
                     ([baseline] if baseline != None else []),
            transitive = [summaries, sdk_inputs],
        ),
        tools = depset(
            direct = launch.inputs,
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

def fallback_summary_ready(info, sdk_version, embedder_sdk_summary):
    """Whether a target without summaries is still checked by `analyzer_summary`.

    True when the analyzing SDK is supported and the closure holds no unbacked
    embedder: every target then runs `analyze_summaries` (either with dependency
    summaries when summaries are enabled and ready, or over staged transitive
    sources with empty summaries in full-source mode or on split-package/opaque
    targets) rather than stock `dart analyze`.

    Args:
      info: The target's `DartInfo` closure.
      sdk_version: The analyzing toolchain's SDK version.
      embedder_sdk_summary: The single embedder SDK summary `File` from the
        closure's `DartAnalyzerSummaryInfo.embedder_sdk_summaries`, or None.

    Returns:
      True when the target is checked by `analyzer_summary`.
    """
    return (
        analyzer_summaries_supported(sdk_version) and
        not unbacked_embedder_in_closure(info, embedder_sdk_summary)
    )
