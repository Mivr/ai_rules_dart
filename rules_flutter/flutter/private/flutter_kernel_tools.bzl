"""Kernel-module tool selection for the modular Flutter kernel.

Picks the module compiler and `dartaotruntime` of the Flutter SDK's own Dart
SDK.
"""

load("@rules_dart//dart:utils.bzl", "kernel_tools_for")

visibility(["//flutter/..."])

def is_same_sdk(exec_tools, flutter_sdk_info):
    """Returns True when `exec_tools` and `flutter_sdk_info` refer to the same Dart SDK.

    Compares executable file identity (`dartaotruntime`, then `dart`), falling back
    to SDK version string comparison when neither executable pair is present.

    Args:
      exec_tools: The kernel tools struct (e.g. from `kernel_tools_for(ctx)`).
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.

    Returns:
      `True` if both toolchains refer to the same Dart SDK, else `False`.
    """
    if exec_tools == None or flutter_sdk_info == None:
        return False
    exec_aot = getattr(exec_tools, "dartaotruntime", None)
    flutter_aot = getattr(flutter_sdk_info, "dartaotruntime", None)
    if exec_aot != None and flutter_aot != None:
        return exec_aot == flutter_aot
    exec_dart = getattr(exec_tools, "dart", None)
    flutter_dart = getattr(flutter_sdk_info, "dart", None)
    if exec_dart != None and flutter_dart != None:
        return exec_dart == flutter_dart
    exec_version = getattr(exec_tools, "version", None)
    flutter_version = getattr(flutter_sdk_info, "version", None)
    if exec_version != None and flutter_version != None:
        return exec_version == flutter_version
    return False

def find_flutter_kernel_module_tools(flutter_sdk_info, exec_tools = None):
    """Selects kernel module tools matching `flutter_sdk_info`'s bundled Dart SDK.

    The module compiler is built from the tag of the Dart SDK that runs it, and
    a Flutter module compiles against Flutter's own platform kernel, so the
    tools are those of the Dart SDK inside Flutter. When `exec_tools` is
    already that SDK (`is_same_sdk(exec_tools, flutter_sdk_info)`), it is
    returned as it is. When `@rules_dart`'s standalone toolchain resolved ahead
    of `@flutter_toolchains`, the module compiler and `dartaotruntime` come from
    the Flutter toolchain instead (`FlutterSdkInfo.dart_module_compiler`), so
    modular `.flutter.kmod` compilation still matches
    `flutter_sdk_info.platform_kernel_dill` and `flutter_tester`.

    Args:
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      exec_tools: Optional struct from `kernel_tools_for(ctx)`.

    Returns:
      A kernel tools struct whose `dartaotruntime` and `module_compiler` are
      the Flutter SDK's own, or `None` if the Flutter toolchain has no module
      compiler.
    """
    if flutter_sdk_info == None or flutter_sdk_info.dart == None or flutter_sdk_info.dartaotruntime == None:
        return None
    if exec_tools != None and is_same_sdk(exec_tools, flutter_sdk_info):
        return exec_tools
    module_compiler = getattr(flutter_sdk_info, "dart_module_compiler", None)
    if module_compiler == None:
        return None
    return struct(
        dart = exec_tools.dart if exec_tools != None else flutter_sdk_info.dart,
        dartvm = exec_tools.dartvm if exec_tools != None else None,
        runtime_files = exec_tools.runtime_files if exec_tools != None else flutter_sdk_info.dart_vm_files,
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        module_compiler = module_compiler,
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        version = exec_tools.version if exec_tools != None else flutter_sdk_info.version,
    )

def flutter_kernel_tools_for(ctx, flutter_sdk_info):
    """Returns kernel module tools whose compiler matches `flutter_sdk_info`, or `None`.

    Args:
      ctx: Rule or aspect context declaring `MODULAR_KERNEL_TOOLCHAINS`.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.

    Returns:
      The kernel tools struct matching `flutter_sdk_info`, or `None`.
    """
    if flutter_sdk_info == None:
        return None
    return find_flutter_kernel_module_tools(flutter_sdk_info, exec_tools = kernel_tools_for(ctx))

def no_flutter_module_compiler_error(label, flutter_sdk_info):
    """The analysis error for a target whose Flutter toolchain has no module compiler.

    Args:
      label: The target's label.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.

    Returns:
      The message.
    """
    return ("%s compiles Flutter kernel modules, but the module compiler cannot be built for the Dart SDK " +
            "of Flutter %s (Dart %s): that Dart version has no pinned sources in `MODULE_COMPILER_SOURCES` " +
            "(@rules_dart//dart/private:module_compiler_versions.bzl), or the Flutter toolchain names no " +
            "`dart_toolchain`. Use a Flutter version whose Dart SDK that table lists.") % (
        label,
        flutter_sdk_info.version if flutter_sdk_info != None else "(none)",
        getattr(flutter_sdk_info, "dart_sdk_version", None) or "unknown",
    )

def required_flutter_kernel_tools(ctx, flutter_sdk_info):
    """The kernel module tools matching `flutter_sdk_info`, failing at analysis when there are none.

    Args:
      ctx: Rule context declaring `MODULAR_KERNEL_TOOLCHAINS`.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.

    Returns:
      The kernel tools struct.
    """
    tools = flutter_kernel_tools_for(ctx, flutter_sdk_info)
    if tools == None:
        fail(no_flutter_module_compiler_error(ctx.label, flutter_sdk_info))
    return tools

def check_library_module_compiler(ctx):
    """Fails a library whose Flutter toolchain's Dart SDK has no module compiler. Returns None.

    A debug program compiles each library of its closure as a kernel module,
    so a library under such a toolchain could never be built into one: it fails
    at analysis, naming the version, as the executable does. A toolchain that
    names no Dart toolchain, or has no debug platform kernel, is not judged here.

    Args:
      ctx: The library's rule context, declaring the Flutter toolchain (optional) and `MODULAR_KERNEL_TOOLCHAINS`.
    """
    toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    info = toolchain.flutter_sdk_info if toolchain else None
    if info == None or info.platform_kernel_dill == None or getattr(info, "dart_sdk_version", None) == None:
        return
    if flutter_kernel_tools_for(ctx, info) == None:
        fail(no_flutter_module_compiler_error(ctx.label, info))
