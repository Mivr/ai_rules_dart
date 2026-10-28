"""Implementation of the dart_binary rule."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartCompileInfo", "DartInfo", "DartRecordedUsesInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "merge_dart_defines")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_transitive_code_assets",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "generate_native_assets_yaml",
    "generate_stable_package_config",
    "resolve_code_assets",
    "runfiles_path",
    "target_dart_abi",
)
load("//dart/private:dart_compile.bzl", "dart_compile_action", "recorded_uses_kind")
load(
    "//dart/private:dart_kernel.bzl",
    "BINARY_MODULAR_KERNEL_ATTRS",
    "DartKernelInfo",
    "EXEC_TOOLS_TOOLCHAIN",
    "MODULAR_KERNEL_TOOLCHAINS",
    "dart_kernel_module_aspect",
    "entry_sources",
    "modular_executable_kernel",
    "modular_executable_tools",
)
load("//dart/private:dart_test_runner.bzl", "DartTestRunnerMainInfo")
load("//dart/private:executable_package.bzl", "EXECUTABLE_PACKAGE_ATTRS", "executable_package")
load("//dart/private:kernel_params.bzl", "kernel_compile_settings")
load("//dart/private:source_set.bzl", "executable_inputs")

def _kernel_launcher_for_mode(compile_mode, launcher):
    if compile_mode == "kernel" and launcher:
        return Label("//dart/private/tools:kernel_launcher")
    return None

def binary_output_basename(name, compile_mode, is_windows):
    """Returns a `dart_binary`'s output filename with the platform exe extension.

    Includes the platform-appropriate executable extension.

    A native `exe` gets a `.exe` suffix on Windows so it is launchable and
    discoverable by the conventional name (e.g. via runfiles
    `rlocation("…/app.exe")`). Without it the output is a bare `app`, and a
    consumer looking up `app.exe` misses — falling through to a non-existent
    path. The snapshot modes use fixed extensions on every platform.

    Args:
      name: The target name (`ctx.label.name`).
      compile_mode: One of `exe`, `aot-snapshot`, `kernel`, `jit-snapshot`.
      is_windows: Whether the target platform is Windows.

    Returns:
      The output filename string.
    """
    if compile_mode == "exe":
        return name + (".exe" if is_windows else "")
    elif compile_mode == "aot-snapshot":
        return name + ".aot"
    elif compile_mode == "kernel":
        return name + ".dill"
    elif compile_mode == "jit-snapshot":
        return name + ".jit"
    fail("Unknown compile_mode: %s" % compile_mode)

def _binary_sdk_info(ctx):
    """Selects the compiling SDK: the exec-tools SDK for tool configurations, else the target toolchain's."""
    exec_tc = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN] if EXEC_TOOLS_TOOLCHAIN in ctx.toolchains else None
    if ctx.configuration.is_tool_configuration() and exec_tc != None and exec_tc.dart_sdk_info != None:
        return exec_tc.dart_sdk_info
    return ctx.toolchains["//dart:toolchain_type"].dart_sdk_info

def _binary_recorded_uses(ctx, compile_mode):
    """Declares the recorded-uses file when `record_use` is set. Returns (compile_recorded_uses, recorded_uses_info)."""
    compile_recorded_uses = None
    recorded_uses_info = []
    if ctx.attr.record_use:
        recorded_uses = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json")
        kind = recorded_uses_kind(compile_mode)
        if kind == "aot":
            compile_recorded_uses = recorded_uses
        else:
            ctx.actions.write(output = recorded_uses, content = "{}")
        recorded_uses_info = [DartRecordedUsesInfo(file = recorded_uses, kind = kind)]
    return compile_recorded_uses, recorded_uses_info

def _binary_source_compile(ctx, dart_sdk_info, own, packages, output, compile_mode, optional_outputs, resolved_assets):
    """Compiles from source through `executable_inputs`. Returns (packages, code_asset_libs)."""

    # Nothing is copied: a package split between the source tree and `bazel-out`
    # compiles in place, through the multi-root file system (`executable_inputs`).
    # The one flatten per rule: the package lookup inspects per-file paths.
    inputs = executable_inputs(
        packages,
        collect_transitive_srcs(ctx.attr.deps).to_list(),
        ctx.file.main,
        ctx.files.srcs,
        own.record,
    )
    packages = inputs.packages
    main_input = inputs.main_input
    main_arg = inputs.main_arg
    all_srcs = inputs.srcs

    # Root resolution must see the rule's own inputs too: a package whose
    # metadata comes from a srcs-less façade library resolves only via the
    # files this rule supplies itself.
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = generate_stable_package_config(packages, all_srcs, inputs.roots),
    )

    code_asset_libs = []
    native_assets_yaml = None
    if resolved_assets:
        abi = target_dart_abi(ctx)
        entries, code_asset_libs = code_asset_entries(
            ctx.label,
            resolved_assets,
            output.dirname,
        )
        native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
        ctx.actions.write(
            output = native_assets_yaml,
            content = generate_native_assets_yaml(abi, entries),
        )

    # Run dart compile
    dart_compile_action(
        ctx = ctx,
        dart_sdk_info = dart_sdk_info,
        cfg = struct(
            main = main_input,
            srcs = all_srcs,
            package_config = package_config,
            output = output,
            compile_mode = compile_mode,
            target_os = dart_sdk_info.target_os,
            target_arch = dart_sdk_info.target_arch,
            extra_flags = ctx.attr.dart_compile_flags,
            defines = merge_dart_defines(ctx),
            main_path = main_arg,
            recorded_uses = optional_outputs.recorded_uses,
            debug_info = optional_outputs.debug_info,
            jit_tool = ctx.files._jit_tool,
            comma_patch = ctx.file._comma_patch,
            native_assets_yaml = native_assets_yaml,
            embed_sources = DartTestRunnerMainInfo not in ctx.attr.main,
            jit_snapshot_fallback = ctx.attr._jit_snapshot_fallback[BuildSettingInfo].value,
        ),
    )
    return packages, code_asset_libs

def _binary_optional_outputs(ctx, compile_mode):
    """Declares the recorded-uses and split-debug outputs for a `dart_binary`.

    Args:
      ctx: The rule context.
      compile_mode: The `dart compile` mode.

    Returns:
      A struct with `recorded_uses` (File or None), `recorded_uses_info`
      (provider list) and `debug_info` (File or None).
    """
    compile_recorded_uses, recorded_uses_info = _binary_recorded_uses(ctx, compile_mode)
    return struct(
        recorded_uses = compile_recorded_uses,
        recorded_uses_info = recorded_uses_info,
        debug_info = _binary_debug_info(ctx, compile_mode),
    )

def _binary_debug_info(ctx, compile_mode):
    """Declares the `<name>.debug` symbols file when `split_debug_info` is set.

    Args:
      ctx: The rule context.
      compile_mode: The `dart compile` mode.

    Returns:
      The declared symbols File, or None when splitting is off.
    """
    if not ctx.attr.split_debug_info:
        return None
    if compile_mode not in ("exe", "aot-snapshot"):
        fail(("dart_binary: `split_debug_info` is only valid with `compile_mode` " +
              "\"exe\" or \"aot-snapshot\", but %s sets `compile_mode` = %r.") %
             (ctx.label, compile_mode))
    return ctx.actions.declare_file(ctx.label.name + ".debug")

def _binary_compile_info(result):
    """The `DartCompileInfo` provider for a compiled binary.

    Args:
      result: The struct describing the compiled binary.

    Returns:
      A `DartCompileInfo` carrying the raw compiled file and its mode.
    """
    return DartCompileInfo(
        executable = result.output,
        compile_mode = result.compile_mode,
        sdk_version = result.dart_sdk_info.version,
    )

def _binary_output_groups(result):
    """The documented `snapshot` and `debug_info` output groups.

    Args:
      result: The struct describing the compiled binary.

    Returns:
      `OutputGroupInfo` exposing the raw compiled file and, when it exists,
      the split symbols file.
    """
    if result.debug_info == None:
        return OutputGroupInfo(snapshot = depset([result.output]))
    return OutputGroupInfo(
        snapshot = depset([result.output]),
        debug_info = depset([result.debug_info]),
    )

def _binary_declared_files(result):
    """The `DefaultInfo.files` of a compiled binary.

    The raw compile output is always present. A split symbols file joins it,
    so a build-only consumer still gets the artifact it asked for.

    Args:
      result: The struct describing the compiled binary.

    Returns:
      A depset of files.
    """
    files = [result.output]
    if result.debug_info != None:
        files.append(result.debug_info)
    return depset(files)

def _snapshot_runner(result):
    """The pinned-SDK VM that runs a snapshot output.

    Args:
      result: The struct describing the compiled binary.

    Returns:
      The `dart` File for `jit-snapshot`, or the `dartaotruntime` File for
      `aot-snapshot` (including a cross target's own runtime).
    """
    if result.compile_mode == "jit-snapshot":
        return result.dart_sdk_info.dart
    cross_runtime = getattr(result.dart_sdk_info, "cross_dartaotruntime", None)
    if cross_runtime != None:
        return cross_runtime
    for f in result.dart_sdk_info.compile_files.to_list():
        if f.basename in ("dartaotruntime", "dartaotruntime.exe"):
            return f
    fail(("dart_binary: `compile_mode = \"aot-snapshot\"` needs a " +
          "`dartaotruntime` in the pinned SDK %s, but the toolchain names none.") %
         result.dart_sdk_info.version)

def _binary_snapshot_outputs(ctx, result):
    """The launcher-executable providers for `aot-snapshot` and `jit-snapshot`.

    The launcher runs the target's own pinned-SDK VM on the raw snapshot in
    runfiles, forwarding every argument. The raw snapshot stays in
    `DefaultInfo.files` and the `snapshot` output group so build-only consumers
    keep receiving the compiled artifact.

    Args:
      ctx: The rule context.
      result: The struct describing the compiled binary.

    Returns:
      The providers for a snapshot-mode `dart_binary`.
    """
    runner = _snapshot_runner(result)
    launcher = ctx.actions.declare_file(
        ctx.label.name + (".bat" if result.is_windows else ".sh"),
    )
    template = ctx.file._snapshot_launcher_bat if result.is_windows else ctx.file._snapshot_launcher_sh
    ctx.actions.expand_template(
        template = template,
        output = launcher,
        substitutions = {
            "@RULES_DART_RUNNER@": runfiles_path(runner, ctx.workspace_name),
            "@RULES_DART_SNAPSHOT@": runfiles_path(result.output, ctx.workspace_name),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(
        files = ctx.files.data + result.code_asset_libs + [result.output, runner],
        transitive_files = depset(
            transitive = [
                collect_transitive_resources(ctx.attr.deps),
                result.dart_sdk_info.runtime_files,
            ],
        ),
    ).merge_all(
        [dep[DefaultInfo].default_runfiles for dep in ctx.attr.data],
    )
    return [
        DefaultInfo(
            files = _binary_declared_files(result),
            executable = launcher,
            runfiles = runfiles,
        ),
        _binary_compile_info(result),
        _binary_output_groups(result),
        # What makes the `dart_analyze` aspect and `dart_fix` reach this entrypoint
        # without making this target a legal `deps` entry. Staging goes by
        # `short_path`, which is the source file's own path.
        result.own.analyzable,
    ] + result.recorded_uses_info

def _binary_launcher_outputs(ctx, result):
    """The launcher-executable providers for `kernel` mode with `launcher = True`.

    Args:
      ctx: The rule context.
      result: The struct describing the compiled binary.

    Returns:
      The providers for a kernel-mode `dart_binary` with a native launcher.
    """
    launcher_exe = ctx.actions.declare_file(
        ctx.label.name + (".exe" if result.is_windows else ""),
    )
    ctx.actions.symlink(
        output = launcher_exe,
        target_file = ctx.executable._kernel_launcher,
        is_executable = True,
    )
    config_file = ctx.actions.declare_file(
        ctx.label.name + ".kernel_launcher.json",
    )
    ctx.actions.write(
        output = config_file,
        content = json.encode({
            "dart": runfiles_path(result.dart_sdk_info.dart, ctx.workspace_name),
            "dill": runfiles_path(result.output, ctx.workspace_name),
            "dart_exec": result.dart_sdk_info.dart.path,
            "dill_exec": result.output.path,
        }),
    )
    runfiles = ctx.runfiles(
        files = ctx.files.data + result.code_asset_libs + [result.output, config_file, result.dart_sdk_info.dart],
        transitive_files = depset(
            transitive = [
                collect_transitive_resources(ctx.attr.deps),
                result.dart_sdk_info.runtime_files,
            ],
        ),
    ).merge_all(
        [dep[DefaultInfo].default_runfiles for dep in ctx.attr.data] +
        [ctx.attr._kernel_launcher[DefaultInfo].default_runfiles],
    )
    return [
        DefaultInfo(
            files = depset([launcher_exe]),
            executable = launcher_exe,
            runfiles = runfiles,
        ),
        RunEnvironmentInfo(
            environment = {
                "RULES_DART_KERNEL_CONFIG": runfiles_path(config_file, ctx.workspace_name),
            },
        ),
        _binary_compile_info(result),
        _binary_output_groups(result),
        result.own.analyzable,
    ] + result.recorded_uses_info

def _binary_default_outputs(ctx, result):
    """The standard executable providers, with package resources in runfiles.

    Args:
      ctx: The rule context.
      result: The struct describing the compiled binary.

    Returns:
      The providers for a `dart_binary` without a launcher.
    """

    # Resources ride the runfiles, not the compile. A dep's `lib/**` non-Dart
    # files are part of the package at run time under pub, and the compiled
    # binary is the one place that cannot recover them: `Isolate.resolvePackageUri`
    # returns null in an AOT binary with no package_config above it, so a
    # package cannot read its own shipped files back out. Staging them here is
    # what makes `rlocation` work for them.
    runfiles = ctx.runfiles(
        files = ctx.files.data + result.code_asset_libs,
        transitive_files = collect_transitive_resources(ctx.attr.deps),
    ).merge_all(
        [dep[DefaultInfo].default_runfiles for dep in ctx.attr.data],
    )

    return [
        DefaultInfo(
            files = _binary_declared_files(result),
            executable = result.output,
            runfiles = runfiles,
        ),
        _binary_compile_info(result),
        _binary_output_groups(result),
        # What makes the `dart_analyze` aspect and `dart_fix` reach this entrypoint
        # without making this target a legal `deps` entry. Staging goes by
        # `short_path`, which is the source file's own path.
        result.own.analyzable,
    ] + result.recorded_uses_info

def _binary_compile(ctx, dart_sdk_info, own, own_files, output, compile_mode, optional_outputs, resolved_assets):
    """Compiles a binary, modularly when eligible. Returns the code-asset libs.

    Args:
      ctx: The rule context.
      dart_sdk_info: The `DartSdkInfo` of the toolchain.
      own: The `executable_package` record for this rule's own inputs.
      own_files: The rule's main and source Files.
      output: The declared raw compile output.
      compile_mode: The `dart compile` mode.
      optional_outputs: The declared recorded-uses and debug-info outputs.
      resolved_assets: The resolved code assets.

    Returns:
      The list of code-asset library Files.
    """
    kernel_tools = modular_executable_tools(
        ctx,
        own_files,
        own.record,
        kernel_mode = (compile_mode == "kernel" and ctx.attr.modular_kernel),
        resolved_assets = resolved_assets,
        own_defines = ctx.attr.defines,
        compile_flags = ctx.attr.dart_compile_flags,
        target_sdk = dart_sdk_info,
    )
    if kernel_tools != None:
        modular_executable_kernel(
            ctx,
            kernel_tools,
            entry_sources(own_files),
            own.packages,
            [dep[DartKernelInfo] for dep in ctx.attr.deps],
            output,
            kernel_compile_settings(),
        )
        return []
    _packages, code_asset_libs = _binary_source_compile(
        ctx,
        dart_sdk_info,
        own,
        own.packages,
        output,
        compile_mode,
        optional_outputs,
        resolved_assets,
    )
    return code_asset_libs

def _dart_binary_impl(ctx):
    # A `dart_binary` evaluated in the execution configuration (`cfg = "exec"`)
    # is a build-time tool — a codegen shim, analyzer/format runner, link-hook
    # runner, or kernel compiler — and will be executed by the host's
    # `//dart:exec_tools_toolchain_type` VM. Compile it with that same SDK so a
    # kernel tool's `.dill` format and SDK hash always match the VM that runs it.
    dart_sdk_info = _binary_sdk_info(ctx)

    own_files = [ctx.file.main] + ctx.files.srcs
    own = executable_package(ctx, own_files)

    if ctx.attr.code_assets_from_deps:
        hook_err = check_unreplaced_hooks(ctx.label, own.packages)
        if hook_err != None:
            fail(hook_err)

    # Determine output filename (Windows gets the `.exe` extension — see
    # `binary_output_basename`).
    compile_mode = ctx.attr.compile_mode
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._os_windows[platform_common.ConstraintValueInfo],
    )
    output = ctx.actions.declare_file(
        binary_output_basename(ctx.label.name, compile_mode, is_windows),
    )

    # Assets reach a binary two ways: propagated from any package in `deps`
    # that owns one (the upstream semantics — depending on a package gets you
    # its assets), or named outright. The explicit attr stays valid for
    # hand-written cases; it is simply no longer the only mechanism.
    resolved_assets = resolve_code_assets(
        ctx.label,
        collect_transitive_code_assets(ctx.attr.deps) if ctx.attr.code_assets_from_deps else [],
        [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    )

    # The compiler records the uses of `@RecordUse` definitions only when it
    # tree-shakes, so the other modes get the file it writes when there is
    # nothing to record: a link hook then runs over no uses, as for a program
    # that uses none. `split_debug_info` declares its symbols file in the same
    # place, so the compile action can write both.
    optional_outputs = _binary_optional_outputs(ctx, compile_mode)

    result = struct(
        output = output,
        compile_mode = compile_mode,
        dart_sdk_info = dart_sdk_info,
        code_asset_libs = _binary_compile(
            ctx,
            dart_sdk_info,
            own,
            own_files,
            output,
            compile_mode,
            optional_outputs,
            resolved_assets,
        ),
        recorded_uses_info = optional_outputs.recorded_uses_info,
        debug_info = optional_outputs.debug_info,
        own = own,
        is_windows = is_windows,
    )

    if compile_mode == "kernel" and ctx.attr.launcher:
        return _binary_launcher_outputs(ctx, result)
    if compile_mode in ("aot-snapshot", "jit-snapshot") and ctx.attr.snapshot_launcher:
        return _binary_snapshot_outputs(ctx, result)
    return _binary_default_outputs(ctx, result)

def _binary_code_assets_transition_impl(_settings, attr):
    return {
        "//dart/private:code_assets_enabled": getattr(attr, "code_assets_from_deps", True),
    }

_binary_code_assets_transition = transition(
    implementation = _binary_code_assets_transition_impl,
    inputs = [],
    outputs = ["//dart/private:code_assets_enabled"],
)

dart_binary = rule(
    implementation = _dart_binary_impl,
    cfg = _binary_code_assets_transition,
    attrs = dict({
        "main": attr.label(
            doc = "The Dart entrypoint file containing a top-level `main()` function.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Additional Dart source files that are part of this binary's package but not reachable via `deps`.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "`dart_library` targets this binary depends on.",
            providers = [DartInfo],
            aspects = [dart_kernel_module_aspect],
        ),
        "data": attr.label_list(
            doc = "Additional files needed at runtime. These are added to runfiles so they can be found via the runfiles tree when using `bazel run`.",
            allow_files = True,
        ),
        "code_assets": attr.label_list(
            doc = """Native code assets (e.g. `//dart/ext/sqlite3:code_asset`) the binary's \
`@Native` FFI bindings resolve against. When set, the main is compiled to a kernel with the \
code-asset mapping embedded (`gen_kernel --native-assets`) before the snapshot/exe is produced, \
and the libraries are staged in runfiles so the Dart VM resolves them relative to the executable \
at runtime. Each entry must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule).""",
            providers = [DartCodeAssetInfo],
        ),
        "code_assets_from_deps": attr.bool(
            default = True,
            doc = """Whether to pick up native code assets propagated through `deps`.

Leave this on for a program that runs the packages it depends on. Turn it off for a `dart_binary` \
used purely as a *build tool* — a code generator, a linter — which imports pub packages for their \
Dart API but never loads their native libraries. Without the opt-out such a tool would build (and \
in an exec configuration, cross-build) every native library anywhere in its dependency closure. \
rules_dart's own `dart/ext` builder shims set this to `False`: `drift_dev` depends on \
`package:sqlite3`, but generating code never calls into libsqlite3.

Also suppresses the unreplaced-`hook/build.dart` diagnostic, on the same grounds — a tool that \
never loads native code is unaffected by a package whose native code was not built.""",
        ),
        "compile_mode": attr.string(
            doc = """\
The `dart compile` mode. Determines the output format:

- `exe` (default): Self-contained native machine code. No Dart SDK needed at runtime. Best for deployment.
- `aot-snapshot`: AOT-compiled snapshot. Requires `dartaotruntime` to execute. Smaller than `exe`.
- `kernel`: Dart kernel binary (`.dill`). Requires `dart` to execute. Fastest compilation, useful for development. Compiles modularly by default (`modular_kernel = True` and `//dart:modular_kernel = True`) against dependency `.kmod`/`.koutline` modules when eligible, or whole-program via `gen_kernel` when `modular_kernel = False` or when target `defines`, `dart_compile_flags`, or `code_assets` are set.
- `jit-snapshot`: JIT snapshot with trained profile data. Requires `dart` to execute. Fastest startup after warmup. The program is trained once, with no arguments, at the keyed absolute path for its output (`/tmp/rules_dart_jit-<key>`, where `<key>` is 16 lowercase hex characters of a deterministic digest of the output's root-relative path) used as its working directory and with no `--packages` value, so the snapshot is byte-identical across builds. The snapshot is reproducible only if that training run is deterministic: a program that reads the clock, random numbers, or files outside the build gives a different snapshot each build (see `app_jit_snapshot.dart`). The training runs from a copy of the SDK's `dart`, so the snapshot does not depend on where the SDK is installed or where the build runs. A training waits for the keyed lock up to `--@rules_dart//dart:jit_snapshot_lock_timeout` seconds (default 300), printing the holder's PID while it waits; when the keyed training path is blocked by an entry another user owns, or the lock stays held past the deadline, the action fails and names the entry rather than training elsewhere under the same action key; `--@rules_dart//dart:jit_snapshot_fallback=true` allows the non-reproducible private-scratch fallback instead. A fallback-trained snapshot stays cached under the same action key (in the local action cache and the output tree) until `bazel clean`, so a build after the host is fixed keeps the fallback bytes. With the flag on, both snapshot actions carry `no-cache`, so they are never uploaded to or served from a disk or remote cache.
""",
            default = "exe",
            values = ["exe", "aot-snapshot", "kernel", "jit-snapshot"],
        ),
        "dart_compile_flags": attr.string_list(
            doc = """\
Extra compiler flags, appended after the compilation-mode defaults so they can override them (e.g., `--extra-gen-snapshot-options=--optimization_level=3`).

Each flag goes to the stage that consumes it. A source entrypoint is first compiled to a kernel by `gen_kernel`, the Dart front end, and then by `dart compile`. The front end takes these flags, so they go to `gen_kernel`:

- `--enable-experiment=<name>`, or `--enable-experiment <name>`
- `-D<KEY=VALUE>`, `--define=<KEY=VALUE>`, or `-D <KEY=VALUE>`, `--define <KEY=VALUE>`
- `--enable-asserts`

Every other flag goes to `dart compile`. In the `kernel` mode, setting `dart_compile_flags` opts out of modular kernel compilation and passes all flags to `gen_kernel`. For a pre-built kernel, all flags go to `dart compile`. The `jit-snapshot` mode takes no `dart compile` flags, so any other flag there is an error. A comma-containing `-D`/`--define` value takes the same comma-safe path as `defines`: the compile runs the toolchain's patched `gen_kernel` snapshot.""",
        ),
        "_jit_tool": attr.label(
            doc = "Every source the JIT tool imports, staged beside its entry in the actions that run it from source.",
            default = "//dart/private/tools:jit_tool_srcs",
            allow_files = True,
        ),
        "_comma_patch": attr.label(
            doc = "The `comma_patch.dart` source staged beside the JIT tool's entry so comma-containing `-D` values survive the front end. Defaults to `//dart/private/tools:comma_patch.dart`.",
            default = "//dart/private/tools:comma_patch.dart",
            allow_single_file = True,
        ),
        "_jit_snapshot_fallback": attr.label(
            doc = "Whether `--fallback-allowed` is passed when the keyed training path is unavailable.",
            default = "//dart:jit_snapshot_fallback",
            providers = [BuildSettingInfo],
        ),
        "_jit_lock_timeout": attr.label(
            doc = "Seconds a `jit-snapshot` training waits for the keyed training lock. Passed as `--lock-timeout=` only when it differs from the default.",
            default = "//dart:jit_snapshot_lock_timeout",
            providers = [BuildSettingInfo],
        ),
        "launcher": attr.bool(
            default = False,
            doc = """Whether `compile_mode = "kernel"` also emits a native launcher executable as \
`DefaultInfo.executable` so the target can be invoked directly with `bazel run` or `ctx.executable`, \
while `DartCompileInfo.executable` continues to carry the compiled `.dill` kernel for \
persistent-worker rules (`dart_codegen`, `dart_aggregate_codegen`, `dart_sqlcodegen`).""",
        ),
        "_kernel_launcher": attr.label(
            default = _kernel_launcher_for_mode,
            executable = True,
            cfg = "target",
            doc = "The native launcher binary symlinked as `DefaultInfo.executable` when `compile_mode = \"kernel\"` and `launcher = True`.",
        ),
        "snapshot_launcher": attr.bool(
            default = True,
            doc = """Whether `aot-snapshot` and `jit-snapshot` also emit a run \
launcher as `DefaultInfo.executable`.

On by default. Turn it off only for a build-time tool that executes its raw snapshot \
directly through `dartaotruntime` or `dart` (for example rules_dart's own `kernel_module` \
worker), where the raw file must stay the executable.""",
        ),
        "split_debug_info": attr.bool(
            default = False,
            doc = """Whether to compile with `--save-debugging-info` and \
`--dwarf-stack-traces` and declare a separate DWARF symbols file.

Only `compile_mode = "exe"` and `compile_mode = "aot-snapshot"` support it; setting it on \
`kernel` or `jit-snapshot` fails analysis naming `compile_mode`. The symbols file is \
`<name>.debug` and is exposed through the `debug_info` output group (and `DefaultInfo.files`). \
Off by default, so no extra file is produced.""",
        ),
        "_snapshot_launcher_sh": attr.label(
            default = "//dart/private/tools:snapshot_launcher.sh.tpl",
            allow_single_file = True,
            doc = "The POSIX shell launcher template for `aot-snapshot` and `jit-snapshot` targets.",
        ),
        "_snapshot_launcher_bat": attr.label(
            default = "//dart/private/tools:snapshot_launcher.bat.tpl",
            allow_single_file = True,
            doc = "The Windows batch launcher template for `aot-snapshot` and `jit-snapshot` targets.",
        ),
        "defines": attr.string_list(
            doc = "Dart environment declarations (`key=value`). Each entry becomes a `-Dkey=value` flag.",
        ),
        "record_use": attr.bool(
            doc = """Record the uses of `@RecordUse` definitions (`package:meta`) as \
`<name>.recorded_uses.json`, provided as `DartRecordedUsesInfo` for `dart_link_hook`. \
In the `exe` and `aot-snapshot` modes the compiler records them as it tree-shakes. The \
`kernel` and `jit-snapshot` modes do not tree-shake, so nothing is recorded and the file is \
the empty JSON object `{}` (`kind = "empty"`).""",
        ),
        "_allowlist_function_transition": attr.label(
            doc = "Allowlist target permitting the Starlark function transition this rule applies. Defaults to `@bazel_tools//tools/allowlists/function_transition_allowlist`.",
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    }, **dict(DART_ABI_CONSTRAINT_ATTRS, **dict(EXTRA_DART_DEFINES_ATTR, **dict(EXECUTABLE_PACKAGE_ATTRS, **BINARY_MODULAR_KERNEL_ATTRS)))),
    executable = True,
    toolchains = ["//dart:toolchain_type"] + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Dart application using `dart compile`.",
)
