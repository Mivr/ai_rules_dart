"""Internal rule for producing an AOT-compiled artifact from Flutter sources.

Chains: sources → kernel .dill → gen_snapshot → platform-specific output.

In debug mode, skips AOT and returns the kernel .dill directly (same as
flutter_application.bzl). Supports macOS/iOS (Mach-O .dylib) and other
platforms (ELF .so).
"""

load("//flutter/private:common.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "FLUTTER_APPLICATION_ATTRS", "KERNEL_COMPILE_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "flutter_build_mode", "flutter_compile_kernel", "make_kernel_inputs", "make_kernel_target", "resolve_flutter_sdk_info")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action", "flutter_aot_gen_snapshot_flags", "flutter_aot_macho_action", "macho_snapshot_options")
load("//flutter/private:platform_constraints.bzl", "target_platform_from_constraints")

visibility(["//flutter/..."])

def _check_aot_cross_compile(flutter_sdk_info, is_debug):
    """Guards against unsupported desktop cross-compilation or missing gen_snapshot."""
    if not is_debug and flutter_sdk_info.target_os in ("linux", "macos", "windows"):
        fail(
            "AOT cross-compilation between desktop platforms is not supported. " +
            "Flutter's gen_snapshot can only produce native code for the host OS. " +
            "Build on the target platform, or use debug mode (-c dbg).",
        )
    if not is_debug and not flutter_sdk_info.gen_snapshot:
        fail(
            (
                "No target-compatible AOT gen_snapshot toolchain is registered for this " +
                "host and target platform (target_os=%s). Apple AOT snapshots require a " +
                "Darwin-target gen_snapshot on a macOS host; build on macOS or use debug mode (-c dbg)."
            ) % (
                flutter_sdk_info.target_os or "native",
            ),
        )

def _aot_target_compile_action(ctx, platform, flutter_sdk_info, kernel_dill, strip, extra_flags, extra_outputs):
    """Registers the Mach-O or ELF gen_snapshot action and returns the output file."""
    if platform.is_ios or platform.is_macos:
        output = ctx.actions.declare_file(ctx.label.name + ".dylib")
        flutter_aot_macho_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = output,
            macho = macho_snapshot_options(
                min_os_version = ctx.attr.min_os_version if ctx.attr.min_os_version else None,
            ),
            strip = strip,
            extra_flags = extra_flags,
            extra_outputs = extra_outputs,
        )
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".so")
        flutter_aot_elf_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = output,
            strip = strip,
            extra_flags = extra_flags,
            extra_outputs = extra_outputs,
        )
    return output

def _flutter_aot_target_impl(ctx):
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)

    is_debug = flutter_build_mode(ctx) == "debug"

    _check_aot_cross_compile(flutter_sdk_info, is_debug)

    # Detect the target platform so kernel compilation (plugin registration)
    # and the action key reflect it, mirroring flutter_application.
    platform = target_platform_from_constraints(ctx)

    # Step 1: Kernel compilation.
    kernel_dill = flutter_compile_kernel(
        ctx = ctx,
        flutter_sdk_info = flutter_sdk_info,
        target = make_kernel_target(aot = not is_debug, target_platform = platform.target_platform),
        inputs = make_kernel_inputs(),
    ).kernel_dill

    # In debug mode, return the kernel .dill directly (JIT, no gen_snapshot).
    if is_debug:
        if getattr(ctx.attr, "analyze_size", False) or ("analyze_size" in getattr(ctx, "features", [])):
            fail("%s: analyze_size is not supported in debug mode: gen_snapshot does not run in debug mode" % ctx.label)
        return [DefaultInfo(files = depset([kernel_dill]))]

    # Step 2: AOT compile — choose format based on target platform.

    strip = ctx.var["COMPILATION_MODE"] == "opt"

    # Obfuscation forces `--strip` (see `flutter_aot_gen_snapshot_flags`):
    # unstripped DWARF would leak the original names.
    extra_flags, extra_outputs, debug_info_output, obfuscation_map_output, strip = flutter_aot_gen_snapshot_flags(
        ctx,
        strip,
    )
    size_output = None
    if getattr(ctx.attr, "analyze_size", False) or ("analyze_size" in getattr(ctx, "features", [])):
        for f in extra_outputs:
            if f.basename == ctx.label.name + "_size.json":
                size_output = f
                break

    output = _aot_target_compile_action(
        ctx,
        platform,
        flutter_sdk_info,
        kernel_dill,
        strip,
        extra_flags,
        extra_outputs,
    )

    output_groups = {}
    if debug_info_output:
        output_groups["debug_info"] = depset([debug_info_output])
    if obfuscation_map_output:
        output_groups["obfuscation_map"] = depset([obfuscation_map_output])
    if size_output:
        output_groups["analyze_size"] = depset([size_output])

    default_files = [output]
    if size_output:
        default_files.append(size_output)

    providers = [
        DefaultInfo(files = depset(default_files)),
    ]
    if output_groups:
        providers.append(OutputGroupInfo(**output_groups))
    return providers

# The compile inputs arrive as a bundle, the gen_snapshot options by name.
# Taking them from the shared bundle rather than copying attrs keeps this rule
# from missing one `flutter_compile_kernel` reads — an attr reaching `ctx.attr`
# on a rule that never declared it fails at analysis.
_AOT_ATTRS = KERNEL_COMPILE_ATTRS | {k: v for k, v in FLUTTER_APPLICATION_ATTRS.items() if k in (
    "obfuscate",
    "split_debug_info",
    "extra_gen_snapshot_options",
    "min_os_version",
)} | {
    "analyze_size": attr.bool(
        default = False,
        doc = (
            "Passes `--print-instructions-sizes-to` to `gen_snapshot` and " +
            "writes a size breakdown JSON to `<name>_size.json`."
        ),
    ),
}

flutter_aot_target = rule(
    implementation = _flutter_aot_target_impl,
    attrs = dict(_AOT_ATTRS, **PLATFORM_CONSTRAINT_ATTRS),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:aot_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles Flutter sources to an AOT artifact (.so or .dylib depending on target platform).",
)
