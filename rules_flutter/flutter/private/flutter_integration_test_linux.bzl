"""The `platform = "linux"` rule of `flutter_integration_test`.

Compiles the app and its in-app test to a kernel `.dill` (and `libapp.so` in
AOT modes), builds the GTK runner against the hermetic sysroot, assembles the
Linux desktop bundle, and runs it under `Xvfb` through
`flutter_integration_test_runner`. `flutter_integration_test.bzl` dispatches
to `linux_integration_test_rule`.
"""

load(
    "@rules_dart//dart:providers.bzl",
    "DartInfo",
)
load(
    "@rules_dart//dart:utils.bzl",
    "MODULAR_KERNEL_TOOLCHAINS",
    "runfiles_path",
)
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_location",
)
load(
    "//flutter/private:common.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "FLUTTER_DEPS_DOC",
    "compute_desktop_bundle_copies",
    "make_desktop_bundle_artifacts",
    "make_desktop_bundle_libs",
    "resolve_exec_dart_vm",
)
load(
    "//flutter/private:flutter_integration_test_bootstrap.bzl",
    "make_linux_integration_bootstrap_content",
)
load(
    "//flutter/private:flutter_integration_test_common.bzl",
    "COMMON_INTEGRATION_TEST_ATTRS",
    "integration_test_aot",
    "integration_test_assets",
    "integration_test_common_setup",
    "integration_test_dart_sources",
    "integration_test_env",
    "integration_test_kernel",
    "integration_test_native_assets",
    "integration_test_native_libs",
    "integration_test_providers",
    "integration_test_runner_executable",
)
load(
    "//flutter/private:flutter_integration_test_ios.bzl",
    "exposes_package",
)
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "flutter_kernel_module_aspect",
)
load(
    "//flutter/private:flutter_linux_application.bzl",
    "compile_linux_runner",
    "linux_plugin_inputs",
    "linux_registrant_inputs",
    "linux_runner_defines",
    "linux_runner_inputs",
)
load("//flutter/private:layering_check.bzl", "LAYERING_CHECK_ASPECT")
load(
    "//flutter/private:native_sources.bzl",
    "native_sources_aspect",
)
load(
    "//flutter/private:plugin_registrant.bzl",
    "generate_native_plugin_registrant",
    "generate_native_plugin_registrant_header",
)

visibility(["//flutter/..."])

def _linux_integration_test_setup(ctx):
    """Validates a Linux target and resolves its shared build inputs.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        An `integration_test_common_setup` struct.
    """
    if ctx.attr.platform != "linux":
        fail(
            "%s: _flutter_linux_integration_test requires platform = 'linux', got %r." % (
                ctx.label,
                ctx.attr.platform,
            ),
        )

    setup = integration_test_common_setup(ctx)
    if not setup.is_debug and setup.sdk.target_os in ("linux", "macos", "windows"):
        fail(
            "AOT cross-compilation between desktop platforms is not supported. " +
            "Build on a Linux host, or use debug mode (-c dbg).",
        )
    if not setup.is_debug and not setup.sdk.gen_snapshot:
        fail(
            "No target-compatible AOT gen_snapshot toolchain is registered for " +
            "this host and target platform.",
        )
    if setup.sdk.engine_library == None:
        fail(
            "No Linux engine library available in the Flutter toolchain. " +
            "Run Linux integration tests on a Linux host.",
        )
    return setup

def _linux_integration_test_sources(ctx, setup):
    """Generates the Linux bootstrap and registrant, and its package config.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_linux_integration_test_setup` struct.

    Returns:
        An `integration_test_dart_sources` struct.
    """
    main_location = app_main_location(setup.package_name, setup.lib_root, setup.main_file)
    content = make_linux_integration_bootstrap_content(
        test_import = main_location.uri,
        has_integration_test = exposes_package(ctx.attr.deps, ["integration_test"]),
    )
    return integration_test_dart_sources(ctx, setup, "linux", content)

def _linux_integration_test_runner(ctx, setup, sources):
    """Compiles the GTK runner and the native plugin registrant sources.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_linux_integration_test_setup` struct.
        sources: The `_linux_integration_test_sources` struct.

    Returns:
        A struct with `binary` and `engine_files`.
    """
    native_registrant_cc = generate_native_plugin_registrant(ctx, sources.plugins.all_plugins, "linux")
    native_registrant_h = generate_native_plugin_registrant_header(ctx, "linux")

    plugin_srcs = []
    plugin_hdrs = []
    plugin_include_dirs = []
    for entry in sources.plugins.linux_plugin_libraries.to_list():
        plugin_srcs.extend(entry.srcs.to_list())
        plugin_hdrs.extend(entry.hdrs.to_list())
        plugin_include_dirs.extend(entry.include_dirs.to_list())

    engine_files = setup.sdk.engine_library.files.to_list()
    runner_binary = compile_linux_runner(
        ctx,
        engine_files = engine_files,
        defines = linux_runner_defines(ctx.attr.gtk_app_id, ctx.attr.window_title),
        linux_sysroot = setup.sdk.linux_sysroot,
        runner = linux_runner_inputs([ctx.file._linux_runner_source]),
        registrant = linux_registrant_inputs([native_registrant_cc], [native_registrant_h]),
        target_arch = setup.sdk.target_arch,
        plugins = linux_plugin_inputs(plugin_srcs, plugin_hdrs, plugin_include_dirs),
    )
    return struct(
        binary = runner_binary,
        engine_files = engine_files,
    )

def _linux_integration_test_bundle(ctx, setup, kernel_dill, aot_output, assets, runner, native_assets):
    """Assembles the Linux desktop bundle directory.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_linux_integration_test_setup` struct.
        kernel_dill: The compiled kernel File.
        aot_output: The AOT `.so` File, or None in debug mode.
        assets: The `flutter_assets` directory.
        runner: The `_linux_integration_test_runner` struct.
        native_assets: The `integration_test_native_assets` struct.

    Returns:
        A struct with `bundle`, `binary_name` and `native_libs`.
    """
    native_libs = integration_test_native_libs(ctx, native_assets.bundled)
    bundle_dir = ctx.actions.declare_directory(ctx.label.name + "_linux")
    binary_name = ctx.label.name
    copies = compute_desktop_bundle_copies(
        artifacts = make_desktop_bundle_artifacts(
            is_debug = setup.is_debug,
            kernel_dill_path = kernel_dill.path if setup.is_debug else None,
            aot_output_path = aot_output.path if aot_output else None,
            aot_dst = "lib/libapp.so",
            icu_data_path = setup.sdk.icu_data.path,
        ),
        libs = make_desktop_bundle_libs(
            engine_basenames = [(f.path, f.basename) for f in runner.engine_files],
            native_basenames = [(lib.path, lib.basename) for lib in native_libs],
        ),
    )
    copies.append({"src": runner.binary.path, "dst": binary_name})

    bundle_config = {
        "output_dir": bundle_dir.path,
        "copies": copies,
        "copy_dirs": [
            {"src": assets.path, "dst": "data/flutter_assets"},
        ],
    }
    bundle_config_file = ctx.actions.declare_file(ctx.label.name + "_linux_bundle_config.json")
    ctx.actions.write(bundle_config_file, json.encode(bundle_config))

    all_bundle_inputs = [bundle_config_file, assets, setup.sdk.icu_data, runner.binary]
    all_bundle_inputs += [kernel_dill] if setup.is_debug else [aot_output]
    all_bundle_inputs += native_libs + runner.engine_files
    exec_dart, dart_vm_files = resolve_exec_dart_vm(ctx, setup.sdk)
    ctx.actions.run(
        executable = exec_dart,
        arguments = [
            ctx.executable._bundle_tool.path,
            "--config",
            bundle_config_file.path,
        ],
        inputs = depset(
            direct = all_bundle_inputs + [ctx.executable._bundle_tool],
            transitive = [dart_vm_files],
        ),
        outputs = [bundle_dir],
        mnemonic = "FlutterLinuxBundle",
        progress_message = "Bundling Flutter Linux integration test %s" % ctx.label,
        toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
    )
    return struct(
        binary_name = binary_name,
        bundle = bundle_dir,
        native_libs = native_libs,
    )

def _linux_integration_test_run(ctx, setup, bundle):
    """Wires the runner executable, environment and runfiles for the Linux bundle.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_linux_integration_test_setup` struct.
        bundle: The `_linux_integration_test_bundle` struct.

    Returns:
        The provider list.
    """
    executable = integration_test_runner_executable(ctx)
    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": "linux",
        "FLUTTER_INTEGRATION_TEST_LINUX_BUNDLE": runfiles_path(bundle.bundle, workspace_name),
        "FLUTTER_INTEGRATION_TEST_LINUX_BINARY": bundle.binary_name,
        "FLUTTER_INTEGRATION_TEST_XVFB": runfiles_path(ctx.file._linux_xvfb, workspace_name),
        "FLUTTER_INTEGRATION_TEST_XKBCOMP": runfiles_path(ctx.file._linux_xkbcomp, workspace_name),
        "FLUTTER_INTEGRATION_TEST_FONTCONFIG": runfiles_path(ctx.file._linux_fontconfig, workspace_name),
        "FLUTTER_INTEGRATION_TEST_PATH": setup.main_file.short_path,
        "FLUTTER_INTEGRATION_TEST_DECLARED_ENV": json.encode(ctx.attr.env),
    }
    library_tags = integration_test_env(ctx, env, setup.main_file)
    return integration_test_providers(
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
                bundle.bundle,
                ctx.file._linux_xvfb,
                ctx.file._linux_xkbcomp,
                ctx.file._linux_fontconfig,
                library_tags,
            ] + ctx.attr._linux_runtime_all_files[DefaultInfo].files.to_list(),
        ),
    )

def _flutter_linux_integration_test_impl(ctx):
    """Compiles, bundles and runs a Linux integration test under `Xvfb`.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        The provider list.
    """
    setup = _linux_integration_test_setup(ctx)
    native_assets = integration_test_native_assets(ctx, setup.sdk, "linux")
    sources = _linux_integration_test_sources(ctx, setup)
    kernel_dill = integration_test_kernel(ctx, setup.sdk, sources, native_assets, setup.aot, setup.mode)
    aot_output = integration_test_aot(ctx, setup.sdk, kernel_dill, setup.is_debug, setup.strip)
    assets = integration_test_assets(
        ctx,
        setup.sdk,
        "linux",
        kernel_dill,
        setup.is_debug,
        native_assets.data_assets,
    )
    runner = _linux_integration_test_runner(ctx, setup, sources)
    bundle = _linux_integration_test_bundle(ctx, setup, kernel_dill, aot_output, assets, runner, native_assets)
    return _linux_integration_test_run(ctx, setup, bundle)

_LINUX_INTEGRATION_TEST_ATTRS = dict(COMMON_INTEGRATION_TEST_ATTRS)
_LINUX_INTEGRATION_TEST_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_kernel_module_aspect, LAYERING_CHECK_ASPECT],
)
_LINUX_INTEGRATION_TEST_ATTRS["native_deps"] = attr.label_list(
    doc = "Native shared library targets (cc_library) for dart:ffi bundled into lib/.",
    aspects = [native_sources_aspect],
)
_LINUX_INTEGRATION_TEST_ATTRS["gtk_app_id"] = attr.string(
    doc = "GTK application identifier for the Linux test runner.",
    default = "com.example.flutter_integration_test",
)
_LINUX_INTEGRATION_TEST_ATTRS["window_title"] = attr.string(
    doc = "Window title for the Linux test runner.",
    default = "Flutter Integration Test",
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_runner_source"] = attr.label(
    doc = "The C++ GTK runner source compiled into the Linux bundle.",
    default = Label("//flutter/private/runners:linux_runner.cc"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_cc_toolchain"] = attr.label(
    doc = "The C++ toolchain that compiles the GTK runner.",
    default = "@bazel_tools//tools/cpp:current_cc_toolchain",
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_xvfb"] = attr.label(
    doc = "The pinned `Xvfb` virtual display server the runner starts.",
    default = Label("@flutter_linux_headless_runtime//:sysroot/usr/bin/Xvfb"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_xkbcomp"] = attr.label(
    doc = "The pinned `xkbcomp` binary `Xvfb` needs for its keyboard map.",
    default = Label("@flutter_linux_headless_runtime//:sysroot/usr/bin/xkbcomp"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_fontconfig"] = attr.label(
    doc = "The fontconfig file the headless Linux runtime loads.",
    default = Label("@flutter_linux_headless_runtime//:fonts/fonts.conf"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_runtime_all_files"] = attr.label(
    doc = "Every file of the headless Linux runtime, made available in runfiles.",
    default = Label("@flutter_linux_headless_runtime//:all_files"),
)
_LINUX_INTEGRATION_TEST_ATTRS["_bootstrap_template"] = attr.label(
    default = Label("//flutter/private/integration_test_bootstrap:linux_bootstrap.dart.tpl"),
    allow_single_file = True,
    doc = "The Dart bootstrap program expanded into the test's `_linux_bootstrap.dart`.",
)

_flutter_linux_integration_test = rule(
    implementation = _flutter_linux_integration_test_impl,
    attrs = _LINUX_INTEGRATION_TEST_ATTRS,
    fragments = ["cpp"],
    test = True,
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
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
            "@rules_flutter//flutter/private:desktop_engine_toolchain_type",
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
    doc = "Compiles a Flutter Linux desktop app with an in-app integration test and runs it headlessly under Xvfb.",
)

linux_integration_test_rule = _flutter_linux_integration_test
