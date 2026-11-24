"""Helpers and attributes the `flutter_integration_test` platforms share.

The web, Linux and Android rule files load the kernel compile, AOT, asset and
native-library steps, the runner environment and the provider list from here,
and copy `COMMON_INTEGRATION_TEST_ATTRS` into their own attribute dicts. The
iOS support in `flutter_integration_test_ios.bzl` supplies the tag, entrypoint
and coverage helpers this file loads.
"""

load(
    "@rules_dart//dart:providers.bzl",
    "DartInfo",
)
load(
    "@rules_dart//dart:utils.bzl",
    "collect_packages",
    "collect_transitive_srcs",
    "derive_lib_root",
    "runfiles_path",
)
load(
    "//flutter:providers.bzl",
    "FlutterInfo",
)
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_scheme_location",
    "compile_kernel_package_config",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "FLUTTER_APPLICATION_ATTRS",
    "KERNEL_COMPILE_ATTRS",
    "LIBRARY_TAGS_TOOL_ATTR",
    "PLATFORM_CONSTRAINT_ATTRS",
    "check_hook_errors",
    "collect_native_libs",
    "declare_flutter_assets_dir",
    "extract_library_tags_action",
    "flutter_build_mode",
    "merge_dart_defines",
    "resolve_flutter_sdk_info",
)
load(
    "//flutter/private:flutter_aot_compile.bzl",
    "flutter_aot_elf_action",
)
load("//flutter/private:flutter_bundle.bzl", "BUNDLE_ATTRS", "flutter_bundle")
load(
    "//flutter/private:flutter_compile.bzl",
    "flutter_kernel_compile_action",
    "flutter_kernel_dills",
    "flutter_kernel_options",
    "flutter_kernel_outputs",
    "flutter_kernel_sources",
)
load(
    "//flutter/private:flutter_info.bzl",
    "collect_flutter_plugin_deps",
)
load(
    "//flutter/private:flutter_integration_test_ios.bzl",
    "RESERVED_TAG_ENV_KEYS",
    "build_analyzable_and_coverage_infos",
    "exposes_package",
    "resolve_main_and_srcs",
    "test_tag_env",
)
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "MODULAR_KERNEL_ATTRS",
)
load("//flutter/private:code_assets.bzl", "FLUTTER_CODE_ASSETS_ATTRS", "flutter_code_assets")
load("//flutter/private:layering_check.bzl", "LAYERING_CHECK_ATTRS", "layering_check_integration")
load(
    "//flutter/private:plugin_registrant.bzl",
    "generate_dart_plugin_registrant",
)

visibility(["//flutter/..."])

def integration_test_common_setup(ctx):
    """The checks and build-mode inputs the dart:io test rules share.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        A struct with `aot`, `extra_srcs`, `is_debug`, `lib_root`, `main_file`,
        `mode`, `package_name`, `sdk` and `strip`.
    """
    if not exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    hook_err = check_hook_errors(ctx.label, ctx.attr.deps)
    if hook_err != None:
        fail(hook_err)

    main_file, extra_srcs = resolve_main_and_srcs(ctx)

    mode = "profile" if ctx.attr.profile else flutter_build_mode(ctx)
    is_debug = mode == "debug"
    return struct(
        aot = not is_debug,
        extra_srcs = extra_srcs,
        is_debug = is_debug,
        lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package),
        main_file = main_file,
        mode = mode,
        package_name = ctx.attr.package_name or ctx.label.name,
        sdk = resolve_flutter_sdk_info(ctx),
        strip = ctx.var["COMPILATION_MODE"] == "opt",
    )

def integration_test_dart_sources(ctx, setup, platform, content):
    """Generates the bootstrap and registrant, and computes the package config.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: An `integration_test_common_setup` struct.
        platform: The registrant's target platform (`linux` or `android`).
        content: The bootstrap `{placeholder: replacement}` dict.

    Returns:
        A struct with `bootstrap`, `bootstrap_location`, `package_config`,
        `plugins`, `registrant` and `registrant_location`.
    """
    packages = collect_packages(ctx.attr.deps)
    packages = synthesize_app_package(
        ctx.label,
        packages,
        setup.package_name,
        setup.lib_root,
        ctx.attr.language_version,
    )

    bootstrap = ctx.actions.declare_file(ctx.label.name + "_" + platform + "_bootstrap.dart")
    ctx.actions.expand_template(
        template = ctx.file._bootstrap_template,
        output = bootstrap,
        substitutions = content,
    )

    plugins = integration_test_plugins(ctx)
    registrant = generate_dart_plugin_registrant(
        ctx,
        plugins.all_plugins,
        target_platform = platform,
    )
    registrant_location = app_scheme_location(registrant) if registrant else None
    bootstrap_location = app_scheme_location(bootstrap)

    all_srcs = (
        list(setup.extra_srcs) +
        collect_transitive_srcs(ctx.attr.deps).to_list() +
        [setup.main_file, bootstrap] +
        ([registrant] if registrant else [])
    )
    pc = compile_kernel_package_config(
        ctx,
        packages,
        all_srcs,
        roots = {setup.package_name: True} if setup.package_name else None,
    )
    return struct(
        bootstrap = bootstrap,
        bootstrap_location = bootstrap_location,
        package_config = pc,
        plugins = plugins,
        registrant = registrant,
        registrant_location = registrant_location,
    )

def integration_test_plugins(ctx):
    """Collects the plugin sets `deps` propagate for the registrant generators.

    Args:
        ctx: Rule context carrying `deps`.

    Returns:
        The `collect_flutter_plugin_deps` struct.
    """
    return collect_flutter_plugin_deps(ctx.attr.deps)

def integration_test_native_assets(ctx):
    """The test app's native-assets manifest and bundled code-asset libraries.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        A struct with `any`, `data_assets`, `manifest` and `bundled` (see
        `flutter_code_assets`).
    """
    return flutter_code_assets(ctx)

def integration_test_runner_executable(ctx):
    """Declares the runner symlink the test rule exposes as its executable.

    Args:
        ctx: Rule context carrying `_tool` and `_windows_constraint`.

    Returns:
        The declared executable File.
    """
    tool = ctx.attr._tool
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    return executable

def integration_test_env(ctx, env, main_file):
    """Completes a platform env dict with the caller's overrides and tags.

    Args:
        ctx: Rule context carrying `env`, `include_tags` and `exclude_tags`.
        env: The platform env dict to complete.
        main_file: The entrypoint whose `@Tags` the runner receives.

    Returns:
        The `library_tags` File the runner reads.
    """
    workspace_name = ctx.workspace_name
    test_tag_env(ctx, env)

    # The entrypoint's own `@Tags`, extracted at build time (see
    # `extract_library_tags_action`): the runner injects them as the root
    # group's metadata, so they inherit down to every test in the suite.
    library_tags = extract_library_tags_action(ctx, main_file)
    env["FLUTTER_TEST_LIBRARY_TAGS"] = runfiles_path(library_tags, workspace_name)
    for key, value in ctx.attr.env.items():
        if key in env or key in RESERVED_TAG_ENV_KEYS:
            fail((
                "flutter_integration_test {name}: env key {key} is set by the " +
                "rule itself and cannot be overridden."
            ).format(name = ctx.label.name, key = key))
        env[key] = value
    return library_tags

def _integration_test_runfiles(ctx, runtime_files):
    """The runner's runfiles: its inputs, the caller's data and the tool's own.

    Args:
        ctx: Rule context carrying `data` and `_tool`.
        runtime_files: The platform files the runner reads.

    Returns:
        The merged runfiles.
    """
    tool = ctx.attr._tool
    runfiles = ctx.runfiles(
        files = runtime_files + ctx.files.data,
    )
    runfiles = runfiles.merge(tool[DefaultInfo].default_runfiles)
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)
    return runfiles

def integration_test_providers(ctx, sources, run):
    """The providers every platform test rule returns.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        sources: struct with `package_name`, `lib_root`, `main_file`, `extra_srcs`.
        run: struct with `executable`, `env` and `runtime_files`.

    Returns:
        The provider list.
    """
    runfiles = _integration_test_runfiles(ctx, run.runtime_files)
    instrumented_files_info, analyzable_info = build_analyzable_and_coverage_infos(
        ctx,
        sources.package_name,
        sources.lib_root,
        sources.main_file,
        sources.extra_srcs,
    )
    return [
        DefaultInfo(executable = run.executable, runfiles = runfiles),
        testing.TestEnvironment(run.env),
        instrumented_files_info,
        analyzable_info,
        OutputGroupInfo(_validation = layering_check_integration(ctx, sources)),
    ]

def _integration_test_platform_dill(flutter_sdk_info, aot, mode):
    """The platform kernel dill the kernel compile reads.

    Args:
        flutter_sdk_info: The resolved Flutter SDK info.
        aot: Whether the build is AOT (non-debug).
        mode: The build mode.

    Returns:
        The platform `.dill` File.
    """
    if aot and mode == "release":
        platform_dill = flutter_sdk_info.platform_kernel_dill_product
        if platform_dill == None:
            fail(
                "Unresolved @rules_flutter//flutter:product_tools_toolchain_type " +
                "(@rules_flutter//flutter/private:product_tools_toolchain_type): " +
                "Flutter toolchain does not provide platform_kernel_dill_product, " +
                "which is required for release AOT kernel compilation. Register " +
                "the Flutter toolchains (e.g. `flutter.toolchain()` in MODULE.bazel " +
                "or `register_toolchains(\"@flutter_toolchains//:all\")`) or set " +
                "`platform_kernel_dill_product` on `flutter_toolchain`.",
            )
        return platform_dill
    platform_dill = flutter_sdk_info.platform_kernel_dill
    if platform_dill == None:
        fail(
            "Unresolved @rules_flutter//flutter:toolchain_type: " +
            "Flutter toolchain does not provide platform_kernel_dill. " +
            "Register a Flutter toolchain (e.g. `flutter.toolchain()` in " +
            "MODULE.bazel) or set `platform_kernel_dill` on `flutter_toolchain`.",
        )
    return platform_dill

def _integration_test_kernel_flags(ctx, mode, aot):
    """The defines and frontend flags the kernel compile passes.

    Args:
        ctx: Rule context carrying `track_widget_creation`.
        mode: The build mode.
        aot: Whether the build is AOT (non-debug).

    Returns:
        A struct with `defines` and `frontend_flags`.
    """
    all_defines = list(merge_dart_defines(ctx))
    if mode == "profile":
        all_defines.append("dart.vm.profile=true")
    elif aot:
        all_defines.append("dart.vm.product=true")
    frontend_flags = []
    if ctx.attr.track_widget_creation and mode != "release":
        frontend_flags.append("--track-widget-creation")
    return struct(
        defines = all_defines,
        frontend_flags = frontend_flags,
    )

def integration_test_kernel(ctx, flutter_sdk_info, sources, native_assets, aot, mode):
    """Runs the kernel compile the dart:io test rules share.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        flutter_sdk_info: The resolved Flutter SDK info.
        sources: struct with `bootstrap`, `bootstrap_location`,
            `package_config` and `registrant_location`.
        native_assets: The `integration_test_native_assets` struct.
        aot: Whether the build is AOT (non-debug).
        mode: The build mode.

    Returns:
        The compiled kernel `.dill` File.
    """
    platform_dill = _integration_test_platform_dill(flutter_sdk_info, aot, mode)
    flags = _integration_test_kernel_flags(ctx, mode, aot)
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx,
        struct(
            dartaotruntime = flutter_sdk_info.dartaotruntime,
            kernel_filter_tool = ctx.executable._kernel_filter_tool,
            frontend_server = flutter_sdk_info.frontend_server,
            platform_dill = platform_dill,
        ),
        flutter_kernel_sources(
            main = sources.bootstrap,
            entrypoint_uri = sources.bootstrap_location.uri,
            srcs = sources.package_config.srcs,
            package_config = sources.package_config.config_file,
            native_assets_manifest = native_assets.manifest,
            dart_plugin_registrant_uri = sources.registrant_location.uri if sources.registrant_location else None,
        ),
        flutter_kernel_outputs(output = kernel_dill),
        flutter_kernel_options(
            aot = aot,
            defines = flags.defines,
            target = "flutter",
            extra_flags = flags.frontend_flags,
        ),
        flutter_kernel_dills(),
    )
    return kernel_dill

def integration_test_aot(ctx, flutter_sdk_info, kernel_dill, is_debug, strip):
    """AOT-compiles the kernel in ELF form when the build is not debug.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        flutter_sdk_info: The resolved Flutter SDK info.
        kernel_dill: The compiled kernel File.
        is_debug: Whether the build is debug.
        strip: Whether to strip the AOT output.

    Returns:
        The AOT `.so` File, or None in debug mode.
    """
    if is_debug:
        return None
    aot_output = ctx.actions.declare_file(ctx.label.name + ".so")
    flutter_aot_elf_action(
        ctx = ctx,
        gen_snapshot = flutter_sdk_info.gen_snapshot,
        kernel_dill = kernel_dill,
        output = aot_output,
        strip = strip,
    )
    return aot_output

def integration_test_assets(ctx, flutter_sdk_info, target_platform, kernel_dill, is_debug, data_assets):
    """Builds the `flutter_assets/` tree from the app's pubspec.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        flutter_sdk_info: The resolved Flutter SDK info.
        target_platform: The bundle's platform.
        kernel_dill: The compiled kernel File, or None for web; read only to
            shake icons in a release or profile build.
        is_debug: Whether the build is debug.
        data_assets: The transitive data-asset depset, or None.

    Returns:
        The declared `flutter_assets` directory.
    """
    flavor = ctx.attr.flavor if hasattr(ctx.attr, "flavor") and ctx.attr.flavor else None
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_bundle(
        ctx,
        flutter_sdk_info,
        flutter_assets,
        target_platform = target_platform,
        mode = "debug" if is_debug else ("profile" if getattr(ctx.attr, "profile", False) else "release"),
        flavor = flavor,
        app_dill = None if is_debug else kernel_dill,
        data_assets = data_assets,
    )
    return flutter_assets

def integration_test_native_libs(ctx):
    """The loose `native_deps` libraries a desktop or Android bundle carries.

    The code assets' libraries are a directory of their own
    (`integration_test_native_assets`).

    Args:
        ctx: Rule context carrying `native_deps` and `deps`.

    Returns:
        The native library File list.
    """
    native_libs = collect_native_libs(ctx.attr.native_deps)
    transitive_native_depsets = [
        dep[FlutterInfo].transitive_native_libs
        for dep in ctx.attr.deps
        if FlutterInfo in dep
    ]
    if transitive_native_depsets:
        native_libs.extend(depset(transitive = transitive_native_depsets).to_list())
    return native_libs

_WEB_RELEVANT_KEYS = (
    "tree_shake_icons",
    "track_widget_creation",
)

# The kernel-compile and asset attributes every platform test or app rule takes.
INTEGRATION_TEST_BUILD_ATTRS = KERNEL_COMPILE_ATTRS | BUNDLE_ATTRS | FLUTTER_CODE_ASSETS_ATTRS | {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in _WEB_RELEVANT_KEYS
}

COMMON_INTEGRATION_TEST_ATTRS = dict(INTEGRATION_TEST_BUILD_ATTRS)
COMMON_INTEGRATION_TEST_ATTRS["main"] = attr.label(
    doc = "The integration test .dart entry point. Optional when `srcs` " +
          "contains a single `.dart` file.",
    allow_single_file = [".dart"],
)
COMMON_INTEGRATION_TEST_ATTRS["package_name"] = attr.string(
    doc = "Dart package name (from pubspec.yaml). Defaults to target name.",
)
COMMON_INTEGRATION_TEST_ATTRS["app_srcs"] = attr.label_list(
    doc = "Dart source files for the application under test (e.g. `[\"lib/main.dart\"]`).",
    allow_files = [".dart"],
)
COMMON_INTEGRATION_TEST_ATTRS["tree_shake_icons"] = attr.bool(
    doc = "Whether to tree-shake icon fonts in non-debug builds.",
    default = False,
)
COMMON_INTEGRATION_TEST_ATTRS["platform"] = attr.string(
    doc = "Target platform to run the integration test on ('web', 'linux', 'android', or 'ios').",
    default = "web",
    values = ["web", "linux", "android", "ios"],
)
COMMON_INTEGRATION_TEST_ATTRS["profile"] = attr.bool(
    doc = "Whether to compile in profile mode.",
    default = False,
)
COMMON_INTEGRATION_TEST_ATTRS["flavor"] = attr.string(
    doc = "The application flavor the integration test compiles and bundles for.",
    default = "",
)
COMMON_INTEGRATION_TEST_ATTRS["data"] = attr.label_list(
    allow_files = True,
    doc = "Runtime data files made available in test runfiles.",
)
COMMON_INTEGRATION_TEST_ATTRS["env"] = attr.string_dict(
    doc = "Extra environment variables for the test runner process.",
)

# Tag selection, as `flutter test --tags` / `--exclude-tags` resolve it.
# Named `include_tags` / `exclude_tags` rather than `tags` because Bazel's
# own `tags` attribute means something else. A `--test_env=FLUTTER_TEST_TAGS=...`
# (or `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute.
#
# Library-level `@Tags` on the entrypoint need no attribute: they are extracted
# at build time and always honoured (see `extract_library_tags_action`).
COMMON_INTEGRATION_TEST_ATTRS["include_tags"] = attr.string_list(
    doc = "Run only tests matching every one of these `package:test` tag " +
          "selectors (library, group or test level), as `flutter test " +
          "--tags` intersects them. Each entry is a boolean selector " +
          "(`a && b`, `a || b`, `!a`, parentheses); several entries, or " +
          "comma-separated values in one entry, all have to match. A test " +
          "matching an `exclude_tags` selector never runs. An attribute " +
          "selection that matches no test fails the target.",
)
COMMON_INTEGRATION_TEST_ATTRS["exclude_tags"] = attr.string_list(
    doc = "Skip tests matching any of these `package:test` tag selectors " +
          "(library, group or test level), as `flutter test " +
          "--exclude-tags` unions them. Wins over `include_tags`.",
)
COMMON_INTEGRATION_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
COMMON_INTEGRATION_TEST_ATTRS.update(MODULAR_KERNEL_ATTRS)
COMMON_INTEGRATION_TEST_ATTRS.update(LAYERING_CHECK_ATTRS)
COMMON_INTEGRATION_TEST_ATTRS["_tool"] = attr.label(
    doc = "The `flutter_integration_test_runner` executable the test target runs.",
    default = Label("//flutter/private/tools:flutter_integration_test_runner"),
    executable = True,
    cfg = "exec",
)
COMMON_INTEGRATION_TEST_ATTRS["_library_tags_tool"] = LIBRARY_TAGS_TOOL_ATTR
COMMON_INTEGRATION_TEST_ATTRS["_bundle_tool"] = attr.label(
    doc = "The `bundle_app` tool that assembles the platform bundle directory.",
    default = Label("//flutter/private/tools:bundle_app"),
    executable = True,
    cfg = "exec",
)
COMMON_INTEGRATION_TEST_ATTRS["_sky_engine"] = attr.label(
    doc = "The `sky_engine` Dart package the kernel compile resolves `dart:` libraries from.",
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)
