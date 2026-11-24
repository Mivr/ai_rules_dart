"""Darwin framework import and xtool platform targeting (private implementation).

Holds `flutter_darwin_xcframework_import` with the target-architecture and
configuration-transition helpers the `xtool` backend bundle rules build on.
`flutter/private/flutter_xtool_bundle.bzl` loads the rule back and re-exports
it, so existing users are unaffected.

Usage: see flutter/private/flutter_xtool_bundle.bzl for public API.
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:providers.bzl", "FlutterDarwinFrameworkInfo")

visibility(["//flutter/..."])

# -- Transitions & Architecture Helpers ----------------------------------------

def _xtool_ios_transition_impl(settings, _attr):
    comp_mode = settings["//command_line_option:compilation_mode"]
    current_platforms = settings["//command_line_option:platforms"]
    target_platform = str(Label("//flutter/platforms:ios_arm64"))
    if comp_mode == "dbg":
        target_platform = str(Label("//flutter/platforms:ios_x64"))
    for p in current_platforms:
        p_str = str(p)
        if p_str.endswith(":ios_arm64") or p_str.endswith(":ios_x64"):
            target_platform = p_str
            break
    return {
        "//command_line_option:platforms": [target_platform],
        "//flutter/settings:apple_backend": "xtool",
    }

xtool_ios_transition = transition(
    implementation = _xtool_ios_transition_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
    ],
    outputs = [
        "//command_line_option:platforms",
        "//flutter/settings:apple_backend",
    ],
)

def _xtool_macos_transition_impl(settings, _attr):
    current_platforms = settings["//command_line_option:platforms"]
    target_platform = str(Label("//flutter/platforms:macos_arm64"))
    for p in current_platforms:
        p_str = str(p)
        if p_str.endswith(":macos_arm64") or p_str.endswith(":macos_x64"):
            target_platform = p_str
            break
    return {
        "//command_line_option:platforms": [target_platform],
        "//flutter/settings:apple_backend": "xtool",
    }

xtool_macos_transition = transition(
    implementation = _xtool_macos_transition_impl,
    inputs = [
        "//command_line_option:platforms",
    ],
    outputs = [
        "//command_line_option:platforms",
        "//flutter/settings:apple_backend",
    ],
)

def xtool_target_arch(ctx):
    """Returns the Darwin target architecture (`"arm64"` or `"x86_64"`).

    Prefers the platform constraint, falling back to `TARGET_CPU`.

    Args:
        ctx: Rule context carrying the platform constraint and `TARGET_CPU`.

    Returns:
        `"arm64"` or `"x86_64"`.
    """
    if ctx.target_platform_has_constraint(
        ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo],
    ):
        return "x86_64"
    cpu = ctx.var.get("TARGET_CPU", "")
    if "x86_64" in cpu or "k8" in cpu:
        return "x86_64"
    return "arm64"

# -- flutter_darwin_xcframework_import -----------------------------------------

def _infer_framework_name(files, explicit_name, fallback_name):
    if explicit_name:
        return explicit_name
    for f in files:
        for segment in f.path.split("/"):
            if segment.endswith(".framework"):
                return segment[:-len(".framework")]
            if segment.endswith(".xcframework"):
                return segment[:-len(".xcframework")]
    return fallback_name

def _scan_path_segments(parts, framework_dirs, framework_search_dirs, include_dirs):
    """Index the `.framework` / `Headers` segments of one split file path."""
    for idx, part in enumerate(parts):
        if part.endswith(".framework"):
            fw_dir = "/".join(parts[:idx + 1])
            parent_dir = "/".join(parts[:idx])
            if fw_dir not in framework_dirs:
                framework_dirs.append(fw_dir)
            if parent_dir:
                framework_search_dirs[parent_dir] = True
        if part == "Headers" and idx > 0 and (
            parts[idx - 1].endswith(".framework") or
            (idx >= 3 and parts[idx - 2] == "Versions")
        ):
            include_dirs["/".join(parts[:idx + 1])] = True

def _scan_framework_search_paths(files):
    """Index framework dirs, headers and include dirs across every file path."""
    framework_dirs = []
    headers = []
    include_dirs = {}
    framework_search_dirs = {}

    for f in files:
        path = f.path
        if f.is_directory and (path.endswith(".framework") or path.endswith(".xcframework")):
            if path not in framework_dirs:
                framework_dirs.append(path)

        parts = path.split("/")
        _scan_path_segments(parts, framework_dirs, framework_search_dirs, include_dirs)

        if path.endswith(".h"):
            headers.append(f)
    return framework_dirs, headers, include_dirs, framework_search_dirs

def _choose_framework_slice(framework_dirs, target_arch, is_simulator, files):
    """Prefer a slice matching simulator vs device when several exist in an xcframework."""
    chosen_dir = ""
    if framework_dirs:
        chosen_dir = framework_dirs[0]
        for candidate in framework_dirs:
            lower = candidate.lower()
            if is_simulator and "simulator" in lower:
                chosen_dir = candidate
                break
            if not is_simulator and "ios-" in lower and "simulator" not in lower:
                chosen_dir = candidate
                break
            if "macos-" in lower:
                chosen_dir = candidate
                break
            if target_arch and target_arch in lower and "simulator" not in lower:
                chosen_dir = candidate

    if not chosen_dir and files:
        chosen_dir = files[0].dirname
    return chosen_dir

def _select_framework_dir_and_headers(files, target_arch, is_simulator):
    framework_dirs, headers, include_dirs, framework_search_dirs = _scan_framework_search_paths(files)
    chosen_dir = _choose_framework_slice(framework_dirs, target_arch, is_simulator, files)
    return chosen_dir, headers, include_dirs.keys(), framework_search_dirs.keys()

def _flutter_darwin_xcframework_import_impl(ctx):
    all_files = ctx.files.xcframework_imports
    target_arch = xtool_target_arch(ctx)
    is_simulator = (target_arch == "x86_64") and ("ios" in ctx.bin_dir.path)

    framework_name = _infer_framework_name(
        all_files,
        ctx.attr.framework_name,
        ctx.label.name,
    )
    framework_dir, headers, include_dirs, fw_search_dirs = _select_framework_dir_and_headers(
        all_files,
        target_arch,
        is_simulator,
    )

    cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(
            headers = depset(headers),
            includes = depset(include_dirs),
            framework_includes = depset(fw_search_dirs),
        ),
    )

    return [
        DefaultInfo(files = depset(all_files)),
        cc_info,
        FlutterDarwinFrameworkInfo(
            framework_name = framework_name,
            framework_files = depset(all_files),
            framework_dir = framework_dir,
            headers = depset(headers),
            is_dynamic = ctx.attr.is_dynamic,
        ),
    ]

# rule_test_coverage: no-actions
flutter_darwin_xcframework_import = rule(
    implementation = _flutter_darwin_xcframework_import_impl,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        {
            "xcframework_imports": attr.label_list(
                allow_files = True,
                mandatory = True,
                doc = "Files comprising the .xcframework or .framework bundle.",
            ),
            "framework_name": attr.string(
                default = "",
                doc = "Explicit framework name (e.g. 'Flutter' or 'FlutterMacOS'). Inferred when omitted.",
            ),
            "is_dynamic": attr.bool(
                default = True,
                doc = "Whether the imported framework is a dynamic framework.",
            ),
        },
    ),
    provides = [
        DefaultInfo,
        CcInfo,
        FlutterDarwinFrameworkInfo,
    ],
    doc = "Host-agnostic Darwin .xcframework / .framework import rule for the xtool backend.",
)
