"""Common Flutter application compilation pipeline.

Chains: sources → kernel .dill → AOT native code → asset bundle.

In debug mode (-c dbg): produces kernel .dill + assets (JIT, no gen_snapshot).
In fastbuild/opt mode: produces AOT native code + assets (release).
With -c opt and `--@rules_flutter//flutter:profile`: AOT for profile mode,
compiled by the profile gen_snapshot the toolchain selects.

This rule produces outputs that platform-specific wrappers consume:
1. AOT compiled native code (.so/.dylib) or kernel .dill (debug)
2. flutter_assets/ tree artifact
3. ICU data file (icudtl.dat)
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "DartDefinesInfo", "MODULAR_KERNEL_ATTRS", "MODULAR_KERNEL_TOOLCHAINS", "dart_link_hook_actions", "link_hook_runner_attr")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterInfo")
load("//flutter/private:code_assets.bzl", "FLUTTER_CODE_ASSETS_ATTRS", "flutter_code_assets")
load("//flutter/private:common.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "FLUTTER_APPLICATION_ATTRS", "FLUTTER_DEPS_DOC", "PLATFORM_CONSTRAINT_ATTRS", "check_hook_errors", "collect_native_libs", "declare_flutter_assets_dir", "detect_target_platform", "flutter_build_mode", "flutter_compile_kernel", "make_kernel_inputs", "make_kernel_target", "resolve_flutter_sdk_info")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action", "flutter_aot_gen_snapshot_flags", "flutter_aot_macho_action", "is_android_arm", "macho_snapshot_options")
load("//flutter/private:flutter_bundle.bzl", "BUNDLE_ATTRS", "flutter_bundle", "implements_android", "lock_android_plugins")
load("//flutter/private:flutter_defines_files.bzl", "DART_DEFINES_DOC", "app_defines_transition", "effective_flavor")
load("//flutter/private:flutter_info.bzl", "collect_flutter_plugin_deps")
load("//flutter/private:flutter_kernel_module.bzl", "flutter_app_kernel_module_aspect")
load("//flutter/private:layering_check.bzl", "LAYERING_CHECK_ASPECT", "LAYERING_CHECK_ATTRS", "layering_check_for", "layering_toolchains")

visibility(["//flutter/..."])

def _check_aot_supported(flutter_sdk_info, is_debug):
    """Guards: AOT cross-compilation between desktop OSes is not supported.

    target_os is non-empty only for cross-compilation toolchains.
    """
    if not is_debug and flutter_sdk_info.target_os in ("linux", "macos", "windows"):
        fail(
            "AOT cross-compilation between desktop platforms is not supported. " +
            "Flutter's gen_snapshot can only produce native code for the host OS. " +
            "Build on the target platform, or use debug mode (-c dbg).",
        )
    if not is_debug and not flutter_sdk_info.gen_snapshot:
        fail(
            (
                "No target-compatible AOT gen_snapshot toolchain is registered for this " +
                "host and target platform (target_os=%s). Apple AOT snapshots require a " +
                "Darwin-target gen_snapshot on a macOS host; build on macOS or use debug mode (-c dbg)."
            ) % (
                flutter_sdk_info.target_os or "native",
            ),
        )

def _has_constraint(ctx, constraint):
    """Whether the target platform has the constraint value behind a private attribute."""
    return ctx.target_platform_has_constraint(constraint[platform_common.ConstraintValueInfo])

def _detect_application_platform(ctx):
    """Reads the platform constraints into flags plus a target-platform string."""
    is_macos = _has_constraint(ctx, ctx.attr._macos_constraint)
    is_ios = _has_constraint(ctx, ctx.attr._ios_constraint)
    is_linux = _has_constraint(ctx, ctx.attr._linux_constraint)
    is_windows = _has_constraint(ctx, ctx.attr._windows_constraint)
    is_android = _has_constraint(ctx, ctx.attr._android_constraint)
    return struct(
        target_platform = detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android),
        is_ios = is_ios,
        is_macos = is_macos,
    )

def _fail_on_hook_errors(ctx):
    """Fails naming the packages in the closure whose build hook cannot run.

    Checked before any compilation so the build fails on the cause rather
    than at runtime on an unresolved `@Native` symbol.
    """
    hook_err = check_hook_errors(ctx.label, ctx.attr.deps)
    if hook_err != None:
        fail(hook_err)

def _compile_application_kernel(
        ctx,
        flutter_sdk_info,
        target_platform,
        assets,
        flutter_assets,
        recorded_uses):
    """Runs Step 1: mode-aware kernel compilation."""
    return flutter_compile_kernel(
        ctx = ctx,
        flutter_sdk_info = flutter_sdk_info,
        target = make_kernel_target(target_platform = target_platform),
        inputs = make_kernel_inputs(
            native_assets_manifest = assets.manifest_file,
            native_assets = assets.native_assets,
            # As stock `flutter`: tracked in debug and profile, never in release.
            track_widget_creation = ctx.attr.track_widget_creation and flutter_build_mode(ctx) != "release",
            assets_dir = flutter_assets,
            recorded_uses = recorded_uses,
        ),
    )

def _compile_application_aot(ctx, flutter_sdk_info, is_debug, is_ios, is_macos, kernel_dill, strip):
    """Runs Step 2: AOT compile in the platform's format (release only).

    Collects gen_snapshot extra flags from user attrs (shared with
    flutter_aot_target so the two stay in step). Obfuscation forces
    `--strip`: unstripped DWARF would leak the original names.
    """
    wants_analyze_size = getattr(ctx.attr, "analyze_size", False) or ("analyze_size" in getattr(ctx, "features", []))
    if wants_analyze_size and is_debug:
        fail("%s: analyze_size is not supported in debug mode: gen_snapshot does not run in debug mode" % ctx.label)
    if is_debug:
        return struct(
            aot_output = None,
            debug_info_output = None,
            obfuscation_map_output = None,
            size_output = None,
            strip = strip,
        )
    extra_flags, extra_outputs, debug_info_output, obfuscation_map_output, strip = flutter_aot_gen_snapshot_flags(
        ctx,
        strip,
    )
    size_output = None
    if wants_analyze_size:
        for f in extra_outputs:
            if f.basename == ctx.label.name + "_size.json":
                size_output = f
                break
    if is_ios or is_macos:
        aot_output = ctx.actions.declare_file(ctx.label.name + ".dylib")
        flutter_aot_macho_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = aot_output,
            macho = macho_snapshot_options(
                min_os_version = ctx.attr.min_os_version if ctx.attr.min_os_version else None,
            ),
            strip = strip,
            extra_flags = extra_flags,
            extra_outputs = extra_outputs,
        )
    else:
        aot_output = ctx.actions.declare_file(ctx.label.name + ".so")
        flutter_aot_elf_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = aot_output,
            strip = strip,
            extra_flags = extra_flags,
            extra_outputs = extra_outputs,
            android_arm = is_android_arm(flutter_sdk_info),
        )
    return struct(
        aot_output = aot_output,
        debug_info_output = debug_info_output,
        obfuscation_map_output = obfuscation_map_output,
        size_output = size_output,
        strip = strip,
    )

def _collect_application_native_libs(ctx):
    """Collects native shared libraries from native_deps + transitive plugin deps."""
    native_libs = collect_native_libs(ctx.attr.native_deps)
    transitive_native_depsets = [
        dep[FlutterInfo].transitive_native_libs
        for dep in ctx.attr.deps
        if FlutterInfo in dep
    ]
    if transitive_native_depsets:
        # lint-allow: depset-flatten terminal: the application bundles its closure's native libraries, once
        native_libs.extend(depset(transitive = transitive_native_depsets).to_list())
    return native_libs

def _run_application_link_hooks(ctx, run_link_hooks, recorded_uses, transitive_data_assets):
    """Runs Step 2b: package link hooks over the recorded uses.

    Each emits the data assets declared in `link_hook_assets`, bundled below
    beside the native assets' data assets.
    """
    if not run_link_hooks:
        return transitive_data_assets, []
    link = dart_link_hook_actions(
        ctx,
        runner = ctx.executable._link_hook_runner,
        sdk = ctx.toolchains["@rules_dart//dart:exec_tools_toolchain_type"].dart_sdk_info,
        recorded_uses = recorded_uses,
        deps = ctx.attr.deps,
        data_asset_ids = ctx.attr.link_hook_assets,
        name = ctx.label.name + "_link_hooks",
    )
    return depset(link.assets, transitive = [transitive_data_assets]), link.validation_outputs

def _aggregate_application_plugins(ctx):
    """Aggregates the plugin channels from deps for the registrant generators.

    These are what the platform registrant generators and desktop runners
    read back off this target — via FlutterApplicationInfo, since an
    application is the end of the library graph and does not contribute to
    another one.
    """
    return collect_flutter_plugin_deps(ctx.attr.deps)

def _index_bundled_libraries(native_libs):
    """Indexes every loose `native_deps` library this app carries by path.

    Deduplicated by path because nothing stops one library arriving twice.
    The code assets' libraries are one directory, whose files the build
    hooks name only when they run; it joins the default outputs on its own.
    """
    bundled_native_libs = {}
    for lib in native_libs:
        bundled_native_libs[lib.path] = lib
    return bundled_native_libs

def _application_default_files(
        flutter_assets,
        package_config,
        native_assets_manifest_file,
        bundled_native_libs,
        aot_output,
        is_debug,
        kernel_dill,
        size_output = None):
    """Assembles the DefaultInfo file list, including the manifest-named code assets.

    The code-asset libraries join `default_files` with the manifest that names
    them. Declaring an output is what makes its path true: the manifest is
    built here and launchers read these files back off this target, and a
    path named by a build that did not write it fails far from its cause.
    """
    default_files = [
        flutter_assets,
        package_config,
        native_assets_manifest_file,
    ] + bundled_native_libs.values()
    if aot_output:
        default_files.append(aot_output)
    if size_output:
        default_files.append(size_output)
    if is_debug:
        default_files.append(kernel_dill)
    return default_files

def _application_providers(flutter_sdk_info, is_debug, outputs, plugins, android_plugins = None):
    """Assembles the result providers for the compiled application."""
    output_groups = {
        "native_assets_manifest": depset([outputs.native_assets_manifest_file]),
        "bundled_code_assets": depset(outputs.bundled_code_assets),
    }
    if android_plugins:
        output_groups["android_plugins"] = depset([android_plugins])
    if outputs.debug_info_output:
        output_groups["debug_info"] = depset([outputs.debug_info_output])
    if outputs.obfuscation_map_output:
        output_groups["obfuscation_map"] = depset([outputs.obfuscation_map_output])
    if outputs.size_output:
        output_groups["analyze_size"] = depset([outputs.size_output])

    # Every hook runs whenever the app builds, even one that emits no asset, so
    # its verdict on the program is never skipped; the strict-layering check
    # on `main`, `srcs` and the first-party libraries below rides beside it.
    output_groups["_validation"] = outputs.validation

    providers = [
        DefaultInfo(files = depset(outputs.default_files)),
        FlutterApplicationInfo(
            aot_output = outputs.aot_output,
            aot_strip = outputs.aot_strip,
            obfuscation_map = outputs.obfuscation_map_output,
            kernel_dill = outputs.kernel_dill if is_debug else None,
            flutter_assets = outputs.flutter_assets,
            icu_data = flutter_sdk_info.icu_data,
            native_libs = outputs.native_libs,
            is_debug = is_debug,
            package_config = outputs.package_config,
            native_assets_manifest = outputs.native_assets_manifest_file,
            bundled_code_assets = outputs.bundled_code_assets,
            bundled_data_assets = outputs.transitive_data_assets,
            apple_privacy_manifests = plugins.apple_privacy_manifests,
            plugins = plugins.all_plugins,
            apple_plugin_libraries = plugins.apple_plugin_libraries,
            linux_plugin_libraries = plugins.linux_plugin_libraries,
            windows_plugin_libraries = plugins.windows_plugin_libraries,
        ),
    ]
    providers.append(OutputGroupInfo(**output_groups))
    return providers

def _prepare_native_assets(ctx):
    """The application's native-assets manifest and bundled code-asset libraries."""
    assets = flutter_code_assets(ctx)
    return struct(
        manifest_file = assets.manifest,
        native_assets = assets.any,
        transitive_data_assets = assets.data_assets,
        bundled_code_assets = assets.bundled,
    )

def _flutter_application_impl(ctx):
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)

    is_debug = flutter_build_mode(ctx) == "debug"

    # Profile strips like release, as `flutter build --profile` does: the
    # profiler names Dart code from the snapshot, not from native symbols.
    # An Android app whose bundle carries native symbols (`flutter_android_bundle`
    # sets the flag) keeps them here, as a stock build does: its packer strips.
    strip = ctx.var["COMPILATION_MODE"] == "opt" and not (
        flutter_sdk_info.target_os == "android" and ctx.attr._android_aot_symbols[BuildSettingInfo].value
    )

    _check_aot_supported(flutter_sdk_info, is_debug)

    platform = _detect_application_platform(ctx)

    _fail_on_hook_errors(ctx)

    # The closure's code assets, so the manifest exists before the kernel
    # compile (the frontend_server reads it via --native-assets).
    assets = _prepare_native_assets(ctx)

    # Declared before the kernel compile, which is told whether the app has one.
    # Declaring an output is independent of registering the action that fills
    # it, so the ordering costs nothing.
    flutter_assets = declare_flutter_assets_dir(ctx)

    # Link hooks and the icon tree shaker run over the uses the AOT compile
    # records, so only a release or profile build has any: a JIT compile
    # tree-shakes nothing and records nothing, and a debug build runs no hook
    # and bundles no asset.
    run_link_hooks = bool(ctx.attr.link_hook_assets) and not is_debug
    shake_icons = ctx.attr.tree_shake_icons and not is_debug
    recorded_uses = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json") if run_link_hooks or shake_icons else None

    # Step 1: Kernel compilation (mode-aware: debug uses debug dill, no AOT).
    compilation = _compile_application_kernel(
        ctx,
        flutter_sdk_info,
        platform.target_platform,
        assets,
        flutter_assets,
        recorded_uses,
    )

    # Step 2: AOT compile — choose format based on target platform.
    aot = _compile_application_aot(
        ctx,
        flutter_sdk_info,
        is_debug,
        platform.is_ios,
        platform.is_macos,
        compilation.kernel_dill,
        strip,
    )

    native_libs = _collect_application_native_libs(ctx)

    # Step 2b: package link hooks over the recorded uses. Each emits the data
    # assets declared in `link_hook_assets`, bundled below beside the native
    # assets' data assets.
    transitive_data_assets, link_hook_validation = _run_application_link_hooks(
        ctx,
        run_link_hooks,
        recorded_uses,
        assets.transitive_data_assets,
    )

    # Step 3: the asset bundle, written by the Flutter tool's own code from
    # the pubspec. The link hooks' data assets are bundled under
    # `packages/<package>/<name>`. Only a release or profile build reads the
    # recorded uses, to shake icon fonts.
    flutter_bundle(
        ctx,
        flutter_sdk_info,
        flutter_assets,
        target_platform = platform.target_platform,
        mode = flutter_build_mode(ctx),
        flavor = effective_flavor(ctx) or None,
        recorded_uses = recorded_uses if shake_icons else None,
        data_assets = transitive_data_assets,
        native_assets_manifest = assets.manifest_file,
    )

    # Aggregate the plugin channels from deps. These are what the platform
    # registrant generators and desktop runners read back off this target —
    # via FlutterApplicationInfo, since an application is the end of the
    # library graph and does not contribute to another one.
    plugins = _aggregate_application_plugins(ctx)

    built = struct(
        flutter_assets = flutter_assets,
        native_assets_manifest_file = assets.manifest_file,
        native_libs = native_libs,
        bundled_code_assets = assets.bundled_code_assets,
        aot_output = aot.aot_output,
        size_output = aot.size_output,
    )
    default_files = _application_default_files(
        built.flutter_assets,
        compilation.package_config,
        built.native_assets_manifest_file,
        _index_bundled_libraries(built.native_libs),
        built.aot_output,
        is_debug,
        compilation.kernel_dill,
        built.size_output,
    ) + built.bundled_code_assets

    outputs = struct(
        kernel_dill = compilation.kernel_dill,
        package_config = compilation.package_config,
        native_assets_manifest_file = assets.manifest_file,
        bundled_code_assets = assets.bundled_code_assets,
        transitive_data_assets = transitive_data_assets,
        aot_output = aot.aot_output,
        aot_strip = aot.strip,
        debug_info_output = aot.debug_info_output,
        obfuscation_map_output = aot.obfuscation_map_output,
        size_output = aot.size_output,
        validation = depset(link_hook_validation, transitive = [layering_check_for(ctx)]),
        flutter_assets = flutter_assets,
        native_libs = native_libs,
        default_files = default_files,
    )

    # For an Android app built from its Gradle model: the plugins with an Android side, which the
    # pin was written for and its check compares. All those of the app's own lock, with their
    # versions (`complete`); or, when the app's packages come from another lock, those the app
    # depends on (`partial`: the pin may hold more).
    plugins_file = None
    if flutter_sdk_info.target_os == "android":
        android_plugins = lock_android_plugins(ctx)
        kind = "complete"
        if android_plugins == None:
            kind = "partial"
            android_plugins = sorted([p.name + " " for p in plugins.all_plugins if implements_android(p)])
        plugins_file = ctx.actions.declare_file(ctx.label.name + ".android_plugins")
        ctx.actions.write(plugins_file, "".join([line + "\n" for line in [kind] + android_plugins]))
    return _application_providers(flutter_sdk_info, is_debug, outputs, plugins, plugins_file)

flutter_application = rule(
    implementation = _flutter_application_impl,
    attrs = dicts.add(
        FLUTTER_APPLICATION_ATTRS | MODULAR_KERNEL_ATTRS | BUNDLE_ATTRS | FLUTTER_CODE_ASSETS_ATTRS,
        {
            "analyze_size": attr.bool(
                default = False,
                doc = (
                    "Passes `--print-instructions-sizes-to` to `gen_snapshot` and " +
                    "writes a size breakdown JSON to `<name>_size.json`."
                ),
            ),
            "_android_aot_symbols": attr.label(
                doc = "Whether an Android AOT library keeps its symbol table (set by `flutter_android_bundle`).",
                default = Label("//flutter/private:android_aot_symbols"),
            ),
            # The module aspect registers nothing outside a debug build. There the app's defines, flavor and `dart_defines` are the configuration of its `deps`, so every
            # module compiles with them and the app stays modular (see `app_defines_transition`).
            "deps": attr.label_list(
                doc = FLUTTER_DEPS_DOC,
                providers = [DartInfo],
                aspects = [flutter_app_kernel_module_aspect, LAYERING_CHECK_ASPECT],
                cfg = app_defines_transition,
            ),
            # Configured like `deps`, so the app and its modules read one defines file.
            "dart_defines": attr.label(
                doc = DART_DEFINES_DOC,
                providers = [DartDefinesInfo],
                cfg = app_defines_transition,
            ),
        },
        PLATFORM_CONSTRAINT_ATTRS,
        link_hook_runner_attr(),
        LAYERING_CHECK_ATTRS,
    ),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:aot_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:font_subset_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + layering_toolchains(MODULAR_KERNEL_TOOLCHAINS) + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter application to AOT native code + asset bundle (release) or kernel .dill + assets (debug).",
)
