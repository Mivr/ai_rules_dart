"""A downstream-style whole-program compile fixture for the incremental kernel tests.

`incr_caller` calls the public compile API with a recording `ctx`, so a test can
read the `execution_requirements` Starlark cannot read back from an action.
"""

load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs")
load("//flutter:utils.bzl", "FLUTTER_KERNEL_COMPILE_ATTRS", "FLUTTER_KERNEL_COMPILE_TOOLCHAINS", "compile_package_config", "flutter_kernel_compile_action", "flutter_kernel_compile_tools", "flutter_kernel_dills", "flutter_kernel_options", "flutter_kernel_outputs", "flutter_kernel_sources")

visibility(["//flutter/tests/..."])

ReqInfo = provider(
    doc = "What the compile passed to `ctx.actions.run`, which Starlark cannot read back from an action.",
    fields = {"requirements": "The `execution_requirements` dict of the `FlutterKernelCompile` run."},
)

def _recording_ctx(ctx, seen):
    """A `ctx` stand-in that records the `ctx.actions.run` keyword arguments.

    Args:
        ctx: The real rule context.
        seen: A list that receives each run's `execution_requirements`.

    Returns:
        A struct with the `ctx` surface the compile uses.
    """

    def run(**kwargs):
        seen.append(kwargs.get("execution_requirements", {}))
        ctx.actions.run(**kwargs)

    return struct(
        actions = struct(
            args = ctx.actions.args,
            declare_file = ctx.actions.declare_file,
            run = run,
            symlink = ctx.actions.symlink,
            write = ctx.actions.write,
        ),
        attr = ctx.attr,
        executable = ctx.executable,
        label = ctx.label,
        toolchains = ctx.toolchains,
        var = ctx.var,
    )

def _caller_impl(ctx):
    """A downstream-style whole-program compile over the public utils."""
    tools = flutter_kernel_compile_tools(ctx)
    packages = collect_packages(ctx.attr.deps)
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list() + [ctx.file.main]
    pc = compile_package_config(ctx, packages, all_srcs)
    output = ctx.actions.declare_file(ctx.label.name + ".dill")
    seen = []
    flutter_kernel_compile_action(
        _recording_ctx(ctx, seen),
        tools,
        flutter_kernel_sources(main = ctx.file.main, srcs = pc.srcs, package_config = pc.config_file),
        flutter_kernel_outputs(output = output),
        flutter_kernel_options(aot = ctx.attr.aot, target = ctx.attr.target),
        flutter_kernel_dills(),
    )
    return [DefaultInfo(files = depset([output])), ReqInfo(requirements = seen)]

incr_caller = rule(
    implementation = _caller_impl,
    attrs = {
        "main": attr.label(mandatory = True, allow_single_file = [".dart"], doc = "The entrypoint."),
        "srcs": attr.label_list(allow_files = [".dart"], doc = "Additional sources."),
        "deps": attr.label_list(doc = "Dependencies."),
        "aot": attr.bool(default = False, doc = "Compile for AOT."),
        "target": attr.string(default = "flutter", doc = "The frontend_server target model."),
    } | FLUTTER_KERNEL_COMPILE_ATTRS,
    toolchains = FLUTTER_KERNEL_COMPILE_TOOLCHAINS,
)
