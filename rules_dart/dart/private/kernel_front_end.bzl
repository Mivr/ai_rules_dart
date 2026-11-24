"""The `gen_kernel` front-end step of a whole-program Dart compile."""

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
load("//dart/private/tools:compile_wrapper.bzl", "wrapper_launch")

visibility(["//dart/..."])

def has_comma_define_flag(flags):
    """Whether any `-D`/`--define` flag in `flags` carries a comma in its value.

    `gen_kernel` splits `-D`/`--define` values on commas, so a comma-containing
    value only survives when the compile runs the toolchain's patched snapshot
    (see `comma_patch.dart`). `split_compile_flags` normalizes every define to
    the one-flag `-D<value>` form, so only that form (and the `--define=<value>`
    form a caller may pass through) is inspected: a comma in any other flag
    never reaches the front end's define splitting.

    Args:
        flags: Flag strings bound for `gen_kernel` (the `extra_flags` of a
            whole-program action).

    Returns:
        True when a `-D<value>` or `--define=<value>` entry contains a comma.
    """
    for flag in flags:
        if flag.startswith("-D") and len(flag) > 2 and "," in flag[2:]:
            return True
        if flag.startswith("--define=") and "," in flag[len("--define="):]:
            return True
    return False

def _kernel_comma_snapshot(ctx, dart_sdk_info, tools, defines, extra_flags, jit_tool):
    """Selects the patched `gen_kernel` snapshot for comma defines. Returns (gen_snapshot, comma_sources)."""

    # A comma-containing value only survives the frontend when `gen_kernel`
    # runs the toolchain's patched snapshot: the frontend splits `-D` values
    # on commas. The patched snapshot is a declared action output taken as a
    # tool input, so the patch runs once per SDK, not once per compile. The
    # wrapper consumes the marker below and refuses comma defines without it,
    # so a comma compile can never silently run the pristine snapshot. A
    # comma `-D` in `dart_compile_flags` takes the same path: those flags all
    # reach `gen_kernel` (see `dart_compile_action`), so they need the patch
    # exactly like `defines` do.
    comma_defines = has_comma_define(defines)
    comma_flags = has_comma_define_flag(extra_flags)
    comma_sources = []
    if comma_defines:
        comma_sources.append("`defines` %s" % (defines,))
    if comma_flags:
        comma_sources.append("`dart_compile_flags` %s" % (extra_flags,))
    gen_snapshot = None
    if comma_sources:
        comma_source = " and ".join(comma_sources)
        gen_snapshot = tools.patched_gen_kernel
        if gen_snapshot == None:
            fail(("dart_compile_action: target %s passes comma-containing " +
                  "%s, but the SDK (Dart %s) declares no patched " +
                  "`gen_kernel` snapshot, so no compile can keep the commas. " +
                  "Use an SDK whose snapshot `comma_patch.dart` knows how " +
                  "to patch.") % (ctx.label, comma_source, dart_sdk_info.version))
        if not jit_tool:
            fail(("dart_compile_action: target %s passes comma-containing " +
                  "%s, but no `jit_tool` wrapper runs its " +
                  "`gen_kernel` step to authorize the patched snapshot.") %
                 (ctx.label, comma_source))
    return gen_snapshot, comma_sources

def _kernel_front_args(ctx, dart_sdk_info, st, aot, enable_asserts, extra_flags, product, output):
    """Builds the `gen_kernel` args and outputs.

    Returns (args, outputs, tools, gen_snapshot, comma_sources): the args and
    outputs for the `gen_kernel` run, the SDK kernel tools, the patched
    `gen_kernel` snapshot (or None), and the comma-define sources authorizing
    it (or None).
    """
    tools = find_sdk_kernel_tools(dart_sdk_info)
    platform = tools.product_platform_dill if product else tools.platform_dill
    gen_snapshot, comma_sources = _kernel_comma_snapshot(
        ctx,
        dart_sdk_info,
        tools,
        st.defines,
        extra_flags,
        st.jit_tool,
    )
    args = gen_kernel_args(ctx, tools, platform, st.package_config, gen_kernel_snapshot = gen_snapshot)
    args.add("-Ddart.vm.product=" + ("true" if product else "false"))
    args.add_all(["-Ddart.vm.asan=false", "-Ddart.vm.msan=false", "-Ddart.vm.tsan=false"])
    if aot:
        args.add("--aot")
        args.add("--tfa")
        args.add("--no-embed-sources")
        if st.target_os:
            args.add("--target-os", st.target_os)
    elif not st.embed_sources:
        args.add("--no-embed-sources")
    if st.native_assets_yaml != None:
        args.add("--native-assets", st.native_assets_yaml)
    if enable_asserts:
        args.add("--enable-asserts")
    for d in st.defines:
        args.add("-D" + d)

    outputs = [output]

    args.add_all(extra_flags)
    args.add("-o", output)
    args.add(STABLE_SCHEME + ":///" + stable_entry_path(ctx, st.main_path if st.main_path != None else st.main.path))
    return args, outputs, tools, gen_snapshot, comma_sources

def _kernel_run_wrapper(ctx, dart_sdk_info, st, tools, args, outputs, gen_snapshot, comma_sources):
    """Runs `gen_kernel` through the isolated-filesystem wrapper."""
    dartvm = sdk_dartvm(dart_sdk_info)
    launch = wrapper_launch(
        ctx,
        st,
        dartvm if dartvm != None else dart_sdk_info.dart,
        tools.dartaotruntime,
    )
    wrapper_args = launch.args
    wrapper_args.add("--gen-kernel")
    wrapper_args.add(tools.dartaotruntime)
    if comma_sources:
        # After `dartaotruntime`: `_runGenKernel` takes `argv.first` as the
        # runtime positionally and consumes this marker in its flag loop,
        # never forwarding it to `gen_kernel`.
        wrapper_args.add("--comma-patched-snapshot")
    input_srcs_args = ctx.actions.args()
    input_srcs_args.use_param_file("--input-sources-file=%s", use_always = True)
    input_srcs_args.set_param_file_format("multiline")
    input_srcs_args.add_all(depset([st.main] + st.srcs))
    direct = [st.main, st.package_config] + st.srcs
    if st.native_assets_yaml != None:
        direct.append(st.native_assets_yaml)
    direct.extend(launch.inputs)
    if gen_snapshot != None:
        # The patched snapshot lives in `bazel-out`, outside the SDK file
        # sets, so it is declared explicitly. Builds without comma defines
        # never take it and never run the action that produces it.
        direct.append(gen_snapshot)
    ctx.actions.run(
        executable = launch.executable,
        arguments = [wrapper_args, input_srcs_args, args],
        inputs = depset(
            direct = direct,
            transitive = [dart_sdk_info.compile_files],
        ),
        outputs = outputs,
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel %s" % ctx.label,
        env = writable_home_env(dart_sdk_info.dart, outputs[0]),
        toolchain = st.toolchain_type,
    )

def _kernel_run_direct(ctx, dart_sdk_info, tools, args, direct, outputs, toolchain_type):
    """Runs `gen_kernel` directly via `dartaotruntime`; the action names `toolchain_type`."""
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
        env = writable_home_env(dart_sdk_info.dart, outputs[0]),
        toolchain = toolchain_type,
    )

def kernel_action(ctx, dart_sdk_info, st, aot, enable_asserts, extra_flags, product, output):
    """Runs `gen_kernel` over a source entrypoint, with stable URIs.

    `dart compile` reads its package config and entrypoint as file paths and
    records them as absolute `file:` URIs. `gen_kernel` takes the scheme
    described in `gen_kernel_args`, so the kernel names every library by its
    repository path. Mode flags that belong to the front end go here: `--aot
    --tfa` for the modes that tree-shake, `dart.vm.product` and sanitizer
    defines matching `dart compile`, and `--enable-asserts`, which is
    constant-folded or dropped while the front end runs.

    The remaining inputs (entrypoint, sources, package config, defines, target
    OS, tools, native assets, source embedding) travel in `st`, the struct
    `dart_compile_action` threads through its helpers. The kernel step never
    records `@RecordUse` uses: only the `dart compile` step of the
    tree-shaking modes does.

    Args:
        ctx: The rule context.
        dart_sdk_info: The `DartSdkInfo` of the toolchain.
        st: The threaded compile struct (see `dart_compile_action`).
        aot: Whether to produce an AOT kernel (`--aot --tfa`).
        enable_asserts: Whether to pass `--enable-asserts`.
        extra_flags: Flags for `gen_kernel` itself, appended last. A
            comma-containing `-D`/`--define` among them takes the same
            comma-safe path as `defines` (the toolchain's patched snapshot
            plus the `--comma-patched-snapshot` marker).
        product: Whether the kernel is for a product runtime: an AOT snapshot or
            executable, or a `dart compile kernel` file. False for the JIT VM
            that builds a `jit-snapshot`.
        output: The kernel File to write.
    """
    args, outputs, tools, gen_snapshot, comma_sources = _kernel_front_args(
        ctx,
        dart_sdk_info,
        st,
        aot,
        enable_asserts,
        extra_flags,
        product,
        output,
    )

    if st.jit_tool:
        _kernel_run_wrapper(ctx, dart_sdk_info, st, tools, args, outputs, gen_snapshot, comma_sources)
        return

    direct = [st.main, st.package_config] + st.srcs
    if st.native_assets_yaml != None:
        direct.append(st.native_assets_yaml)
    _kernel_run_direct(ctx, dart_sdk_info, tools, args, direct, outputs, st.toolchain_type)

def linked_kernel_action(ctx, dart_sdk_info, st, output):
    """Runs the AOT front end over a linked kernel instead of sources.

    The linked kernel holds the platform and every library's module, each
    compiled already (constants evaluated, `dart.vm.product` set). `gen_kernel
    --from-dill` loads it and applies only the whole-program steps (`--aot
    --tfa`), so no source file is an input. The flags are those of
    `kernel_action` for an AOT kernel, less the ones that act on sources
    (package config, file system roots, defines, native assets, asserts).

    Args:
        ctx: The rule context.
        dart_sdk_info: The `DartSdkInfo` of the toolchain.
        st: The threaded compile struct (see `dart_compile_action`), whose
            `linked_kernel` names the linked kernel File.
        output: The AOT kernel File to write.
    """
    tools = find_sdk_kernel_tools(dart_sdk_info)
    args = ctx.actions.args()
    args.add(tools.gen_kernel_snapshot)
    args.add("--platform", tools.product_platform_dill)
    args.add_all([
        "-Ddart.vm.product=true",
        "-Ddart.vm.asan=false",
        "-Ddart.vm.msan=false",
        "-Ddart.vm.tsan=false",
        "--aot",
        "--tfa",
        "--no-embed-sources",
    ])
    if st.target_os:
        args.add("--target-os", st.target_os)
    args.add(st.linked_kernel, format = "--from-dill=%s")
    args.add("-o", output)
    args.add(st.linked_kernel)
    _kernel_run_direct(ctx, dart_sdk_info, tools, args, [st.linked_kernel], [output], st.toolchain_type)
