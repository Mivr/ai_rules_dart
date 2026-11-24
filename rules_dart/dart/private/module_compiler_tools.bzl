"""The module compiler and the SDK files that run it, for behaviour tests.

`module_compiler_tools` resolves the exec tools toolchain, as every module
action does, and hands a test the same tool those actions run: its only file is
a JSON object naming the runfiles path of the module compiler, of the
`dartaotruntime` that runs it, of the platform kernel and of `dart`.
"""

visibility(["//dart/..."])

_EXEC_TOOLS_TOOLCHAIN = Label("//dart:exec_tools_toolchain_type")

def _rlocation(ctx, f):
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return ctx.workspace_name + "/" + f.short_path

def _module_compiler_tools_impl(ctx):
    sdk = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN].dart_sdk_info
    files = {
        "module_compiler": sdk.module_compiler,
        "dartaotruntime": sdk.kernel_module_files.dartaotruntime,
        "platform": sdk.kernel_module_files.platform_dill,
        "dart": sdk.dart,
    }
    manifest = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(manifest, json.encode({key: _rlocation(ctx, f) for key, f in files.items()}))
    return [DefaultInfo(
        files = depset([manifest]),
        runfiles = ctx.runfiles(
            files = [manifest] + files.values(),
            transitive_files = sdk.runtime_files,
        ),
    )]

module_compiler_tools = rule(
    implementation = _module_compiler_tools_impl,
    doc = "The exec SDK's module compiler and the files that run it, named by a JSON manifest.",
    toolchains = [_EXEC_TOOLS_TOOLCHAIN],
)
