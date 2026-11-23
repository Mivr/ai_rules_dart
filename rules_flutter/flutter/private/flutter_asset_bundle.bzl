"""Flutter asset bundle generation.

Produces a `flutter_assets/` tree artifact containing:
- AssetManifest.bin  (StandardMessageCodec binary manifest)
- FontManifest.json  (font family declarations)
- NOTICES.Z          (gzip-compressed license text)
- Copied asset files (images, etc.)
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("//flutter/private:asset_keys.bzl", "bundle_asset_entries")
load(
    "//flutter/private:common.bzl",
    "check_bundle_claims",
    "flutter_compile_shaders",
    "flutter_tester_shader_aspect",
)
load(
    "//flutter/private:flutter_asset_bundle_action.bzl",
    "flutter_asset_bundle_action",
    "make_bundle_content",
    "make_tree_shake",
    _build_asset_manifest = "build_asset_manifest",
    _detect_dpr = "detect_dpr",
)
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions")

visibility(["//flutter/..."])

_TOOL = Label("//flutter/private/tools:generate_asset_manifest")

# Re-exported from `//flutter/private:flutter_asset_bundle_action.bzl`, where the
# manifest helpers live next to the action that consumes them. Kept under
# these names so existing loads keep working.
build_asset_manifest = _build_asset_manifest
detect_dpr = _detect_dpr

def _flutter_asset_bundle_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    # Collect keyed assets: the bundle's own, rooted at its Bazel package,
    # plus every dependency's, each already keyed by the target that listed
    # it and carried through `FlutterInfo.assets`.
    all_entries = bundle_asset_entries(ctx.label, ctx.files.assets, ctx.attr.deps)

    # Walk pub-package font/asset contributions from FlutterInfo. To get
    # MaterialIcons in the bundle, list `@rules_flutter//flutter:material_icons`
    # in deps — the same channel cupertino_icons et al. arrive through.
    # The pub claims ride the same list as the shader claims, in bundle
    # order, for the one cross-channel key check. Data assets are not read
    # here: this tree ships none, so only `flutter_build_assets`
    # (applications and tests) claims that channel.
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, "tester")
    extra_claims = [struct(key = dest, file = f, channel = "shader") for dest, f in compiled_shaders.items()]
    fonts, pub_extra_asset_copies = aggregate_pub_contributions(
        ctx.attr.deps,
        "tester",
        extra_claims,
    )

    # Shaders compiled for `flutter_tester`, as `flutter test` compiles them
    # (SkSL for Skia, Vulkan for Impeller): the target's own `shaders` plus
    # the SDK, package and dep shaders the tester aspect compiled on the
    # owning targets. Without these a `flutter_prebuilt_test` over this tree
    # cannot draw what the `flutter_test` it was split from drew.
    extra_asset_copies = dict(compiled_shaders)
    extra_asset_copies.update(pub_extra_asset_copies)

    check_bundle_claims(struct(label = ctx.label, deps = ctx.attr.deps), all_entries, extra_claims)

    output_dir = flutter_asset_bundle_action(
        ctx = ctx,
        content = make_bundle_content(
            assets = all_entries,
            fonts = fonts,
            license_files = ctx.files.license_files,
            extra_asset_copies = extra_asset_copies,
        ),
        shaking = make_tree_shake(),
        output_dir = ctx.actions.declare_directory(ctx.label.name),
    )

    return [DefaultInfo(files = depset([output_dir]))]

flutter_asset_bundle = rule(
    implementation = _flutter_asset_bundle_impl,
    attrs = {
        "assets": attr.label_list(
            doc = "Asset files to include in the bundle.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "Flutter library dependencies whose assets to include. " +
                  "Shaders owned by these deps are compiled for " +
                  "`flutter_tester` and bundled, so list the same deps a " +
                  "`flutter_test` over this tree would.",
            providers = [DartInfo],
            aspects = [flutter_tester_shader_aspect],
        ),
        "shaders": attr.label_list(
            doc = "Fragment shader files (.frag) to compile with impellerc " +
                  "for `flutter_tester` and include in the asset bundle, as " +
                  "`flutter_test` compiles its own `shaders`.",
            allow_files = [".frag", ".glsl"],
        ),
        "shader_includes": attr.label_list(
            doc = "Files the `shaders` may `#include`. A shader compiles in a " +
                  "sandbox holding only its declared inputs, so an include not " +
                  "listed here is not found.",
            allow_files = True,
        ),
        "require_sksl_shaders": attr.bool(
            doc = "Fail the build when a shader cannot be compiled for Skia " +
                  "(SkSL). By default such a shader is compiled for Impeller " +
                  "alone with a warning, as `flutter build` does.",
            default = False,
        ),
        "license_files": attr.label_list(
            doc = "License/NOTICE files to include in NOTICES.Z. Typically LICENSE files from dependencies.",
            allow_files = True,
        ),
        "_asset_bundle_tool": attr.label(
            doc = "Tool that renders the asset manifest for the bundle.",
            default = _TOOL,
            executable = True,
            cfg = "exec",
        ),
        "_const_finder_tool": attr.label(
            doc = "Tool that extracts used icon code points from kernel dills.",
            default = Label("//flutter/private/tools:const_finder"),
            executable = True,
            cfg = "exec",
        ),
        "_shader_compile_tool": attr.label(
            doc = "Shader compiler for the bundle's shaders.",
            default = Label("//flutter/private/tools:compile_shader"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "Generates a flutter_assets/ tree artifact with manifests and asset files. Always bundles for the `tester` platform: pub-asset platform and flavor conditions and shader targets are the tester's.",
)
