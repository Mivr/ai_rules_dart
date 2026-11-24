"""Hermetic Apple framework import and application bundle rules for the `xtool` backend.

Provides:
  - `flutter_darwin_xcframework_import`: Host-agnostic `.xcframework` /
    `.framework` import rule returning `DefaultInfo`, `CcInfo`, and
    `FlutterDarwinFrameworkInfo` without depending on `@rules_apple`.
  - `flutter_xtool_ios_bundle`: Assembles an unsigned `.ipa`
    (`Payload/<App>.app`) using `//flutter/private/tools:xtool_pack` without
    Xcode, or signs it when `zsign` is provided.
  - `flutter_xtool_macos_bundle`: Assembles an unsigned `.app.zip`
    (`<App>.app/Contents/...`) using `//flutter/private/tools:xtool_pack`
    without Xcode, or signs it when `zsign` is provided.

The version rule lives in `flutter/private/xtool_version.bzl`, the framework
import and platform transitions in `flutter/private/xtool_import.bzl`, and the
bundle action in `flutter/private/flutter_xtool_bundle_pack.bzl`; this file
keeps the shared bundle attributes with the two bundle rules and re-exports
the moved rule names.
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load(":constants.bzl", "IOS_MINIMUM_OS_VERSION", "MACOS_MINIMUM_OS_VERSION")
load(":flutter_xtool_bundle_pack.bzl", "run_xtool_pack_bundle")
load(":xtool_import.bzl", "xtool_ios_transition", "xtool_macos_transition", "xtool_target_arch", _flutter_darwin_xcframework_import = "flutter_darwin_xcframework_import")
load(":xtool_version.bzl", _flutter_xtool_bundle_version = "flutter_xtool_bundle_version")

visibility(["//flutter/..."])

# Re-exported for flutter_apple_plugin_library.bzl, flutter/ios.bzl,
# flutter/macos.bzl and the bundling tests, which load them from this file.
flutter_darwin_xcframework_import = _flutter_darwin_xcframework_import
flutter_xtool_bundle_version = _flutter_xtool_bundle_version

# -- flutter_xtool_ios_bundle --------------------------------------------------

def _flutter_xtool_ios_bundle_impl(ctx):
    if not ctx.attr.families:
        fail(
            "%s: 'families' must not be empty; expected one or more of 'iphone', 'ipad'." % ctx.label,
        )
    for fam in ctx.attr.families:
        if fam not in ("iphone", "ipad"):
            fail(
                "%s: invalid device family %r in 'families'; expected 'iphone' or 'ipad'." % (
                    ctx.label,
                    fam,
                ),
            )

    target_arch = xtool_target_arch(ctx)
    is_sim = (target_arch == "x86_64") or (ctx.var.get("COMPILATION_MODE", "") == "dbg")
    platform = "ios_sim" if is_sim else "ios"
    return run_xtool_pack_bundle(
        ctx,
        platform = platform,
        archive_ext = ".ipa",
        mnemonic = "FlutterXtoolIosBundle",
        families = ctx.attr.families,
    )

_COMMON_BUNDLE_ATTRS = {
    "app_name": attr.string(
        default = "",
        doc = "Application bundle name (`<app_name>.app`). Defaults to the target name.",
    ),
    "bundle_id": attr.string(
        mandatory = True,
        doc = "Bundle identifier (e.g. `com.example.app`).",
    ),
    "version": attr.label(
        allow_files = True,
        doc = "Optional version target (such as `apple_bundle_version`, `flutter_xtool_bundle_version`, or a JSON file with `build_version` and `short_version_string`).",
    ),
    "invalid_version_error": attr.string(
        default = "",
        doc = "Internal validation error message when `version` references an unsupported target.",
    ),
    "build_version": attr.string(
        default = "",
        doc = "Optional explicit `CFBundleVersion` (`FLUTTER_BUILD_NUMBER`) override.",
    ),
    "short_version": attr.string(
        default = "",
        doc = "Optional explicit `CFBundleShortVersionString` (`FLUTTER_BUILD_NAME`) override.",
    ),
    "defines": attr.string_dict(
        default = {},
        doc = "Optional variable substitutions (`KEY: VALUE`) applied when merging `Info.plist` files.",
    ),
    "env": attr.string_dict(
        default = {},
        doc = "Optional explicit environment variables set on the `xtool_pack` bundle action.",
    ),
    "infoplists": attr.label_list(
        allow_files = [".plist"],
        default = [],
        doc = "List of `Info.plist` files to merge and variable-substitute into the bundle.",
    ),
    "executable": attr.label(
        allow_single_file = True,
        doc = "Optional pre-compiled Mach-O main executable binary. When omitted, `FlutterXtoolRunner` compiles/synthesizes the runner from `srcs`, `registrant`, `plugins`, and `deps`.",
    ),
    "srcs": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Runner Swift/ObjC source files compiled by `FlutterXtoolRunner` when `executable` is omitted.",
    ),
    "registrant": attr.label(
        allow_files = True,
        doc = "GeneratedPluginRegistrant target compiled into the runner.",
    ),
    "plugins": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Apple plugin aggregator or plugin library targets linked into the runner.",
    ),
    "deps": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Additional runner library targets.",
    ),
    "require_sdk": attr.bool(
        default = False,
        doc = "When True, fails at analysis with a named error if `@flutter_xtool_darwin_sdk` is not configured.",
    ),
    "_xtool_sdk_status": attr.label(
        default = Label("@flutter_xtool_darwin_sdk//:sdk_status"),
        doc = "The `@flutter_xtool_darwin_sdk` status target carrying `FlutterXtoolSdkInfo`.",
    ),
    "frameworks": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Framework targets (`FlutterDarwinFrameworkInfo` or `.framework`/`.xcframework` files) to embed in `Frameworks/`.",
    ),
    "resources": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Additional pre-compiled resource files or directories to copy into the bundle (`ibtool`/`actool` sources like `.storyboard`, `.xib`, and `.xcassets` are rejected at analysis).",
    ),
    "additional_contents": attr.label_keyed_string_dict(
        allow_files = True,
        default = {},
        doc = "Mapping of file/directory targets to relative bundle subdirectories (e.g. `{\":helper\": \"PlugIns\"}`).",
    ),
    "app_icons": attr.label_list(
        allow_files = True,
        default = [],
        doc = "Asset catalog icon files. Rejected at analysis on the `xtool` backend because `actool` is not hermetically available.",
    ),
    "provisioning_profile": attr.label(
        allow_single_file = True,
        doc = "Optional `.mobileprovision` file to embed as `embedded.mobileprovision`.",
    ),
    "entitlements": attr.label(
        allow_single_file = [".plist", ".entitlements"],
        doc = "Optional entitlements plist passed to `zsign` when signing.",
    ),
    "zsign": attr.label(
        executable = True,
        cfg = "exec",
        doc = "Optional `zsign` executable for cryptographic code signing.",
    ),
    "certificate": attr.label(
        allow_single_file = True,
        doc = "Optional signing certificate (`.p12` or `.pem`) for `zsign`.",
    ),
    "certificate_password_file": attr.label(
        allow_single_file = True,
        doc = "Optional file containing the password for `certificate`. Read at execution time by `xtool_pack` so the secret never appears on action command lines.",
    ),
    "certificate_password_env": attr.string(
        default = "",
        doc = "Optional environment variable name holding the password for `certificate`, read at execution time from the action's declared `env` by `xtool_pack`.",
    ),
    "certificate_password": attr.string(
        default = "",
        doc = "Deprecated/rejected plain-text password attribute. Setting this fails at analysis to prevent leaking secrets on command lines; use `certificate_password_file` or `certificate_password_env`.",
    ),
    "unsupported_kwargs": attr.string_list(
        default = [],
        doc = "Internal list of unsupported attribute names forwarded from macros so they fail at analysis with a named error.",
    ),
    "_xtool_pack": attr.label(
        default = Label("//flutter/private/tools:xtool_pack"),
        executable = True,
        cfg = "exec",
        doc = "The `xtool_pack` host tool performing bundle assembly.",
    ),
    "_allowlist_function_transition": attr.label(
        default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
        doc = "Allowlist for the outgoing configuration transition.",
    ),
}

flutter_xtool_ios_bundle = rule(
    implementation = _flutter_xtool_ios_bundle_impl,
    cfg = xtool_ios_transition,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        _COMMON_BUNDLE_ATTRS,
        {
            "minimum_os_version": attr.string(
                default = IOS_MINIMUM_OS_VERSION,
                doc = "Minimum iOS deployment target version.",
            ),
            "families": attr.string_list(
                default = ["iphone", "ipad"],
                doc = "Supported iOS device families (`'iphone'`, `'ipad'`). Populates `UIDeviceFamily` in `Info.plist`.",
            ),
            "launch_storyboard": attr.label(
                allow_single_file = True,
                doc = "Launch storyboard file. Rejected at analysis on the `xtool` backend because `ibtool` is not hermetically available.",
            ),
        },
    ),
    doc = "Packages an iOS application into an unsigned `.ipa` (`Payload/<App>.app`) using the host-agnostic `xtool_pack` bundler, or signs it when `zsign` is provided.",
)

# -- flutter_xtool_macos_bundle ------------------------------------------------

def _flutter_xtool_macos_bundle_impl(ctx):
    return run_xtool_pack_bundle(
        ctx,
        platform = "macos",
        archive_ext = ".app.zip",
        mnemonic = "FlutterXtoolMacosBundle",
        native_libs = ctx.files.native_libs,
    )

flutter_xtool_macos_bundle = rule(
    implementation = _flutter_xtool_macos_bundle_impl,
    cfg = xtool_macos_transition,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        _COMMON_BUNDLE_ATTRS,
        {
            "minimum_os_version": attr.string(
                default = MACOS_MINIMUM_OS_VERSION,
                doc = "Minimum macOS deployment target version.",
            ),
            "native_libs": attr.label_list(
                allow_files = True,
                default = [],
                doc = "Optional staged native dynamic libraries (`flutter_macos_native_libs`) embedded under `Contents/Frameworks/`.",
            ),
            "menu_xib": attr.label(
                allow_single_file = True,
                doc = "Main menu `.xib` file. Rejected at analysis on the `xtool` backend because `ibtool` is not hermetically available.",
            ),
        },
    ),
    doc = "Packages a macOS application into an unsigned `.app.zip` (`<App>.app/Contents/...`) using the host-agnostic `xtool_pack` bundler, or signs it when `zsign` is provided.",
)
