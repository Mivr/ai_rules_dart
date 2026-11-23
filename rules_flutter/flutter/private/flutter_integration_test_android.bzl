"""The `platform = "android"` rules and macro helpers of `flutter_integration_test`.

Compiles the app and its in-app test for `android_x64`, packages a signed APK
through `android_binary`, and runs it in the hermetic headless emulator
through `flutter_integration_test_runner`. `declare_android_integration_test`
creates the helper app, bundle, registrant, manifest and APK targets and the
test target `flutter_integration_test.bzl` dispatches to.
"""

load(
    "@bazel_skylib//rules:write_file.bzl",
    "write_file",
)
load(
    "@rules_android//android:rules.bzl",
    "android_binary",
)
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
    "@rules_kotlin//kotlin:android.bzl",
    "kt_android_library",
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
    "//flutter/private:constants.bzl",
    "ANDROID_MIN_SDK_VERSION",
    "ANDROID_TARGET_SDK_VERSION",
)
load(
    "//flutter/private:flutter_android_engine.bzl",
    "flutter_android_engine",
)
load(
    "//flutter/private:flutter_android_manifest_merge.bzl",
    "flutter_android_manifest_merge",
)
load(
    "//flutter/private:flutter_android_plugin_closure.bzl",
    "declare_android_bundle_targets",
    "declare_android_plugin_closure",
)
load(
    "//flutter/private:flutter_android_registrant.bzl",
    "flutter_android_registrant",
)
load(
    "//flutter/private:flutter_integration_android_app.bzl",
    "ANDROID_APP_KWARG_KEYS",
    "android_integration_app_kernel",
    "make_android_integration_manifest_lines",
    "sanitize_android_package_segment",
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
    ] + native_libs + native_assets.bundled.to_list()
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
            android_plugin_libraries = sources.plugins.android_plugin_libraries,
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
    native_assets = integration_test_native_assets(ctx, setup.sdk, "android")
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
        A struct with `main_file`, `extra_srcs`, `package_name`, `lib_root`
        and `apk_file`.
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

    apk_files = [
        f
        for f in ctx.files.apk
        if f.path.endswith(".apk") and not f.path.endswith("_unsigned.apk")
    ]
    if not apk_files:
        fail(
            "flutter_integration_test %s: expected a signed .apk from %s, got %s" % (
                ctx.label.name,
                ctx.attr.apk.label,
                [f.short_path for f in ctx.files.apk],
            ),
        )
    return struct(
        apk_file = apk_files[0],
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
        "FLUTTER_INTEGRATION_TEST_ANDROID_PACKAGE": ctx.attr.android_package,
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
        allow_files = True,
        doc = "The compiled Android APK target.",
    ),
    "android_package": attr.string(
        mandatory = True,
        doc = "Android application ID (e.g. 'com.example.app_test').",
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

def _android_integration_test_app(name, package_name, deps, kwargs):
    """Declares the Android helper app, bundle, engine and plugin targets.

    Args:
        name: The test target's name the helper names derive from.
        package_name: The resolved Dart package name.
        deps: The merged dependencies.
        kwargs: The macro's extra attributes.
    """
    helper_tags = ["manual"]
    app_kwargs = {}
    for k in ANDROID_APP_KWARG_KEYS:
        if k in kwargs:
            app_kwargs[k] = kwargs[k]

    _flutter_android_integration_app(
        name = "__%s_app" % name,
        package_name = package_name,
        deps = deps,
        tags = helper_tags,
        visibility = ["//visibility:private"],
        **app_kwargs
    )

    flutter_android_engine(
        name = "__%s_engine_raw" % name,
        android_abi = "x64",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )
    declare_android_bundle_targets(
        name = name,
        application = ":__%s_app" % name,
        full_abi = "x86_64",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    native.filegroup(
        name = "__%s_flutter_assets" % name,
        srcs = [":__%s_bundle" % name],
        output_group = "mobile_install",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    flutter_android_registrant(
        name = "__%s_registrant_src" % name,
        application = ":__%s_app" % name,
        android_abi = "x86_64",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    declare_android_plugin_closure(
        name = name,
        application = ":__%s_app" % name,
        android_abi = "x86_64",
        engine = ":__%s_engine" % name,
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

def _android_integration_test_apk(name, android_package, android_deps):
    """Declares the Android registrant, merged manifest and signed APK targets.

    Args:
        name: The test target's name the helper names derive from.
        android_package: The resolved Android application ID.
        android_deps: Extra Android library targets.
    """
    helper_tags = ["manual"]
    registrant_deps = [
        ":__%s_engine" % name,
        ":__%s_android_plugin_deps" % name,
    ]
    registrant_deps = registrant_deps + list(android_deps)

    kt_android_library(
        name = "__%s_registrant" % name,
        srcs = [":__%s_registrant_src" % name],
        custom_package = "io.flutter.plugins",
        deps = registrant_deps,
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    binary_deps = [
        ":__%s_native_libs" % name,
        ":__%s_engine" % name,
        ":__%s_registrant" % name,
        ":__%s_android_plugin_deps" % name,
    ]
    binary_deps = binary_deps + list(android_deps)

    write_file(
        name = "__%s_base_manifest" % name,
        out = "__%s_base_manifest/AndroidManifest.xml" % name,
        content = make_android_integration_manifest_lines(
            android_package,
            name,
        ),
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    flutter_android_manifest_merge(
        name = "__%s_manifest" % name,
        base = ":__%s_base_manifest" % name,
        libraries = binary_deps,
        placeholders = ["applicationId", "minSdkVersion", "targetSdkVersion"],
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    android_binary(
        name = "__%s_apk" % name,
        manifest = ":__%s_manifest" % name,
        manifest_values = {
            "applicationId": android_package,
            "minSdkVersion": ANDROID_MIN_SDK_VERSION,
            "targetSdkVersion": ANDROID_TARGET_SDK_VERSION,
        },
        assets = [":__%s_flutter_assets" % name],
        assets_dir = "assets",
        deps = binary_deps,
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

def declare_android_integration_test(name, package_name, deps, android_package, android_deps, pub_hub_name, kwargs):
    """Declares the Android integration-test app and test targets.

    Args:
        name: The test target's name.
        package_name: The resolved Dart package name.
        deps: The merged dependencies.
        android_package: Optional explicit Android application ID.
        android_deps: Extra Android library targets.
        pub_hub_name: Accepted for compatibility and no longer read; plugins come from `deps`.
        kwargs: The macro's extra attributes.
    """
    _ = pub_hub_name
    resolved_android_package = android_package or (
        "com.example.%s" % sanitize_android_package_segment(package_name)
    )
    _android_integration_test_app(name, package_name, deps, kwargs)
    _android_integration_test_apk(name, resolved_android_package, android_deps)

    test_kwargs = {
        k: v
        for k, v in kwargs.items()
        if k not in ANDROID_APP_KWARG_KEYS or k in ("srcs", "main", "app_srcs", "language_version")
    }

    _flutter_android_integration_test(
        name = name,
        apk = ":__%s_apk" % name,
        android_package = resolved_android_package,
        package_name = package_name,
        deps = deps,
        platform = "android",
        **test_kwargs
    )

android_integration_test_rule = _flutter_android_integration_test
