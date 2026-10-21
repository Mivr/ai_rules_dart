"""This module implements the Dart SDK toolchain rule."""

DartSdkInfo = provider(
    doc = "Information about the Dart SDK provided by the toolchain.",
    fields = {
        "dart": "File: The `dart` executable.",
        "sdk_root": "Target: The root directory of the SDK, containing `lib/` and `bin/`.",
        "version": "str: The SDK version string (e.g. `3.11.0`).",
        "tool_files": "depset[File]: All files needed to run the SDK. Pass as a `transitive` entry to action inputs / `ctx.runfiles(transitive_files = ...)`; flatten only to inspect paths.",
        "compile_files": "depset[File]: The SDK files `dart compile`, `gen_kernel` and `dart format` read. A subset of `tool_files`; equal to it when the toolchain names none.",
        "runtime_files": "depset[File]: The SDK files a test needs at run time to run a compiled kernel. A subset of `tool_files`; equal to it when the toolchain names none.",
        "analyze_files": "depset[File]: The SDK files `dart analyze`, `dart fix` and the analyzer-summary tool read: the launcher, the analysis snapshots and the SDK's `lib/` sources. A subset of `tool_files`; equal to it when the toolchain names none.",
        "target_os": "str: Cross-compilation target OS (`macos`, `linux`, `windows`), or empty for native.",
        "target_arch": "str: Cross-compilation target architecture (`x64`, `arm64`, `riscv64`, `arm`), or empty for native.",
        "cross_gen_snapshot": "File or None: Pinned host-to-target `gen_snapshot` binary for cross-compilation (`target_os`/`target_arch`), or `None` for native.",
        "cross_dartaotruntime": "File or None: Pinned target `dartaotruntime` binary for cross-compilation (`target_os`/`target_arch`), or `None` for native.",
        "patched_kernel_worker": "File or None: The `kernel_worker` AOT snapshot with comma-splitting disabled (see `comma_patch.dart`), or `None` when the SDK names no `kernel_worker` snapshot. Declared by one action per SDK; compiles that pass comma-containing `-D` values take it as a tool input.",
        "patched_gen_kernel": "File or None: The `gen_kernel` AOT snapshot with comma-splitting disabled, or `None` when the SDK names no `gen_kernel` snapshot. One action per SDK, like `patched_kernel_worker`.",
    },
)

_SUPPORTED_CROSS_TARGET_PAIRS = {
    ("linux", "x64"): True,
    ("linux", "arm64"): True,
    ("linux", "riscv64"): True,
    ("linux", "arm"): True,
}

def _patched_snapshot(ctx, sdk_files, dart, snapshot_suffix, out_name, kind):
    """Declares the comma-patch action for one SDK AOT snapshot, or None.

    The patched snapshot is a declared action output (the SDK snapshot in,
    the patched copy out), so every compile of this SDK that passes a
    comma-containing `-D` value takes the same file as a tool input, and the
    patch runs once per SDK instead of once per compile process. The action
    executes only when a compile needs its output: builds without comma
    defines never run it and never fail for it. When the snapshot matches no
    known pattern, the action fails loudly, so a comma-containing compile of
    this SDK fails with the patch tool's error instead of silently splitting
    the value.

    Args:
      ctx: The `dart_toolchain` rule context.
      sdk_files: Depset of the SDK files to search for the snapshot.
      dart: The SDK's `dart` File, which runs the patch tool from source when
          the SDK names no `dartvm`.
      snapshot_suffix: The `bin/snapshots/...` suffix naming the snapshot.
      out_name: The basename of the declared patched output.
      kind: The snapshot kind for the patch tool's diagnostics.

    Returns:
      The declared patched File, or None when the SDK names no such snapshot
      (an older SDK without a `kernel_worker` snapshot compiles no module).
    """
    snapshot = None
    dartvm = None
    for f in sdk_files.to_list():
        if snapshot == None and f.path.endswith("/" + snapshot_suffix):
            snapshot = f
        if dartvm == None and f.basename in ("dartvm", "dartvm.exe"):
            dartvm = f
    if snapshot == None:
        return None

    # The patch tool is Dart source, and both `dart` and `dartvm` run it. The
    # `dart` launcher finds its sibling `dartvm` by following its own path,
    # which works only when the sandbox lays the SDK out as siblings: under
    # remote execution (and the referee's twin) the launcher cannot find it,
    # so the action runs `dartvm` directly, declared as an input like every
    # other file it reads. An SDK layout without `dartvm` keeps the launcher.
    runner = dartvm if dartvm != None else dart
    patched = ctx.actions.declare_file(out_name)
    patch_tool = ctx.file._comma_patch
    args = ctx.actions.args()
    args.add(patch_tool)
    args.add(snapshot, format = "--input=%s")
    args.add(patched, format = "--output=%s")
    args.add("--sdk-version=" + ctx.attr.version)
    args.add("--kind=" + kind)
    ctx.actions.run(
        executable = runner,
        arguments = [args],
        inputs = depset(direct = [patch_tool, snapshot, runner]),
        outputs = [patched],
        mnemonic = "DartPatchSnapshot",
        progress_message = "Patching Dart SDK %s %s snapshot" % (ctx.attr.version, kind),
    )
    return patched

def _dart_toolchain_impl(ctx):
    if bool(ctx.attr.target_os) != bool(ctx.attr.target_arch):
        fail("dart_toolchain requires both target_os and target_arch to be set together or both omitted (got target_os=%r, target_arch=%r)" % (
            ctx.attr.target_os,
            ctx.attr.target_arch,
        ))
    if ctx.attr.target_os and (ctx.attr.target_os, ctx.attr.target_arch) not in _SUPPORTED_CROSS_TARGET_PAIRS:
        fail("Unsupported cross-compilation target (%s, %s); supported targets are linux/{x64,arm64,riscv64,arm}" % (
            ctx.attr.target_os,
            ctx.attr.target_arch,
        ))

    sdk_root = ctx.attr.sdk_root
    tool_files = ctx.attr.sdk_root.files

    # A toolchain that names no `compile_files` or `runtime_files` keeps the
    # whole SDK for those uses. That is always correct, if slower: a toolchain a
    # rule set declares itself may not know which SDK files the compiler reads.
    if ctx.attr.compile_files != None:
        compile_files = ctx.attr.compile_files.files
    else:
        compile_files = tool_files
    if ctx.attr.runtime_files != None:
        runtime_files = ctx.attr.runtime_files.files
    else:
        runtime_files = tool_files
    if ctx.attr.analyze_files != None:
        analyze_files = ctx.attr.analyze_files.files
    else:
        analyze_files = tool_files

    dart_sdk_info = DartSdkInfo(
        dart = ctx.file.dart,
        sdk_root = sdk_root,
        version = ctx.attr.version,
        tool_files = tool_files,
        compile_files = compile_files,
        runtime_files = runtime_files,
        analyze_files = analyze_files,
        target_os = ctx.attr.target_os,
        target_arch = ctx.attr.target_arch,
        cross_gen_snapshot = ctx.file.cross_gen_snapshot,
        cross_dartaotruntime = ctx.file.cross_dartaotruntime,
        patched_kernel_worker = _patched_snapshot(
            ctx,
            compile_files,
            ctx.file.dart,
            "bin/snapshots/kernel_worker_aot.dart.snapshot",
            "kernel_worker_nocomma.snapshot",
            "kernel_worker",
        ),
        patched_gen_kernel = _patched_snapshot(
            ctx,
            compile_files,
            ctx.file.dart,
            "bin/snapshots/gen_kernel_aot.dart.snapshot",
            "gen_kernel_nocomma.snapshot",
            "gen_kernel",
        ),
    )

    template_variables = platform_common.TemplateVariableInfo({
        "DART_BIN": ctx.file.dart.path,
    })
    default = DefaultInfo(
        files = tool_files,
        runfiles = ctx.runfiles(transitive_files = tool_files),
    )

    toolchain_info = platform_common.ToolchainInfo(
        dart_sdk_info = dart_sdk_info,
        template_variables = template_variables,
        default = default,
    )
    return [
        default,
        toolchain_info,
        template_variables,
    ]

dart_toolchain = rule(
    implementation = _dart_toolchain_impl,
    attrs = {
        "dart": attr.label(
            doc = "The `dart` executable from the SDK's `bin/` directory.",
            mandatory = True,
            allow_single_file = True,
        ),
        "sdk_root": attr.label(
            doc = "A filegroup containing all SDK files. Used for runfiles and for actions that need the whole SDK; compile and format actions use `compile_files`.",
            mandatory = True,
        ),
        "compile_files": attr.label(
            doc = "A filegroup of the SDK files `dart compile`, `gen_kernel` and `dart format` read; a subset of `sdk_root`. Leave unset to use all of `sdk_root` for those actions too.",
        ),
        "runtime_files": attr.label(
            doc = "A filegroup of the SDK files a test needs at run time to run a compiled kernel; a subset of `sdk_root`. Leave unset to use all of `sdk_root` for test runfiles too.",
        ),
        "analyze_files": attr.label(
            doc = "A filegroup of the SDK files `dart analyze`, `dart fix` and the analyzer-summary tool read; a subset of `sdk_root`. Leave unset to use all of `sdk_root` for those actions too.",
        ),
        "version": attr.string(
            doc = "The SDK version string (e.g. `3.11.0`).",
            mandatory = True,
        ),
        "target_os": attr.string(
            doc = "Cross-compilation target OS (`macos`, `linux`, `windows`). Leave empty for native compilation.",
        ),
        "target_arch": attr.string(
            doc = "Cross-compilation target architecture (`x64`, `arm64`, `riscv64`, `arm`). Leave empty for native compilation.",
        ),
        "cross_gen_snapshot": attr.label(
            doc = "Pinned host-to-target `gen_snapshot` binary for cross-compilation (`target_os`/`target_arch`).",
            allow_single_file = True,
        ),
        "cross_dartaotruntime": attr.label(
            doc = "Pinned target `dartaotruntime` binary for cross-compilation (`target_os`/`target_arch`).",
            allow_single_file = True,
        ),
        "_comma_patch": attr.label(
            doc = "The `comma_patch.dart` tool that disables comma-splitting in the SDK snapshots.",
            default = Label("//dart/private/tools:comma_patch.dart"),
            allow_single_file = True,
        ),
    },
    doc = "Defines a Dart SDK toolchain. Typically generated by the `dart_repositories` repository rule.",
)

# The SDK files `dart compile`, `gen_kernel` and `dart format` read. Those
# actions take this set as inputs instead of all of `sdk_root`: every input is
# symlinked into the sandbox and, remotely, hashed and uploaded, so about 15
# files beat 1,049. The patterns are generous so older SDK layouts and
# macOS/Windows names match; `allow_empty` lets a pattern that names nothing on
# this SDK pass.
_COMPILE_FILE_PATTERNS = [
    "bin/dart",
    "bin/dart.exe",
    "bin/dart.sym",
    "bin/dartvm*",
    "bin/dartaotruntime*",
    "bin/*.dll",
    "bin/utils/**",
    "bin/snapshots/dartdev*",
    "bin/snapshots/gen_kernel*",
    "bin/snapshots/frontend_server*",
    "bin/snapshots/kernel-service*",
    "bin/snapshots/kernel_worker*",
    "lib/_internal/vm_platform*.dill",
    "lib/_internal/allowed_experiments.json",
    "lib/libraries.json",
    "version",
    "revision",
]

# The SDK files a test needs to run a compiled kernel: the launcher and the VM
# that runs it. A test's runfiles take this set instead of all of `sdk_root`.
# The kernel-service snapshot and platform dill keep `Isolate.spawnUri` working
# on `.dart` sources.
_RUNTIME_FILE_PATTERNS = [
    "bin/dart",
    "bin/dart.exe",
    "bin/dart.sym",
    "bin/dartvm*",
    "bin/*.dll",
    "bin/snapshots/dartdev*",
    "bin/snapshots/kernel-service*",
    "lib/_internal/vm_platform*.dill",
    "lib/_internal/allowed_experiments.json",
    "lib/libraries.json",
    "version",
    "revision",
]

# The SDK files `dart analyze`, `dart fix` and the analyzer-summary tool read:
# the launcher and the analysis snapshots, the `lib/` sources the analyzer
# parses, the metadata it reads from `lib/_internal`, and `version`. That is
# about 470 `.dart` files of `lib/` and the two snapshots, against the whole
# SDK's 1,049 files and 642 MB: the dart2js, dartdevc and dart2wasm snapshots
# are never opened. The patterns are generous so older layouts and macOS and
# Windows names match, and `allow_empty` lets a pattern that names nothing on
# this SDK pass.
_ANALYZE_FILE_PATTERNS = [
    "bin/dart",
    "bin/dart.exe",
    "bin/dart.sym",
    "bin/dartaotruntime",
    "bin/dartaotruntime.exe",
    "bin/dartaotruntime.sym",
    "bin/*.dll",
    "bin/snapshots/analysis_server*",
    "bin/snapshots/dartdev.*",
    "bin/snapshots/dartdev_*",
    "lib/**/*.dart",
    "lib/_internal/*.json",
    "lib/_internal/*.yaml",
    "lib/_internal/sdk_library_metadata/**",
    "lib/libraries.json",
    "version",
    "revision",
]

# Public macro exported by `//dart:toolchain.bzl` and `//dart:repositories.bzl`
# that declares the fixed suite of SDK filegroups (`sdk_root`, `compile_files`,
# `runtime_files`, `analyze_files`) and `dart_toolchain` targets; its positional
# `(version, dart, ...)` signature is public API and cannot add a leading `name`
# parameter without an API break.
# buildifier: disable=unnamed-macro
def declare_dart_sdk_toolchains(
        version,
        dart,
        prefix = "",
        sdk_root_name = "sdk_root",
        cross_targets = ()):
    """Declares SDK filegroups and `dart_toolchain` targets over an extracted Dart SDK.

    Args:
        version: The Dart SDK version string (e.g. `3.11.0`).
        dart: Label or repo-relative path of the `dart` executable (e.g. `bin/dart`
            or `dart-sdk/bin/dart`).
        prefix: Path prefix inside the package where the Dart SDK lives (e.g. `""`
            when the SDK is at the root, or `"dart-sdk/"` when nested). A non-empty
            prefix without a trailing `"/"` has one appended.
        sdk_root_name: Name of the full SDK filegroup (default `"sdk_root"`). When
            set to another name (e.g. `"dart_sdk_files"`), a public `"sdk_root"`
            alias pointing to `":" + sdk_root_name` is also declared.
        cross_targets: Cross-compilation targets to declare `dart_toolchain_cross_<platform>`
            rules for. Accepts either a sequence of `(target_platform, target_os, target_arch[, cross_gen_snapshot, cross_dartaotruntime])`
            tuples or a dict mapping `target_platform` to `(target_os, target_arch[, cross_gen_snapshot, cross_dartaotruntime])`.
    """
    if prefix and not prefix.endswith("/"):
        prefix = prefix + "/"

    native.filegroup(
        name = sdk_root_name,
        srcs = native.glob([prefix + "**"]),
        visibility = ["//visibility:public"],
    )
    if sdk_root_name != "sdk_root":
        native.alias(
            name = "sdk_root",
            actual = ":" + sdk_root_name,
            visibility = ["//visibility:public"],
        )

    native.filegroup(
        name = "compile_files",
        srcs = native.glob(
            [prefix + p for p in _COMPILE_FILE_PATTERNS],
            allow_empty = True,
        ),
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "runtime_files",
        srcs = native.glob(
            [prefix + p for p in _RUNTIME_FILE_PATTERNS],
            allow_empty = True,
        ),
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "analyze_files",
        srcs = native.glob(
            [prefix + p for p in _ANALYZE_FILE_PATTERNS],
            allow_empty = True,
        ),
        visibility = ["//visibility:public"],
    )

    sdk_root_label = ":" + sdk_root_name
    dart_toolchain(
        name = "dart_toolchain",
        analyze_files = ":analyze_files",
        compile_files = ":compile_files",
        dart = dart,
        runtime_files = ":runtime_files",
        sdk_root = sdk_root_label,
        version = version,
        visibility = ["//visibility:public"],
    )

    if type(cross_targets) == "dict":
        cross_items = [
            (
                target_platform,
                entry[0],
                entry[1],
                entry[2] if len(entry) > 2 else None,
                entry[3] if len(entry) > 3 else None,
            )
            for target_platform, entry in cross_targets.items()
        ]
    else:
        cross_items = [
            (
                entry[0],
                entry[1],
                entry[2],
                entry[3] if len(entry) > 3 else None,
                entry[4] if len(entry) > 4 else None,
            )
            for entry in cross_targets
        ]

    for target_platform, target_os, target_arch, cross_gen_snapshot, cross_dartaotruntime in cross_items:
        dart_toolchain(
            name = "dart_toolchain_cross_" + target_platform,
            analyze_files = ":analyze_files",
            compile_files = ":compile_files",
            cross_dartaotruntime = cross_dartaotruntime,
            cross_gen_snapshot = cross_gen_snapshot,
            dart = dart,
            runtime_files = ":runtime_files",
            sdk_root = sdk_root_label,
            target_arch = target_arch,
            target_os = target_os,
            version = version,
            visibility = ["//visibility:public"],
        )
