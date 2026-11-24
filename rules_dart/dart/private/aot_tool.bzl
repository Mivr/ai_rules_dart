"""Launch of a rules_dart build tool that ships as an AOT snapshot.

`kernel_link` and `analyzer_summary` are `aot-snapshot` binaries: `dart` refuses
to run an `.aot` file, so `dartaotruntime` from the executing SDK runs them.
A user-supplied tool (the public `//dart:analyzer_summary_tool` flag) in any
other compile mode still runs under `dart`, as before.
"""

load("//dart:providers.bzl", "DartCompileInfo")
load("//dart/private:common.bzl", "kernel_sdk_mismatch_error")

def _find_runtime(files):
    for f in files.to_list():
        if f.basename in ("dartaotruntime", "dartaotruntime.exe"):
            return f
    return None

def aot_tool_launch(ctx, attr_name, dart_sdk_info, sdk_files):
    """Chooses the executable that runs a tool, and what the action needs for it.

    Args:
      ctx: The rule or aspect context; its `attr_name` attribute is the tool.
      attr_name: The tool attribute name, such as `_tool`.
      dart_sdk_info: The `DartSdkInfo` of the SDK that executes the tool; a kernel
        tool built by another SDK version fails here.
      sdk_files: The depset of SDK files that holds `dartaotruntime`.

    Returns:
      `struct(executable, prefix, inputs)`: the action's executable, the
      leading arguments (the tool path when `dart` runs it) and the Files the
      action takes as inputs and tools besides the tool itself.
    """
    target = getattr(ctx.attr, attr_name, None)
    mismatch = kernel_sdk_mismatch_error(ctx.label, attr_name, target, dart_sdk_info.version)
    if mismatch != None:
        fail(mismatch)
    tool = getattr(ctx.executable, attr_name)
    if target == None or DartCompileInfo not in target or target[DartCompileInfo].compile_mode != "aot-snapshot":
        return struct(executable = dart_sdk_info.dart, prefix = [tool.path], inputs = [tool, dart_sdk_info.dart])
    runtime = _find_runtime(sdk_files)
    if runtime == None:
        fail(("%s: `%s` is an AOT snapshot and needs `dartaotruntime`, which the Dart SDK %s at %s " +
              "does not provide (target platform %s); the kernel form is not used as a fallback.") % (
            ctx.label,
            target.label,
            dart_sdk_info.version,
            dart_sdk_info.dart.path,
            ctx.var.get("TARGET_CPU", "unknown"),
        ))
    return struct(executable = runtime, prefix = [tool.path], inputs = [tool, runtime])
