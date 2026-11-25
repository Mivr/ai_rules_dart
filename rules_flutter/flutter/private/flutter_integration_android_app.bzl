"""Android app helpers for the `flutter_integration_test` macro.

Moved out of `flutter_integration_test.bzl` so iOS support can extend that
file without growing it.
"""

load(
    "//flutter/private:common.bzl",
    "collect_define_flagfiles",
    "merge_dart_defines",
)
load(
    "//flutter/private:flutter_compile.bzl",
    "flutter_kernel_compile_action",
    "flutter_kernel_dills",
    "flutter_kernel_options",
    "flutter_kernel_outputs",
    "flutter_kernel_sources",
)
load(
    "//flutter/private:flutter_integration_test_common.bzl",
    "integration_test_kernel",
)

visibility(["//flutter/..."])

def android_integration_app_kernel(ctx, setup, sources, native_assets, recorded_uses = None):
    """Compiles the Android integration-test app kernel, including `defines_files`.

    Args:
      ctx: The rule context of `_flutter_android_integration_app`.
      setup: The `_android_integration_app_setup` struct.
      sources: The `_android_integration_app_sources` struct.
      native_assets: The `integration_test_native_assets` struct.
      recorded_uses: The File the compile records its uses to, or None.

    Returns:
      The compiled kernel `.dill` File.
    """
    if not ctx.files.defines_files:
        return integration_test_kernel(ctx, setup.sdk, sources, native_assets, setup.aot, setup.mode, recorded_uses)
    is_release_aot = setup.aot and setup.mode == "release"
    platform_dill = setup.sdk.platform_kernel_dill_product if is_release_aot else setup.sdk.platform_kernel_dill
    if platform_dill == None:
        return integration_test_kernel(ctx, setup.sdk, sources, native_assets, setup.aot, setup.mode, recorded_uses)
    user_defines = merge_dart_defines(ctx)
    flagfiles = collect_define_flagfiles(ctx, user_defines)
    defines = list(user_defines)
    if setup.mode == "profile":
        defines.append("dart.vm.profile=true")
    elif setup.aot:
        defines.append("dart.vm.product=true")
    extra_flags = ["--track-widget-creation"] if ctx.attr.track_widget_creation and setup.mode != "release" else []
    registrant_uri = sources.registrant_location.uri if sources.registrant_location else None
    tools = struct(
        dartaotruntime = setup.sdk.dartaotruntime,
        frontend_server = setup.sdk.frontend_server,
        kernel_filter_tool = ctx.executable._kernel_filter_tool,
        platform_dill = platform_dill,
    )
    kernel_sources = flutter_kernel_sources(
        dart_plugin_registrant_uri = registrant_uri,
        entrypoint_uri = sources.bootstrap_location.uri,
        main = sources.bootstrap,
        native_assets_manifest = native_assets.manifest,
        package_config = sources.package_config.config_file,
        srcs = sources.package_config.srcs,
    )
    options = flutter_kernel_options(
        aot = setup.aot,
        define_flagfiles = flagfiles,
        defines = defines,
        extra_flags = extra_flags,
        target = "flutter",
    )
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx,
        tools,
        kernel_sources,
        flutter_kernel_outputs(output = dill, recorded_uses = recorded_uses),
        options,
        flutter_kernel_dills(),
    )
    return dill

ANDROID_APP_KWARG_KEYS = (
    "srcs",
    "main",
    "app_srcs",
    "pubspec",
    "pubspec_srcs",
    "pub_packages",
    "asset_transformers",
    "build_name",
    "build_number",
    "tree_shake_icons",
    "track_widget_creation",
    "profile",
    "language_version",
    "defines",
    "defines_files",
    "native_deps",
    "flavor",
)
