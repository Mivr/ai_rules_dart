"""Bridge a prebuilt Apple framework's Clang module map into `CcInfo` headers.

`rules_apple`'s framework import rules keep `Modules/module.modulemap` out of
`CcInfo.compilation_context.headers`; only `rules_swift` sees it, through the
`SwiftInfo` its aspect synthesizes. A sandboxed `objc_library` compile stages
`CcInfo` headers only, so `@import Flutter;` fails with `module 'Flutter' not
found`. `apple_framework_modulemap_import` wraps one import rule, reads the
module maps from that synthesized `SwiftInfo`, and adds them to the headers
while forwarding every other provider unchanged.
"""

load("@rules_apple//apple:providers.bzl", "AppleDynamicFrameworkInfo", "AppleFrameworkImportInfo")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_cc//cc/common:objc_info.bzl", "ObjcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo", "swift_clang_module_aspect")

visibility(["//flutter/..."])

_OPTIONAL_PROVIDERS = [AppleDynamicFrameworkInfo, ObjcInfo, SwiftInfo, OutputGroupInfo]

def _module_maps(dep):
    """Return the `.modulemap` files the aspect-synthesized `SwiftInfo` carries.

    Args:
        dep: The wrapped import target.

    Returns:
        A list of module map `File`s; empty when `dep` has no `SwiftInfo`.
    """
    if SwiftInfo not in dep:
        return []
    return [
        module.clang.module_map
        for module in dep[SwiftInfo].direct_modules
        if module.clang and module.clang.module_map and type(module.clang.module_map) == "File"
    ]

def _apple_framework_modulemap_import_impl(ctx):
    dep = ctx.attr.dep
    module_maps = _module_maps(dep)
    cc_info = dep[CcInfo]
    if module_maps:
        extra_cc = CcInfo(
            compilation_context = cc_common.create_compilation_context(headers = depset(module_maps)),
        )
        cc_info = cc_common.merge_cc_infos(direct_cc_infos = [extra_cc], cc_infos = [cc_info])
    providers = [
        DefaultInfo(files = dep[DefaultInfo].files),
        dep[AppleFrameworkImportInfo],
        cc_info,
    ]
    for provider in _OPTIONAL_PROVIDERS:
        if provider in dep:
            providers.append(dep[provider])
    return providers

apple_framework_modulemap_import = rule(
    implementation = _apple_framework_modulemap_import_impl,
    attrs = {
        "dep": attr.label(
            mandatory = True,
            providers = [AppleFrameworkImportInfo, CcInfo],
            aspects = [swift_clang_module_aspect],
            doc = "The `rules_apple` framework import target whose module maps are bridged.",
        ),
    },
    doc = "Re-exposes a framework import with its `.modulemap` files in `CcInfo` headers.",
)
