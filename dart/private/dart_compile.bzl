"""Shared compilation action helpers for Dart."""

load(
    "//dart/private:common.bzl",
    "STABLE_SCHEME",
    "find_sdk_kernel_tools",
    "gen_kernel_args",
    "has_comma_define",
    "sdk_dartvm",
    "stable_entry_path",
    "writable_home_env",
)

# The `dart compile` modes that tree-shake, and so can record the uses of
# `@RecordUse` definitions: what survives tree-shaking is the set of uses.
RECORDING_COMPILE_MODES = ("exe", "aot-snapshot")

def recorded_uses_kind(compile_mode):
    """The `DartRecordedUsesInfo.kind` a `dart_binary` in `compile_mode` provides.

    Args:
        compile_mode: The `dart compile` mode.

    Returns:
        `aot` when the compiler records the uses, `empty` when it cannot.
    """
    return "aot" if compile_mode in RECORDING_COMPILE_MODES else "empty"

def defines_stage_error(defines, package_config):
    """Returns an error string if `defines` would reach the compiler too late.

    `-D` values are consumed by the front end during constant evaluation —
    `String.fromEnvironment` and friends resolve there, not at run time. When
    `main` is a pre-built kernel (signalled by a `None` `package_config`) the
    front end has already run, and `dart compile` accepts `-D` and silently
    ignores it: no error, no warning, just the default value baked into the
    output. Environment declarations for a kernel input have to go to whatever
    action produced that kernel.

    Args:
        defines: Environment declarations destined for this action.
        package_config: The `package_config.json` File, or None when `main` is
            a pre-built `.dill`.

    Returns:
        An error string, or None when the combination is sound.
    """
    if defines and package_config == None:
        return ("dart_compile_action: `defines` %s cannot be applied to a " +
                "pre-built kernel — constant evaluation already happened in " +
                "the action that produced it. Pass them to that action " +
                "instead (e.g. `gen_kernel_native_assets_action`).") % defines
    return None

def compile_quiet_flags(compile_mode):
    """Returns the flags that keep `dart compile` from writing to stdout.

    `exe` and `aot-snapshot` print `Generated: <output path>` on success, and
    Bazel echoes any action output, so every build would show a sandbox path.
    Errors still print. The other modes have no flag that silences them.

    Args:
        compile_mode: The Dart compile mode ("exe", "aot-snapshot", "kernel", "jit-snapshot").

    Returns:
        A list of flag strings.
    """
    if compile_mode in ("exe", "aot-snapshot"):
        return ["--verbosity=error"]
    return []

def get_compilation_mode_flags(ctx, compile_mode):
    """Returns compiler flags for the current Bazel compilation mode.

    Args:
        ctx: The rule context (used to read ctx.var["COMPILATION_MODE"]).
        compile_mode: The Dart compile mode ("exe", "aot-snapshot", "kernel", "jit-snapshot").

    Returns:
        A list of flag strings.
    """
    bazel_mode = ctx.var["COMPILATION_MODE"]

    if bazel_mode == "dbg":
        # `dart compile kernel` rejects `--enable-asserts`: a kernel file
        # retains asserts and the invoking VM decides whether to enable them
        # (dart_test's runner always passes `--enable-asserts` at runtime).
        if compile_mode == "kernel":
            return []
        return ["--enable-asserts"]
    elif bazel_mode == "opt":
        if compile_mode in ("exe", "aot-snapshot"):
            return ["--extra-gen-snapshot-options=--optimization_level=2"]
        else:
            return []
    else:
        # fastbuild: no extra flags
        return []

# `dart_compile_flags` that the Dart front end consumes. A source compile runs
# the front end in `gen_kernel`, so these go there; the rest go to `dart compile`.
FRONT_END_VALUE_FLAGS = ["--enable-experiment", "-D", "--define"]
FRONT_END_SWITCHES = ["--enable-asserts", "--no-embed-sources", "--embed-sources"]

def split_compile_flags(flags):
    """Splits `dart_compile_flags` between the front end and `dart compile`.

    A front-end flag is `--enable-experiment=<name>`, a define (`-D<KEY=VALUE>`,
    `--define=<KEY=VALUE>`, or `-D` or `--define` with the define as the next
    flag), or `--enable-asserts`. Every other flag is a back-end flag. The
    front-end flags come back in the one-flag form that `gen_kernel` reads.

    Args:
        flags: The list of flag strings from `dart_compile_flags`.

    Returns:
        A struct with `front_end` and `backend` lists, and `error`: a message
        for a value flag with no value, or None.
    """
    front_end = []
    backend = []
    skip_next = False
    for i, flag in enumerate(flags):
        if skip_next:
            skip_next = False
            continue
        if flag in FRONT_END_VALUE_FLAGS:
            if i + 1 >= len(flags):
                return struct(
                    front_end = front_end,
                    backend = backend,
                    error = "`%s` in dart_compile_flags has no value" % flag,
                )
            value = flags[i + 1]
            skip_next = True
            if flag == "--enable-experiment":
                front_end.append("--enable-experiment=" + value)
            else:
                front_end.append("-D" + value)
        elif flag in FRONT_END_SWITCHES or flag.startswith("--enable-experiment=") or (flag.startswith("-D") and len(flag) > 2):
            front_end.append(flag)
        elif flag.startswith("--define="):
            front_end.append("-D" + flag[len("--define="):])
        else:
            backend.append(flag)
    return struct(front_end = front_end, backend = backend, error = None)

def _jit_snapshot_action(ctx, dart_sdk_info, jit_tool, main, output, enable_asserts, comma_patch = None):
    """Trains the app-JIT snapshot of a kernel in a fixed-length scratch directory.

    `dart compile jit-snapshot` trains in the action's own directory, so the
    absolute path of the sandbox ends up in the snapshot. `jit_tool` trains in a
    scratch directory with a fixed-length path, with the flags that keep the
    snapshot the same from build to build. See `app_jit_snapshot.dart`. A
    program whose own training run is not deterministic (it reads the clock,
    random numbers, or files outside the build) still differs between builds.

    Args:
        ctx: The rule context.
        dart_sdk_info: The `DartSdkInfo` of the toolchain.
        jit_tool: The `app_jit_snapshot.dart` File.
        comma_patch: The `comma_patch.dart` File the tool imports. It lands
            beside the tool in the sandbox, so the tool's relative import
            resolves. Required whenever `jit_tool` runs.
        main: The kernel File to train on, with no program arguments.
        output: The `.jit` File to produce.
        enable_asserts: Whether the training run enables asserts.
    """
    dart_bin = dart_sdk_info.dart
    dartvm = sdk_dartvm(dart_sdk_info)
    pkg_cfg = ctx.actions.declare_file(output.basename + ".jit_package_config.json")
    ctx.actions.write(
        output = pkg_cfg,
        content = '{"configVersion": 2, "packages": []}\n',
    )
    args = ctx.actions.args()
    args.add(pkg_cfg, format = "--packages=%s")
    args.add(jit_tool)
    args.add(dart_bin, format = "--dart=%s")
    if dartvm != None:
        args.add(dartvm, format = "--dartvm=%s")
    args.add(output, format = "--snapshot=%s")
    if enable_asserts:
        args.add("--enable-asserts")
    args.add("--env=TMPDIR=.")
    args.add("--env=HOME=.")
    args.add(main, format = "--copy=input.dill=%s")
    args.add("--")
    args.add("input.dill")
    ctx.actions.run(
        executable = dart_bin,
        arguments = [args],
        inputs = depset(
            direct = [jit_tool, pkg_cfg, dart_bin, main] + ([dartvm] if dartvm != None else []) + ([comma_patch] if comma_patch != None else []),
            transitive = [dart_sdk_info.compile_files],
        ),
        outputs = [output],
        mnemonic = "DartJitSnapshot",
        progress_message = "Compiling Dart jit-snapshot %s" % ctx.label,
        env = writable_home_env(dart_bin, output),
    )

def _kernel_action(
        ctx,
        dart_sdk_info,
        main,
        srcs,
        package_config,
        output,
        main_path,
        aot,
        target_os,
        enable_asserts,
        defines,
        recorded_uses,
        extra_flags,
        jit_tool = None,
        comma_patch = None,
        native_assets_yaml = None,
        embed_sources = True,
        product = None):
    """Runs `gen_kernel` over a source entrypoint, with stable URIs.

    `dart compile` reads its package config and entrypoint as file paths and
    records them as absolute `file:` URIs. `gen_kernel` takes the scheme
    described in `gen_kernel_args`, so the kernel names every library by its
    repository path. Mode flags that belong to the front end go here: `--aot
    --tfa` for the modes that tree-shake, `dart.vm.product` and sanitizer
    defines matching `dart compile`, and `--enable-asserts`, which is
    constant-folded or dropped while the front end runs.

    Args:
        ctx: The rule context.
        dart_sdk_info: The `DartSdkInfo` of the toolchain.
        main: The entrypoint File (or the assembled directory holding it).
        srcs: The source Files the entrypoint's closure reads.
        package_config: The `package_config.json` File.
        output: The kernel File to write.
        main_path: The entrypoint's exec path, or None to use `main.path`.
        aot: Whether to produce an AOT kernel (`--aot --tfa`).
        target_os: The target OS for an AOT kernel, or "".
        enable_asserts: Whether to pass `--enable-asserts`.
        defines: Environment declarations; each becomes a `-D` flag. When one
            contains a comma, the `gen_kernel` step runs the toolchain's
            patched snapshot (see below); otherwise the pristine snapshot runs.
        recorded_uses: Optional File for the recorded `@RecordUse` uses.
        extra_flags: Flags for `gen_kernel` itself, appended last.
        jit_tool: Optional `app_jit_snapshot.dart` File, used to run the
            `gen_kernel` step above with an isolated filesystem root. Required
            when `defines` contains a comma: only the wrapper consumes the
            `--comma-patched-snapshot` marker that authorizes the patched
            snapshot.
        comma_patch: Optional `comma_patch.dart` File the wrapper imports. It
            lands beside the wrapper in the sandbox, so the wrapper's relative
            import resolves. Required whenever `jit_tool` is passed.
        native_assets_yaml: Optional `native_assets.yaml` File, embedded as the
            `vm:ffi:native-assets` mapping.
        embed_sources: Whether non-AOT kernels embed source text. The generated
            `package:test` runner entrypoint passes `False`.
        product: Whether the kernel is for a product runtime: an AOT snapshot or
            executable, or a `dart compile kernel` file. False for the JIT VM
            that builds a `jit-snapshot`. Defaults to `True`.
    """
    if product == None:
        product = True
    tools = find_sdk_kernel_tools(dart_sdk_info)
    platform = tools.product_platform_dill if product else tools.platform_dill

    # A comma-containing value only survives the frontend when `gen_kernel`
    # runs the toolchain's patched snapshot: the frontend splits `-D` values
    # on commas. The patched snapshot is a declared action output taken as a
    # tool input, so the patch runs once per SDK, not once per compile. The
    # wrapper consumes the marker below and refuses comma defines without it,
    # so a comma compile can never silently run the pristine snapshot.
    comma_defines = has_comma_define(defines)
    gen_snapshot = None
    if comma_defines:
        gen_snapshot = tools.patched_gen_kernel
        if gen_snapshot == None:
            fail(("dart_compile_action: target %s passes comma-containing " +
                  "`defines` %s, but the SDK (Dart %s) declares no patched " +
                  "`gen_kernel` snapshot, so no compile can keep the commas. " +
                  "Use an SDK whose snapshot `comma_patch.dart` knows how " +
                  "to patch.") % (ctx.label, defines, dart_sdk_info.version))
        if jit_tool == None:
            fail(("dart_compile_action: target %s passes comma-containing " +
                  "`defines` %s, but no `jit_tool` wrapper runs its " +
                  "`gen_kernel` step to authorize the patched snapshot.") %
                 (ctx.label, defines))
    args = gen_kernel_args(ctx, tools, platform, package_config, gen_kernel_snapshot = gen_snapshot)
    args.add("-Ddart.vm.product=" + ("true" if product else "false"))
    args.add_all(["-Ddart.vm.asan=false", "-Ddart.vm.msan=false", "-Ddart.vm.tsan=false"])
    if aot:
        args.add("--aot")
        args.add("--tfa")
        args.add("--no-embed-sources")
        if target_os:
            args.add("--target-os", target_os)
    elif not embed_sources:
        args.add("--no-embed-sources")
    if native_assets_yaml != None:
        args.add("--native-assets", native_assets_yaml)
    if enable_asserts:
        args.add("--enable-asserts")
    for d in defines:
        args.add("-D" + d)

    outputs = [output]
    if recorded_uses != None:
        args.add(recorded_uses, format = "--recorded-usages-file=%s")
        outputs.append(recorded_uses)

    args.add_all(extra_flags)
    args.add("-o", output)
    args.add(STABLE_SCHEME + ":///" + stable_entry_path(ctx, main_path if main_path != None else main.path))

    direct = [main, package_config] + srcs
    if native_assets_yaml != None:
        direct.append(native_assets_yaml)

    if jit_tool != None:
        dartvm = sdk_dartvm(dart_sdk_info)
        wrapper_args = ctx.actions.args()
        wrapper_args.add(package_config, format = "--packages=%s")
        wrapper_args.add(jit_tool)
        wrapper_args.add("--gen-kernel")
        wrapper_args.add(tools.dartaotruntime)
        if comma_defines:
            # After `dartaotruntime`: `_runGenKernel` takes `argv.first` as the
            # runtime positionally and consumes this marker in its flag loop,
            # never forwarding it to `gen_kernel`.
            wrapper_args.add("--comma-patched-snapshot")
        input_srcs_args = ctx.actions.args()
        input_srcs_args.use_param_file("--input-sources-file=%s", use_always = True)
        input_srcs_args.set_param_file_format("multiline")
        input_srcs_args.add_all(depset([main] + srcs))
        direct.append(jit_tool)
        if comma_patch != None:
            direct.append(comma_patch)
        if gen_snapshot != None:
            # The patched snapshot lives in `bazel-out`, outside the SDK file
            # sets, so it is declared explicitly. Builds without comma defines
            # never take it and never run the action that produces it.
            direct.append(gen_snapshot)
        if dartvm != None:
            direct.append(dartvm)
        else:
            direct.append(dart_sdk_info.dart)
        ctx.actions.run(
            executable = dartvm if dartvm != None else dart_sdk_info.dart,
            arguments = [wrapper_args, input_srcs_args, args],
            inputs = depset(
                direct = direct,
                transitive = [dart_sdk_info.compile_files],
            ),
            outputs = outputs,
            mnemonic = "DartKernel",
            progress_message = "Compiling Dart kernel %s" % ctx.label,
            env = writable_home_env(dart_sdk_info.dart, output),
        )
        return

    ctx.actions.run(
        executable = tools.dartaotruntime,
        arguments = [args],
        inputs = depset(
            direct = direct,
            transitive = [dart_sdk_info.compile_files],
        ),
        outputs = outputs,
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel %s" % ctx.label,
        env = writable_home_env(dart_sdk_info.dart, output),
    )

_SUPPORTED_CROSS_TARGET_PAIRS = {
    ("linux", "x64"): True,
    ("linux", "arm64"): True,
    ("linux", "riscv64"): True,
    ("linux", "arm"): True,
}

def cross_target_error(target_os, target_arch):
    """Returns an error string if `(target_os, target_arch)` is an invalid cross-compile target.

    Args:
        target_os: Target OS string (or `""` for native).
        target_arch: Target architecture string (or `""` for native).

    Returns:
        An error message string, or `None` when native or a supported cross target.
    """
    if bool(target_os) != bool(target_arch):
        return "dart_compile_action: target_os and target_arch must both be set or both be empty (got target_os=%r, target_arch=%r)" % (
            target_os,
            target_arch,
        )
    if target_os and (target_os, target_arch) not in _SUPPORTED_CROSS_TARGET_PAIRS:
        return "dart_compile_action: unsupported cross-compilation target (%s, %s); supported targets are linux/{x64,arm64,riscv64,arm}" % (
            target_os,
            target_arch,
        )
    return None

def dart_compile_action(
        ctx,
        dart_sdk_info,
        main,
        srcs,
        package_config,
        output,
        compile_mode = "exe",
        target_os = "",
        target_arch = "",
        extra_flags = [],
        defines = [],
        main_path = None,
        recorded_uses = None,
        jit_tool = None,
        comma_patch = None,
        native_assets_yaml = None,
        embed_sources = True):
    """Creates the actions that compile a Dart entrypoint in `compile_mode`.

    A source entrypoint (one with a `package_config`) is first compiled to a
    kernel by `gen_kernel`, which names every library by a stable URI (see
    `gen_kernel_args`). The `dart compile` step then works from that kernel, so
    no output embeds the sandbox it was built in. The `kernel` mode is the
    `gen_kernel` step alone. A pre-built kernel `main` is compiled directly.

    Args:
        ctx: The rule context.
        dart_sdk_info: The `DartSdkInfo` of the toolchain.
        main: The main File to add to action inputs. Usually the entrypoint
            `.dart` File; an assembled directory when `main_path` points inside it.
        srcs: List of all source Files needed for compilation (direct + transitive).
        package_config: The package_config.json File, or None when `main` is a
            pre-built kernel.
        output: The output File to produce.
        compile_mode: The compilation mode ("exe", "aot-snapshot", "kernel", "jit-snapshot").
        target_os: Cross-compilation target OS (e.g. "linux"). Empty for native.
        target_arch: Cross-compilation target architecture (e.g. "x64"). Empty for native.
        extra_flags: Additional compiler flags (from dart_compile_flags attribute).
            `kernel` passes them all to `gen_kernel`, the stage that produces that
            mode. For a source entrypoint in the other modes, the front-end flags
            (see `split_compile_flags`) go to `gen_kernel` and the rest to
            `dart compile`. A pre-built kernel passes them all to `dart compile`.
        defines: Environment declarations; each entry becomes a -D flag, given to
            the `gen_kernel` step. A comma-containing entry runs the
            toolchain's patched `gen_kernel` snapshot.
        main_path: Optional path string to pass as the compile target instead of
            `main.path` (e.g. a path inside an assembled `main` directory).
        recorded_uses: Optional output File for the uses of `@RecordUse`
            definitions the compiler records (`--recorded-uses`). Only the
            `exe` and `aot-snapshot` modes record.
        jit_tool: The `app_jit_snapshot.dart` File. The `jit-snapshot` mode trains
            with it when given, so the snapshot is reproducible. Without it, and on
            a Windows host (which has no fixed-length scratch directory), the mode
            uses `dart compile jit-snapshot`.
        comma_patch: The `comma_patch.dart` File the tool imports, staged beside
            it in every action that runs it from source. Required whenever
            `jit_tool` is passed.
        native_assets_yaml: Optional `native_assets.yaml` File.
        embed_sources: Whether non-AOT kernels embed source text.
    """
    cross_err = cross_target_error(target_os, target_arch)
    if cross_err != None:
        fail(cross_err)
    stage_err = defines_stage_error(defines, package_config)
    if stage_err != None:
        fail(stage_err)
    if recorded_uses != None and compile_mode not in RECORDING_COMPILE_MODES:
        fail("dart_compile_action: `dart compile %s` records no uses." % compile_mode)
    if jit_tool != None and comma_patch == None:
        fail("dart_compile_action: target %s passes `jit_tool` without the " +
             "`comma_patch.dart` File it imports, so no action could run it " +
             "from source. Pass `comma_patch` alongside `jit_tool`." % ctx.label)

    dart_bin = dart_sdk_info.dart
    sdk_files = dart_sdk_info.compile_files

    # The front end consumes its flags, so they go to `gen_kernel` for a source
    # entrypoint. `kernel` is the `gen_kernel` stage itself and gets them all; a
    # pre-built kernel has no front end to receive them.
    front_end_flags = []
    backend_flags = extra_flags
    if package_config != None:
        split = split_compile_flags(extra_flags)
        if split.error != None:
            fail(split.error)
        front_end_flags = split.front_end
        backend_flags = split.backend

    mode_flags = get_compilation_mode_flags(ctx, compile_mode)
    enable_asserts = (
        "--enable-asserts" in mode_flags or
        "--enable-asserts" in front_end_flags or
        "--enable-asserts" in backend_flags
    )

    compile_main = main
    compile_main_path = main_path
    compile_srcs = srcs
    compile_recorded_uses = recorded_uses
    if package_config != None:
        if compile_mode == "kernel":
            _kernel_action(
                ctx = ctx,
                dart_sdk_info = dart_sdk_info,
                main = main,
                srcs = srcs,
                package_config = package_config,
                output = output,
                main_path = main_path,
                aot = False,
                target_os = "",
                enable_asserts = False,
                defines = defines,
                recorded_uses = None,
                extra_flags = front_end_flags + backend_flags,
                jit_tool = jit_tool,
                comma_patch = comma_patch,
                native_assets_yaml = native_assets_yaml,
                embed_sources = embed_sources,
                product = True,
            )
            return

        # The front end runs once, here, with the stable URIs. Its kernel is the
        # input of the `dart compile` step below.
        aot = compile_mode in RECORDING_COMPILE_MODES
        kernel = ctx.actions.declare_file(output.basename + ".dill")
        _kernel_action(
            ctx = ctx,
            dart_sdk_info = dart_sdk_info,
            main = main,
            srcs = srcs,
            package_config = package_config,
            output = kernel,
            main_path = main_path,
            aot = aot,
            target_os = target_os,
            enable_asserts = "--enable-asserts" in mode_flags and "--enable-asserts" not in front_end_flags,
            defines = defines,
            recorded_uses = None,
            extra_flags = front_end_flags,
            jit_tool = jit_tool,
            comma_patch = comma_patch,
            native_assets_yaml = native_assets_yaml,
            embed_sources = embed_sources,
            product = compile_mode != "jit-snapshot",
        )
        compile_main = kernel
        compile_main_path = None
        compile_srcs = []

    # The app-JIT snapshot is trained by the fixed-scratch tool when it has one,
    # and on a POSIX host, which has the fixed-length `/tmp` the tool needs.
    if compile_mode == "jit-snapshot" and jit_tool != None and compile_main_path == None and not dart_bin.basename.endswith(".exe"):
        if backend_flags:
            fail("dart_compile_flags %s do not apply to jit-snapshot" % backend_flags)
        _jit_snapshot_action(
            ctx = ctx,
            dart_sdk_info = dart_sdk_info,
            jit_tool = jit_tool,
            comma_patch = comma_patch,
            main = compile_main,
            output = output,
            enable_asserts = enable_asserts,
        )
        return

    is_cross = bool(target_os) or bool(target_arch)
    cross_gen_snapshot = getattr(dart_sdk_info, "cross_gen_snapshot", None) if is_cross else None
    cross_dartaotruntime = getattr(dart_sdk_info, "cross_dartaotruntime", None) if is_cross else None

    if compile_mode in ("exe", "aot-snapshot", "jit-snapshot") and jit_tool != None and compile_main_path == None:
        pkg_cfg = package_config
        if pkg_cfg == None:
            pkg_cfg = ctx.actions.declare_file(output.basename + ".aot_package_config.json")
            ctx.actions.write(output = pkg_cfg, content = "{\"configVersion\": 2, \"packages\": []}\n")
        args = ctx.actions.args()
        args.add(pkg_cfg, format = "--packages=%s")
        args.add(jit_tool)
        args.add("--aot")
        args.add(dart_bin, format = "--dart=%s")
        args.add(compile_mode, format = "--mode=%s")
        if target_os:
            args.add("--target-os", target_os)
        if target_arch:
            args.add("--target-arch", target_arch)
        if cross_gen_snapshot != None:
            args.add(cross_gen_snapshot, format = "--gen-snapshot=%s")
        if cross_dartaotruntime != None:
            args.add(cross_dartaotruntime, format = "--dartaotruntime=%s")
        args.add_all(compile_quiet_flags(compile_mode))
        args.add_all(mode_flags)
        if enable_asserts and "--enable-asserts" not in mode_flags and "--enable-asserts" not in backend_flags:
            args.add("--enable-asserts")
        outputs = [output]
        if compile_recorded_uses != None:
            args.add(compile_recorded_uses, format = "--recorded-uses=%s")
            outputs.append(compile_recorded_uses)
        args.add_all(backend_flags)
        args.add("-o", output)
        args.add(compile_main)
        direct_inputs = [jit_tool, pkg_cfg, compile_main] + compile_srcs
        if comma_patch != None:
            direct_inputs.append(comma_patch)
        if cross_gen_snapshot != None:
            direct_inputs.append(cross_gen_snapshot)
        if cross_dartaotruntime != None:
            direct_inputs.append(cross_dartaotruntime)
        ctx.actions.run(
            executable = dart_bin,
            arguments = [args],
            inputs = depset(
                direct = direct_inputs,
                transitive = [sdk_files],
            ),
            outputs = outputs,
            mnemonic = "DartCompile",
            progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
            env = writable_home_env(dart_bin, output),
        )
        return

    args = ctx.actions.args()
    args.add("compile")
    args.add(compile_mode)
    args.add_all(compile_quiet_flags(compile_mode))

    # Cross-compilation flags (only valid for exe and aot-snapshot modes)
    if target_os and (compile_mode == "exe" or compile_mode == "aot-snapshot"):
        args.add("--target-os", target_os)
    if target_arch and (compile_mode == "exe" or compile_mode == "aot-snapshot"):
        args.add("--target-arch", target_arch)

    # Compilation mode defaults
    args.add_all(mode_flags)
    if enable_asserts and "--enable-asserts" not in mode_flags and "--enable-asserts" not in backend_flags:
        args.add("--enable-asserts")

    outputs = [output]
    if compile_recorded_uses != None:
        args.add(compile_recorded_uses, format = "--recorded-uses=%s")
        outputs.append(compile_recorded_uses)

    # Per-target extra flags (last, so they can override defaults)
    args.add_all(backend_flags)

    args.add("-o", output)
    args.add(compile_main_path if compile_main_path != None else compile_main)

    env = writable_home_env(dart_bin, output)

    direct_inputs = [compile_main] + compile_srcs
    if cross_gen_snapshot != None and compile_mode in ("exe", "aot-snapshot"):
        direct_inputs.append(cross_gen_snapshot)
    if cross_dartaotruntime != None and compile_mode in ("exe", "aot-snapshot"):
        direct_inputs.append(cross_dartaotruntime)

    ctx.actions.run(
        executable = dart_bin,
        arguments = [args],
        inputs = depset(
            direct = direct_inputs,
            transitive = [sdk_files],
        ),
        outputs = outputs,
        mnemonic = "DartCompile",
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
        env = env,
    )
