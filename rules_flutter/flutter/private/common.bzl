"""Shared utilities for Flutter rules.

Package config generation, transitive source collection, and the shared
compilation pipeline (kernel → AOT → assets → FFI collection) used by
flutter_application, flutter_android_bundle, and flutter_ios_application.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs", "derive_lib_root", "generate_dev_package_config", _COPY_TO_DIRECTORY_TOOLCHAINS = "COPY_TO_DIRECTORY_TOOLCHAINS")
load("//flutter:providers.bzl", "FlutterNativeLibraryInfo", _resolve_exec_dart = "resolve_exec_dart", _resolve_exec_dart_vm = "resolve_exec_dart_vm", _resolve_flutter_sdk_info = "resolve_flutter_sdk_info")
load("//flutter/private:app_entrypoint.bzl", "AGENT_DIR", "APP_SCHEME", "agent_layout_path", "app_main_location", "app_scheme_location", "app_scheme_sources", "compile_kernel_package_config", "resolve_kernel_entrypoint", "stage_agent_extensions", "synthesize_app_package", "with_root")
load(
    "//flutter/private:flutter_compile.bzl",
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
    "flutter_module_tools",
)
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
            written from; a debug entry module embeds the manifest when it
            is non-empty.

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

def _debug_module_shape(ctx, agent, reg, flags, twins):
    """Fails when a debug Flutter program's own shape cannot ride the entry module.

    The staged agent, native agent and registrant compile into the entry module under their
    constant URIs, and the SDK `flutter` module they replace is the closure's registrant twin.
    Every frontend flag but `--track-widget-creation` has no module configuration, and that one
    must match the twin's.
    """
    reasons = []
    if reg.registrant or agent.agent:
        if not agent.constant:
            reasons.append("its plugin registrant or debug agent is not staged at the constant debug layout")
        elif not twins:
            reasons.append("its closure has no registrant twin of the SDK `flutter` module, which the plugin registrant needs: put `flutter` (or a library depending on it) under `deps`")
        elif reg.registrant and not (reg.location and reg.location.uri == _CONSTANT_REGISTRANT_URI):
            reasons.append("its plugin registrant is not at %s" % _CONSTANT_REGISTRANT_URI)
    tracked = ["--track-widget-creation"] if twins and twins[0].tracked else []
    other = [f for f in flags.extra_frontend if f != "--track-widget-creation"]
    if other:
        reasons.append("frontend flag(s) %s cannot be given to a kernel module compile" % ", ".join(other))
    elif twins and flags.extra_frontend != tracked:
        reasons.append("`track_widget_creation` is %s, and its closure's modules were compiled with it %s" % (
            "on" if flags.extra_frontend else "off",
            "on" if tracked else "off",
        ))
    if reasons:
        fail("%s compiles as Flutter kernel modules in a debug build, and cannot:\n%s" % (
            ctx.label,
            "\n".join(["  - " + r for r in reasons]),
        ))

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
    # A JIT kernel (debug) is the entry module linked with the closure's modules: there is no other way
    # to build it. AOT (profile, release, `aot = True`) compiles the whole program.
    if plan.aot:
        return _compile_full_kernel(ctx, flutter_sdk_info, st, agent, reg, flags, plan)
    twins = flutter_closure_twins(ctx)
    _debug_module_shape(ctx, agent, reg, flags, twins)
    own_files = [ctx.file.main] + [f for f in ctx.files.srcs if f != ctx.file.main]
    modular_tools = flutter_module_tools(ctx, flutter_sdk_info, own_files, st.packages)
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
        native_assets = plan.native_assets_manifest if plan.native_assets else None,
    )

    # An application still publishes its package config; a kernel target has none to give.
    return _kernel_package_config(ctx, st).config_file if plan.assets_dir != None else None

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
    # A debug kernel's closure holds the registrant twin of the SDK `flutter` module exactly when it holds
    # `flutter`, which the agent imports.
    agent = stage_agent_extensions(ctx, aot, mode, has_flutter = aot or bool(flutter_closure_twins(ctx)))
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

def declare_flutter_assets_dir(ctx):
    """Declare the `flutter_assets/` tree artifact for this target.

    Split out from `flutter_bundle` so a rule can name the directory
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
        doc = "`dart_library` or `flutter_library` dependencies.",
        providers = [DartInfo],
    ),
    "defines": attr.string_list(doc = "Dart environment defines (-D flags)."),
} | EXTRA_DART_DEFINES_ATTR | BUILD_MODE_ATTR

FLUTTER_DEPS_DOC = (
    "`dart_library` or `flutter_library` dependencies. What the asset " +
    "bundle holds comes from the app's `pubspec.yaml` and the packages " +
    "these reach, as `flutter build` bundles it."
)

# Shared attrs for all flutter application rules.
FLUTTER_APPLICATION_ATTRS = KERNEL_COMPILE_ATTRS | {
    "default_flavor": _DEFAULT_FLAVOR_ATTR,
    "flavor": attr.string(
        default = "",
        doc = "The application flavor (e.g. 'dev', 'prod'). When set, sets the " +
              "FLUTTER_APP_FLAVOR Dart environment define and bundles the " +
              "pubspec's assets for that flavor, as `flutter build --flavor` does.",
    ),
    "deps": attr.label_list(
        doc = FLUTTER_DEPS_DOC,
        providers = [DartInfo],
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
    "min_os_version": attr.string(
        doc = "Minimum OS deployment target for Apple platforms (iOS/macOS). " +
              "Passed to gen_snapshot as --macho-min-os-version. " +
              "Platform-specific bundle rules set appropriate defaults.",
    ),
} | AGENT_EXTENSIONS_ATTR
