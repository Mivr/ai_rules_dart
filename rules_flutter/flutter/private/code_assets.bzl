"""The code assets of a Flutter app: the native-assets manifest and bundled libraries.

Every package's build hook runs in rules_dart (`declare_hooks` /
`register_hook_actions`), and its output directory rides the package record.
An application, test or integration test turns the closure's outputs into the
mapping the frontend_server embeds (`--native-assets`) and one directory of
the libraries to bundle, through rules_dart's `native_assets_manifest`: one
action, which reads each hook's output with `package:hooks_runner`'s own
types. This replaces the asset bundle step flutter_tools runs
(`installCodeAssets`); T32's program on `package:flutter_tools` is not on
`next`, so the step is rules_dart's.

How the manifest names a bundled library is flutter_tools': the bare file
name on Android, Linux, Windows and macOS (the loader finds it beside the app's
other libraries), `<name>.framework/<name>` on iOS, and the path under the
runfiles root for a `flutter_test`, which runs out of Bazel's runfiles.
"""

load("@rules_dart//dart:utils.bzl", "APPLE_HOOK_OSES", "HOOK_TARGET_ATTRS", "NATIVE_ASSETS_APP_ATTRS", "collect_native_assets", "hook_target", "native_assets_manifest")
load("//flutter:providers.bzl", "FlutterInfo")

visibility(["//flutter/..."])

# What a rule that writes the manifest adds to its `attrs`.
FLUTTER_CODE_ASSETS_ATTRS = NATIVE_ASSETS_APP_ATTRS | HOOK_TARGET_ATTRS

# As the Flutter tool writes a manifest with no assets.
_EMPTY_MANIFEST = json.encode({"format-version": [1, 0, 0], "native-assets": {}})

def _style(target_os):
    return "framework" if target_os == "ios" else "basename"

def flutter_code_assets(ctx, runfiles = False):
    """Writes the native-assets manifest of `ctx.attr.deps` and bundles their libraries.

    Args:
      ctx: A rule context with `deps`, `FLUTTER_CODE_ASSETS_ATTRS` and the
        exec tools toolchain.
      runfiles: Whether the program runs out of runfiles (a `flutter_test`)
        rather than from a platform bundle.

    Returns:
      `struct(manifest, bundled, any, data_assets)`: the manifest File; a
      list holding the bundle directory (empty when nothing is bundled), or
      on macOS and iOS the code-asset libraries themselves;
      whether the closure has any code assets (a debug entry module embeds
      the manifest only then); and the closure's `flutter_data_asset`s.
    """
    assets = collect_native_assets(ctx.attr.deps)
    data_assets = depset(transitive = [dep[FlutterInfo].data_assets for dep in ctx.attr.deps if FlutterInfo in dep])
    if not assets:
        manifest = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
        ctx.actions.write(manifest, _EMPTY_MANIFEST)
        return struct(manifest = manifest, bundled = [], any = False, data_assets = data_assets)
    target = hook_target(ctx)
    if not target.os or not target.arch:
        fail("%s: the closure has code assets, and the target platform has no OS or CPU the hook protocol knows." % ctx.label)
    if runfiles:
        prefix = "../%s/" % ctx.label.workspace_name if ctx.label.workspace_name else ""
        if ctx.label.package:
            prefix += ctx.label.package + "/"
        result = native_assets_manifest(
            ctx,
            assets,
            "%s_%s" % (target.os, target.arch),
            ctx.label.name,
            style = "runfiles",
            runfiles_prefix = prefix + ctx.label.name + ".native_assets/",
            format = "flutter",
        )
    elif target.os in APPLE_HOOK_OSES:
        # Build hooks do not run on Apple OSes yet (their actions fail, naming
        # the package), so every library here is a `dart_code_asset`'s, a File
        # known now: the iOS and macOS rules embed each as they embed
        # `native_libs` (an iOS framework, `Contents/Frameworks`). Goes with
        # `APPLE_HOOK_OSES`.
        result = native_assets_manifest(
            ctx,
            assets,
            "%s_%s" % (target.os, target.arch),
            ctx.label.name,
            style = _style(target.os),
            bundle = False,
            format = "flutter",
        )
        return struct(
            manifest = result.manifest,
            # lint-allow: depset-flatten terminal: an Apple app embeds each code-asset library by name
            bundled = [f for f in assets.to_list() if not f.is_directory and not f.basename.endswith(".json")],
            any = True,
            data_assets = data_assets,
        )
    else:
        result = native_assets_manifest(
            ctx,
            assets,
            "%s_%s" % (target.os, target.arch),
            ctx.label.name,
            style = _style(target.os),
            format = "flutter",
        )
    return struct(
        manifest = result.manifest,
        bundled = [result.bundle],
        any = True,
        data_assets = data_assets,
    )

def native_asset_framework_name(filename):
    """Derive the framework name for a bundled native-asset dylib on Apple.

    Mirrors flutter_tools' `frameworkUri` (native_assets_host.dart): strip a
    trailing `.dylib`, drop a leading `lib`, and sanitize to `[A-Za-z0-9_-]`.
    iOS embeds each `dynamic_loading_bundle` dylib as `<name>.framework/<name>`.
    The hook runner's manifest (`frameworkName`) names a code asset the same
    way; this one names the `native_deps` libraries an iOS app wraps.

    Args:
      filename: The dylib's basename (e.g. `objective_c.dylib`).

    Returns:
      The sanitized framework name (e.g. `objective_c`).
    """
    name = filename
    if name.endswith(".dylib"):
        name = name[:-len(".dylib")]
        if name.startswith("lib"):
            name = name[len("lib"):]
    sanitized = ""
    for c in name.elems():
        if c.isalnum() or c == "_" or c == "-":
            sanitized += c
    return sanitized
