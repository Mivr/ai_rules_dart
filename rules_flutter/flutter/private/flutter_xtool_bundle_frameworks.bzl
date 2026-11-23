"""Framework collection for the `xtool` bundle rules (private implementation).

Sorts every `.framework` / `.xcframework` slice reachable from a bundle rule
into the set the runner compile links against (static and dynamic) and the
subset that is embedded in the bundle's `Frameworks/` directory (dynamic
only).

Usage: see flutter/private/flutter_xtool_bundle_pack.bzl.
"""

load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterDarwinFrameworkInfo")

visibility(["//flutter/..."])

def _extract_framework_dirs_from_files(files):
    """The ordered, unique `.framework` / `.xcframework` directories `files` live in."""
    dirs = []
    for f in files:
        if f.is_directory:
            candidate = f.path
        else:
            candidate = None
            parts = f.path.split("/")
            for idx, part in enumerate(parts):
                if part.endswith(".xcframework") or part.endswith(".framework"):
                    candidate = "/".join(parts[:idx + 1])
                    break
        if candidate and candidate not in dirs:
            dirs.append(candidate)
    return dirs

def _framework_files_in(files):
    """The subset of `files` that belongs to a `.framework` / `.xcframework`."""
    return [
        f
        for f in files
        if f.is_directory or ".framework/" in f.path or ".xcframework/" in f.path or
           f.path.endswith(".framework") or f.path.endswith(".xcframework")
    ]

def _record(state, dirs, files, is_dynamic):
    """Record `files` under every directory in `dirs`; a dynamic mark is never downgraded."""
    for fw_dir in dirs:
        state.dynamic[fw_dir] = state.dynamic.get(fw_dir, False) or is_dynamic
        state.inputs.setdefault(fw_dir, []).append(files)

def _record_framework_info(state, fw_info):
    """Fold one `FlutterDarwinFrameworkInfo` into the accumulator."""
    if fw_info.framework_dir:
        dirs = [fw_info.framework_dir]
    else:
        dirs = _extract_framework_dirs_from_files(fw_info.framework_files.to_list())
    _record(state, dirs, fw_info.framework_files, fw_info.is_dynamic)

def _structured_infos(target):
    """The structured framework infos `target` carries, or `None` when it carries neither provider."""
    if FlutterDarwinFrameworkInfo not in target and FlutterApplePluginInfo not in target:
        return None
    infos = []
    if FlutterDarwinFrameworkInfo in target:
        infos.append(target[FlutterDarwinFrameworkInfo])
    plugin_infos = None
    if FlutterApplePluginInfo in target:
        plugin_infos = getattr(target[FlutterApplePluginInfo], "framework_infos", None)
    if plugin_infos != None:
        infos.extend(plugin_infos.to_list())
    return infos

def _record_target(state, target, keep_all_files):
    """Record one target: structured infos when present, otherwise its raw framework files."""
    infos = _structured_infos(target)
    if infos != None:
        for fw_info in infos:
            _record_framework_info(state, fw_info)
        return
    files = target[DefaultInfo].files.to_list()
    if not keep_all_files:
        files = _framework_files_in(files)
    if files:
        _record(state, _extract_framework_dirs_from_files(files), depset(files), True)

def collect_framework_args_and_inputs(framework_targets, plugin_and_dep_targets = []):
    """Collect the framework directories and inputs for the runner compile and the bundle.

    Raw `.framework` file targets, and `FlutterDarwinFrameworkInfo` entries
    with `is_dynamic`, are embedded; static entries are only linked. A slice
    reached through several edges is dynamic when any edge says so.

    Args:
        framework_targets: Targets of the `frameworks` attribute.
        plugin_and_dep_targets: Targets of the `plugins` and `deps` attributes.

    Returns:
        struct(compile, bundle), each a struct(dirs, transitive_inputs).
    """
    state = struct(dynamic = {}, inputs = {})
    for target in framework_targets:
        _record_target(state, target, True)
    for target in plugin_and_dep_targets:
        _record_target(state, target, False)

    compile_dirs = list(state.dynamic.keys())
    bundle_dirs = [d for d in compile_dirs if state.dynamic[d]]
    return struct(
        compile = struct(
            dirs = compile_dirs,
            transitive_inputs = [fs for d in compile_dirs for fs in state.inputs[d]],
        ),
        bundle = struct(
            dirs = bundle_dirs,
            transitive_inputs = [fs for d in bundle_dirs for fs in state.inputs[d]],
        ),
    )
