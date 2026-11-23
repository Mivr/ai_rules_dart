"""Aggregates Apple plugin libraries from a Flutter application's
transitive dep graph into a single CcInfo + SwiftInfo target so the
runner's swift_library or xtool runner compilation can depend on it.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_cc//cc/common:objc_info.bzl", "ObjcInfo", "new_objc_provider")
load("@rules_swift//swift:swift.bzl", "SwiftInfo", "swift_clang_module_aspect")
load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterApplicationInfo")

visibility(["//flutter/..."])

def _append_unique(acc, values):
    """Appends each value not already present, preserving first-seen order."""
    for value in values:
        if value not in acc:
            acc.append(value)

def _collect_apple_plugin_inputs(entries, target_platform):
    """Collects CcInfo/SwiftInfo/files/SDK-link inputs for one platform."""
    cc_infos = []
    swift_infos = []
    files = []
    sdk_frameworks = []
    sdk_dylibs = []
    framework_infos = []
    for entry in entries:
        if entry.platform != target_platform:
            continue
        if entry.cc_info:
            cc_infos.append(entry.cc_info)
        if entry.swift_info:
            swift_infos.append(entry.swift_info)
        if hasattr(entry, "files") and entry.files:
            files.append(entry.files)
        if hasattr(entry, "sdk_frameworks") and entry.sdk_frameworks:
            _append_unique(sdk_frameworks, entry.sdk_frameworks)
        if hasattr(entry, "sdk_dylibs") and entry.sdk_dylibs:
            _append_unique(sdk_dylibs, entry.sdk_dylibs)
        if getattr(entry, "framework_infos", None) != None:
            framework_infos.append(entry.framework_infos)
    return struct(
        cc_infos = cc_infos,
        swift_infos = swift_infos,
        files = files,
        sdk_frameworks = sdk_frameworks,
        sdk_dylibs = sdk_dylibs,
        framework_infos = framework_infos,
    )

def _flutter_apple_plugins_aggregator_impl(ctx):
    flutter_info = ctx.attr.application[FlutterApplicationInfo]
    target_platform = ctx.attr.platform

    collected = _collect_apple_plugin_inputs(flutter_info.apple_plugin_libraries.to_list(), target_platform)

    return [
        DefaultInfo(files = depset(transitive = collected.files)),
        cc_common.merge_cc_infos(cc_infos = collected.cc_infos),
        SwiftInfo(swift_infos = collected.swift_infos),
        FlutterApplePluginInfo(
            module_name = "",
            platform = target_platform,
            swift_srcs = depset(),
            objc_srcs = depset(),
            headers = depset(),
            modulemap = None,
            sdk_frameworks = tuple(collected.sdk_frameworks),
            sdk_dylibs = tuple(collected.sdk_dylibs),
            framework_infos = depset(transitive = collected.framework_infos),
        ),
    ]

# rule_test_coverage: no-actions
flutter_apple_plugins_aggregator = rule(
    implementation = _flutter_apple_plugins_aggregator_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target whose transitive deps carry " +
                  "Apple plugin libraries via FlutterApplicationInfo.apple_plugin_libraries.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "platform": attr.string(
            doc = "Target platform: 'macos' or 'ios'.",
            mandatory = True,
            values = ["macos", "ios"],
        ),
    },
    doc = "Merges transitive Apple plugin libraries from a flutter_application " +
          "into a single CcInfo + SwiftInfo target the runner can depend on.",
)

# -- Mixed Swift + Objective-C plugins -----------------------------------------
#
# A mixed plugin has two halves that cannot be each other's dep: the ObjC half
# compiles against the Swift half's generated header, so the Swift half cannot
# also depend on the ObjC implementation. The public target is therefore a
# merge of both, carrying the same providers a single-layer plugin does.

def _flutter_apple_plugin_bundle_impl(ctx):
    """Merge the Swift and ObjC halves into the public plugin target."""
    cc_infos = []
    objc_infos = []
    swift_infos = []
    dep_files = []
    framework_infos = []
    for dep in ctx.attr.deps + ctx.attr.clang_module_deps:
        if FlutterApplePluginInfo in dep and getattr(dep[FlutterApplePluginInfo], "framework_infos", None) != None:
            framework_infos.append(dep[FlutterApplePluginInfo].framework_infos)
        if CcInfo in dep:
            cc_infos.append(dep[CcInfo])
        if ObjcInfo in dep:
            objc_infos.append(dep[ObjcInfo])
        if SwiftInfo in dep:
            swift_infos.append(dep[SwiftInfo])
        dep_files.append(dep[DefaultInfo].files)

    return [
        DefaultInfo(files = depset(transitive = dep_files)),
        cc_common.merge_cc_infos(cc_infos = cc_infos),
        new_objc_provider(providers = objc_infos),
        SwiftInfo(direct_swift_infos = swift_infos),
        FlutterApplePluginInfo(
            module_name = ctx.attr.module_name,
            platform = ctx.attr.platform,
            swift_srcs = depset(ctx.files.swift_srcs),
            objc_srcs = depset(ctx.files.objc_srcs),
            headers = depset(ctx.files.headers),
            modulemap = None,
            sdk_frameworks = tuple(ctx.attr.sdk_frameworks),
            sdk_dylibs = tuple(ctx.attr.sdk_dylibs),
            framework_infos = depset(transitive = framework_infos),
        ),
    ]

flutter_apple_plugin_bundle = rule(
    implementation = _flutter_apple_plugin_bundle_impl,
    attrs = {
        "clang_module_deps": attr.label_list(
            aspects = [swift_clang_module_aspect],
            default = [],
            doc = "C-family dependencies whose Clang module SwiftInfo must be synthesized.",
        ),
        "deps": attr.label_list(
            default = [],
            doc = "The Swift library and the ObjC implementation library to merge.",
        ),
        "headers": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Plugin header files reported to FlutterApplePluginInfo.",
        ),
        "module_name": attr.string(
            default = "",
            doc = "Swift/Clang module name reported to FlutterApplePluginInfo.",
        ),
        "objc_srcs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Objective-C/C++ source files reported to FlutterApplePluginInfo.",
        ),
        "platform": attr.string(
            default = "macos",
            doc = "Target Apple platform ('ios' or 'macos').",
            values = ["macos", "ios"],
        ),
        "sdk_dylibs": attr.string_list(
            default = [],
            doc = "Apple SDK dynamic libraries reported to FlutterApplePluginInfo.",
        ),
        "sdk_frameworks": attr.string_list(
            default = [],
            doc = "Apple SDK frameworks reported to FlutterApplePluginInfo.",
        ),
        "swift_srcs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Swift source files reported to FlutterApplePluginInfo.",
        ),
    },
    provides = [
        DefaultInfo,
        CcInfo,
        ObjcInfo,
        SwiftInfo,
        FlutterApplePluginInfo,
    ],
    doc = "Merges the Swift and ObjC halves of a mixed Apple plugin " +
          "into the public target's DefaultInfo, CcInfo, ObjcInfo, SwiftInfo and " +
          "FlutterApplePluginInfo.",
)
