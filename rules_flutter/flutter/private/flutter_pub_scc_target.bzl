"""Per-member public target rule for merged SCC spoke repositories.

A merged spoke combines strongly connected components of pub packages into a
single repository. Each `flutter_pub_scc_member_target` exposes the merged
`DartInfo` (and `DartKernelInfo`), `dart:ui`-aware `DartAnalyzableInfo`, and
the combined `FlutterInfo` across all cycle members and outside dependencies.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartKernelInfo")
load("@rules_dart//dart:utils.bzl", "dart_analyzable_info")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_info.bzl", "flutter_info")
load("//flutter/private:flutter_library.bzl", "SKY_ENGINE_ATTR")

visibility(["//flutter/..."])

def _flutter_pub_scc_member_target_impl(ctx):
    """Forwards merged Dart providers and combines SCC + outside FlutterInfo."""
    if not ctx.attr.package_name:
        fail("%s: package_name must be non-empty on merged SCC member targets" % ctx.label)
    if not ctx.attr.srcs_dir:
        fail("%s: srcs_dir must be non-empty on merged SCC member targets" % ctx.label)
    providers = [
        DefaultInfo(
            files = ctx.attr.library[DefaultInfo].files,
            runfiles = ctx.attr.library[DefaultInfo].default_runfiles,
        ),
        ctx.attr.library[DartInfo],
        dart_analyzable_info(deps = [ctx.attr.library, ctx.attr._sky_engine]),
        flutter_info(deps = ctx.attr.scc_members + ctx.attr.deps),
    ]
    if DartKernelInfo in ctx.attr.library:
        providers.append(ctx.attr.library[DartKernelInfo])
    return providers

flutter_pub_scc_member_target = rule(
    implementation = _flutter_pub_scc_member_target_impl,
    attrs = {
        "package_name": attr.string(
            mandatory = True,
            doc = "The member package name.",
        ),
        "library": attr.label(
            mandatory = True,
            providers = [DartInfo],
            doc = "The merged multi-package `dart_library` target.",
        ),
        "scc_members": attr.label_list(
            default = [],
            providers = [FlutterInfo],
            doc = "The per-member `_flutter_info` targets across the SCC.",
        ),
        "deps": attr.label_list(
            default = [],
            providers = [DartInfo],
            doc = "Dependencies leaving the SCC.",
        ),
        "srcs_dir": attr.string(
            default = ".",
            doc = "Marks multi-package targets opaque to single-package modular Flutter kernel compilation.",
        ),
        "_sky_engine": SKY_ENGINE_ATTR,
    },
    doc = "Per-member public target for a merged SCC spoke.",
)
