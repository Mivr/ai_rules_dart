"""The `platform = "android"` rules and macro helpers of `flutter_integration_test`.

Compiles the app and its in-app test, hands that Dart program to the app macro
of the pinned Gradle model (`flutter_android_app` of the pin's `defs.bzl`), and
runs the APK it builds in the hermetic headless emulator through
`flutter_integration_test_runner`. The Android side (manifest, resources,
plugins, application id) is the app's own Gradle project, as in
`flutter test integration_test`.
"""

load(
    "@rules_dart//dart:providers.bzl",
    "DartInfo",
)
load(
    "@rules_dart//dart:utils.bzl",
    "MODULAR_KERNEL_TOOLCHAINS",
    "derive_lib_root",
    "runfiles_path",
)
load(
    "//flutter:providers.bzl",
    "FlutterApplicationInfo",
)
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_location",
)
load(
    "//flutter/private:common.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "DEFINES_FILES_APPLICATION_ATTRS",
    "FLUTTER_DEPS_DOC",
    "KERNEL_COMPILE_ATTRS",
    "PLATFORM_CONSTRAINT_ATTRS",
)
load(
    "//flutter/private:flutter_integration_android_app.bzl",
    "ANDROID_APP_KWARG_KEYS",
    "android_integration_app_kernel",
)
load(
    "//flutter/private:flutter_integration_test_bootstrap.bzl",
    "make_android_integration_bootstrap_content",
)
load(
    "//flutter/private:flutter_integration_test_common.bzl",
    "COMMON_INTEGRATION_TEST_ATTRS",
    "INTEGRATION_TEST_BUILD_ATTRS",
    "integration_test_aot",
    "integration_test_assets",
    "integration_test_common_setup",
    "integration_test_dart_sources",
    "integration_test_env",
    "integration_test_native_assets",
    "integration_test_native_libs",
    "integration_test_providers",
    "integration_test_runner_executable",
)
load(
    "//flutter/private:flutter_integration_test_ios.bzl",
    "exposes_package",
    "resolve_main_and_srcs",
)
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "MODULAR_KERNEL_ATTRS",
    "flutter_kernel_module_aspect",
)
load("//flutter/private:layering_check.bzl", "LAYERING_CHECK_ASPECT", "LAYERING_CHECK_ATTRS", "LAYERING_CHECK_TOOLCHAINS")
load(
    "//flutter/private:native_sources.bzl",
    "native_sources_aspect",
)
load("//flutter/private/android_model:rules.bzl", "RdfApkInfo")

visibility(["//flutter/..."])

def _android_integration_app_setup(ctx):
    """Validates an Android app target and resolves its shared build inputs.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        An `integration_test_common_setup` struct.
    """
    setup = integration_test_common_setup(ctx)
    if not setup.is_debug and not setup.sdk.gen_snapshot:
        fail(
            "No target-compatible AOT gen_snapshot toolchain is registered for " +
            "this host and Android target platform.",
        )
    return setup

def _android_integration_app_sources(ctx, setup):
    """Generates the Android bootstrap and registrant, and its package config.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_android_integration_app_setup` struct.

    Returns:
        An `integration_test_dart_sources` struct.
    """
    main_location = app_main_location(setup.package_name, setup.lib_root, setup.main_file)
    content = make_android_integration_bootstrap_content(
        test_import = main_location.uri,
        has_integration_test = exposes_package(ctx.attr.deps, ["integration_test"]),
    )
    return integration_test_dart_sources(ctx, setup, "android", content)

def _android_integration_app_providers(ctx, setup, sources, native_assets, kernel_dill, aot_output, assets):
    """The providers a compiled Android integration-test app returns.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_android_integration_app_setup` struct.
        sources: The `_android_integration_app_sources` struct.
        native_assets: The `integration_test_native_assets` struct.
        kernel_dill: The compiled kernel File.
        aot_output: The AOT `.so` File, or None in debug mode.
        assets: The `flutter_assets` directory.

    Returns:
        The provider list.
    """
    native_libs = integration_test_native_libs(ctx)
    default_files = [
        assets,
        sources.package_config.config_file,
        native_assets.manifest,
    ] + native_libs + native_assets.bundled
    if aot_output:
        default_files.append(aot_output)
    if setup.is_debug:
        default_files.append(kernel_dill)
    return [
        DefaultInfo(files = depset(default_files)),
        FlutterApplicationInfo(
            aot_output = aot_output,
            aot_strip = setup.strip if aot_output != None else False,
            kernel_dill = kernel_dill if setup.is_debug else None,
            flutter_assets = assets,
            icu_data = setup.sdk.icu_data,
            native_libs = native_libs,
            is_debug = setup.is_debug,
            package_config = sources.package_config.config_file,
            native_assets_manifest = native_assets.manifest,
            bundled_code_assets = native_assets.bundled,
            bundled_data_assets = native_assets.data_assets,
            apple_privacy_manifests = sources.plugins.apple_privacy_manifests,
            plugins = sources.plugins.all_plugins,
            apple_plugin_libraries = sources.plugins.apple_plugin_libraries,
            linux_plugin_libraries = sources.plugins.linux_plugin_libraries,
            windows_plugin_libraries = sources.plugins.windows_plugin_libraries,
        ),
    ]

def _flutter_android_integration_app_impl(ctx):
    """Compiles the Android integration-test app and returns its application info.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        The provider list.
    """
    setup = _android_integration_app_setup(ctx)
    native_assets = integration_test_native_assets(ctx)
    sources = _android_integration_app_sources(ctx, setup)
    kernel_dill = android_integration_app_kernel(ctx, setup, sources, native_assets)
    aot_output = integration_test_aot(ctx, setup.sdk, kernel_dill, setup.is_debug, setup.strip)
    assets = integration_test_assets(
        ctx,
        setup.sdk,
        "android",
        kernel_dill,
        setup.is_debug,
        native_assets.data_assets,
    )
    return _android_integration_app_providers(ctx, setup, sources, native_assets, kernel_dill, aot_output, assets)

def _android_integration_test_setup(ctx):
    """Validates an Android test target and resolves its run inputs.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        A struct with `main_file`, `extra_srcs`, `package_name`, `lib_root`,
        `apk_file` and `android_package`.
    """
    if ctx.attr.platform != "android":
        fail(
            "%s: _flutter_android_integration_test requires platform = 'android', got %r." % (
                ctx.label,
                ctx.attr.platform,
            ),
        )

    if not exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, extra_srcs = resolve_main_and_srcs(ctx)

    return struct(
        android_package = ctx.attr.apk[RdfApkInfo].application_id,
        apk_file = ctx.attr.apk[RdfApkInfo].apk,
        extra_srcs = extra_srcs,
        lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package),
        main_file = main_file,
        package_name = ctx.attr.package_name or ctx.label.name,
    )

# Execution requirements of the Android test action (see the comment at the
# return of the impl below): `no-sandbox` stays until the cause is fixed.
ANDROID_TEST_EXECUTION_REQUIREMENTS = {"no-sandbox": ""}

def _flutter_android_integration_test_impl(ctx):
    """Runs a compiled Android integration-test APK in the headless emulator.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        The provider list.
    """
    setup = _android_integration_test_setup(ctx)
    executable = integration_test_runner_executable(ctx)
    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": "android",
        "FLUTTER_INTEGRATION_TEST_ANDROID_APK": runfiles_path(setup.apk_file, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ANDROID_PACKAGE": setup.android_package,
        "FLUTTER_INTEGRATION_TEST_ANDROID_EMULATOR": runfiles_path(ctx.file._android_emulator, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ANDROID_ADB": runfiles_path(ctx.file._android_adb, workspace_name),
        "FLUTTER_INTEGRATION_TEST_PATH": setup.main_file.short_path,
        "FLUTTER_INTEGRATION_TEST_DECLARED_ENV": json.encode(ctx.attr.env),
    }
    library_tags = integration_test_env(ctx, env, setup.main_file)
    providers = integration_test_providers(
        ctx,
        struct(
            extra_srcs = setup.extra_srcs,
            lib_root = setup.lib_root,
            main_file = setup.main_file,
            package_name = setup.package_name,
        ),
        struct(
            env = env,
            executable = executable,
            runtime_files = [
                setup.apk_file,
                ctx.file._android_emulator,
                ctx.file._android_adb,
                library_tags,
            ] + ctx.attr._android_runtime_all_files.files.to_list(),
        ),
    )

    # The emulator needs the host: /dev/kvm and loopback ports shared with its
    # adb server. Under `linux-sandbox` (CI enables user namespaces) the
    # emulator boots (KVM works) but adb never sees it ("device
    # 'emulator-N' not found"), and `requires-network` alone does not fix that.
    # `no-sandbox` runs just this test unsandboxed, as it effectively was under
    # `processwrapper-sandbox`; every other action stays on `linux-sandbox`.
    return providers + [testing.ExecutionInfo(ANDROID_TEST_EXECUTION_REQUIREMENTS)]

_ANDROID_INTEGRATION_APP_ATTRS = dict(INTEGRATION_TEST_BUILD_ATTRS)
_ANDROID_INTEGRATION_APP_ATTRS["main"] = COMMON_INTEGRATION_TEST_ATTRS["main"]
_ANDROID_INTEGRATION_APP_ATTRS["package_name"] = COMMON_INTEGRATION_TEST_ATTRS["package_name"]
_ANDROID_INTEGRATION_APP_ATTRS["app_srcs"] = COMMON_INTEGRATION_TEST_ATTRS["app_srcs"]
_ANDROID_INTEGRATION_APP_ATTRS["tree_shake_icons"] = COMMON_INTEGRATION_TEST_ATTRS["tree_shake_icons"]
_ANDROID_INTEGRATION_APP_ATTRS["profile"] = COMMON_INTEGRATION_TEST_ATTRS["profile"]
_ANDROID_INTEGRATION_APP_ATTRS["flavor"] = attr.string(default = "", doc = "The application flavor.")
_ANDROID_INTEGRATION_APP_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_kernel_module_aspect],
)
_ANDROID_INTEGRATION_APP_ATTRS["native_deps"] = attr.label_list(
    doc = "Native shared library targets (cc_library) for dart:ffi bundled into lib/.",
    aspects = [native_sources_aspect],
)

# The app is built like a `flutter_application`, so it takes `defines_files`
# (and the tool that parses them) and its kernel compile consumes the
# generated flagfile. `define_flagfiles` stays off this rule.
_ANDROID_INTEGRATION_APP_ATTRS["defines_files"] = DEFINES_FILES_APPLICATION_ATTRS["defines_files"]
_ANDROID_INTEGRATION_APP_ATTRS["_defines_files_tool"] = DEFINES_FILES_APPLICATION_ATTRS["_defines_files_tool"]
_ANDROID_INTEGRATION_APP_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_ANDROID_INTEGRATION_APP_ATTRS.update(MODULAR_KERNEL_ATTRS)
_ANDROID_INTEGRATION_APP_ATTRS["_bootstrap_template"] = attr.label(
    default = Label("//flutter/private/integration_test_bootstrap:android_bootstrap.dart.tpl"),
    allow_single_file = True,
    doc = "The Dart bootstrap program expanded into the app's `_android_bootstrap.dart`.",
)

_ANDROID_INTEGRATION_TEST_ATTRS = {
    "apk": attr.label(
        mandatory = True,
        providers = [RdfApkInfo],
        doc = "The whole APK of the app built from the pinned Gradle model; it names its application id.",
    ),
    "srcs": KERNEL_COMPILE_ATTRS["srcs"],
    "main": COMMON_INTEGRATION_TEST_ATTRS["main"],
    "app_srcs": COMMON_INTEGRATION_TEST_ATTRS["app_srcs"],
    "package_name": COMMON_INTEGRATION_TEST_ATTRS["package_name"],
    "language_version": KERNEL_COMPILE_ATTRS["language_version"],
    "deps": attr.label_list(
        doc = FLUTTER_DEPS_DOC,
        providers = [DartInfo],
        aspects = [LAYERING_CHECK_ASPECT],
    ),
    "platform": COMMON_INTEGRATION_TEST_ATTRS["platform"],
    "data": COMMON_INTEGRATION_TEST_ATTRS["data"],
    "env": COMMON_INTEGRATION_TEST_ATTRS["env"],
    "include_tags": COMMON_INTEGRATION_TEST_ATTRS["include_tags"],
    "exclude_tags": COMMON_INTEGRATION_TEST_ATTRS["exclude_tags"],
    "_tool": COMMON_INTEGRATION_TEST_ATTRS["_tool"],
    "_library_tags_tool": COMMON_INTEGRATION_TEST_ATTRS["_library_tags_tool"],
    "_sky_engine": COMMON_INTEGRATION_TEST_ATTRS["_sky_engine"],
    "_android_emulator": attr.label(
        doc = "The pinned Android emulator binary the runner boots.",
        default = Label("@flutter_android_headless_runtime//:sdk/emulator/emulator"),
        allow_single_file = True,
    ),
    "_android_adb": attr.label(
        doc = "The pinned `adb` binary the runner installs and drives the APK with.",
        default = Label("@flutter_android_headless_runtime//:sdk/platform-tools/adb"),
        allow_single_file = True,
    ),
    "_android_runtime_all_files": attr.label(
        doc = "Every file of the headless Android runtime, made available in runfiles.",
        default = Label("@flutter_android_headless_runtime//:all_files"),
    ),
}
_ANDROID_INTEGRATION_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_ANDROID_INTEGRATION_TEST_ATTRS.update(LAYERING_CHECK_ATTRS)

_flutter_android_integration_app = rule(
    implementation = _flutter_android_integration_app_impl,
    attrs = _ANDROID_INTEGRATION_APP_ATTRS,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:product_tools_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:aot_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:font_subset_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_dart//dart:exec_tools_toolchain_type",
            mandatory = False,
        ),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter Android application with an in-app integration test bootstrap.",
)

_flutter_android_integration_test = rule(
    implementation = _flutter_android_integration_test_impl,
    attrs = _ANDROID_INTEGRATION_TEST_ATTRS,
    test = True,
    toolchains = LAYERING_CHECK_TOOLCHAINS,
    doc = "Runs a compiled Flutter Android integration test APK inside a hermetic, pinned headless Android emulator.",
)

def declare_android_integration_test(name, package_name, deps, android_app, android_variant, kwargs):
    """Declares the Android integration-test app and test targets.

    Args:
        name: The test target's name.
        package_name: The resolved Dart package name.
        deps: The merged dependencies.
        android_app: `flutter_android_app` of the pin's `defs.bzl` (the function), which builds
            the app's Android side from its Gradle model.
        android_variant: The app variant to build, a debuggable one (`debug`, `devDebug`).
        kwargs: The macro's extra attributes.
    """
    if android_app == None:
        fail(("flutter_integration_test %s: platform = \"android\" needs `android_app`: the app's Android side is built " +
              "from its Gradle model. Load `flutter_android_app` from the pin's `defs.bzl` " +
              "(`@android_model//:defs.bzl`) and pass `android_app = flutter_android_app`. " +
              "See docs/android-model.md.") % name)
    helper_tags = ["manual"]
    app_kwargs = {}
    for k in ANDROID_APP_KWARG_KEYS:
        if k in kwargs:
            app_kwargs[k] = kwargs[k]

    # The Dart program: the app with the in-app test bootstrap.
    _flutter_android_integration_app(
        name = "__%s_app" % name,
        package_name = package_name,
        deps = deps,
        tags = helper_tags,
        visibility = ["//visibility:private"],
        **app_kwargs
    )

    # The Android app around it, from the pin. The hermetic emulator is x86_64.
    app = android_app(
        name = "__%s_android" % name,
        application = ":__%s_app" % name,
        variant = android_variant,
        abis = ["x86_64"],
        visibility = ["//visibility:private"],
    )

    test_kwargs = {
        k: v
        for k, v in kwargs.items()
        if k not in ANDROID_APP_KWARG_KEYS or k in ("srcs", "main", "app_srcs", "language_version")
    }

    _flutter_android_integration_test(
        name = name,
        apk = app.apk,
        package_name = package_name,
        deps = deps,
        platform = "android",
        **test_kwargs
    )

android_integration_test_rule = _flutter_android_integration_test
