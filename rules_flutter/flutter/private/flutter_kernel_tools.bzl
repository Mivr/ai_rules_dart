"""Kernel-module tool selection for the modular Flutter kernel.

Picks the `kernel_worker` and `dartaotruntime` that match the Flutter SDK's own
Dart SDK.
"""

load("@rules_dart//dart:utils.bzl", "kernel_tools_for")

visibility(["//flutter/..."])

def _sdk_root_from_dart(dart_file):
    p = dart_file.path
    for suffix in ("/bin/dart", "/bin/dart.exe"):
        if p.endswith(suffix):
            return p[:-len(suffix)]
    return p

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

    When `exec_tools` is already from the same SDK (`is_same_sdk(exec_tools, flutter_sdk_info)`),
    returns `exec_tools` directly. When `@rules_dart`'s standalone toolchain resolved
    ahead of `@flutter_toolchains`, locates `kernel_worker_aot.dart.snapshot` and
    `libraries.json` in `flutter_sdk_info.tool_files` so modular `.flutter.kmod`
    compilation runs the `kernel_worker` and `dartaotruntime` matching
    `flutter_sdk_info.platform_kernel_dill` and `flutter_tester`, while keeping
    `exec_tools`'s outer VM (`dart`, `dartvm`, `runtime_files`, `version`) that
    launches the `@rules_dart//dart/private/tools:kernel_module` tool.

    Args:
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      exec_tools: Optional struct from `kernel_tools_for(ctx)`.

    Returns:
      A kernel tools struct whose `dartaotruntime`, `kernel_worker`, and
      `libraries_json` match `flutter_sdk_info`, or `None` if `flutter_sdk_info`
      lacks the required files.
    """
    if flutter_sdk_info == None or flutter_sdk_info.dart == None or flutter_sdk_info.dartaotruntime == None:
        return None
    if exec_tools != None and is_same_sdk(exec_tools, flutter_sdk_info):
        return exec_tools

    sdk_root = _sdk_root_from_dart(flutter_sdk_info.dart)
    dartvm_paths = (sdk_root + "/bin/dartvm", sdk_root + "/bin/dartvm.exe")
    wanted = {
        "kernel_worker": sdk_root + "/bin/snapshots/kernel_worker_aot.dart.snapshot",
        "libraries_json": sdk_root + "/lib/libraries.json",
    }
    dartvm = None
    found = {}
    for f in flutter_sdk_info.tool_files.to_list():
        if f.path in dartvm_paths:
            dartvm = f
        for key, path in wanted.items():
            if f.path == path:
                found[key] = f
    if len(found) != len(wanted):
        return None

    return struct(
        dart = exec_tools.dart if exec_tools != None else flutter_sdk_info.dart,
        dartvm = exec_tools.dartvm if exec_tools != None else dartvm,
        runtime_files = exec_tools.runtime_files if exec_tools != None else flutter_sdk_info.dart_vm_files,
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        kernel_worker = found["kernel_worker"],
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        libraries_json = found["libraries_json"],
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
    exec_tools = kernel_tools_for(ctx)
    if exec_tools == None or flutter_sdk_info == None:
        return None
    return find_flutter_kernel_module_tools(flutter_sdk_info, exec_tools = exec_tools)
