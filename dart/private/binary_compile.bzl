"""Compiles a `dart_binary`: from linked per-library kernels where the SDK allows, else from source."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart/private:build_settings.bzl", "merge_dart_defines")
load(
    "//dart/private:common.bzl",
    "code_asset_entries",
    "collect_transitive_srcs",
    "find_sdk_kernel_tools",
    "generate_native_assets_yaml",
    "generate_stable_package_config",
    "target_dart_abi",
)
load("//dart/private:dart_compile.bzl", "dart_compile_action", "get_compilation_mode_flags")
load(
    "//dart/private:dart_kernel.bzl",
    "DartKernelInfo",
    "entry_sources",
    "modular_executable_kernel",
    "modular_executable_tools",
)
load("//dart/private:dart_test_runner.bzl", "DartTestRunnerMainInfo")
load("//dart/private:kernel_params.bzl", "kernel_compile_settings")
load("//dart/private:source_set.bzl", "executable_inputs")
load("//dart/private/tools:compile_wrapper.bzl", "compile_wrapper_inputs")

visibility(["//dart/..."])

def _modular_kernel_mode(ctx, compile_mode):
    """Whether `compile_mode` may take the modular path, before the eligibility facts.

    `kernel` links the modules. `exe` and `aot-snapshot` link them too, with
    the platform, and run the AOT whole-program steps over that kernel, unless
    the build sets `--enable-asserts` (the `dbg` compilation mode): the front
    end drops `assert`s while it builds a module, so the modules hold none for
    the whole-program step to keep. `jit-snapshot` trains from the kernel of
    its source compile and stays on sources.

    Args:
      ctx: The `dart_binary` rule context.
      compile_mode: The `dart compile` mode.

    Returns:
      True when the modular path may apply.
    """
    if not ctx.attr.modular_kernel:
        return False
    if compile_mode == "kernel":
        return True
    if compile_mode not in ("exe", "aot-snapshot"):
        return False
    return "--enable-asserts" not in get_compilation_mode_flags(ctx, compile_mode)

def _compile_cfg(ctx, run, inputs):
    """The `dart_compile_action` config for one binary.

    Args:
      ctx: The rule context.
      run: The `struct` `binary_compile` takes.
      inputs: A struct with what differs between the source and the linked
        compile: `main`, `srcs`, `package_config`, `main_path`, `defines`,
        `native_assets_yaml` and `linked_kernel`.

    Returns:
      The `cfg` struct of `dart_compile_action`.
    """
    wrapper = compile_wrapper_inputs(ctx)
    sdk = run.dart_sdk_info
    return struct(
        main = inputs.main,
        srcs = inputs.srcs,
        package_config = inputs.package_config,
        output = run.output,
        compile_mode = run.compile_mode,
        target_os = sdk.target_os,
        target_arch = sdk.target_arch,
        extra_flags = ctx.attr.dart_compile_flags,
        defines = inputs.defines,
        main_path = inputs.main_path,
        recorded_uses = run.optional_outputs.recorded_uses,
        debug_info = run.optional_outputs.debug_info,
        jit_tool = wrapper.jit_tool,
        comma_patch = wrapper.comma_patch,
        compile_wrapper = wrapper.compile_wrapper,
        native_assets_yaml = inputs.native_assets_yaml,
        linked_kernel = inputs.linked_kernel,
        embed_sources = DartTestRunnerMainInfo not in ctx.attr.main,
        jit_snapshot_fallback = ctx.attr._jit_snapshot_fallback[BuildSettingInfo].value,
    )

def _source_compile(ctx, run):
    """Compiles from source through `executable_inputs`. Returns the code-asset libs."""

    # Nothing is copied: a package split between the source tree and `bazel-out`
    # compiles in place, through the multi-root file system (`executable_inputs`).
    # The one flatten per rule: the package lookup inspects per-file paths.
    inputs = executable_inputs(
        run.own.packages,
        collect_transitive_srcs(ctx.attr.deps).to_list(),
        ctx.file.main,
        ctx.files.srcs,
        run.own.record,
    )

    # Root resolution must see the rule's own inputs too: a package whose
    # metadata comes from a srcs-less façade library resolves only via the
    # files this rule supplies itself.
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = generate_stable_package_config(inputs.packages, inputs.srcs, inputs.roots),
    )

    code_asset_libs = []
    native_assets_yaml = None
    if run.resolved_assets:
        entries, code_asset_libs = code_asset_entries(
            ctx.label,
            run.resolved_assets,
            run.output.dirname,
        )
        native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
        ctx.actions.write(
            output = native_assets_yaml,
            content = generate_native_assets_yaml(target_dart_abi(ctx), entries),
        )

    dart_compile_action(
        ctx = ctx,
        dart_sdk_info = run.dart_sdk_info,
        cfg = _compile_cfg(ctx, run, struct(
            main = inputs.main_input,
            srcs = inputs.srcs,
            package_config = package_config,
            main_path = inputs.main_arg,
            defines = merge_dart_defines(ctx),
            native_assets_yaml = native_assets_yaml,
            linked_kernel = None,
        )),
        toolchain_type = run.toolchain_type,
    )
    return code_asset_libs

def _linked_compile(ctx, run, kernel_tools):
    """Links the modules with the platform, then runs the AOT steps over that kernel.

    The front end's input is the linked kernel, so a body edit in one library
    recompiles that module and the whole-program steps run again without
    parsing a source. Nothing but the `.kmod` directories, the platform and the
    SDK is an input of those steps. The flags of the `dart compile` step are
    those of the source compile; `defines` are not among them, since every
    module took the `//dart:extra_dart_defines` values when it compiled.

    Args:
      ctx: The rule context.
      run: The `struct` `binary_compile` takes.
      kernel_tools: The struct from `find_kernel_module_tools`.
    """
    linked = ctx.actions.declare_file(ctx.label.name + ".linked.dill")
    modular_executable_kernel(
        ctx,
        kernel_tools,
        entry_sources(run.own_files),
        run.own.packages,
        [dep[DartKernelInfo] for dep in ctx.attr.deps],
        linked,
        kernel_compile_settings(),
        platform_dill = find_sdk_kernel_tools(run.dart_sdk_info).product_platform_dill,
    )
    dart_compile_action(
        ctx = ctx,
        dart_sdk_info = run.dart_sdk_info,
        cfg = _compile_cfg(ctx, run, struct(
            main = linked,
            srcs = [],
            package_config = None,
            main_path = None,
            defines = [],
            native_assets_yaml = None,
            linked_kernel = linked,
        )),
        toolchain_type = run.toolchain_type,
    )

def binary_compile(ctx, run):
    """Compiles a binary, modularly when eligible. Returns the code-asset libs.

    Args:
      ctx: The rule context.
      run: A struct with `dart_sdk_info` (the `DartSdkInfo` of the toolchain),
        `toolchain_type`, `own` (the `executable_package` record for this
        rule's own inputs), `own_files` (the main and source Files), `output`
        (the declared raw compile output), `compile_mode`, `optional_outputs`
        (the declared recorded-uses and debug-info outputs) and
        `resolved_assets` (the resolved code assets).

    Returns:
      The list of code-asset library Files.
    """
    kernel_tools = modular_executable_tools(
        ctx,
        run.own_files,
        run.own.record,
        kernel_mode = _modular_kernel_mode(ctx, run.compile_mode),
        resolved_assets = run.resolved_assets,
        own_defines = ctx.attr.defines,
        compile_flags = ctx.attr.dart_compile_flags,
        target_sdk = run.dart_sdk_info,
    )
    if kernel_tools == None:
        return _source_compile(ctx, run)
    if run.compile_mode == "kernel":
        modular_executable_kernel(
            ctx,
            kernel_tools,
            entry_sources(run.own_files),
            run.own.packages,
            [dep[DartKernelInfo] for dep in ctx.attr.deps],
            run.output,
            kernel_compile_settings(),
        )
    else:
        _linked_compile(ctx, run, kernel_tools)
    return []
