"""`build_runner` builders as Bazel actions.

`dart_build_runner` builds the generated files of one Dart package with the
builders in the user's lock, through one generic runner that drives
`build_runner`'s own build engine (see `//dart/build_runner/runner`). The
runner is compiled from the user's lock by the pub hub (`@<hub>//build_runner`,
written by `build_runner_targets` below), so the builders, their versions and
`build_runner` itself are the user's. Nothing here names a builder.
"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//dart:providers.bzl", "DartInfo")
load("//dart/private:dart_analyzer_summary.bzl", "embedder_in_closure")
load("//dart/private:dart_binary.bzl", _dart_binary = "dart_binary")
load("//dart/private:dart_library.bzl", _dart_library = "dart_library")

visibility("public")

BuildRunnerInfo = provider(
    doc = "The generic `build_runner` runner compiled from one lock, and what it runs with.",
    fields = {
        "runner": "FilesToRunProvider: the runner (exec configuration).",
        "package_graph": "File: the lock's package graph, in the shape of pub's `.dart_tool/package_graph.json`.",
        "sdk_summary": "BuildRunnerSdkSummaryInfo: the plain Dart SDK's summary, made once by the runner.",
    },
)

BuildRunnerSdkSummaryInfo = provider(
    doc = "An SDK summary made by a `build_runner` runner's own analyzer.",
    fields = {
        "file": "File: the summary.",
        "flutter": "bool: whether it holds Flutter's `dart:ui` libraries.",
    },
)

# The oldest `build_runner` the runner supports: 2.8.0 moved the engine the
# runner calls into `build_runner` itself.
MIN_BUILD_RUNNER = (2, 8, 0)

def _version_tuple(version):
    """`2.16.1` as `(2, 16, 1)`; a pre-release sorts below its release."""
    core = version.split("+")[0]
    pre = "-" in core
    core = core.split("-")[0]
    parts = core.split(".")
    nums = []
    for part in parts[:3]:
        if not part.isdigit():
            return None
        nums.append(int(part))
    if len(nums) != 3:
        return None
    return (nums[0], nums[1], nums[2], 0 if pre else 1)

def build_runner_version_error(hub, version):
    """The message for a lock whose `build_runner` the runner cannot drive.

    Args:
      hub: The hub's name.
      version: The locked `build_runner` version, or "" when the lock has none.

    Returns:
      The message, or None when the version is supported.
    """
    if not version:
        return (
            "The lock of the pub hub \"%s\" has no build_runner, which runs the builders of " +
            "`dart_build_runner`. Add it as a dev dependency (`dart pub add dev:build_runner`) " +
            "and run `dart pub get`."
        ) % hub
    parsed = _version_tuple(version)
    if parsed == None or parsed < MIN_BUILD_RUNNER + (1,):
        return (
            "The lock of the pub hub \"%s\" has build_runner %s; `dart_build_runner` supports " +
            "build_runner %s and later. Upgrade it (`dart pub upgrade build_runner`)."
        ) % (hub, version, ".".join([str(n) for n in MIN_BUILD_RUNNER]))
    return None

def _unavailable_impl(ctx):
    fail(ctx.attr.message)

build_runner_unavailable = rule(
    implementation = _unavailable_impl,
    doc = "Stands for the runner of a lock it cannot be built from; fails with `message` when used.",
    attrs = {"message": attr.string(mandatory = True)},
    provides = [BuildRunnerInfo],
)

def _embedder_yaml(f):
    if f.basename == "_embedder.yaml" and f.dirname.endswith("/lib"):
        return f.path
    return None

def _summary_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".sum")
    args = ctx.actions.args()
    args.add("--emit-sdk-summary", out)
    inputs = []
    flutter = False
    if ctx.attr.embedder:
        info = ctx.attr.embedder[DartInfo]
        args.add("--embedder", str(ctx.attr.embedder.label))
        args.add_all(info.transitive_resources, map_each = _embedder_yaml, before_each = "--embedder-yaml")
        inputs = depset(transitive = [info.transitive_srcs, info.transitive_resources])
        flutter = True
    ctx.actions.run(
        executable = ctx.executable.runner,
        arguments = [args],
        inputs = inputs,
        outputs = [out],
        mnemonic = "DartBuildRunnerSdkSummary",
        # The executable is an exec-configured attribute, not a toolchain.
        toolchain = None,
        progress_message = "Summarising the SDK for build_runner %{label}",
    )
    return [
        DefaultInfo(files = depset([out])),
        BuildRunnerSdkSummaryInfo(file = out, flutter = flutter),
    ]

build_runner_sdk_summary = rule(
    implementation = _summary_impl,
    doc = """The SDK summary `build_runner`'s analyzer reads, made once with the runner's own analyzer.

The hub makes the plain Dart one (`@<hub>//build_runner:sdk_summary`). A package that
imports Flutter needs one with Flutter's `dart:ui`: name `sky_engine` as `embedder`
and pass the target as `dart_build_runner.sdk_summary`.""",
    attrs = {
        "runner": attr.label(
            doc = "The runner, `@<hub>//build_runner:runner`.",
            mandatory = True,
            executable = True,
            cfg = "exec",
        ),
        "embedder": attr.label(
            doc = "Flutter's `sky_engine` package, whose `lib/_embedder.yaml` adds `dart:ui` and the other engine libraries.",
            providers = [DartInfo],
        ),
    },
)

def _tool_impl(ctx):
    return [BuildRunnerInfo(
        runner = ctx.attr.runner[DefaultInfo].files_to_run,
        package_graph = ctx.file.package_graph,
        sdk_summary = ctx.attr.sdk_summary[BuildRunnerSdkSummaryInfo],
    )]

build_runner_tool = rule(
    implementation = _tool_impl,
    doc = "Bundles a lock's runner with its package graph and SDK summary for `dart_build_runner.runner`.",
    attrs = {
        "runner": attr.label(mandatory = True, executable = True, cfg = "exec"),
        "package_graph": attr.label(mandatory = True, allow_single_file = True),
        "sdk_summary": attr.label(mandatory = True, providers = [BuildRunnerSdkSummaryInfo]),
    },
    provides = [BuildRunnerInfo],
)

def _build_yaml_args(ctx, args):
    for target, package in ctx.attr.build_yamls.items():
        args.add_all(target.files, before_each = "--build-yaml", format_each = package + "=%s")
    return depset(transitive = [target.files for target in ctx.attr.build_yamls])

def _entry_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".dart")
    args = ctx.actions.args()
    args.add("--out", out)
    ctx.actions.run(
        executable = ctx.executable.generator,
        arguments = [args],
        inputs = _build_yaml_args(ctx, args),
        outputs = [out],
        mnemonic = "DartBuildRunnerEntry",
        # The executable is an exec-configured attribute, not a toolchain.
        toolchain = None,
        progress_message = "Writing the build_runner entry point %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

_BUILD_YAMLS_ATTR = attr.label_keyed_string_dict(
    doc = "Each builder package's `build.yaml` (an empty file group when it has none), to the package's name.",
    allow_files = True,
)

build_runner_entry = rule(
    implementation = _entry_impl,
    doc = "Writes the runner's entry point from the `build.yaml` of the lock's builder packages.",
    attrs = {
        "generator": attr.label(mandatory = True, executable = True, cfg = "exec"),
        "build_yamls": _BUILD_YAMLS_ATTR,
    },
)

def _facts_impl(ctx):
    out = ctx.outputs.out
    if ctx.attr.error:
        ctx.actions.write(out, json.encode_indent({"builders": [], "error": ctx.attr.error, "version": 1}) + "\n")
        return [DefaultInfo(files = depset([out]))]
    args = ctx.actions.args()
    args.add("--facts", out)
    ctx.actions.run(
        executable = ctx.executable.generator,
        arguments = [args],
        inputs = _build_yaml_args(ctx, args),
        outputs = [out],
        mnemonic = "DartBuildRunnerFacts",
        # The executable is an exec-configured attribute, not a toolchain.
        toolchain = None,
        progress_message = "Writing the build_runner builder facts %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

build_runner_facts = rule(
    implementation = _facts_impl,
    doc = """Writes `out`: the builder definitions of the lock's builder packages, as JSON.

Gazelle reads it to predict the files `dart_build_runner` builds (`gen_entry --facts`
documents the shape). With `error` set (the lock cannot run builders) it lists no
builder and carries the message.""",
    attrs = {
        "out": attr.output(mandatory = True),
        "generator": attr.label(executable = True, cfg = "exec"),
        "build_yamls": _BUILD_YAMLS_ATTR,
        "error": attr.string(),
    },
)

# What the runner library imports, all in `build_runner`'s own closure.
_RUNNER_DEPS = [
    "analyzer",
    "build",
    "build_runner",
    "built_collection",
    "glob",
    "logging",
    "package_config",
    "path",
    "pub_semver",
    "watcher",
    "yaml",
]

def build_runner_targets(name, hub, version, builder_packages):
    """The targets of a hub's `build_runner` package, written by the hub.

    Args:
      name: The name of the target `dart_build_runner(runner = ...)` names,
        `build_runner` in the hub's `build_runner` package. The other targets
        keep their fixed names: `builders.json` and `:runner` are read by
        label.
      hub: The hub's name, for messages.
      version: The locked `build_runner` version, or "" when the lock has none.
      builder_packages: Dict of package name to the label of its `build.yaml`
        file group, for every package of the lock that may define builders
        (it depends on `build`, `build_config` or `source_gen`, and its whole
        closure is in the lock).
    """
    err = build_runner_version_error(hub, version)
    if err:
        build_runner_unavailable(
            name = name,
            message = err,
            visibility = ["//visibility:public"],
        )
        build_runner_facts(
            name = "builders",
            out = "builders.json",
            error = err,
            visibility = ["//visibility:public"],
        )
        return

    _dart_library(
        name = "runner_lib",
        package_name = "rules_dart_build_runner",
        srcs = ["lib/declared_paths.dart", "lib/runner.dart"],
        language_version = "3.4",
        deps = ["//:" + d for d in _RUNNER_DEPS],
    )
    _dart_binary(
        name = "gen_entry",
        main = "bin/gen_entry.dart",
        compile_mode = "kernel",
        launcher = True,
        deps = ["//:build_config"],
    )
    build_yamls = {label: package for package, label in builder_packages.items()}
    build_runner_entry(
        name = "entry",
        generator = ":gen_entry",
        build_yamls = build_yamls,
    )

    # What Gazelle reads to write `dart_build_runner` targets.
    build_runner_facts(
        name = "builders",
        out = "builders.json",
        generator = ":gen_entry",
        build_yamls = build_yamls,
        visibility = ["//visibility:public"],
    )
    _dart_binary(
        name = "runner",
        main = ":entry",
        # A builder's dependency may ship a build hook (drift_dev's sqlite3):
        # code generation never loads native code.
        code_assets_from_deps = False,
        compile_mode = "kernel",
        launcher = True,
        visibility = ["//visibility:public"],
        deps = [":runner_lib"] + ["//:" + p for p in sorted(builder_packages.keys())],
    )
    build_runner_sdk_summary(
        name = "sdk_summary",
        runner = ":runner",
        visibility = ["//visibility:public"],
    )
    build_runner_tool(
        name = name,
        runner = ":runner",
        package_graph = "//:package_graph.json",
        sdk_summary = ":sdk_summary",
        visibility = ["//visibility:public"],
    )

def _exec_dir(lib_root):
    # `lib_root` is short_path-based: an external repository's short paths
    # are `../<repo>/...` and its exec paths `external/<repo>/...`.
    if lib_root.startswith("../"):
        return "external/" + lib_root[3:]
    return lib_root or "."

def _pkg_arg(pkg):
    return "%s=%s=%s" % (pkg.package_name, _exec_dir(pkg.lib_root), getattr(pkg, "language_version", "") or "")

def _dart_build_runner_impl(ctx):
    tool = ctx.attr.runner[BuildRunnerInfo]
    pubspec = ctx.file.pubspec
    package_prefix = ctx.label.package + "/" if ctx.label.package else ""
    pubspec_rel = pubspec.short_path
    if ctx.label.workspace_root:
        pubspec_rel = pubspec.short_path[len("../" + ctx.label.workspace_name) + 1:]
    if not pubspec_rel.startswith(package_prefix) or pubspec.basename != "pubspec.yaml":
        fail("%s: `pubspec` must be a pubspec.yaml in this Bazel package or below it, got %s." % (ctx.label, pubspec.short_path))
    dart_dir = paths.dirname(pubspec_rel[len(package_prefix):])
    dart_prefix = dart_dir + "/" if dart_dir else ""

    if ctx.attr.sdk_summary:
        summary = ctx.attr.sdk_summary[BuildRunnerSdkSummaryInfo]
    else:
        summary = tool.sdk_summary
    dep_infos = [d[DartInfo] for d in ctx.attr.deps]
    if not summary.flutter:
        for info in dep_infos:
            if embedder_in_closure(info):
                fail(("%s: this package's dependencies include Flutter, whose `dart:ui` the plain Dart " +
                      "SDK summary lacks. Set `sdk_summary` to a `build_runner_sdk_summary` whose " +
                      "`embedder` is Flutter's `sky_engine`.") % ctx.label)

    short_prefix = paths.dirname(pubspec.short_path)
    short_prefix = short_prefix + "/" if short_prefix else ""
    outputs = []
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    args.add("--target", str(ctx.label))
    args.add("--pubspec", pubspec)
    args.add("--bin-dir", ctx.bin_dir.path)
    args.add("--package-graph", tool.package_graph)
    args.add("--sdk-summary", summary.file)
    for flag in ctx.attr.build_runner_args:
        args.add("--arg", flag)
    outs = []
    for f in ctx.outputs.outs:
        rel = f.short_path[len(short_prefix):] if f.short_path.startswith(short_prefix) else None
        if rel == None:
            fail("%s: output %s is outside the Dart package at %s." % (ctx.label, f.short_path, short_prefix or "."))
        outputs.append(f)
        outs.append(rel)
        args.add("--out", "%s=%s" % (rel, f.path))

    # Files of the package the target does not declare: a builder glob that
    # could see one of them fails the action, since its result would differ
    # from a build that saw the whole package.
    declared = {}
    for f in ctx.files.srcs + [pubspec]:
        declared[f.short_path] = True
    for path in ctx.attr.package_files:
        if not path.startswith(dart_prefix):
            continue
        asset = path[len(dart_prefix):]
        if asset in outs or (short_prefix + asset) in declared:
            continue
        args.add("--undeclared", asset)

    packages = depset(transitive = [i.transitive_packages for i in dep_infos])
    args.add_all(packages, map_each = _pkg_arg, before_each = "--pkg", uniquify = True)
    package_inputs = depset(
        ctx.files.srcs + ctx.files.data + [pubspec],
        transitive = [i.transitive_srcs for i in dep_infos] +
                     [i.transitive_resources for i in dep_infos],
    )
    args.add_all(package_inputs, before_each = "--in")

    ctx.actions.run(
        executable = tool.runner,
        arguments = [args],
        inputs = depset(
            [tool.package_graph, summary.file],
            transitive = [package_inputs],
        ),
        outputs = outputs,
        mnemonic = "DartBuildRunner",
        # The executable is an exec-configured attribute, not a toolchain.
        toolchain = None,
        progress_message = "Running build_runner builders for %{label}",
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "json",
        },
    )
    return [DefaultInfo(files = depset(outputs))]

dart_build_runner_rule = rule(
    implementation = _dart_build_runner_impl,
    doc = "See `dart_build_runner`.",
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "outs": attr.output_list(mandatory = True, allow_empty = False),
        "deps": attr.label_list(providers = [DartInfo]),
        "data": attr.label_list(allow_files = True),
        "pubspec": attr.label(mandatory = True, allow_single_file = True),
        "runner": attr.label(mandatory = True, providers = [BuildRunnerInfo], cfg = "exec"),
        "sdk_summary": attr.label(providers = [BuildRunnerSdkSummaryInfo], cfg = "exec"),
        "build_runner_args": attr.string_list(),
        "package_files": attr.string_list(),
    },
)

_EXCLUDED = [
    "BUILD",
    "BUILD.bazel",
    "**/BUILD",
    "**/BUILD.bazel",
    ".dart_tool/**",
    "build/**",
    "**/.dart_tool/**",
]

def dart_build_runner(
        name,
        outs,
        runner,
        srcs = None,
        deps = [],
        data = [],
        pubspec = "pubspec.yaml",
        sdk_summary = None,
        build_runner_args = [],
        **kwargs):
    """Builds a Dart package's generated files with the builders in the lock.

    One action runs `build_runner`'s own engine, with every builder of the
    user's lock that applies to the package (`auto_apply`, `build.yaml`,
    options, phases, post-process builders), and writes `outs`: the bytes
    `dart run build_runner build` writes for them. In a persistent worker it
    keeps `build_runner`'s build state between builds, so an edit rebuilds
    what `build_runner watch` would.

    Args:
      name: Target name. Its outputs go in the package's `dart_library`
        `srcs`.
      outs: The generated files to build, relative to the Dart package root
        (`lib/src/user.g.dart`). Each must be one `build_runner build` writes:
        a declared file no builder writes fails the action. Files of
        `build_to: cache` builders stay inside the action.
      runner: The lock's runner, `@<hub>//build_runner`.
      srcs: The package's own files. Defaults to every file of the package
        except `outs` and BUILD files, which is what the builders see in a
        stock build. With a smaller list, a builder that searches the package
        (`findAssets`) and could match a file left out fails the action.
      deps: The package's dependencies, as for its `dart_library`.
      data: Other files the build reads: the `pubspec.yaml` and `build.yaml`
        of a dependency that is the user's own package, so builders apply
        to it as they do in a stock build.
      pubspec: The package's `pubspec.yaml`; its directory is the package
        root, in this Bazel package or below it.
      sdk_summary: A `build_runner_sdk_summary`, for a package that imports
        Flutter. Defaults to the runner's plain Dart one.
      build_runner_args: `build_runner build` flags: `--release`,
        `--define=<builder>=<option>=<value>`, `--config=<name>`.
      **kwargs: Common attributes (`visibility`, `tags`, ...).
    """
    package_files = native.glob(["**"], exclude = _EXCLUDED, allow_empty = True)
    dart_dir = paths.dirname(pubspec)
    outs = [(dart_dir + "/" + o if dart_dir else o) for o in outs]
    if srcs == None:
        srcs = [f for f in package_files if f not in outs and f != pubspec]
    dart_build_runner_rule(
        name = name,
        outs = outs,
        runner = runner,
        srcs = srcs,
        deps = deps,
        data = data,
        pubspec = pubspec,
        sdk_summary = sdk_summary,
        build_runner_args = build_runner_args,
        package_files = package_files,
        **kwargs
    )
