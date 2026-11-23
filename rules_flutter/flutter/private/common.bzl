"""Shared utilities for Flutter rules.

Package config generation, transitive source collection, and the shared
compilation pipeline (kernel → AOT → assets → FFI collection) used by
flutter_application, flutter_android_bundle, and flutter_ios_application.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs", "derive_lib_root", "generate_dev_package_config", _COPY_TO_DIRECTORY_TOOLCHAINS = "COPY_TO_DIRECTORY_TOOLCHAINS")
load("//flutter:providers.bzl", "FlutterCompiledShadersInfo", "FlutterInfo", "FlutterNativeLibraryInfo", _resolve_exec_dart = "resolve_exec_dart", _resolve_exec_dart_vm = "resolve_exec_dart_vm", _resolve_flutter_sdk_info = "resolve_flutter_sdk_info")
load("//flutter/private:app_entrypoint.bzl", "AGENT_DIR", "APP_SCHEME", "agent_layout_path", "app_main_location", "app_scheme_location", "app_scheme_sources", "compile_kernel_package_config", "resolve_kernel_entrypoint", "stage_agent_extensions", "synthesize_app_package", "with_root")
load("//flutter/private:asset_keys.bzl", "bundle_asset_entries", "fail_asset_key_conflict", "is_within_package", "relative_key")
load("//flutter/private:asset_uri.bzl", "encode_asset_key")
load("//flutter/private:flutter_asset_bundle_action.bzl", "flutter_asset_bundle_action", "make_bundle_content", "make_tree_shake")
load(
    "//flutter/private:flutter_compile.bzl",
    "INCREMENTAL_KERNEL_ATTRS",
    "flutter_kernel_compile_action",
    "flutter_kernel_dills",
    "flutter_kernel_options",
    "flutter_kernel_outputs",
    "flutter_kernel_sources",
)
load(
    "//flutter/private:flutter_defines_files.bzl",
    "entry_dart_env",
    _DEFAULT_FLAVOR_ATTR = "DEFAULT_FLAVOR_ATTR",
    _DEFINES_FILES_APPLICATION_ATTRS = "DEFINES_FILES_APPLICATION_ATTRS",
    _EXTRA_DART_DEFINES_ATTR = "EXTRA_DART_DEFINES_ATTR",
    _collect_define_flagfiles = "collect_define_flagfiles",
    _merge_dart_defines = "merge_dart_defines",
)
load("//flutter/private:flutter_info.bzl", "collect_flutter_plugin_deps")
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "compile_flutter_modular_app_kernel",
    "flutter_closure_twins",
    "flutter_modular_test_tools",
)
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions", "build_pub_contributions", "dedupe_shader_jobs", "pub_shader_matches_target", "resolve_font_subset_tools")
load("//flutter/private:flutter_shader_compile.bzl", "flutter_shader_compile_action", "shader_compile_tools")
load("//flutter/private:native_sources.bzl", "native_sources_aspect")
load("//flutter/private:plugin_registrant.bzl", "generate_dart_plugin_registrant", "generate_dev_plugin_registrants")
load("//flutter/private:validation.bzl", _detect_target_platform = "detect_target_platform")

visibility(["//flutter/..."])

COPY_TO_DIRECTORY_TOOLCHAINS = _COPY_TO_DIRECTORY_TOOLCHAINS
detect_target_platform = _detect_target_platform
resolve_exec_dart = _resolve_exec_dart
resolve_exec_dart_vm = _resolve_exec_dart_vm
resolve_flutter_sdk_info = _resolve_flutter_sdk_info
DEFINES_FILES_APPLICATION_ATTRS = _DEFINES_FILES_APPLICATION_ATTRS
EXTRA_DART_DEFINES_ATTR = _EXTRA_DART_DEFINES_ATTR
collect_define_flagfiles = _collect_define_flagfiles
merge_dart_defines = _merge_dart_defines

def check_unreplaced_hooks(label, deps):
    """Returns an error naming pub packages whose build hook nothing replaces.

    A pub package shipping `hook/build.dart` builds its native library at
    `pub get` time. Bazel cannot run that hook, so without a replacement the
    package's `@Native` bindings resolve to nothing: the manifest is simply
    missing an entry, and the failure surfaces at runtime as "couldn't resolve
    native function" with nothing pointing at the cause.

    Checked at the application rather than when the spoke repo is generated.
    `flutter.pub()` materialises the whole lock file, so failing at generation
    would fail over packages nothing depends on, and on platforms where the
    hook is irrelevant. Only a package an application actually reaches is a
    problem, and only here is the depending target known.

    rules_dart applies the same rule at `dart_binary` with its own copy. The
    two differ only in the remediation they suggest — a Flutter user fixes this
    through `flutter.pub()`, not `pub.from_lock()` — so this collapses into one
    shared helper once rules_dart exports one that takes the hint as an
    argument.

    Args:
      label: The consuming target's label, for the message.
      deps: The application's `deps`, each providing `DartInfo`.

    Returns:
      An error message string, or `None`.
    """
    packages = depset(
        transitive = [dep[DartInfo].transitive_packages for dep in deps],
    ).to_list()

    # Guarded for the same reason `bridge_dart_code_assets` guards
    # `code_assets`: `DartPackageInfo` is rules_dart's, and it deliberately
    # tolerates a record built against a rules_dart predating a field. Absent
    # is not "unknown" here — a producer with no such field could not have
    # recorded a hook — so it reads as "no hook". Unguarded, the read fails
    # analysis on records that are not even offenders.
    offenders = [
        pkg
        for pkg in packages
        if hasattr(pkg, "has_unreplaced_hook") and pkg.has_unreplaced_hook
    ]
    if not offenders:
        return None
    return (
        "%s depends on pub package(s) that build native code with a hook " +
        "Bazel cannot run:\n%s\n\n" +
        "Their `@Native` bindings will not resolve at runtime. Either:\n" +
        "  - add a `dart_code_asset` to the owning package's `code_assets` " +
        "(for a pub package, that means a `flutter.plugin_overlays` entry, " +
        "or a curated entry upstream in rules_dart), or\n" +
        "  - list the package in `flutter.pub(ignore_hooks = [...])` if its " +
        "native code is genuinely unused here."
    ) % (
        label,
        "\n".join([
            "  - %s (%s)" % (pkg.package_name, pkg.has_unreplaced_hook)
            for pkg in offenders
        ]),
    )

# Implicit attr for the build-time `@Tags` extractor (see
# `//flutter/private/tools:extract_library_tags`). The test isolate never
# parses annotations — `package:test`'s analyzer-backed loader does that for
# `flutter test`, but under `flutter_tester` only this action reads the
# entrypoint — so every test rule extracts the tags at build time and ships
# the JSON to the runner, which injects them as the root group's metadata.
LIBRARY_TAGS_TOOL_ATTR = attr.label(
    doc = "Build-time tool that extracts the test entrypoint's `@Tags` into JSON for the runner.",
    default = Label("//flutter/private/tools:extract_library_tags"),
    executable = True,
    cfg = "exec",
)

def extract_library_tags_action(ctx, main_file):
    """Extract the entrypoint's `@Tags` into a JSON file for the test runner.

    Only the entrypoint file is read. An imported file's own `@Tags` stays
    invisible, exactly as under `flutter test`: the test_core loader parses
    each suite file, and only the suite file's annotations become that suite's
    root metadata.

    Args:
        ctx: Rule context. Must declare `_library_tags_tool`
            (`LIBRARY_TAGS_TOOL_ATTR`).
        main_file: The test entrypoint source `File`.

    Returns:
        The `{"tags": [...]}` JSON `File`, to ship in runfiles and name from
        `FLUTTER_TEST_LIBRARY_TAGS`.
    """
    output = ctx.actions.declare_file(ctx.label.name + ".library_tags.json")
    ctx.actions.run(
        executable = ctx.executable._library_tags_tool,
        arguments = [main_file.path, output.path],
        inputs = [main_file],
        outputs = [output],
        mnemonic = "FlutterExtractLibraryTags",
        progress_message = "Extracting library tags %s" % ctx.label,
        toolchain = None,
    )
    return output

def collect_native_libs(native_deps):
    """Collect shared libraries from native_deps for dart:ffi.

    Filters DefaultInfo files by extension (.so, .dylib, .dll).

    Args:
        native_deps: List of targets providing DefaultInfo with shared libs.

    Returns:
        List of shared library Files.
    """
    libs = []
    for dep in native_deps:
        libs.extend([f for f in dep[DefaultInfo].files.to_list() if f.extension in ("so", "dylib", "dll")])
    return libs

def resolve_dev_generated_sources(paths, candidates):
    """The Files behind `_dev_config.json`'s `generatedSourcePaths`.

    `_dev_config.json` sends the frontend_server to read these paths. Nothing
    asks for them by label, and being an action's *input* is not what makes bazel
    write a file to this machine — a cache hit (disk or remote) runs no action, so
    an input-only file is never materialized and the dev tool reports "the build
    declared files it did not write". Declaring them is what makes the paths true.

    Args:
        paths: The `generatedSourcePaths` going into the dev config.
        candidates: The Files the paths were derived from.

    Returns:
        The Files, in the order [paths] names them.
    """
    by_path = {f.path: f for f in candidates}
    missing = [p for p in paths if p not in by_path]
    if missing:
        fail(
            "dev config names generated sources with no File to declare: " +
            ", ".join(missing) +
            "\nThey would be written into _dev_config.json for the " +
            "frontend_server to read and never materialized by the build.",
        )
    return [by_path[p] for p in paths]

def collect_binding_contracts(native_deps):
    """Pair each `native_deps` entry's libraries with its declared binding contract.

    Only a `flutter_native_library` wrapper declares one. A bare shared library
    contributes a pair with an empty contract rather than being left out: "this
    library has nothing describing its bindings" is the state the dev tool has to
    be able to name, and a library missing from the map would read as a library
    that is not bundled.

    Args:
        native_deps: The `native_deps` targets, wrapped or bare.

    Returns:
        List of `struct(library = File, contract = tuple[File])`, one per shared
        library.
    """
    pairs = []
    for dep in native_deps:
        if FlutterNativeLibraryInfo in dep:
            contract = tuple(dep[FlutterNativeLibraryInfo].binding_contract.to_list())
            for lib in dep[FlutterNativeLibraryInfo].libraries.to_list():
                pairs.append(struct(library = lib, contract = contract))
        else:
            pairs.extend([struct(library = f, contract = ()) for f in collect_native_libs([dep])])
    return pairs

def _kernel_source_inputs(ctx):
    """Collect the kernel compile's sources and synthesize the app package."""
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list()
    packages = collect_packages(ctx.attr.deps)

    # Register the app itself as a package so the frontend_server keys the
    # entrypoint as `package:<name>/main.dart` — the URI the dev tool's
    # incremental compiler uses (without this, hot-reload deltas keyed via
    # sandbox `file://` URIs can't be matched against the kernel's libraries).
    app_pkg_name = ctx.attr.package_name

    # The app's own library root, which is what `package:<name>/…` resolves
    # against. Derived from the label rather than assumed to be the workspace
    # root, so an app in a nested Bazel package registers a `rootUri` pointing
    # at its own directory; assuming `""` pointed every nested app's
    # `package:` URIs at whatever sits in the *workspace's* `lib/`.
    app_lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    packages = synthesize_app_package(
        ctx.label,
        packages,
        app_pkg_name,
        app_lib_root,
        ctx.attr.language_version,
    )

    # Include the app's own `main` so the synthesized package keyed as
    # `package:<name>/main.dart` (hot-reload URI parity) is co-located with
    # its lib/ siblings when any of them are generated.
    colocate_inputs = all_srcs + ([ctx.file.main] if ctx.file.main else [])
    return struct(
        all_srcs = all_srcs,
        packages = packages,
        app_pkg_name = app_pkg_name,
        app_lib_root = app_lib_root,
        colocate_inputs = colocate_inputs,
    )

def _kernel_dev_config(ctx, st, mode):
    """Write the debug-only dev package config; return the hot-reload metadata."""
    emit = mode == "debug"
    dev_package_config = None
    dev_filesystem_roots = []
    dev_filesystem_scheme = ""
    dev_generated_source_paths = []
    dev_generated_source_uris = []
    dev_generated_source_files = []
    dev_source_packages = []
    dev_app_sources = []
    main_location = app_main_location(st.app_pkg_name, st.app_lib_root, ctx.file.main) if ctx.file.main else None
    app_entrypoint_uri = main_location.uri if main_location else None
    if emit:
        dev_package_config = ctx.actions.declare_file(ctx.label.name + ".dev_package_config.json")
        dev_pc = generate_dev_package_config(st.packages, st.colocate_inputs, dev_package_config, scheme = APP_SCHEME)
        ctx.actions.write(dev_package_config, dev_pc.content)

        # A `main` with no `package:` URI is compiled under the app scheme,
        # and the dev loop's compiler has to mount the same root to name it
        # the same way.
        dev_filesystem_roots = with_root(dev_pc.filesystem_roots, main_location.root if main_location else None)
        dev_filesystem_scheme = dev_pc.scheme
        dev_app_sources = []
        if ctx.file.main:
            dev_app_sources = app_scheme_sources(st.app_pkg_name, st.app_lib_root, ctx.file.main, ctx.files.srcs)
        dev_generated_source_paths = dev_pc.generated_source_paths
        dev_generated_source_uris = dev_pc.generated_source_uris
        dev_source_packages = dev_pc.source_packages

        # Resolved from the same list the paths came from, so the two cannot
        # drift — see [resolve_dev_generated_sources] for why declaring them is
        # what makes the config's paths true.
        dev_generated_source_files = resolve_dev_generated_sources(
            dev_generated_source_paths,
            st.colocate_inputs,
        )
    return struct(
        emit = emit,
        package_config = dev_package_config,
        filesystem_roots = dev_filesystem_roots,
        filesystem_scheme = dev_filesystem_scheme,
        generated_source_paths = dev_generated_source_paths,
        generated_source_uris = dev_generated_source_uris,
        generated_source_files = dev_generated_source_files,
        source_packages = dev_source_packages,
        app_sources = dev_app_sources,
        entrypoint_uri = app_entrypoint_uri,
    )

def _resolve_kernel_platform_dill(platform_dill, aot, mode, flutter_sdk_info):
    """Resolve the platform dill for a kernel compile, failing when absent."""
    if platform_dill != None:
        return platform_dill

    # Profile and debug compile against the non-product platform: the product
    # one has the VM service and the profiling hooks compiled out, and is not
    # fetched in `-c dbg`.
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

def _build_info_json(ctx, plan, inputs, target_platform):
    """The JSON build record of a debug app, or None when the app carries none."""

    # A debug app describes its own build to itself. `ext.rules_flutter.buildInfo`
    # hands this straight back to the dev tool, which needs it because
    # `flutter_bazel attach` starts from nothing but a VM service URL: it has no
    # `-d` device, no knowledge of the configuration, and no way to ask the user
    # for flags they never typed. Debug only: profile mode must look like
    # release on the agent surface, and there is no dev loop to serve in AOT.
    #
    # It reaches the app through the generated registrant, never as a compile-time
    # define, so it is no argument of the kernel compile. It is deliberately NOT
    # part of `user_defines` either: that list is replayed by the dev tool's own
    # frontend_server, which runs against the host-configured dev build. The dev
    # tool re-injects the value it read from the running app instead.
    assets_dir = inputs.assets_dir
    if assets_dir == None or plan.aot or plan.mode != "debug":
        return None
    return json.encode({
        "label": str(ctx.label),
        "compilationMode": ctx.var["COMPILATION_MODE"],
        "platformBuildArgs": inputs.platform_build_args,
        "dartDefines": merge_dart_defines(ctx),
        "assetsDir": assets_dir.path,
        # The platform this kernel was compiled for. The dev tool's own
        # build runs in the host configuration, so only the app can say
        # which platform-filtered plugin registrant its reloads need.
        "targetPlatform": target_platform,
    })

def _kernel_registrant(ctx, target_platform, agent, emit_dev_config, build_info):
    """Collect plugins and generate the registrant plus dev-loop registrants."""

    # Collect plugins from deps and generate the registrant. The registrant is
    # a side library (upstream _PluginRegistrant shape) the engine invokes
    # before main() on every root-isolate launch — including hot restart.
    plugins = collect_flutter_plugin_deps(ctx.attr.deps).all_plugins
    registrant = generate_dart_plugin_registrant(
        ctx,
        plugins,
        target_platform = target_platform,
        agent_import = agent.agent.basename if agent.agent else None,
        native_agent_import = agent.native_agent.basename if agent.native_agent else None,
        build_info_json = build_info if agent.agent else None,
        declared_path = agent_layout_path(ctx, "plugin_registrant.dart") if agent.constant else None,
    )
    registrant_location = app_scheme_location(registrant) if registrant else None

    # Dev-loop registrants, one per platform (debug only). The dev tool reads
    # these from a HOST-configuration build while the app can be running on a
    # different platform, so the host build emits every platform's filter and
    # the dev tool selects by the platform the running app reports. See
    # generate_dev_plugin_registrants.
    dev_plugin_registrants = {}
    if emit_dev_config:
        dev_plugin_registrants = generate_dev_plugin_registrants(
            ctx,
            plugins,
            agent_import = agent.dev_agent,
            native_agent_import = agent.dev_native_agent,
        )
    return struct(registrant = registrant, location = registrant_location, dev_registrants = dev_plugin_registrants)

def _kernel_compile_flags(ctx, track_widget_creation, mode, aot):
    """Merge frontend flags and defines for a kernel compile."""

    # Collect extra frontend_server flags from build flag attrs.
    extra_frontend_flags = ["--track-widget-creation"] if track_widget_creation else []

    # Merge defines with mode-specific Dart VM flags. user_defines (attr +
    # extra_dart_defines flag, no mode keys) is surfaced in the return struct
    # so dev-config writers can replay it on the dev tool's frontend_server.
    user_defines = merge_dart_defines(ctx)
    all_defines = list(user_defines)

    # Only `flutter_application` declares `dart_defines`; every other rule that
    # shares this helper compiles exactly as it did before. The file is carried
    # as a File so the whole-program compile can pass it as `@<path>` (before
    # the `-D`s, which win) and declare it as an input without reading it at
    # analysis. The modular compile reads it through `entry_dart_env`.
    define_flagfiles = [f for f in [entry_dart_env(ctx).flagfile] if f != None] if hasattr(ctx.attr, "dart_defines") else []
    mode_defines = ["dart.vm.profile=true"] if mode == "profile" else ["dart.vm.product=true"] if aot else []
    all_defines.extend(mode_defines)

    return struct(
        extra_frontend = extra_frontend_flags,
        user_defines = user_defines,
        all_defines = all_defines,
        define_flagfiles = define_flagfiles,
    )

def make_kernel_target(aot = None, platform_dill = None, target_platform = None, frontend_server_target = "flutter"):
    """Which kernel to compile: AOT or JIT, which platform dill, for which platform, through which frontend.

    Args:
        aot: If set, override AOT mode. Otherwise determined by compilation mode.
        platform_dill: If set, override platform dill. Otherwise determined by compilation mode.
        target_platform: Optional platform string (e.g. "web", "linux", "android").
            When set, only plugins with dartPluginClass on that platform are registered.
        frontend_server_target: Frontend server --target flag ("flutter" or "dartdevc" for web).

    Returns:
        A struct with `aot`, `platform_dill`, `target_platform` and
        `frontend_server_target`.
    """
    return struct(
        aot = aot,
        platform_dill = platform_dill,
        target_platform = target_platform,
        frontend_server_target = frontend_server_target,
    )

def make_kernel_inputs(
        native_assets_manifest = None,
        track_widget_creation = False,
        assets_dir = None,
        platform_build_args = [],
        recorded_uses = None,
        native_assets = []):
    """What else feeds the kernel compile besides sources and target.

    Args:
        native_assets_manifest: Optional File pointing at the
            `native_assets.json` manifest (the JSON shape the
            frontend_server reads via `--native-assets`). Always passed
            through when set; the manifest's contents may be empty.
        track_widget_creation: Whether to pass `--track-widget-creation` to
            the frontend server. Passed rather than read off `ctx.attr`,
            because the rules calling this do not share one attribute set —
            `flutter_kernel_target` has no such attr — and a rule that has no
            opinion should say `False` rather than be probed for one.
        assets_dir: The declared `flutter_assets/` tree artifact, from
            `declare_flutter_assets_dir`. Supplying it is what makes a debug
            build carry `rules_flutter.build_info`; the rules with no asset
            bundle of their own (`flutter_kernel_target`,
            `flutter_aot_target`) leave it None and emit no define, because
            an app with no assets tree has nothing for the dev tool to watch.
        platform_build_args: Flags from `launch_build_args`, recorded in
            `build_info` so an attaching dev tool can reproduce this
            configuration. Only meaningful alongside `assets_dir`.
        recorded_uses: Optional declared File for the compiler's recorded
            `@RecordUse` uses, the input of package link hooks. Pass it for
            AOT compiles only.
        native_assets: The resolved native asset list the manifest was
            written from; a non-empty list keeps the whole-program compile.

    Returns:
        A struct with `native_assets_manifest`, `track_widget_creation`,
        `assets_dir`, `platform_build_args`, `recorded_uses` and `native_assets`.
    """
    return struct(
        native_assets_manifest = native_assets_manifest,
        track_widget_creation = track_widget_creation,
        assets_dir = assets_dir,
        platform_build_args = platform_build_args,
        recorded_uses = recorded_uses,
        native_assets = native_assets,
    )

_CONSTANT_REGISTRANT_URI = "%s:///%s/plugin_registrant.dart" % (APP_SCHEME, AGENT_DIR)

def _debug_registrant_modular(agent, reg, twins):
    """Whether the staged agent, native agent and registrant can ride the modular entry module."""
    if not (reg.registrant or agent.agent):
        return True
    staged = twins and agent.constant and agent.agent and agent.native_agent and reg.registrant
    return bool(staged and reg.location and reg.location.uri == _CONSTANT_REGISTRANT_URI)

def _use_modular_kernel(plan, agent, reg, flags, twins):
    # Defines, the flavor and the `dart_defines` file are the `deps` configuration (see
    # `flutter_defines_files.bzl`), so every module compiles with them and they keep nothing whole-program.
    # Whole-program (FlutterKernelCompile) is kept for: a recorded use or native asset (the per-package
    # modules are built without them), AOT, profile, web, any frontend flag other than
    # `--track-widget-creation` (the application's aspect compiles every module with that one, and its
    # registrant twin records that), and a closure with no registrant twin of the SDK `flutter` module (the
    # SDK constant would not resolve to the registrant).
    return (
        not plan.aot and plan.mode != "profile" and
        plan.frontend_server_target == "flutter" and
        _debug_registrant_modular(agent, reg, twins) and
        not plan.native_assets and not plan.recorded_uses and
        flags.extra_frontend == (["--track-widget-creation"] if twins and twins[0].tracked else [])
    )

def _modular_tools_or_none(ctx, flutter_sdk_info, packages, native_assets):
    """The modular kernel tools, or None when the target needs a whole-program compile."""
    own_files = [ctx.file.main] + [f for f in ctx.files.srcs if f != ctx.file.main]
    return flutter_modular_test_tools(ctx, flutter_sdk_info, own_files, packages, native_assets)

def _kernel_package_config(ctx, st):
    """The stable-URI `package_config.json` of the app's packages."""
    roots = {st.app_pkg_name: True} if st.app_pkg_name else None
    return compile_kernel_package_config(ctx, st.packages, st.colocate_inputs, roots = roots)

def _compile_full_kernel(ctx, flutter_sdk_info, st, agent, reg, flags, plan):
    pc = _kernel_package_config(ctx, st)
    all_srcs = pc.srcs
    if reg.registrant:
        all_srcs = all_srcs + [reg.registrant]
    if agent.agent:
        all_srcs = all_srcs + [agent.agent, agent.native_agent]

    # Resolve the kernel entrypoint: the user's main, keyed by its package:
    # URI for hot-reload parity with the dev tool.
    entrypoint_info = resolve_kernel_entrypoint(ctx, st.app_pkg_name, st.app_lib_root)
    flutter_kernel_compile_action(
        ctx,
        struct(
            dartaotruntime = flutter_sdk_info.dartaotruntime,
            kernel_filter_tool = ctx.executable._kernel_filter_tool,
            frontend_server = flutter_sdk_info.frontend_server,
            platform_dill = plan.platform_dill,
        ),
        flutter_kernel_sources(
            main = entrypoint_info.file,
            entrypoint_uri = entrypoint_info.uri,
            srcs = all_srcs,
            package_config = pc.config_file,
            native_assets_manifest = plan.native_assets_manifest,
            dart_plugin_registrant_uri = reg.location.uri if reg.location else None,
        ),
        flutter_kernel_outputs(
            output = plan.kernel_dill,
            recorded_uses = plan.recorded_uses,
        ),
        flutter_kernel_options(
            aot = plan.aot,
            defines = flags.all_defines,
            define_flagfiles = flags.define_flagfiles,
            target = plan.frontend_server_target,
            extra_flags = flags.extra_frontend,
        ),
        flutter_kernel_dills(),
    )
    return pc.config_file

# The library the engine reads `dartPluginRegistrantLibrary` from before `main()`. Nothing imports it:
# the whole-program compile names it with `--source`.
_REGISTRANT_LOOKUP_LIBRARY = "package:flutter/src/dart_plugin_registrant.dart"

def _registrant_lookup_anchor(ctx):
    """A library that imports `_REGISTRANT_LOOKUP_LIBRARY`, for the modular entry module.

    The link keeps only the kernels the entry's imports reach, so without this
    import a modular debug app has no `_REGISTRANT_LOOKUP_LIBRARY`: the engine
    finds no registrant and runs `main()` with no plugins and no debug agent.

    Args:
        ctx: The rule context.

    Returns:
        The generated `.dart` File, declared in the constant agent layout.
    """
    anchor = ctx.actions.declare_file(agent_layout_path(ctx, "registrant_lookup.dart"))
    ctx.actions.write(anchor, "\n".join([
        "// Generated by rules_flutter: keeps the engine's registrant lookup library in the linked kernel.",
        "// ignore_for_file: implementation_imports, unused_import",
        "import '%s';" % _REGISTRANT_LOOKUP_LIBRARY,
        "",
    ]))
    return anchor

def _run_kernel_compile(ctx, flutter_sdk_info, st, agent, reg, flags, plan):
    # The closure holds a twin only for a `flutter_kernel_target`, or for a `flutter_application`
    # with the private debug_modular_app flag on (the default) in a debug build; its `deps` aspect registers
    # nothing otherwise.
    twins = flutter_closure_twins(ctx)
    if _use_modular_kernel(plan, agent, reg, flags, twins):
        modular_tools = _modular_tools_or_none(ctx, flutter_sdk_info, st.packages, plan.native_assets)
        if modular_tools != None:
            files = [f for f in [agent.agent, agent.native_agent, reg.registrant] if f]
            if reg.registrant:
                files.append(_registrant_lookup_anchor(ctx))
            compile_flutter_modular_app_kernel(
                ctx,
                modular_tools,
                st.app_lib_root,
                st.packages,
                plan.kernel_dill,
                plan.platform_dill,
                struct(files = files, twins = twins, flags = flags.extra_frontend) if files else None,
            )

            # An application still publishes its package config; a kernel target has none to give.
            return _kernel_package_config(ctx, st).config_file if plan.assets_dir != None else None
    return _compile_full_kernel(ctx, flutter_sdk_info, st, agent, reg, flags, plan)

def flutter_compile_kernel(ctx, flutter_sdk_info, target, inputs):
    """Run the shared kernel compilation step.

    Collects sources, generates package_config.json, and invokes
    flutter_kernel_compile_action. If deps contain plugins with
    dartPluginClass (or the debug agent is injected), generates a
    registrant library the engine invokes before main() on every
    root-isolate launch — including hot restart.

    If `target.aot` and `target.platform_dill` are not specified, they
    follow the build mode (`flutter_build_mode`): debug → debug dill +
    JIT, profile → debug (non-product) dill + AOT, release → product
    dill + AOT.

    Args:
        ctx: Rule context (must have main, srcs, deps, defines attrs).
        flutter_sdk_info: FlutterSdkInfo from the toolchain.
        target: Which kernel to compile, from `make_kernel_target`.
        inputs: What else feeds the compile, from `make_kernel_inputs`.

    Returns:
        struct with kernel_dill (File) and package_config (File).
    """
    st = _kernel_source_inputs(ctx)

    # Dev hot-reload metadata (debug only): a *second* package_config that, for a
    # source-assembled app package, points its `rootUri` at the live source tree
    # + generated bazel-out roots via a filesystem scheme — instead of the frozen
    # assembled `.pkgsrcs` dir the build package_config uses. This is what lets
    # the dev tool's frontend_server pick up live edits AND find generated parts.
    # Computed from the PRE-colocation `packages`/`colocate_inputs` so `lib_root`
    # and `File.is_source` are still intact. See rules_dart
    # `generate_dev_package_config`.
    mode = flutter_build_mode(ctx)
    dev = _kernel_dev_config(ctx, st, mode)

    aot = target.aot
    if aot == None:
        aot = mode != "debug"
    platform_dill = _resolve_kernel_platform_dill(target.platform_dill, aot, mode, flutter_sdk_info)
    agent = stage_agent_extensions(ctx, aot, mode)
    build_info = _build_info_json(ctx, struct(mode = mode, aot = aot), inputs, target.target_platform)
    reg = _kernel_registrant(ctx, target.target_platform, agent, dev.emit, build_info)
    flags = _kernel_compile_flags(ctx, inputs.track_widget_creation, mode, aot)

    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    config_file = _run_kernel_compile(
        ctx,
        flutter_sdk_info,
        st,
        agent,
        reg,
        flags,
        # The resolved compile plan: how to compile plus the declared
        # output and the resolved platform dill, built once here and read
        # by the modular check and both compile paths.
        struct(
            mode = mode,
            aot = aot,
            frontend_server_target = target.frontend_server_target,
            native_assets_manifest = inputs.native_assets_manifest,
            native_assets = inputs.native_assets,
            recorded_uses = inputs.recorded_uses,
            assets_dir = inputs.assets_dir,
            kernel_dill = kernel_dill,
            platform_dill = platform_dill,
        ),
    )
    return struct(
        kernel_dill = kernel_dill,
        package_config = config_file,
        # Dev-loop plugin registrants, keyed by platform (empty outside
        # debug). The dev tool replays the entry matching the running app's
        # platform on its resident frontend_server so the engine hook keeps
        # firing — with the right plugin set — after hot restart.
        dev_plugin_registrants = reg.dev_registrants,
        # Merged user defines (attr + flag), without the mode-specific
        # dart.vm.* keys — the dev tool replays these on its own compiler.
        dart_defines = flags.user_defines,
        # Hot-reload dev metadata (None/empty outside debug). Consumed by the
        # rule impl to emit `_dev_config.json` for the dev tool.
        app_entrypoint_uri = dev.entrypoint_uri,
        dev_package_config = dev.package_config,
        dev_filesystem_roots = dev.filesystem_roots,
        dev_filesystem_scheme = dev.filesystem_scheme,
        dev_generated_source_paths = dev.generated_source_paths,
        dev_generated_source_uris = dev.generated_source_uris,
        dev_generated_source_files = dev.generated_source_files,
        dev_source_packages = dev.source_packages,
        dev_app_sources = dev.app_sources,
    )

def collect_sdk_shader_srcs(deps):
    """Collect shader source files from transitive FlutterInfo deps.

    These are raw .frag/.glsl files (e.g. Flutter SDK material shaders)
    that need to be compiled per-platform before inclusion in the asset bundle.

    Args:
        deps: List of targets, some of which may provide FlutterInfo.

    Returns:
        List of shader source Files.
    """
    transitive_depsets = [
        dep[FlutterInfo].shader_srcs
        for dep in deps
        if FlutterInfo in dep
    ]
    if transitive_depsets:
        return depset(transitive = transitive_depsets).to_list()
    return []

def _shader_jobs(ctx, target_platform = None, flavor = None):
    """Every shader this target bundles, as struct(bundle_path, file, includes).

    The target's own shaders are keyed like its assets: relative to the
    listing target's package directory, which is where
    `FragmentProgram.fromAsset` looks for them. SDK shaders go under
    "shaders/<basename>" (Flutter's convention), and a package's under
    "packages/<pkg>/<path>" (bare "<path>" when it has no package name).
    Basenames and contribution paths arrive percent-encoded
    (`asset_uri.bzl`), so a file named `a b.frag` compiles to
    `shaders/a%20b.frag`, the key the engine asks for. A
    shader outside the listing target's package fails here rather than
    guessing a key, and two shaders claiming one bundle path fail here: one
    would otherwise overwrite the other.

    Package shaders are filtered with `pub_shader_matches_target`: a
    `flutter.shaders` entry restricted to other platforms is neither
    compiled nor staged, matching `flutter build`. `target_platform` None
    lists every shader, for callers that describe the workspace rather than
    one bundle.

    Args:
        ctx: Rule context with `shaders`, `shader_includes`, `deps` and
            `label` attributes.
        target_platform: The bundle's platform (`android`, `ios`, ...), or
            None to list shaders for every platform.
        flavor: Active flavor string, or None when no flavor is selected.

    Returns:
        The deduplicated shader jobs, in first-reached order.
    """
    jobs = []
    user_includes = tuple(getattr(ctx.files, "shader_includes", []))
    for shader in ctx.files.shaders:
        if not is_within_package(ctx.label.workspace_root, ctx.label.package, shader.short_path):
            fail("%s: shader %s is outside the target's package; move it into a flutter_library with a package_name and depend on it instead." % (ctx.label, shader.short_path))
        jobs.append(struct(
            bundle_path = relative_key(ctx.label.workspace_root, ctx.label.package, shader.short_path),
            file = shader,
            includes = user_includes,
        ))
    for entry in collect_sdk_shader_srcs(ctx.attr.deps):
        shader = entry.file if hasattr(entry, "file") else entry
        jobs.append(struct(
            bundle_path = "shaders/" + encode_asset_key(shader.basename),
            file = shader,
            includes = entry.includes if hasattr(entry, "includes") else (),
        ))

    # One flatten of the package-shader channel, through one `depset` union
    # over the deps: a shader file reached through W thin deps costs one
    # listing, not W. The union lists each contribution once in
    # first-reached order, so bundles without a repeat keep today's jobs.
    pub_shaders = [dep[FlutterInfo].pub_shaders for dep in ctx.attr.deps if FlutterInfo in dep]
    for entry in depset(transitive = pub_shaders).to_list():
        if not pub_shader_matches_target(entry, target_platform, flavor = flavor):
            continue
        prefix = "packages/{}/".format(entry.package_name) if entry.package_name else ""
        jobs.append(struct(
            bundle_path = prefix + entry.shader_path,
            file = entry.file,
            includes = entry.includes,
        ))

    # One package can reach a target along several paths; the same file at
    # the same bundle path is one shader.
    return dedupe_shader_jobs(ctx, jobs).values()

def shader_sources(ctx, target_platform = None, flavor = None):
    """The workspace files behind each bundled shader, for the dev tool.

    `{bundle path: [workspace-relative path]}`: the shader and what it may
    `#include`, where those are source files of this workspace. A shader from
    another repository maps to an empty list; it is still a shader, which is
    what the dev tool needs to know to make the app reload it.

    Args:
        ctx: Rule context with `shaders`, `shader_includes`, `deps` and
            `label` attributes.
        target_platform: The bundle's platform, so shaders restricted to other
            platforms stay out just as they are not compiled; None lists
            every shader.
        flavor: Active flavor string, or None when no flavor is selected.

    Returns:
        The bundle-path-to-source-paths map.
    """
    return {
        job.bundle_path: [
            f.short_path
            for f in [job.file] + list(job.includes)
            if f.is_source and not f.short_path.startswith("../")
        ]
        for job in _shader_jobs(ctx, target_platform, flavor = flavor)
    }

def _collect_dep_compiled_shaders(ctx, target_platform, compiled):
    """Fold dep `FlutterCompiledShadersInfo` entries for the platform into `compiled`.

    Returns the `require_sksl` flag: when true every shader is (re)compiled
    locally, so dep entries are skipped.
    """
    require_sksl = getattr(ctx.attr, "require_sksl_shaders", False)
    if not require_sksl:
        for dep in getattr(ctx.attr, "deps", []):
            if type(dep) == "Target" and FlutterCompiledShadersInfo in dep:
                for entry in dep[FlutterCompiledShadersInfo].compiled_shaders.to_list():
                    if getattr(entry, "target_platform", None) != target_platform:
                        continue
                    seen = compiled.get(entry.bundle_path)
                    if seen == None:
                        compiled[entry.bundle_path] = entry.file
                    elif seen != entry.file:
                        fail("%s: two shaders are bundled at %s: %s and %s." % (
                            ctx.label,
                            entry.bundle_path,
                            seen.short_path,
                            entry.file.short_path,
                        ))
    return require_sksl

def _compile_missing_shaders(ctx, flutter_sdk_info, target_platform, require_sksl, compiled, flavor = None):
    """Compile each `_shader_jobs` entry missing from `compiled`, in place."""
    tools = shader_compile_tools(
        impellerc = flutter_sdk_info.impellerc,
        shader_lib = flutter_sdk_info.shader_lib,
        compile_tool = ctx.executable._shader_compile_tool,
    )
    for job in _shader_jobs(ctx, target_platform, flavor = flavor):
        if job.bundle_path not in compiled:
            # Named by the bundle path, which is unique, so no two outputs meet.
            out_path = job.bundle_path.replace("../", "_external/")
            output = ctx.actions.declare_file("_shaders_%s/%s/%s.iplr" % (target_platform, ctx.label.name, out_path))
            flutter_shader_compile_action(
                ctx = ctx,
                job = job,
                output = output,
                tools = tools,
                target_platform = target_platform,
                is_web = target_platform == "web",
                # What compiles a shader whose SkSL stage fails without it.
                require_sksl = require_sksl,
            )
            compiled[job.bundle_path] = output

def flutter_compile_shaders(ctx, flutter_sdk_info, target_platform, flavor = None):
    """Compile every shader this target bundles for the target platform.

    The shaders are the target's own (`shaders`), the SDK's (collected from
    FlutterInfo.shader_srcs) and its packages' (FlutterInfo.pub_shaders); see
    `_shader_jobs` for where each is bundled.

    Shaders from dependencies are compiled once per platform via the shader
    aspect on the owning target and collected from FlutterCompiledShadersInfo.
    Any shader not supplied by deps (including the target's own `shaders` attr)
    is compiled here. If `require_sksl_shaders` is True, all shaders are
    compiled here with `require_sksl = True`.

    Args:
        ctx: Rule context (must have shaders attr and deps attr).
        flutter_sdk_info: FlutterSdkInfo from the toolchain.
        target_platform: Target platform string ("ios", "macos", "android", "linux", "windows", "web").
        flavor: Active flavor string, or None when no flavor is selected.

    Returns:
        Dict mapping bundle destination path → compiled File. Pass to
        extra_asset_copies in flutter_asset_bundle_action.
    """
    if not flutter_sdk_info or not flutter_sdk_info.impellerc:
        return {}

    compiled = {}
    require_sksl = _collect_dep_compiled_shaders(ctx, target_platform, compiled)
    _compile_missing_shaders(ctx, flutter_sdk_info, target_platform, require_sksl, compiled, flavor = flavor)
    return compiled

def _any_entry_is(entries, file):
    """Whether any entry in `entries` has `.file == file`."""
    return any([entry.file == file for entry in entries])

def _any_font_is(entries, file):
    """Whether any font entry in `entries` lists `file` among its files."""
    return any([file in entry.files for entry in entries])

def _dep_carries_claim(dep, channel, file):
    """Whether direct `dep` carries `file` in `channel` (`pub`, `shader`, `data`)."""
    if channel == "shader":
        if FlutterCompiledShadersInfo not in dep:
            return False
        return _any_entry_is(dep[FlutterCompiledShadersInfo].compiled_shaders.to_list(), file)
    if FlutterInfo not in dep:
        return False
    info = dep[FlutterInfo]
    if channel == "pub":
        return _any_entry_is(info.pub_assets.to_list(), file) or _any_font_is(info.pub_fonts.to_list(), file)
    if channel == "data":
        return _any_entry_is(info.data_assets.to_list(), file)
    return False

def _resolve_claim_origin(bundle, channel, file):
    """Name where a conflicting extra-channel file came from.

    Only runs on the failure path, after the one-flatten assembly found two
    different files for one key. The scans below re-flatten deps, but a
    conflicting analysis fails here, so their cost never reaches a build.

    Args:
        bundle: A `struct(label, deps)` naming the bundling target.
        channel: Which channel claimed the file (`pub`, `shader` or `data`).
        file: The conflicting file.

    Returns:
        A label string for the failure message.
    """
    if channel not in ("pub", "shader", "data"):
        fail("check_bundle_claims: unknown channel %r for %s." % (channel, file.short_path))
    for dep in bundle.deps:
        if _dep_carries_claim(dep, channel, file):
            return str(dep.label)
    return str(bundle.label)

def _claim_bundle_key(seen, bundle, key, file, channel, label):
    """Claim one bundle key for a file, failing on a different file's claim.

    The first claim wins; the same file under the same key, reached along
    several paths or channels, stays legal and is bundled once.

    Args:
        seen: Dict of key to the winning `struct(file, channel, label)`.
        bundle: A `struct(label, deps)` naming the bundling target.
        key: The bundle key being claimed.
        file: The file claiming it.
        channel: Which channel claims it (`assets`, `pub`, `shader`, `data`).
        label: Where the file came from, or None for extra channels (their
            origin is resolved only when a conflict fails the build).
    """
    prev = seen.get(key)
    if prev == None:
        seen[key] = struct(file = file, channel = channel, label = label)
        return
    if prev.file == file:
        return
    first_origin = prev.label if prev.label != None else _resolve_claim_origin(bundle, prev.channel, prev.file)
    origin = label if label != None else _resolve_claim_origin(bundle, channel, file)
    fail_asset_key_conflict(bundle.label, key, prev.file, first_origin, file, origin)

def check_bundle_claims(bundle, asset_entries, extra_claims):
    """Fail when two different files claim one bundle key, across any channels.

    The one cross-channel key check every bundle runs: the `assets` entries
    first, then the extra claims in bundle order (compiled shaders, pub
    files, data assets — the order the copies dict is assembled in). A key
    claimed twice by the same file stays legal; a key claimed by two
    different files fails in COV-1's same-channel shape, naming the key,
    both files and where each came from.

    Args:
        bundle: A `struct(label, deps)` — the bundling target's label and
            direct deps (deps are only read to name an origin on failure).
        asset_entries: `struct(key, file, label)` entries in bundle order.
        extra_claims: `struct(key, file, channel)` claims in bundle order.
    """
    seen = {}
    for entry in asset_entries:
        _claim_bundle_key(seen, bundle, entry.key, entry.file, "assets", entry.label)
    for claim in extra_claims:
        _claim_bundle_key(seen, bundle, claim.key, claim.file, claim.channel, None)

def declare_flutter_assets_dir(ctx):
    """Declare the `flutter_assets/` tree artifact for this target.

    Split out from `flutter_build_assets` so a rule can name the directory
    before it compiles the kernel: an application bakes this path into
    `rules_flutter.build_info.assetsDir`, and the dev tool matches the app's
    reported value against the tree it watches and rebuilds. Every rule that
    bundles assets uses this one helper so the name is stated in a single
    place rather than re-spelled at each call site.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        The declared directory (tree artifact) File.
    """
    return ctx.actions.declare_directory(ctx.label.name + "_flutter_assets")

def make_bundle_inputs(
        target_platform,
        compiled_shaders = {},
        kernel_dill = None,
        kernel_dills = [],
        tree_shake_key = "",
        is_debug = False,
        data_assets = None,
        flavor = None):
    """One `flutter_build_assets` call's inputs: what to bundle and how its icons shake.

    Args:
        target_platform: The bundle's platform (`android`, `ios`, `macos`,
            `linux`, `windows`, `web`, or `tester` for test bundles).
            Required, so a new bundle call site cannot silently inherit the
            wrong filter: pub assets carrying `platforms` / `flavors`
            conditions bundle only where flutter_tools would bundle them.
        compiled_shaders: Dict mapping bundle dest path → compiled shader File.
        kernel_dill: The compiled kernel .dill File (needed for icon tree shaking).
        kernel_dills: Optional list of compiled kernel .dill Files when a bundle
            ships multiple programs with distinct defines (e.g. WASM + JS fallback).
        tree_shake_key: Optional configuration fingerprint for the shipped
            programs whose icons are tree-shaken.
        is_debug: Whether this is a debug build (icon tree shaking is skipped in debug).
        data_assets: Optional depset[FlutterDataAssetInfo]. Each entry is
            placed at `flutter_assets/packages/<package>/<name>` and listed in
            the asset manifest under that key, as flutter_tools bundles a
            hook's data asset.
        flavor: Active flavor string, or None when no flavor is selected.

    Returns:
        A struct with `target_platform`, `compiled_shaders`, `kernel_dill`,
        `kernel_dills`, `tree_shake_key`, `is_debug`, `data_assets` and `flavor`.
    """
    return struct(
        target_platform = target_platform,
        compiled_shaders = compiled_shaders,
        kernel_dill = kernel_dill,
        kernel_dills = kernel_dills,
        tree_shake_key = tree_shake_key,
        is_debug = is_debug,
        data_assets = data_assets,
        flavor = flavor,
    )

def _own_font_targets(ctx):
    """The rule's own `fonts` targets when its `attrs` declare `fonts`."""
    return ctx.attr.fonts if hasattr(ctx.attr, "fonts") else []

def _bundle_tree_shake(ctx, flutter_sdk_info, bundle, fonts):
    """Resolve the `make_tree_shake` inputs for `flutter_build_assets`.

    `const_finder.dart.snapshot` is a kernel snapshot built by the Flutter
    engine's bundled Dart SDK and analyzes `kernel_dill` compiled by Flutter's
    `frontend_server`, so it must run on `flutter_sdk_info.dart` paired with
    `flutter_sdk_info.dart_vm_files` rather than `@rules_dart`'s exec-tools SDK.

    Args:
        ctx: Rule context (reads `label` and `tree_shake_icons`).
        flutter_sdk_info: `FlutterSdkInfo` from the toolchain, or `None`.
        bundle: The `make_bundle_inputs` struct that carries the compiled kernel dills.
        fonts: Aggregated `FontManifest` family entries.

    Returns:
        A `make_tree_shake` struct.
    """
    const_finder, font_subset = resolve_font_subset_tools(flutter_sdk_info) if fonts else (None, None)
    all_kernel_dills = list(bundle.kernel_dills)
    if not all_kernel_dills and bundle.kernel_dill != None:
        all_kernel_dills = [bundle.kernel_dill]
    needs_tree_shake = ctx.attr.tree_shake_icons and bool(fonts) and not bundle.is_debug and bool(all_kernel_dills)
    if needs_tree_shake and (const_finder == None or font_subset == None):
        fail(
            "%s: icon tree shaking is enabled (`tree_shake_icons = True`) and the target bundles fonts, " % ctx.label +
            "but `const_finder` or `font_subset` (`font-subset`) is not available in the Flutter toolchain " +
            "(`@rules_flutter//flutter:font_subset_toolchain_type`) for the execution platform.",
        )

    # Icon tree shaking: enabled only in non-debug mode with tree_shake_icons=True
    # when the dependency graph actually contributes at least one font family.
    if not needs_tree_shake:
        return make_tree_shake()
    return make_tree_shake(
        dart = flutter_sdk_info.dart,
        flutter_sdk_files = flutter_sdk_info.dart_vm_files,
        const_finder = const_finder,
        font_subset = font_subset,
        kernel_dill = all_kernel_dills[0],
        kernel_dills = all_kernel_dills,
        tree_shake_key = bundle.tree_shake_key,
    )

def flutter_build_assets(ctx, flutter_sdk_info, output_dir, bundle):
    """Run the shared asset bundling step.

    Walks `FlutterInfo.pub_fonts` / `pub_assets` from deps to bundle
    pub-package contributions (fonts/assets — shaders are pre-compiled by
    `flutter_compile_shaders` and arrive via `compiled_shaders`). The rule's
    own `fonts` attribute, when it has one, contributes its families bare
    ahead of the deps' as the root pubspec's fonts do.

    Args:
        ctx: Rule context (must have assets, deps, license_files, tree_shake_icons attrs and _asset_bundle_tool).
        flutter_sdk_info: FlutterSdkInfo from the toolchain.
        output_dir: The tree artifact to bundle into, from
            `declare_flutter_assets_dir`. Passed in rather than declared here
            so an application can bake the path into its `build_info` before
            the kernel compile that this action depends on.
        bundle: This bundle's inputs, from `make_bundle_inputs`.

    Returns:
        The flutter_assets/ tree artifact File.
    """
    all_entries = bundle_asset_entries(ctx.label, ctx.files.assets, ctx.attr.deps)

    # Walk pub-package font/asset contributions from FlutterInfo.
    # MaterialIcons is no longer special-cased here — apps depend on
    # `@rules_flutter//flutter:material_icons` to get it via this same path.
    # The pub claims ride the same list as the shader and data claims below,
    # in bundle order, for the one cross-channel key check.
    extra_claims = [struct(key = dest, file = f, channel = "shader") for dest, f in bundle.compiled_shaders.items()]
    fonts, pub_extra_asset_copies = aggregate_pub_contributions(
        ctx.attr.deps,
        bundle.target_platform,
        extra_claims,
        _own_font_targets(ctx),
        flavor = getattr(bundle, "flavor", None),
    )
    extra_asset_copies = dict(bundle.compiled_shaders.items() + pub_extra_asset_copies.items())

    # Drop each DataAsset at flutter_assets/packages/<pkg>/<name>, the key
    # flutter_tools gives a hook's data asset and the one `rootBundle` loads
    # it by. The bundle action keys extra_asset_copies on a destination path
    # relative to the assets/ root. A data asset landing on another channel's
    # key fails in the cross-channel check below, naming both files.
    if bundle.data_assets != None:
        for entry in bundle.data_assets.to_list():
            dst = "packages/{pkg}/{name}".format(pkg = entry.package, name = entry.name)
            extra_claims.append(struct(key = dst, file = entry.file, channel = "data"))
            extra_asset_copies[dst] = entry.file

    check_bundle_claims(struct(label = ctx.label, deps = ctx.attr.deps), all_entries, extra_claims)

    return flutter_asset_bundle_action(
        ctx = ctx,
        content = make_bundle_content(
            assets = all_entries,
            fonts = fonts,
            license_files = ctx.files.license_files,
            extra_asset_copies = extra_asset_copies,
        ),
        shaking = _bundle_tree_shake(ctx, flutter_sdk_info, bundle, fonts),
        output_dir = output_dir,
    )

def make_desktop_bundle_artifacts(is_debug, kernel_dill_path, aot_output_path, aot_dst, icu_data_path):
    """The app build outputs a desktop bundle copies into its directory.

    Args:
        is_debug: Whether this is a debug build.
        kernel_dill_path: Source path to kernel .dill file (used in debug mode), or None.
        aot_output_path: Source path to AOT output (used in release mode), or None.
        aot_dst: Destination path for AOT output (e.g. "lib/libapp.so" or "app.so").
        icu_data_path: Source path to icudtl.dat.

    Returns:
        A struct with `is_debug`, `kernel_dill_path`, `aot_output_path`,
        `aot_dst` and `icu_data_path`.
    """
    return struct(
        is_debug = is_debug,
        kernel_dill_path = kernel_dill_path,
        aot_output_path = aot_output_path,
        aot_dst = aot_dst,
        icu_data_path = icu_data_path,
    )

def make_desktop_bundle_libs(engine_basenames, native_basenames, engine_dst_prefix = "lib/", native_dst_prefix = "lib/"):
    """The engine and native libraries a desktop bundle copies, and where they land.

    Args:
        engine_basenames: List of (src_path, basename) tuples for engine files.
        native_basenames: List of (src_path, basename) tuples for native FFI libs.
        engine_dst_prefix: Destination prefix for engine files (default "lib/").
        native_dst_prefix: Destination prefix for native FFI / Native
            Assets `dynamic_loading_bundle` libs. Linux uses `lib/`
            (next to libapp.so); Windows uses `""` so DLLs land next to
            the runner `.exe` where Windows' dynamic loader picks them
            up via the standard search order.

    Returns:
        A struct with `engine_basenames`, `native_basenames`,
        `engine_dst_prefix` and `native_dst_prefix`.
    """
    return struct(
        engine_basenames = engine_basenames,
        native_basenames = native_basenames,
        engine_dst_prefix = engine_dst_prefix,
        native_dst_prefix = native_dst_prefix,
    )

def compute_desktop_bundle_copies(artifacts, libs):
    """Compute the file-copy list for a desktop Flutter bundle.

    Builds the list of {"src": ..., "dst": ...} dicts that the Dart bundler
    tool uses to assemble a Linux or Windows application directory.

    Args:
        artifacts: The app build outputs, from `make_desktop_bundle_artifacts`.
        libs: The engine and native libraries, from `make_desktop_bundle_libs`.

    Returns:
        List of {"src": ..., "dst": ...} dicts.
    """
    copies = [{"src": artifacts.icu_data_path, "dst": "data/icudtl.dat"}]

    if artifacts.is_debug and artifacts.kernel_dill_path:
        # The Flutter engine's embedder looks for kernel_blob.bin inside the
        # assets directory (settings.assets_path / "kernel_blob.bin").
        copies.append({"src": artifacts.kernel_dill_path, "dst": "data/flutter_assets/kernel_blob.bin"})
    elif artifacts.aot_output_path:
        copies.append({"src": artifacts.aot_output_path, "dst": artifacts.aot_dst})

    copies.extend([{"src": p, "dst": libs.engine_dst_prefix + b} for p, b in libs.engine_basenames])
    copies.extend([{"src": p, "dst": libs.native_dst_prefix + b} for p, b in libs.native_basenames])

    return copies

def compute_android_jni_path(target_name, abi, basename):
    """Compute the JNI symlink path for an Android native library.

    Scoped by [target_name] because `ctx.actions.declare_file` resolves
    package-relative: two Android bundles in one package would otherwise both
    declare `jni/<abi>/libapp.so` and collide. That is not hypothetical — the
    Tier 1 `flutter_android_app` macro generates a bundle internally, so a
    package holding two apps (or an app plus an explicit Tier 2 bundle) hits
    it, and `bazel build //...` fails with conflicting actions. Bazel only
    tolerates the duplicate while both symlinks happen to point at the *same*
    source file, which masks the bug until the two apps differ.

    Mirrors the same scoping already applied to the mobile-install assets
    directory in `flutter_android_application.bzl`.

    Args:
        target_name: Name of the declaring target (`ctx.label.name`).
        abi: Android ABI string (e.g. "arm64-v8a").
        basename: Filename within the ABI directory.

    Returns:
        Path string like "my_app_jni/arm64-v8a/libapp.so".
    """
    return "{}_jni/{}/{}".format(target_name, abi, basename)

# Android ABIs with AOT cross-compilation support. Single source of truth
# mapping each ABI to the Bazel platform Android rules transition to and the
# ELF e_machine value native libraries packaged for that ABI must carry.
ANDROID_ABIS = {
    "arm64-v8a": struct(
        platform = Label("//flutter/platforms:android_arm64"),
        elf_machine = 183,  # EM_AARCH64
    ),
    "x86_64": struct(
        platform = Label("//flutter/platforms:android_x64"),
        elf_machine = 62,  # EM_X86_64
    ),
}

def _android_abi(abi):
    """The `ANDROID_ABIS` record for `abi`, failing when it is unsupported."""
    if abi not in ANDROID_ABIS:
        fail("Unsupported Android ABI '{}'. Supported: {}.".format(
            abi,
            ", ".join(ANDROID_ABIS.keys()),
        ))
    return ANDROID_ABIS[abi]

def android_platform_for_abi(abi):
    """The Bazel platform label Android rules build for, given an ABI.

    Args:
        abi: Android ABI string ("arm64-v8a" or "x86_64").

    Returns:
        A Label for the platform under //flutter/platforms.
    """
    return _android_abi(abi).platform

def android_elf_machine_for_abi(abi):
    """The ELF e_machine value native libraries must have for an ABI.

    Args:
        abi: Android ABI string ("arm64-v8a" or "x86_64").

    Returns:
        The e_machine value as an int (e.g. 183 for EM_AARCH64).
    """
    return _android_abi(abi).elf_machine

def host_target_arch(ctx, flutter_sdk_info):
    """Best-effort target architecture string for Native Assets.

    The toolchain's `target_arch` is set on cross-compilation toolchains
    but empty for native builds. For native builds we infer from
    `bin_dir` path. Returns one of `arm64`, `x64`, `arm`, or "" if
    unknown. The empty string causes the Native Assets manifest to omit
    the target section, which is still valid for the engine.

    Args:
      ctx: Rule context — used only for `ctx.bin_dir`.
      flutter_sdk_info: `FlutterSdkInfo` from the toolchain. Carries the
        `target_arch` field, which when set wins over the heuristic.

    Returns:
      A lowercase architecture string (`arm64`, `x64`, `arm`) or "" when
      neither the toolchain nor the bin_dir hint at a known arch.
    """
    if flutter_sdk_info.target_arch:
        return flutter_sdk_info.target_arch

    # Heuristic: parse the bazel-out output dir for cpu hints. The bin_dir
    # path looks like `bazel-out/<cpu>-<mode>/bin`. Match the same `cpu`
    # values rules_flutter assumes elsewhere. Windows cpu names put the
    # arch first (`x64_windows`, `arm64_windows`), so match those before
    # the suffix-style patterns.
    bin_dir = ctx.bin_dir.path
    if "arm64_windows" in bin_dir:
        return "arm64"
    if "x64_windows" in bin_dir:
        return "x64"
    if "darwin_arm64" in bin_dir or "_arm64" in bin_dir:
        return "arm64"
    if "darwin_x86_64" in bin_dir or "_x86_64" in bin_dir or "_amd64" in bin_dir or "k8" in bin_dir:
        return "x64"
    if "darwin_x64" in bin_dir or "_x64" in bin_dir:
        return "x64"
    if "armv7" in bin_dir or "arm-" in bin_dir:
        return "arm"
    return ""

# Shared platform constraint attrs used by rules that need to check target platform.
PLATFORM_CONSTRAINT_ATTRS = {
    "_macos_constraint": attr.label(
        doc = "macOS platform constraint value, matched against the target platform.",
        default = "@platforms//os:macos",
    ),
    "_ios_constraint": attr.label(
        doc = "iOS platform constraint value, matched against the target platform.",
        default = "@platforms//os:ios",
    ),
    "_linux_constraint": attr.label(
        doc = "Linux platform constraint value, matched against the target platform.",
        default = "@platforms//os:linux",
    ),
    "_windows_constraint": attr.label(
        doc = "Windows platform constraint value, matched against the target platform.",
        default = "@platforms//os:windows",
    ),
    "_android_constraint": attr.label(
        doc = "Android platform constraint value, matched against the target platform.",
        default = "@platforms//os:android",
    ),
    # CPU alongside OS, because Android's ABI selects a whole platform label
    # in `launch_build_args`. Read from the resolved platform rather than
    # parsed out of `ctx.bin_dir` the way `host_target_arch` still does — a
    # value the dev tool builds against has to be right or absent, not
    # guessed.
    "_arm64_constraint": attr.label(
        doc = "ARM64 CPU constraint value, matched against the target platform alongside the OS.",
        default = "@platforms//cpu:arm64",
    ),
    "_x86_64_constraint": attr.label(
        doc = "x86_64 CPU constraint value, matched against the target platform alongside the OS.",
        default = "@platforms//cpu:x86_64",
    ),
}

# Target compatibility constraint for targets that only run on a host OS
# (Linux, macOS, Windows) and must be skipped when `--platforms` targets a
# mobile/device OS such as Android or iOS.
HOST_COMPATIBLE = select({
    Label("@platforms//os:linux"): [],
    Label("@platforms//os:macos"): [],
    Label("@platforms//os:windows"): [],
    "//conditions:default": [Label("@platforms//:incompatible")],
})

def launch_build_args(target_platform, is_simulator, is_arm64, is_x86_64):
    """The bazel flags the *launch target's* build needs to produce this app.

    MIRRORS `Device.buildArgs` in `tools/dev_tool/lib/device.dart`. The dev
    tool normally gets these from the `-d` device the user named — but
    `flutter_bazel attach` has no `-d`, and even on `run` these flags come
    from the device rather than from anything the user typed, so they are not
    something an attaching process can ask the user to repeat. The app
    therefore carries them, and the dev tool replays them when it builds and
    queries the wrapper. Keep the two lists in step; a drift shows up as the
    dev tool's `assetsDir` mismatch, loudly, rather than as a silent rebuild
    into a tree the app never reads.

    These are NOT flags that would reproduce this configuration on a bare
    build of the `flutter_application` itself. That is not expressible: the
    Apple and Android wrappers reach this target through split transitions
    whose output directories (`…-ST-<hash>`) no command line can name. These
    are the flags for the *wrapper*, which is what the dev tool builds.

    Takes booleans rather than `ctx` for the same reason
    `detect_target_platform` does: the interesting part is the mapping, and a
    mapping only a configured target can call is a mapping nothing can test.

    Args:
        target_platform: Platform string from `detect_target_platform`.
        is_simulator: True when the Apple target environment is the simulator.
            Resolved by the caller through `apple_support`, which is where
            that question is answerable; ignored off Apple.
        is_arm64: True when the target platform has the arm64 CPU constraint.
        is_x86_64: True when it has the x86_64 CPU constraint.

    Returns:
        list[str] of bazel flags. Empty on desktop.
    """
    if target_platform == "ios":
        # `Device.buildArgs` hardcodes arm64 on both sides — a 32-bit or x86
        # simulator is not a target rules_flutter builds for.
        return ["--ios_multi_cpus=sim_arm64"] if is_simulator else ["--ios_multi_cpus=arm64"]

    if target_platform == "android":
        if is_arm64:
            abi = "arm64"
        elif is_x86_64:
            abi = "x64"
        else:
            fail(
                "flutter_application: the Android target platform has neither an arm64 nor " +
                "an x86_64 CPU constraint, so the `--platforms` flag a dev-loop rebuild " +
                "needs cannot be named. rules_flutter ships android_arm64 and android_x64 " +
                "under @rules_flutter//flutter/platforms.",
            )
        return ["--platforms=@rules_flutter//flutter/platforms:android_" + abi]

    # Desktop needs no flag: the app is already built in the top-level
    # configuration. `Device.buildArgs` emits `--platforms=` only when
    # cross-building, and that case is out of reach here anyway — the dev tool
    # reads the app's own bazel-out paths, so it has to be on the machine that
    # built it. Emitting the flag regardless would move a dev-loop rebuild to a
    # different output directory than the one the running app came from.
    return []

AGENT_EXTENSIONS_ATTR = {
    "_agent_extensions_src": attr.label(
        doc = "AI-agent service-extension source. Registered from the generated plugin registrant in debug builds; ignored in AOT/release.",
        default = Label("//flutter/private/agent_extensions:agent.dart"),
        allow_single_file = [".dart"],
    ),
    "_native_agent_extensions_src": attr.label(
        doc = "The native-only agent extensions (`dart:ffi`): loading a `flutter_native_library.hot_patch`. Staged beside `_agent_extensions_src` in native debug builds; never on web.",
        default = Label("//flutter/private/agent_extensions:native_patch.dart"),
        allow_single_file = [".dart"],
    ),
}

BUILD_MODE_ATTR = {
    "_profile_flag": attr.label(
        doc = "The //flutter:profile build setting. Read through `flutter_build_mode`.",
        default = Label("//flutter:profile"),
    ),
}

def flutter_build_mode(ctx):
    """Flutter's build mode for this configuration: "debug", "profile" or "release".

    `-c dbg` is debug and any other `-c` is release, unless
    `--@rules_flutter//flutter:profile` asks for profile, which needs `-c opt`:
    the engine and gen_snapshot selects match profile only there, and a
    profile Dart snapshot on any other engine does not start.

    Args:
        ctx: Rule context carrying `BUILD_MODE_ATTR`.

    Returns:
        "debug", "profile" or "release".
    """
    compilation_mode = ctx.var["COMPILATION_MODE"]
    if ctx.attr._profile_flag[BuildSettingInfo].value:
        if compilation_mode != "opt":
            fail(
                "--@rules_flutter//flutter:profile builds Flutter's profile mode, " +
                "which is optimized AOT code and needs -c opt (this build is -c " +
                compilation_mode + "). Add -c opt, or drop the flag.",
            )
        return "profile"
    return "debug" if compilation_mode == "dbg" else "release"

# The attrs `flutter_compile_kernel` reads off its caller's `ctx`. Every rule
# that calls it spreads this bundle wholesale rather than naming the members,
# because naming them is what let the contract break: `flutter_compile_kernel`
# reaches into `ctx.attr.language_version` on whatever context it is handed,
# and the two callers that built a narrowed attr surface — `flutter_aot_target`
# cherry-picking from `FLUTTER_APPLICATION_ATTRS`, `flutter_kernel_target`
# hand-rolling a near-copy that had already drifted — simply did not have it.
# One failed at analysis, the other silently; a caller that spreads the bundle
# can omit nothing.
#
# Per-rule inputs stay out. `track_widget_creation` and `assets_dir`
# are function parameters of `flutter_compile_kernel` for the reason its
# docstring gives — the callers genuinely disagree about whether they have one
# — and `_agent_extensions_src` is declared by the rules that inject the agent,
# not by every kernel compile.
KERNEL_COMPILE_ATTRS = {
    "_kernel_filter_tool": attr.label(
        doc = "Guard tool that runs the kernel compile only after its sources pass the declared-inputs check.",
        default = Label("//flutter/private/tools:kernel_filter"),
        executable = True,
        cfg = "exec",
    ),
    "_incr_worker_tool": attr.label(
        default = Label("//flutter/private/tools:incr_fkc_worker"),
        executable = True,
        cfg = "exec",
        doc = "Persistent incremental kernel compile worker tool.",
    ),
    "_web_guard_tool": attr.label(
        doc = "Guard tool that runs the web compile confined to its staged sources.",
        default = Label("//flutter/private/tools:web_guard"),
        executable = True,
        cfg = "exec",
    ),
    "main": attr.label(
        doc = "The main .dart entry point.",
        mandatory = True,
        allow_single_file = [".dart"],
    ),
    "package_name": attr.string(
        doc = "Dart package name (same value as `pubspec.yaml`'s `name:`). " +
              "Required: keys the kernel's libraries under stable `package:` URIs " +
              "(hot-reload parity with the dev tool), anchors codegen sibling " +
              "co-location, and resolves `package:<self>/...` imports. There is " +
              "no signal in the Bazel graph that can determine this reliably, " +
              "so it must be declared explicitly.\n\n" +
              "A target declared beside the library it covers — a " +
              "`flutter_test` in the same directory as its `flutter_library`, " +
              "the layout pub uses — *is* that package rather than a consumer " +
              "of it: give it the library's `package_name` and list the " +
              "library's sources in `srcs`, instead of depending on the " +
              "sibling target. Two Dart packages cannot share a directory, so " +
              "a dependency declaring a different package name at this " +
              "target's own root is refused.",
        mandatory = True,
    ),
    "language_version": attr.string(
        doc = "Dart language version for the app's own package, in " +
              "`<major>.<minor>` form — the same value pub derives from this " +
              "package's `environment.sdk` lower bound and writes into " +
              "`package_config.json` (`sdk: ^3.12.0` → `\"3.12\"`). " +
              "Optional, and it lives here for the same reason `package_name` " +
              "does: it is stated in `pubspec.yaml`, which the analysis phase " +
              "cannot read.\n\n" +
              "Left unset, the app's entry carries no `languageVersion`, and " +
              "`package_config.json` reads that as the *current* SDK's — so " +
              "the build accepts newer syntax than the app's own pubspec " +
              "permits, and applies newer semantics to code written against " +
              "an older version. That is a divergence from `flutter build`, " +
              "not a neutral default. Set it to match your pubspec if the two " +
              "differ. Same attribute, same meaning, as on `flutter_library` " +
              "and `flutter_plugin`.",
    ),
    "srcs": attr.label_list(
        doc = "Additional Dart source files.",
        allow_files = [".dart"],
    ),
    "deps": attr.label_list(
        doc = "`dart_library` or `flutter_library` dependencies. A rule that " +
              "builds an asset bundle needs `@rules_flutter//flutter:material_icons` " +
              "listed here to bundle `MaterialIcons-Regular.otf` into " +
              "`flutter_assets/` for Material widgets; the rules that emit only " +
              "a kernel or an AOT artifact have no bundle for it to reach.",
        providers = [DartInfo],
    ),
    "defines": attr.string_list(doc = "Dart environment defines (-D flags)."),
} | EXTRA_DART_DEFINES_ATTR | BUILD_MODE_ATTR | INCREMENTAL_KERNEL_ATTRS

def _aspect_target_platform(ctx, fixed_platform):
    """The platform string the shader aspect compiles for."""
    if fixed_platform != None:
        return fixed_platform
    is_macos = ctx.target_platform_has_constraint(
        ctx.attr._macos_constraint[platform_common.ConstraintValueInfo],
    )
    is_ios = ctx.target_platform_has_constraint(
        ctx.attr._ios_constraint[platform_common.ConstraintValueInfo],
    )
    is_linux = ctx.target_platform_has_constraint(
        ctx.attr._linux_constraint[platform_common.ConstraintValueInfo],
    )
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    is_android = ctx.target_platform_has_constraint(
        ctx.attr._android_constraint[platform_common.ConstraintValueInfo],
    )
    return detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android)

def _aspect_direct_jobs(ctx, shader_includes, target_platform):
    """The uncompiled shader jobs owned directly by the aspect's target.

    Package shaders carry `platforms` / `flavors` conditions from their
    `flutter.shaders` entries, so entries for other platforms are skipped
    here before any compile action is registered.

    Args:
        ctx: The aspect context.
        shader_includes: The target's own `shader_includes` files.
        target_platform: The platform this aspect compiles for.

    Returns:
        The shader jobs this target owns directly.
    """
    direct_jobs = []

    # 1. Direct shaders from `shaders` attribute (e.g. on @flutter_sdk//:flutter or a flutter_library)
    if hasattr(ctx.rule.files, "shaders"):
        for shader in ctx.rule.files.shaders:
            direct_jobs.append(struct(
                bundle_path = "shaders/" + encode_asset_key(shader.basename),
                file = shader,
                includes = shader_includes,
            ))

    # 2. Direct shaders from `pkg_shaders` attribute (e.g. on flutter_library / flutter_plugin)
    if hasattr(ctx.rule.attr, "pkg_shaders") and ctx.rule.attr.pkg_shaders:
        pkg_name = getattr(ctx.rule.attr, "package_name", "") if hasattr(ctx.rule.attr, "package_name") else ""
        _, _, pub_shaders = build_pub_contributions(
            package_name = pkg_name,
            fonts_json = "",
            font_files_dict = {},
            pkg_assets_dict = {},
            pkg_shaders_dict = ctx.rule.attr.pkg_shaders,
            shader_includes = shader_includes,
            pkg_asset_platforms = getattr(ctx.rule.attr, "pkg_asset_platforms", {}),
            pkg_asset_flavors = getattr(ctx.rule.attr, "pkg_asset_flavors", {}),
        )
        for entry in pub_shaders:
            if not pub_shader_matches_target(entry, target_platform):
                continue
            direct_jobs.append(struct(
                bundle_path = ("packages/{}/".format(entry.package_name) if entry.package_name else "") + entry.shader_path,
                file = entry.file,
                includes = entry.includes,
            ))
    return direct_jobs

def _compile_aspect_direct_jobs(ctx, flutter_sdk_info, target_platform, direct_jobs):
    """Compile the aspect target's own shaders, deduplicated by bundle path."""
    direct_compiled = []
    if direct_jobs and flutter_sdk_info and flutter_sdk_info.impellerc:
        tools = shader_compile_tools(
            impellerc = flutter_sdk_info.impellerc,
            shader_lib = flutter_sdk_info.shader_lib,
            compile_tool = ctx.executable._shader_compile_tool,
        )
        by_path = dedupe_shader_jobs(ctx, direct_jobs)

        for job in by_path.values():
            out_path = job.bundle_path.replace("../", "_external/")
            output = ctx.actions.declare_file("_shaders_%s/%s/%s.iplr" % (target_platform, ctx.label.name, out_path))
            flutter_shader_compile_action(
                ctx = ctx,
                job = job,
                output = output,
                tools = tools,
                target_platform = target_platform,
                is_web = target_platform == "web",
                require_sksl = False,
            )
            direct_compiled.append(struct(
                bundle_path = job.bundle_path,
                file = output,
                target_platform = target_platform,
            ))
    return direct_compiled

def _aspect_transitive_shaders(ctx):
    """The dep `compiled_shaders` sets propagated through the aspect."""
    transitive = []
    if hasattr(ctx.rule.attr, "deps"):
        deps = ctx.rule.attr.deps
        for dep in (deps if type(deps) == "list" else [deps]):
            if type(dep) == "Target" and FlutterCompiledShadersInfo in dep:
                transitive.append(dep[FlutterCompiledShadersInfo].compiled_shaders)
    return transitive

def _shader_aspect_impl(ctx, fixed_platform):
    target_platform = _aspect_target_platform(ctx, fixed_platform)
    shader_includes = tuple(getattr(ctx.rule.files, "shader_includes", [])) if hasattr(ctx.rule.files, "shader_includes") else ()
    direct_jobs = _aspect_direct_jobs(ctx, shader_includes, target_platform)
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"] if "@rules_flutter//flutter:toolchain_type" in ctx.toolchains else None
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info if flutter_toolchain else None
    direct_compiled = _compile_aspect_direct_jobs(ctx, flutter_sdk_info, target_platform, direct_jobs)
    transitive = _aspect_transitive_shaders(ctx)
    return [
        FlutterCompiledShadersInfo(
            compiled_shaders = depset(direct = direct_compiled, transitive = transitive),
        ),
    ]

def _tester_shader_aspect_impl(_target, ctx):
    return _shader_aspect_impl(ctx, "tester")

def _web_shader_aspect_impl(_target, ctx):
    return _shader_aspect_impl(ctx, "web")

def _app_shader_aspect_impl(_target, ctx):
    return _shader_aspect_impl(ctx, None)

_SHADER_ASPECT_BASE_ATTRS = {
    "_shader_compile_tool": attr.label(
        doc = "Shader compiler the aspect runs over the target's transitive shaders.",
        default = Label("//flutter/private/tools:compile_shader"),
        executable = True,
        cfg = "exec",
    ),
}

_SHADER_ASPECT_TOOLCHAINS = [
    "@rules_flutter//flutter:toolchain_type",
    config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
]

flutter_tester_shader_aspect = aspect(
    implementation = _tester_shader_aspect_impl,
    attr_aspects = ["deps"],
    attrs = _SHADER_ASPECT_BASE_ATTRS,
    toolchains = _SHADER_ASPECT_TOOLCHAINS,
    doc = "Compiles transitive shaders for the flutter_tester platform on the owning targets.",
)

flutter_web_shader_aspect = aspect(
    implementation = _web_shader_aspect_impl,
    attr_aspects = ["deps"],
    attrs = _SHADER_ASPECT_BASE_ATTRS,
    toolchains = _SHADER_ASPECT_TOOLCHAINS,
    doc = "Compiles transitive shaders for the web platform on the owning targets.",
)

flutter_app_shader_aspect = aspect(
    implementation = _app_shader_aspect_impl,
    attr_aspects = ["deps"],
    attrs = _SHADER_ASPECT_BASE_ATTRS | PLATFORM_CONSTRAINT_ATTRS,
    toolchains = _SHADER_ASPECT_TOOLCHAINS,
    doc = "Compiles transitive shaders for the target application platform on the owning targets.",
)

FLUTTER_DEPS_DOC = (
    "`dart_library` or `flutter_library` dependencies. A rule that " +
    "builds an asset bundle needs `@rules_flutter//flutter:material_icons` " +
    "listed here to bundle `MaterialIcons-Regular.otf` into " +
    "`flutter_assets/` for Material widgets; the rules that emit only " +
    "a kernel or an AOT artifact have no bundle for it to reach."
)

# Shared attrs for all flutter application rules.
FLUTTER_APPLICATION_ATTRS = KERNEL_COMPILE_ATTRS | {
    "default_flavor": _DEFAULT_FLAVOR_ATTR,
    "flavor": attr.string(
        default = "",
        doc = "The application flavor (e.g. 'dev', 'prod'). When set, sets the " +
              "FLUTTER_APP_FLAVOR Dart environment define and filters pub " +
              "assets and shaders by flavor.",
    ),
    "deps": attr.label_list(
        doc = FLUTTER_DEPS_DOC,
        providers = [DartInfo],
        aspects = [flutter_app_shader_aspect],
    ),
    "assets": attr.label_list(
        doc = "Asset files to include in the bundle.",
        allow_files = True,
    ),
    "native_deps": attr.label_list(
        doc = "cc_library targets providing shared libraries for dart:ffi.",
        aspects = [native_sources_aspect],
    ),
    "obfuscate": attr.bool(
        doc = "If True, obfuscate Dart symbols in the AOT output. Pair with split_debug_info to produce a symbol map for deobfuscation.",
        default = False,
    ),
    "split_debug_info": attr.bool(
        doc = "If True, extract debug info from the AOT output into a separate file. Produces a .symbols output alongside the AOT binary.",
        default = False,
    ),
    "extra_gen_snapshot_options": attr.string_list(
        doc = "Extra gen_snapshot flags. Only the allow-list in `flutter/private/flutter_aot_compile.bzl` may be used: flags that read or write no file and change neither the snapshot kind, outputs, target nor debugging info. Anything else fails analysis; use `obfuscate` and `split_debug_info` for the obfuscation map and symbols. `--no-obfuscate` fails with `obfuscate = True` and `--no-dwarf-stack-traces` fails with `split_debug_info = True`; remove the flag or set the attribute to False.",
    ),
    "track_widget_creation": attr.bool(
        doc = "Track widget creation locations (`--track-widget-creation`), which the widget inspector and the stock tool's hot reload need. " +
              "On by default, as in stock `flutter run` and `flutter build`; like there, it applies to debug and profile builds and never to release. " +
              "Set False to compile a debug kernel without it.",
        default = True,
    ),
    "shaders": attr.label_list(
        doc = "Fragment shader files (.frag) to compile with impellerc. Compiled shaders are included in the asset bundle.",
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
              "alone with a warning, as `flutter build` does, and fails to " +
              "load only where the app renders with Skia. Set this for an " +
              "app that renders with Skia. Web builds always need SkSL.",
        default = False,
    ),
    "_shader_compile_tool": attr.label(
        doc = "Shader compiler for the app's `shaders`, run before the asset bundle is assembled.",
        default = Label("//flutter/private/tools:compile_shader"),
        executable = True,
        cfg = "exec",
    ),
    "link_hook_assets": attr.string_list(
        doc = "Data assets the packages' link hooks emit, each " +
              "`package:<package>/<name>`. In a release or profile build " +
              "the compiler records the uses of `@RecordUse` classes " +
              "(`--recorded-uses`), each listed package's `hook/link.dart` " +
              "runs over them, and the assets it emits are bundled at " +
              "`packages/<package>/<name>`, loadable with `rootBundle`. " +
              "A hook that emits an asset not listed, skips one that is, or " +
              "reports an error fails the build with its own message. Every " +
              "package with a link hook in `deps` runs, so list the assets " +
              "of each. Debug builds run no hook and bundle none: load what " +
              "the hook would index on demand there. Empty runs no hook.",
    ),
    "tree_shake_icons": attr.bool(
        doc = "If True, tree-shake icon fonts to only include used glyphs. " +
              "Requires all IconData instances to be const. Only applies to release builds.",
        default = True,
    ),
    "license_files": attr.label_list(
        doc = "License/NOTICE files to include in NOTICES.Z. Typically LICENSE files from dependencies.",
        allow_files = True,
    ),
    "min_os_version": attr.string(
        doc = "Minimum OS deployment target for Apple platforms (iOS/macOS). " +
              "Passed to gen_snapshot as --macho-min-os-version. " +
              "Platform-specific bundle rules set appropriate defaults.",
    ),
    "_asset_bundle_tool": attr.label(
        doc = "Tool that renders the asset manifest bundled as `flutter_assets`.",
        default = Label("//flutter/private/tools:generate_asset_manifest"),
        executable = True,
        cfg = "exec",
    ),
    "_const_finder_tool": attr.label(
        doc = "Tool that extracts used icon code points from kernel dills.",
        default = Label("//flutter/private/tools:const_finder"),
        executable = True,
        cfg = "exec",
    ),
} | AGENT_EXTENSIONS_ATTR
