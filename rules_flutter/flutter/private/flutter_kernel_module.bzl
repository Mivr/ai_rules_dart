"""Modular Flutter kernel compilation for `flutter_test` dependencies and entrypoints.

Compiles each `DartInfo` dependency target in a `flutter_test` closure once into
a `<name>.flutter.kmod` directory against Flutter's patched `platform_strong.dill`
(`--target flutter`), then links the entry module and reachable dependency
modules with `DartKernelLink`.

Uses a distinct provider (`FlutterKernelModuleInfo`) and directory suffix
(`.flutter.kmod`) so the aspect can run over `dart_library` targets alongside
`dart_library`'s own VM `DartKernelInfo` (`<name>.kmod`) without provider or
output-path collisions.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo", "DartKernelInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "EXECUTABLE_DEFINES_ATTRS",
    "KERNEL_MODULE_ATTRS",
    "MODULAR_KERNEL_TOOLCHAINS",
    "collect_packages",
    "derive_lib_root",
    "duplicated_source_message",
    "duplicated_source_owners",
    "entry_point_library",
    "entry_sources_from_library",
    "first_per_package",
    "kernel_link_action",
    "kernel_package_config",
    "kernel_packages_consistent",
    "add_module_source_args",
    "collect_native_assets",
    "library_module_source",
    "no_kernel_module",
    _DART_MODULAR_KERNEL_ATTRS = "MODULAR_KERNEL_ATTRS",
)
load("//flutter:providers.bzl", "FlutterInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "AGENT_DIR",
    "APP_SCHEME",
    "app_main_location",
    "app_scheme_location",
    "package_lib_prefix",
    "stage_generated_inputs",
    "synthesize_app_package",
)
load(
    "//flutter/private:flutter_defines_files.bzl",
    "defines_transition",
    "entry_dart_env",
    "module_dart_env",
)
load(
    "//flutter/private:flutter_kernel_tools.bzl",
    "flutter_kernel_tools_for",
    "no_flutter_module_compiler_error",
    "required_flutter_kernel_tools",
)
load(
    "//flutter/private:flutter_test_common.bzl",
    "flutter_test_bootstrap_action",
)

visibility(["//flutter/..."])

FlutterKernelModuleInfo = provider(
    doc = "Modular Flutter kernel info for a DartInfo target.",
    fields = {
        "kernel_info": "DartKernelInfo compiled for the Flutter target and patched SDK.",
        "product_kernel_info": "DartKernelInfo compiled for the Flutter target and product patched SDK (`-Ddart.vm.product=true`).",
        "registrant_twins": "Depset of `struct(plain, kmod, koutline)` registrant twins in the closure, or None.",
    },
)

# The one define the twin adds: the debug build's constant registrant URI.
_TWIN_DEFINE = "flutter.dart_plugin_registrant=%s:///%s/plugin_registrant.dart" % (APP_SCHEME, AGENT_DIR)

MODULAR_KERNEL_ATTRS = _DART_MODULAR_KERNEL_ATTRS | {
    "_extra_dart_defines": attr.label(
        doc = "The //flutter:extra_dart_defines build setting, appended after the target's own `defines`.",
        default = Label("//flutter:extra_dart_defines"),
        providers = [BuildSettingInfo],
    ),
}

# The application's `track_widget_creation` value, as an aspect parameter: with True every module of the closure
# compiles with `--track-widget-creation`. Only the application's aspect takes it; the `flutter_test` aspect does not.
TRACK_WIDGET_CREATION_FLAG = "--track-widget-creation"
_TRACK_ATTR = {"track_widget_creation": attr.bool(doc = "Whether the app tracks widget creation.", default = False)}

def _no_flutter_kernel_module(reason = None):
    """The provider of a target that compiles no module, saying why (`DartKernelInfo.not_modular`)."""
    empty = no_kernel_module(reason)
    return [FlutterKernelModuleInfo(kernel_info = empty, product_kernel_info = empty)]

def _own_package_record(info):
    """Returns the `DartPackageInfo` for the package a `DartInfo` itself owns."""
    if not info.package_name:
        return None
    for pkg in info.transitive_packages.to_list():
        if pkg.package_name == info.package_name and pkg.lib_root == info.lib_root:
            return pkg
    return None

def _is_manual(ctx):
    if ctx.label.package.startswith("flutter/tests"):
        return True
    tags = getattr(ctx.attr, "tags", None)
    if tags == None and hasattr(ctx, "rule"):
        tags = getattr(ctx.rule.attr, "tags", None)
    return tags != None and "manual" in tags

def _dedup_module_sources(sources):
    """Deduplicates `struct(uri, file)` entries by `uri`, preferring generated files over source files to match `[stage.root, '.']` resolution."""
    by_uri = {}
    order = []
    for s in sources:
        prev = by_uri.get(s.uri)
        if prev == None:
            by_uri[s.uri] = s
            order.append(s.uri)
        elif prev.file != None and s.file != None and prev.file.is_source and not s.file.is_source:
            by_uri[s.uri] = s
    return [by_uri[u] for u in order]

def _kernel_module_staged_inputs(ctx, sources, output, extra_inputs, packages, scheme):
    """Dedup sources and stage every generated input; returns `(package_config, stage)`."""
    sources = _dedup_module_sources(sources)
    package_config = ctx.actions.declare_file(output.basename + ".package_config.json", sibling = output)
    ctx.actions.write(
        output = package_config,
        content = kernel_package_config(packages, scheme = scheme),
    )

    # An entry point a dependency module defines has no file here.
    stage_candidates = [s.file for s in sources if s.file != None]
    if extra_inputs != None:
        stage_candidates = stage_candidates + extra_inputs.to_list()

    # Every source is staged and only the staging root is mounted: mounting
    # the exec root (`.`) lets the compile read files the action did not
    # declare, which Bazel then caches without rerunning on their change.
    stage = stage_generated_inputs(ctx, stage_candidates, output.basename, include_sources = True)
    return sources, package_config, stage

def _kernel_module_base_args(ctx, package_config, stage, platform, options):
    """The module compiler flags naming the target, the platform and the defines.

    Args:
        ctx: The rule or aspect context.
        package_config: The `--packages-file` package config File.
        stage: The staging result from `_kernel_module_staged_inputs`.
        platform: The platform `.dill` File the module compiles against.
        options: struct with the compile options: `target`, `scheme`,
            `defines`, `define_file` and `extra_frontend_flags`.
    """
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")

    args.add("--target", options.target)
    args.add("--dart-sdk-summary", platform)
    args.add("--packages-file", package_config)
    if stage.root != None:
        args.add("--multi-root", stage.root)
    args.add("--multi-root-scheme", options.scheme)

    # The defines file first: a `-D` of the same key (the target's own defines, the global flag) wins, as in the
    # whole-program compile. The module compiler takes the defines as a map, so a value keeps its commas.
    define_file = getattr(options, "define_file", None)
    if define_file != None:
        args.add("--define-file", define_file)
    args.add_all(options.defines, format_each = "-D%s")
    args.add_all(options.extra_frontend_flags)
    return args

def _kernel_module_source_args(args, module, excluded, unused_inputs_list, options):
    """Append the per-source and output flags to the module compiler args.

    Args:
        args: The module compiler args object to append to.
        module: struct with the per-module data: `sources`, `dep_kmods`,
            `output`, `koutline` and `extra_inputs`.
        excluded: The sidecar File listing the sources left out (`--excluded-output`).
        unused_inputs_list: The unused-inputs list File, or None.
        options: struct with the compile options (`droppable`).
    """
    args.add_all(module.dep_kmods, before_each = "--input-kmod", expand_directories = False)
    add_module_source_args(args, module.sources, unused_inputs_list != None)
    args.add("--output", module.output.path)
    if module.koutline != None:
        args.add("--output-outline", module.koutline.path)

    args.add("--excluded-output", excluded)
    if unused_inputs_list != None:
        args.add("--unused-inputs-list", unused_inputs_list)
    if not options.droppable:
        args.add("--no-drop")
    if getattr(options, "native_assets", None) != None:
        args.add("--native-assets", options.native_assets)
    if module.extra_inputs:
        args.add_all(module.extra_inputs, before_each = "--input-source")

def _optional_kernel_outputs(module, unused_inputs_list):
    """The unused-inputs list and the outline, for those the module declares."""
    outputs = [unused_inputs_list] if unused_inputs_list != None else []
    return outputs + ([module.koutline] if module.koutline != None else [])

def flutter_kernel_module_action(ctx, tools, module, options):
    """Compiles one Flutter kernel module with staged generated inputs instead of mounting `ctx.bin_dir`.

    Args:
      ctx: The rule or aspect context, used to declare outputs and register the action.
      tools: Kernel tool files (the SDK's module compiler, `dartaotruntime` and platform dill).
      module: struct with the per-module data: `sources` (structs with `uri`
        and `file` for the module's own Dart sources), `packages` (package
        records rendered into the `--packages-file` package config),
        `dep_kmods` (the outline directories of the modules it compiles
        against (`--input-kmod`)), `output` (the module output: a `.kmod`
        directory for libraries, entries otherwise), `koutline` (optional
        outline output receiving `--output-outline`) and `extra_inputs`
        (optional additional input files, e.g. entry sources).
      options: struct with the compile options: `defines` (the `-D`
        declarations of the compile), `define_file` (optional File of `-D`
        lines read before `defines`), `droppable` (whether the module may
        leave out the libraries that do not compile for the target; an entry
        may not), `target` (the front end's target, `"flutter"` by default),
        `platform_dill` (platform kernel override; defaults to the
        toolchain's), `scheme` (package-config URI scheme for the module's
        sources), `extra_frontend_flags` (additional flags for the module
        compiler), `native_assets` (optional native-assets mapping an entry
        embeds) and `unused_inputs` (whether the compile writes its
        unused-inputs list — the declared inputs no compile of this action
        read — and takes it as the action's `unused_inputs_list`, so Bazel
        skips the action when only an unread input changed. True at every
        call site: each registers its action once (the aspect's evaluations
        of one target compute identical actions, which Bazel merges), as
        `dart_library`'s own module does in rules_dart. False registers the
        action with no list).

    Returns:
      The declared sidecar file listing the sources the module left out.
    """
    sources, package_config, stage = _kernel_module_staged_inputs(
        ctx,
        module.sources,
        module.output,
        module.extra_inputs,
        module.packages,
        options.scheme,
    )
    platform = options.platform_dill if options.platform_dill != None else tools.platform_dill
    excluded = ctx.actions.declare_file(module.output.basename + ".vm_excluded.txt", sibling = module.output)
    if options.unused_inputs:
        # Written by the module compiler alongside the module. Declared here, where
        # the one registering action is, so the declaration and the action
        # that generates the file can never part ways.
        unused_inputs_list = ctx.actions.declare_file(module.output.basename + ".unused_inputs", sibling = module.output)
    else:
        unused_inputs_list = None

    args = _kernel_module_base_args(
        ctx = ctx,
        package_config = package_config,
        stage = stage,
        platform = platform,
        options = options,
    )
    _kernel_module_source_args(
        args = args,
        module = module,
        excluded = excluded,
        unused_inputs_list = unused_inputs_list,
        options = options,
    )

    # The compile reads every source through the staging root, and the module
    # compiler reads only the files the request declares: the staged copies.
    if stage.files:
        args.add_all(stage.files, before_each = "--input-source")

    direct_inputs = [
        package_config,
        platform,
    ] + [s.file for s in sources if s.file != None] + stage.files + [
        f
        for f in [getattr(options, "define_file", None), getattr(options, "native_assets", None)]
        if f != None
    ]

    ctx.actions.run(
        # The module compiler of the Dart SDK inside Flutter, run by that SDK's `dartaotruntime`.
        executable = tools.dartaotruntime,
        arguments = [tools.module_compiler.path, args],
        inputs = depset(
            direct = direct_inputs,
            transitive = [module.dep_kmods] + ([module.extra_inputs] if module.extra_inputs else []),
        ),
        tools = [tools.dartaotruntime, tools.module_compiler],
        outputs = [module.output, excluded] + _optional_kernel_outputs(module, unused_inputs_list),
        unused_inputs_list = unused_inputs_list,
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel module %s" % module.output.short_path,
        execution_requirements = {} if _is_manual(ctx) else {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
        toolchain = None,
    )
    return excluded

def _modular_gate_inputs(ctx, target):
    """The target's Dart metadata and dependency list behind the modular-kernel gate."""
    dart_info = target[DartInfo]
    rule_deps = getattr(ctx.rule.attr, "deps", [])
    if type(rule_deps) != "list":
        rule_deps = [rule_deps]
    return (
        dart_info,
        dart_info.package_name,
        dart_info.lib_root,
        _own_package_record(dart_info),
        getattr(ctx.rule.files, "srcs_dir", []) if getattr(ctx.rule.attr, "srcs_dir", None) else getattr(ctx.rule.files, "srcs", []),
        rule_deps,
    )

def _opaque_reason(ctx, dart_info, package_name, lib_root, own_record, own_srcs, rule_deps):
    """Why the target compiles no module because its sources cannot be named, or None."""
    srcs_dir = getattr(ctx.rule.attr, "srcs_dir", None)
    if srcs_dir:
        if not (len(own_srcs) == 1 and own_srcs[0].is_directory):
            return "its `srcs_dir` is not one directory (a `dart_source_set`)"
        if not package_name or own_record == None:
            return "it names no Dart package (`package_name`), so its sources have no `package:` URI"
        return None
    # A depset is true when it is not empty; asking does not flatten it.
    if not hasattr(ctx.rule.attr, "srcs") and dart_info.transitive_srcs and len(rule_deps) == 0:
        return "its rule has no `srcs`, so its files are not known at analysis"
    if not own_srcs:
        return None
    if not package_name or own_record == None:
        return "it names no Dart package (`package_name`), so its sources have no `package:` URI"
    prefix = package_lib_prefix(lib_root)
    for f in own_srcs:
        if not f.short_path.startswith(prefix):
            return "its source %s is outside its package's `lib/`; move it there, or into the executable's own `srcs`" % f.short_path
    return None

def _collect_dep_mod_infos(rule_deps):
    """The dep `FlutterKernelModuleInfo` values, or the labels of the deps that carry none."""
    dep_mod_infos = [
        dep[FlutterKernelModuleInfo]
        for dep in rule_deps
        if type(dep) == "Target" and FlutterKernelModuleInfo in dep
    ]
    if len(dep_mod_infos) != len(rule_deps):
        return [str(dep.label) for dep in rule_deps if type(dep) != "Target" or FlutterKernelModuleInfo not in dep]
    return dep_mod_infos

def _modular_consistency(own_record, rule_deps, dep_kernels):
    """The package records and whether deps agree on one modular closure."""
    raw = depset(
        transitive = [
            dep[DartInfo].transitive_packages
            for dep in rule_deps
            if type(dep) == "Target" and DartInfo in dep
        ],
    ).to_list()
    records = ([own_record] if own_record != None else []) + raw
    packages_ok = kernel_packages_consistent(records)
    modular = packages_ok and all([k.modular for k in dep_kernels])
    return records, packages_ok, modular

def _modular_dep_closures(target, dep_kernels, rule_deps, own_srcs):
    """The postorder dep closures and ownership graphs propagated by the aspect."""
    dep_closure = depset(order = "postorder", transitive = [k.transitive_kmods for k in dep_kernels])
    dep_outline_closure = depset(order = "postorder", transitive = [k.transitive_koutlines for k in dep_kernels])
    upstream_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels])
    cross_pkg_srcs = depset(transitive = [k.cross_pkg_srcs for k in dep_kernels])
    owned = depset(
        [(str(target.label), f.short_path) for f in own_srcs],
        transitive = [k.owned for k in dep_kernels],
    )
    edges = depset(
        [(str(target.label), str(dep.label)) for dep in rule_deps],
        transitive = [k.edges for k in dep_kernels],
    )
    return dep_closure, dep_outline_closure, upstream_excluded, cross_pkg_srcs, owned, edges

def _find_dep_base_dill(dep_kernels):
    """The first dep-seeded base dill triple, or empty defaults when no dep seeds one."""
    base_dill = None
    base_keys = None
    base_kmods = depset()
    for k in dep_kernels:
        kd = getattr(k, "base_dill", None)
        kk = getattr(k, "base_keys", None)
        if kd != None and kk != None:
            base_dill = kd
            base_keys = kk
            base_kmods = getattr(k, "base_kmods", depset())
            break
    return base_dill, base_keys, base_kmods

def _without_base_kmods(dep_closure, base_dill, base_keys, base_kmods):
    """`dep_closure` minus the modules a seeded base dill already holds (unchanged without one)."""
    base_paths = {f.path: True for f in base_kmods.to_list()} if base_dill != None and base_keys != None else {}
    if not base_paths:
        return dep_closure
    return depset([f for f in dep_closure.to_list() if f.path not in base_paths], order = "postorder")

def _header_only_module_info(product_modular, dep_product_kernels, closures, base):
    """The provider list for a target with no own sources: dep closures only.

    Args:
        product_modular: Whether the product closure agrees on one modular world.
        dep_product_kernels: The deps' product `DartKernelInfo` values.
        closures: struct with the dep closures: `dep_closure`,
            `dep_outline_closure`, `upstream_excluded`, `cross_pkg_srcs`,
            `owned`, `edges` and `twins`.
        base: struct with the base dill triple seeded by deps: `base_dill`,
            `base_keys` and `base_kmods`.
    """
    product_kernel_info = (
        DartKernelInfo(
            kmod = None,
            koutline = None,
            transitive_kmods = depset(
                order = "postorder",
                transitive = [k.transitive_kmods for k in dep_product_kernels],
            ),
            transitive_koutlines = depset(
                order = "postorder",
                transitive = [k.transitive_koutlines for k in dep_product_kernels],
            ),
            modular = True,
            closure_excluded = depset(transitive = [k.closure_excluded for k in dep_product_kernels]),
            cross_pkg_srcs = closures.cross_pkg_srcs,
            owned = closures.owned,
            edges = closures.edges,
            base_dill = None,
            base_keys = None,
            base_kmods = depset(),
            unseeded_base_kmods = depset(),
        ) if product_modular else no_kernel_module()
    )
    return [
        FlutterKernelModuleInfo(
            kernel_info = DartKernelInfo(
                kmod = None,
                koutline = None,
                transitive_kmods = closures.dep_closure,
                transitive_koutlines = closures.dep_outline_closure,
                modular = True,
                closure_excluded = closures.upstream_excluded,
                cross_pkg_srcs = closures.cross_pkg_srcs,
                owned = closures.owned,
                edges = closures.edges,
                base_dill = base.base_dill,
                base_keys = base.base_keys,
                base_kmods = base.base_kmods,
                unseeded_base_kmods = depset(),
            ),
            product_kernel_info = product_kernel_info,
            registrant_twins = closures.twins,
        ),
    ]

def _flutter_module_options(env, platform_dill, droppable, frontend_flags, extra_defines = [], native_assets = None):
    """The `flutter_kernel_module_action` options of a Flutter-target module compile.

    Args:
        env: struct(defines, flagfile): the environment of the compile (`module_dart_env` or `entry_dart_env`).
        platform_dill: The platform `.dill` the module compiles against.
        droppable: Whether the module is a dependency module the link may drop.
        frontend_flags: Extra frontend flags (`--track-widget-creation` for a tracking application).
        extra_defines: Defines after the environment's (the registrant twin's, the product ones).
        native_assets: The native-assets mapping an entry embeds, or None.

    Returns:
        The `options` struct for `flutter_kernel_module_action`.
    """
    return struct(
        defines = env.defines + extra_defines,
        define_file = env.flagfile,
        exclude_non_sources = True,
        droppable = droppable,
        target = "flutter",
        platform_dill = platform_dill,
        libraries_json = None,
        libraries_platform = None,
        extra_libraries = ["ui", "nativewrappers"],
        scheme = APP_SCHEME,
        extra_frontend_flags = frontend_flags,
        native_assets = native_assets,
        unused_inputs = True,
    )

def _compile_main_kmod(ctx, tools, flutter_sdk_info, spec, twin = False):
    """Compile the target's own sources into the debug `.flutter.kmod` directory.

    Args:
        ctx: The aspect context.
        tools: The kernel tools struct matching `flutter_sdk_info`.
        flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
        spec: struct with the target's module inputs: `target_name`,
            `package_name`, `lib_root`, `own_srcs` (the target's own source
            Files), `records` (the package records), `dep_outline_closure`
            `upstream_excluded` and `frontend_flags`.
        twin: Whether to compile the registrant twin: same inputs, distinct outputs, one more define.
    """
    stem = spec.target_name + (".flutter_registrant" if twin else ".flutter")
    kmod = ctx.actions.declare_directory(stem + ".kmod")
    koutline = ctx.actions.declare_directory(stem + ".koutline")
    sources = [
        library_module_source(spec.package_name, spec.lib_root, f)
        for f in spec.own_srcs
    ]
    deduped_packages = first_per_package(spec.records)
    env = module_dart_env(ctx)
    excluded = flutter_kernel_module_action(
        ctx = ctx,
        tools = tools,
        module = struct(
            sources = sources,
            packages = deduped_packages,
            dep_kmods = spec.dep_outline_closure,
            output = kmod,
            koutline = koutline,
            extra_inputs = None,
            closure_excluded = spec.upstream_excluded,
        ),
        options = _flutter_module_options(
            env,
            flutter_sdk_info.platform_kernel_dill,
            True,
            spec.frontend_flags,
            [_TWIN_DEFINE] if twin else [],
        ),
    )
    return kmod, koutline, sources, deduped_packages, env, excluded

def _link_flutter_test_base(ctx, target_name, package_name, kmod, dep_closure, base_dill, base_keys, base_kmods):
    """Seed the `flutter_test` base dill from the debug modules; returns the base triple."""
    if package_name == "flutter_test" and hasattr(ctx.executable, "_kernel_link"):
        base_dill = ctx.actions.declare_file(target_name + ".flutter_base.dill")
        base_keys = ctx.actions.declare_file(target_name + ".flutter_base.keys")
        seed_modules = [kmod] + dep_closure.to_list()
        kernel_link_action(
            ctx,
            dep_closure,
            entry = None,
            output = base_dill,
            seed_modules = seed_modules,
            write_keys = base_keys,
        )
        base_kmods = depset(direct = [kmod], transitive = [dep_closure])
    return base_dill, base_keys, base_kmods

def _compile_product_kmod(ctx, tools, flutter_sdk_info, spec):
    """Compile the product (AOT/profile) `.flutter_product.kmod` directory.

    Args:
        ctx: The aspect context.
        tools: The kernel tools struct matching `flutter_sdk_info`.
        flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
        spec: struct with the target's module inputs: `target_name`, `sources`
            (the debug compile's `struct(uri, file)` entries), `deduped_packages`,
            `env` (the debug compile's environment), `dep_product_kernels`,
            `cross_pkg_srcs`, `owned` and `edges`.
    """
    product_dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in spec.dep_product_kernels],
    )
    product_dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in spec.dep_product_kernels],
    )
    product_upstream_excluded = depset(transitive = [k.closure_excluded for k in spec.dep_product_kernels])
    product_kmod = ctx.actions.declare_directory(spec.target_name + ".flutter_product.kmod")
    product_koutline = ctx.actions.declare_directory(spec.target_name + ".flutter_product.koutline")
    product_excluded = flutter_kernel_module_action(
        ctx = ctx,
        tools = tools,
        module = struct(
            sources = spec.sources,
            packages = spec.deduped_packages,
            dep_kmods = product_dep_outline_closure,
            output = product_kmod,
            koutline = product_koutline,
            extra_inputs = None,
            closure_excluded = product_upstream_excluded,
        ),
        options = _flutter_module_options(
            spec.env,
            flutter_sdk_info.platform_kernel_dill_product,
            True,
            [],
            ["dart.vm.product=true", "FLUTTER_WEB_USE_SKIA=false", "FLUTTER_WEB_USE_SKWASM=true"],
        ),
    )
    return DartKernelInfo(
        kmod = product_kmod,
        koutline = product_koutline,
        transitive_kmods = depset(order = "postorder", direct = [product_kmod], transitive = [product_dep_closure]),
        transitive_koutlines = depset(
            order = "postorder",
            direct = [product_koutline],
            transitive = [product_dep_outline_closure],
        ),
        modular = True,
        closure_excluded = depset(direct = [product_excluded], transitive = [product_upstream_excluded]),
        cross_pkg_srcs = spec.cross_pkg_srcs,
        owned = spec.owned,
        edges = spec.edges,
        base_dill = None,
        base_keys = None,
        base_kmods = depset(),
        unseeded_base_kmods = depset(),
    )

def _modular_dep_state(label, rule_deps, own_record, flutter_sdk_info):
    """The validated dependency kernel state, or why the target compiles no module.

    Collects the deps' `FlutterKernelModuleInfo` values and checks the closure
    agrees on one modular world. A debug program that reaches a target that
    fails them fails, with the reason this returns.

    Args:
        label: The target's label, for the reason.
        rule_deps: The target's dependency Targets.
        own_record: The `DartPackageInfo` for the target's own package.
        flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.

    Returns:
        struct(dep_kernels, dep_product_kernels, records, product_modular, twins), or
        a reason string when a dep compiles no module or the closure disagrees.
    """
    dep_mod_infos = _collect_dep_mod_infos(rule_deps)
    if dep_mod_infos and type(dep_mod_infos[0]) == "string":
        return "%s compiles no module: its dependencies %s carry no Flutter kernel module" % (label, ", ".join(dep_mod_infos))
    dep_kernels = [m.kernel_info for m in dep_mod_infos]
    dep_product_kernels = [m.product_kernel_info for m in dep_mod_infos]

    for k in dep_kernels:
        if not k.modular:
            return getattr(k, "not_modular", None) or "%s compiles no module: a dependency compiles none" % label
    records, packages_ok, modular = _modular_consistency(own_record, rule_deps, dep_kernels)
    if not modular:
        return "%s compiles no module: one package of its closure has two roots, or two packages sit at the workspace root; a package config names one root per package" % label
    product_modular = (
        packages_ok and
        flutter_sdk_info.platform_kernel_dill_product != None and
        all([k.modular for k in dep_product_kernels])
    )
    return struct(
        dep_kernels = dep_kernels,
        dep_product_kernels = dep_product_kernels,
        records = records,
        product_modular = product_modular,
        twins = depset(transitive = [m.registrant_twins for m in dep_mod_infos if m.registrant_twins != None]),
    )

def _compile_target_kernels(ctx, tools, flutter_sdk_info, target_name, package_name, job):
    """Compiles a target's own debug and product modules and returns the provider list.

    Args:
        ctx: The aspect context.
        tools: The kernel tools struct matching `flutter_sdk_info`.
        flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
        target_name: The target's short name, for output paths.
        package_name: The target's `package:` name.
        job: struct with the target's module inputs: `own_srcs`, `records`,
            `dep_product_kernels`, `dep_closure`, `dep_outline_closure`,
            `upstream_excluded`, `cross_pkg_srcs`, `owned`, `edges`,
            `base_dill`, `base_keys`, `base_kmods`, `product_modular`, `twins` and `frontend_flags`.
    """
    spec = struct(
        target_name = target_name,
        package_name = package_name,
        lib_root = job.lib_root,
        own_srcs = job.own_srcs,
        records = job.records,
        dep_outline_closure = job.dep_outline_closure,
        upstream_excluded = job.upstream_excluded,
        frontend_flags = job.frontend_flags,
    )
    kmod, koutline, sources, deduped_packages, env, excluded = _compile_main_kmod(
        ctx = ctx,
        tools = tools,
        flutter_sdk_info = flutter_sdk_info,
        spec = spec,
    )
    twin = None
    if package_name == "flutter":
        twin_kmod, twin_koutline, _, _, _, twin_excluded = _compile_main_kmod(ctx, tools, flutter_sdk_info, spec, True)
        twin = struct(
            plain = kmod,
            kmod = twin_kmod,
            koutline = twin_koutline,
            excluded = twin_excluded,
            tracked = bool(job.frontend_flags),
        )
    base_dill, base_keys, base_kmods = _link_flutter_test_base(
        ctx,
        target_name,
        package_name,
        kmod,
        job.dep_closure,
        job.base_dill,
        job.base_keys,
        job.base_kmods,
    )

    if job.product_modular:
        product_kernel_info = _compile_product_kmod(
            ctx = ctx,
            tools = tools,
            flutter_sdk_info = flutter_sdk_info,
            spec = struct(
                target_name = target_name,
                sources = sources,
                deduped_packages = deduped_packages,
                env = env,
                dep_product_kernels = job.dep_product_kernels,
                cross_pkg_srcs = job.cross_pkg_srcs,
                owned = job.owned,
                edges = job.edges,
            ),
        )
    else:
        product_kernel_info = no_kernel_module()

    return [
        FlutterKernelModuleInfo(
            kernel_info = DartKernelInfo(
                kmod = kmod,
                koutline = koutline,
                transitive_kmods = depset(order = "postorder", direct = [kmod], transitive = [job.dep_closure]),
                transitive_koutlines = depset(order = "postorder", direct = [koutline], transitive = [job.dep_outline_closure]),
                modular = True,
                closure_excluded = depset(direct = [excluded], transitive = [job.upstream_excluded]),
                cross_pkg_srcs = job.cross_pkg_srcs,
                owned = job.owned,
                edges = job.edges,
                base_dill = base_dill,
                base_keys = base_keys,
                base_kmods = base_kmods,
                unseeded_base_kmods = depset(),
            ),
            product_kernel_info = product_kernel_info,
            registrant_twins = depset(direct = [twin] if twin else [], transitive = [job.twins]),
        ),
    ] + ([OutputGroupInfo(flutter_registrant_twin = depset([twin.kmod, twin.koutline, twin.excluded]))] if twin else [])

def swap_flutter_registrant_twin(closure, twins):
    """Returns `closure` with the plain SDK `flutter` module replaced by its registrant twin.

    Args:
        closure: A depset of module `.kmod` Files (a `DartKernelInfo.transitive_kmods`).
        twins: The `FlutterKernelModuleInfo.registrant_twins` depset of the closure's root, or None.

    Returns:
        `closure` itself when there is no twin; otherwise a postorder depset in the same order.
    """
    if twins == None or not twins.to_list():
        return closure
    swap = {t.plain: t.kmod for t in twins.to_list()}
    return depset([swap.get(f, f) for f in closure.to_list()], order = "postorder")

def _flutter_kernel_module_aspect_impl(target, ctx):
    # The application's aspect (it takes `track_widget_creation`) compiles modules only in a debug build: a profile
    # or release app compiles whole-program AOT. Its outputs carry an `.app_debug` stem so they never collide with
    # the `flutter_test` aspect's outputs for a library both reach in one configuration.
    app = hasattr(ctx.attr, "track_widget_creation")
    tracked = getattr(ctx.attr, "track_widget_creation", False)
    if DartInfo not in target or (app and ctx.var["COMPILATION_MODE"] != "dbg"):
        return _no_flutter_kernel_module()

    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info if flutter_toolchain else None
    if flutter_sdk_info == None or flutter_sdk_info.platform_kernel_dill == None:
        return _no_flutter_kernel_module("%s compiles no module: the Flutter toolchain has no debug platform kernel" % ctx.label)
    tools = flutter_kernel_tools_for(ctx, flutter_sdk_info)
    if tools == None:
        return _no_flutter_kernel_module(no_flutter_module_compiler_error(ctx.label, flutter_sdk_info))

    dart_info, package_name, lib_root, own_record, own_srcs, rule_deps = _modular_gate_inputs(ctx, target)
    opaque = _opaque_reason(ctx, dart_info, package_name, lib_root, own_record, own_srcs, rule_deps)
    if opaque != None:
        return _no_flutter_kernel_module("%s compiles no module: %s" % (ctx.label, opaque))

    dep = _modular_dep_state(ctx.label, rule_deps = rule_deps, own_record = own_record, flutter_sdk_info = flutter_sdk_info)
    if type(dep) == "string":
        return _no_flutter_kernel_module(dep)

    dep_closure, dep_outline_closure, upstream_excluded, cross_pkg_srcs, owned, edges = _modular_dep_closures(
        target,
        dep.dep_kernels,
        rule_deps,
        own_srcs,
    )
    base_dill, base_keys, base_kmods = _find_dep_base_dill(dep.dep_kernels)

    if not own_srcs:
        return _header_only_module_info(
            product_modular = dep.product_modular,
            dep_product_kernels = dep.dep_product_kernels,
            closures = struct(
                twins = dep.twins,
                dep_closure = dep_closure,
                dep_outline_closure = dep_outline_closure,
                upstream_excluded = upstream_excluded,
                cross_pkg_srcs = cross_pkg_srcs,
                owned = owned,
                edges = edges,
            ),
            base = struct(
                base_dill = base_dill,
                base_keys = base_keys,
                base_kmods = base_kmods,
            ),
        )

    return _compile_target_kernels(
        ctx = ctx,
        tools = tools,
        flutter_sdk_info = flutter_sdk_info,
        target_name = target.label.name + (".app_debug" if app else "") + (".tracked" if tracked else ""),
        package_name = package_name,
        job = struct(
            lib_root = lib_root,
            own_srcs = own_srcs,
            records = dep.records,
            dep_product_kernels = dep.dep_product_kernels,
            dep_closure = dep_closure,
            dep_outline_closure = dep_outline_closure,
            upstream_excluded = upstream_excluded,
            cross_pkg_srcs = cross_pkg_srcs,
            owned = owned,
            edges = edges,
            base_dill = base_dill,
            base_keys = base_keys,
            base_kmods = base_kmods,
            product_modular = dep.product_modular,
            twins = dep.twins,
            frontend_flags = [TRACK_WIDGET_CREATION_FLAG] if tracked else [],
        ),
    )

def _module_aspect(extra_attrs):
    """Builds a module aspect over `deps`.

    Args:
        extra_attrs: Attrs added to the aspect's own: the `track_widget_creation` parameter makes it a
            `flutter_application` aspect, which registers nothing outside a debug build.

    Returns:
        The aspect compiling each `DartInfo` library into a modular `.flutter.kmod` directory.
    """
    return aspect(
        implementation = _flutter_kernel_module_aspect_impl,
        attr_aspects = ["deps"],
        attrs = KERNEL_MODULE_ATTRS | EXECUTABLE_DEFINES_ATTRS | extra_attrs | {
            "_extra_dart_defines": attr.label(
                doc = "The //flutter:extra_dart_defines build setting, read for the aspect's module compiles.",
                default = Label("//flutter:extra_dart_defines"),
                providers = [BuildSettingInfo],
            ),
        },
        toolchains = [
            "@rules_flutter//flutter:toolchain_type",
        ] + MODULAR_KERNEL_TOOLCHAINS,
        doc = "Compiles each DartInfo library in a dependency closure into a modular .flutter.kmod directory.",
    )

flutter_kernel_module_aspect = _module_aspect({})
flutter_app_kernel_module_aspect = _module_aspect(_TRACK_ATTR)

def _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        entry_name,
        platform_dill,
        frontend_flags = [],
        native_assets = None):
    """Compiles one Flutter entry module against dependency outlines.

    Shared by the built-in test/app compiles below and the public custom-kernel
    functions: the entry module sees only the dependency outlines (never their
    sources), so a body-only edit to a library recompiles that library's module
    plus the entry/link actions — never the whole program. `frontend_flags` are the entry's extra
    frontend flags (`--track-widget-creation` for a tracking application).

    The entry compiles with the environment its `deps` were configured with (`entry_dart_env`), so it and every
    dependency module see the same defines. A value may hold a comma. `native_assets` is the program's
    native-assets mapping, which the entry embeds as `frontend_server --native-assets` embeds it in a whole program.
    """
    env = entry_dart_env(ctx)
    dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_kernels],
    )
    cross_pkg_srcs = depset(
        transitive = [k.cross_pkg_srcs for k in dep_kernels],
    )
    entry = ctx.actions.declare_directory(entry_name)
    flutter_kernel_module_action(
        ctx = ctx,
        tools = tools,
        module = struct(
            sources = sources,
            packages = first_per_package(packages),
            dep_kmods = dep_outline_closure,
            output = entry,
            koutline = None,
            extra_inputs = cross_pkg_srcs,
            closure_excluded = depset(
                transitive = [k.closure_excluded for k in dep_kernels],
            ),
        ),
        options = _flutter_module_options(env, platform_dill, False, frontend_flags, native_assets = native_assets),
    )
    return entry

def _link_flutter_test_entry_module(ctx, dep_kernels, entry, output):
    """Links a test entry module, delta-linking against the flutter_test base dill.

    Returns the base dill linked against, or `None` when no base dill applies.
    Shared by the built-in test compile below and the public custom test kernel.
    """
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    base_dill, base_keys, base_kmods = _find_dep_base_dill(dep_kernels)
    kernel_link_action(
        ctx,
        _without_base_kmods(dep_closure, base_dill, base_keys, base_kmods),
        entry,
        output,
        base_keys = base_keys,
    )
    return base_dill

def flutter_module_tools(ctx, flutter_sdk_info, own_files, packages, what = None):
    """The kernel tools a debug Flutter program compiles its entry module with, failing when it cannot.

    A debug `flutter_test`, `flutter_application` and `flutter_kernel_target`
    compile their entry module against the closure's outlines and link the
    modules; there is no other way to build their kernel. Every shape that
    cannot fails here at analysis, naming the target and each reason.

    Args:
      ctx: The rule context.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      own_files: The target's own `.dart` files (`[ctx.file.main] + ctx.files.srcs`), `main` first.
        A `main` that a library in `deps` lists is that library's, not the target's
        (`entry_point_library`): the entry module takes it from the library's module.
      packages: The synthesized `DartPackageInfo` list for the target.
      what: Optional name of the calling function, for a custom rule's message.

    Returns:
      The kernel tools struct from `flutter_kernel_tools_for`.
    """
    who = "%s (%s)" % (ctx.label, what) if what else str(ctx.label)
    if flutter_sdk_info == None or flutter_sdk_info.platform_kernel_dill == None:
        fail("%s compiles Flutter kernel modules, which needs a Flutter toolchain with a debug platform kernel (`platform_kernel_dill`)." % who)
    tools = required_flutter_kernel_tools(ctx, flutter_sdk_info)

    reasons = []
    infos = [dep[FlutterKernelModuleInfo] if FlutterKernelModuleInfo in dep else None for dep in ctx.attr.deps]
    missing = [str(dep.label) for dep, info in zip(ctx.attr.deps, infos) if info == None]
    if missing:
        reasons.append("%s carry no Flutter kernel module: put them under `deps` with `flutter_kernel_module_aspect` applied" % ", ".join(missing))
    dep_kernels = [info.kernel_info for info in infos if info != None]
    for k in dep_kernels:
        if not k.modular:
            reasons.append(getattr(k, "not_modular", None) or "a dependency compiles no module")
            break
    if not kernel_packages_consistent(packages):
        reasons.append("one package of its closure has two roots, or two packages sit at the workspace root: a package config names one root per package")
    owned = depset(transitive = [k.owned for k in dep_kernels]).to_list()
    edges = depset(transitive = [k.edges for k in dep_kernels]).to_list()

    # A `main` that a library in `deps` lists is that library's: the entry takes it from the library's module.
    main = own_files[0] if own_files else None
    entry_point = entry_point_library(main, ctx.attr.deps)
    own_paths = [f.short_path for f in own_files if entry_point == None or f != entry_point.file]
    duplicate = duplicated_source_owners(own_paths, owned, edges)
    if duplicate != None:
        reasons.append(duplicated_source_message(duplicate, str(ctx.label), main))
    if reasons:
        fail("%s compiles Flutter kernel modules, and cannot:\n%s" % (who, "\n".join(["  - " + r for r in reasons])))
    return tools

def compile_flutter_modular_test_kernel(
        ctx,
        flutter_sdk_info,
        tools,
        bootstrap,
        staged_comparator,
        lib_root,
        packages,
        output,
        native_assets = None):
    """Compiles a `flutter_test`'s entry module and links it with dependency modules.

    Compiles against the debug `platform_kernel_dill` without product defines so
    The module compiler preserves `AssertStatement` and `AssertInitializer` nodes in
    both `.flutter.kmod` / `.flutter.koutline` and `.flutter_entry.kmod` (matching
    `--enable-asserts` in a whole-program `-c dbg` compile), which fire at runtime
    under `flutter_tester --enable-checked-mode`.

    Args:
      ctx: The `flutter_test` rule context.
      flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain.
      tools: The kernel tools struct returned by `flutter_module_tools`.
      bootstrap: The generated `<name>_bootstrap.dart` File (entry point).
      staged_comparator: Optional staged `<name>.golden_comparator.dart` File.
      lib_root: The test package's `lib_root` from `derive_lib_root`.
      packages: The synthesized `DartPackageInfo` list for the test.
      output: The linked `.dill` File to produce.
      native_assets: The test's native-assets mapping (`native_assets.json`), embedded in the entry, or None.

    Returns:
      The `base_dill` File from the transitive SDK packages if present, or `None`.
    """
    sources = [
        struct(uri = app_scheme_location(bootstrap).uri, file = bootstrap),
    ]
    if staged_comparator != None:
        sources.append(struct(uri = app_scheme_location(staged_comparator).uri, file = staged_comparator))
    sources.append(struct(
        uri = app_main_location(ctx.attr.package_name, lib_root, ctx.file.main).uri,
        file = ctx.file.main,
    ))
    for f in ctx.files.srcs:
        if f == ctx.file.main:
            continue
        sources.append(struct(
            uri = app_main_location(ctx.attr.package_name, lib_root, f).uri,
            file = f,
        ))

    # A `main` a library in `deps` lists comes from that library's module; the bootstrap imports it.
    sources = entry_sources_from_library(sources, entry_point_library(ctx.file.main, ctx.attr.deps))

    dep_kernels = [
        dep[FlutterKernelModuleInfo].kernel_info
        for dep in ctx.attr.deps
        if FlutterKernelModuleInfo in dep
    ]
    entry = _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        ctx.label.name + ".flutter_entry.kmod",
        flutter_sdk_info.platform_kernel_dill,
        native_assets = native_assets,
    )
    return _link_flutter_test_entry_module(ctx, dep_kernels, entry, output)

def flutter_closure_twins(ctx):
    """The registrant twins of `ctx.attr.deps`' closure, as a list (empty when it holds no twin)."""
    infos = [d[FlutterKernelModuleInfo] for d in ctx.attr.deps if FlutterKernelModuleInfo in d]
    return depset(transitive = [getattr(i, "registrant_twins", None) or depset() for i in infos]).to_list()

def compile_flutter_modular_app_kernel(
        ctx,
        tools,
        lib_root,
        packages,
        output,
        platform_dill,
        debug = None,
        native_assets = None):
    """Compiles a Flutter kernel target's entry module and links it with dependency modules and `platform_dill`.

    Args:
      ctx: The rule context (`flutter_kernel_target`, etc.).
      tools: The kernel tools struct returned by `flutter_module_tools`.
      lib_root: The app package's `lib_root` from `derive_lib_root`.
      packages: The synthesized `DartPackageInfo` list for the app.
      output: The linked `.dill` File to produce (with `platform_dill` prepended).
      platform_dill: The platform `.dill` File to compile and link against.
      debug: None, or `struct(files, twins, flags)`: the staged agent, native agent and registrant
        Files compiled into the entry module under their constant URIs, the closure's
        registrant twins, which the link uses in place of the plain SDK `flutter` module, and the
        entry's extra frontend flags (`--track-widget-creation`, as the closure's modules carry).
      native_assets: The program's native-assets mapping (`native_assets.json`), embedded in the entry, or None.
    """
    own = [ctx.file.main] + [f for f in ctx.files.srcs if f != ctx.file.main]
    sources = [struct(uri = app_main_location(ctx.attr.package_name, lib_root, f).uri, file = f) for f in own]

    # A `main` a library in `deps` lists is that library's: the entry names it by the library's
    # `package:` URI and the module compiler links it from that library's module.
    sources = entry_sources_from_library(sources, entry_point_library(ctx.file.main, ctx.attr.deps))
    sources += [struct(uri = app_scheme_location(f).uri, file = f) for f in (debug.files if debug else [])]
    twins = depset(debug.twins) if debug else None

    dep_kernels = [
        dep[FlutterKernelModuleInfo].kernel_info
        for dep in ctx.attr.deps
        if FlutterKernelModuleInfo in dep
    ]
    entry = _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        ctx.label.name + ".flutter_entry.kmod",
        platform_dill,
        debug.flags if debug else [],
        native_assets = native_assets,
    )
    dep_closure = swap_flutter_registrant_twin(
        depset(order = "postorder", transitive = [k.transitive_kmods for k in dep_kernels]),
        twins,
    )
    kernel_link_action(
        ctx,
        dep_closure,
        entry,
        output,
        platform_dill = platform_dill,
    )

FLUTTER_MODULAR_KERNEL_ATTRS = {
    "deps": attr.label_list(
        doc = "DartInfo dependencies, compiled once each by `flutter_kernel_module_aspect`.",
        providers = [DartInfo],
        aspects = [flutter_kernel_module_aspect],
        # The kernel's own `defines` are the closure's configuration, so every module compiles with them.
        cfg = defines_transition,
    ),
    "defines": attr.string_list(
        doc = "Dart environment defines (`KEY=VALUE`) of the kernel: its dependency modules and its entry compile with them, followed by the global `//flutter:extra_dart_defines`. A value may hold a comma.",
        default = [],
    ),
    "_extra_dart_defines": attr.label(
        doc = "The //flutter:extra_dart_defines build setting, appended after the kernel's own `defines`.",
        default = Label("//flutter:extra_dart_defines"),
        providers = [BuildSettingInfo],
    ),
    "_allowlist_function_transition": attr.label(
        doc = "Function-transition allowlist the `deps` edge's platform transition requires.",
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
} | KERNEL_MODULE_ATTRS

FLUTTER_MODULAR_KERNEL_TOOLCHAINS = [
    "@rules_flutter//flutter:toolchain_type",
] + MODULAR_KERNEL_TOOLCHAINS

def _flutter_modular_custom_tools(ctx, deps, own_files, packages, what):
    """Resolves the debug SDK and kernel tools for a custom modular kernel, or fails.

    Every shape the built-in rules refuse fails here with the same reasons
    (see `flutter_module_tools`). A custom kernel takes no native-assets
    mapping, so a closure with code assets (a build hook's output or a
    `dart_code_asset`) fails too.

    Args:
      ctx: The custom rule context. Must merge `FLUTTER_MODULAR_KERNEL_ATTRS`.
      deps: The custom rule's dependency Targets.
      own_files: The entry's own `.dart` Files.
      packages: The `DartPackageInfo` list for the entry compile.
      what: The calling function name, for error messages.

    Returns:
      `(flutter_sdk_info, tools)` usable with `_compile_flutter_entry_module`.
    """
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info if flutter_toolchain else None
    if collect_native_assets(deps):
        fail("%s: %s takes no native-assets mapping, and its closure has code assets (a build hook's output or a `dart_code_asset`); build the program with `flutter_test` or `flutter_application`, whose entry module embeds the mapping" % (ctx.label, what))
    return flutter_sdk_info, flutter_module_tools(ctx, flutter_sdk_info, own_files, packages, what = what)

def _custom_dep_kernels(ctx, deps, what):
    """Returns the debug `DartKernelInfo` list for a custom kernel's deps, or fails."""
    dep_kernels = [
        dep[FlutterKernelModuleInfo].kernel_info
        for dep in deps
        if FlutterKernelModuleInfo in dep
    ]
    if len(dep_kernels) != len(deps):
        fail("%s: %s needs every dep to carry FlutterKernelModuleInfo (put them under `deps` with `%s` applied); got %d of %d" % (ctx.label, what, "flutter_kernel_module_aspect", len(dep_kernels), len(deps)))
    return dep_kernels

def flutter_modular_test_kernel(ctx, *, test_uri, deps, output, use_base_dill = False):
    """Compiles a custom modular test kernel runnable by `flutter_prebuilt_test`.

    Writes a `flutter_test`-compatible bootstrap importing `test_uri` (plus the
    golden comparator when one is configured), compiles it as an entry module
    against the dependency outlines, and links it — the same protocol the
    built-in `flutter_test` rule's modular path uses. The test runs under the
    prebuilt `flutter_tester` binary with no SDK source needed at runtime.

    By default (`use_base_dill = False`, as in rules_dart's
    `modular_executable_kernel`) the link is complete: every reachable
    dependency module lands in `output`, which runs under
    `flutter_prebuilt_test(dill = ...)` with no `base_dill`. With
    `use_base_dill = True` the kernel delta-links against the `flutter_test`
    base dill instead — a smaller per-test dill sharing one SDK base across
    many tests — and the returned base dill must reach `flutter_prebuilt_test`'s
    `base_dill`, exactly as a `flutter_test` kernel's `test_base_kernel` must:
    the delta is incomplete without it.

    Args:
      ctx: The custom rule context. Must merge `FLUTTER_MODULAR_KERNEL_ATTRS`
        (and `FLUTTER_TEST_BOOTSTRAP_ATTRS` when the caller wants a configurable
        golden comparator) and resolve `FLUTTER_MODULAR_KERNEL_TOOLCHAINS`.
        Pass `ctx.attr.deps` as `deps` so the eligibility check sees the same
        closure the aspect ran over.
      test_uri: The `package:` URI of the test library the bootstrap imports.
      deps: The custom rule's dependency Targets.
      output: The linked test `.dill` File to produce.
      use_base_dill: When True, delta-link against the shared `flutter_test`
        base dill and return it; otherwise link a complete kernel and return
        None.

    Returns:
      The `base_dill` File linked against when `use_base_dill` is True and a
      dependency provides one (`flutter_prebuilt_test`'s `base_dill`), or
      `None` — always `None` with the default complete link.
    """
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_modular_bootstrap.dart")
    staged_comparator = flutter_test_bootstrap_action(ctx, test_uri, bootstrap)
    sources = [
        struct(uri = app_scheme_location(bootstrap).uri, file = bootstrap),
    ]
    own_files = [bootstrap]
    if staged_comparator != None:
        sources.append(struct(uri = app_scheme_location(staged_comparator).uri, file = staged_comparator))
        own_files.append(staged_comparator)
    packages = collect_packages(deps)
    dep_kernels = _custom_dep_kernels(ctx, deps, "flutter_modular_test_kernel")
    flutter_sdk_info, tools = _flutter_modular_custom_tools(
        ctx,
        deps,
        own_files,
        packages,
        "flutter_modular_test_kernel",
    )
    entry = _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        ctx.label.name + ".flutter_entry.kmod",
        flutter_sdk_info.platform_kernel_dill,
    )
    if use_base_dill:
        return _link_flutter_test_entry_module(ctx, dep_kernels, entry, output)
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    kernel_link_action(ctx, dep_closure, entry, output)
    return None

def flutter_modular_app_kernel(ctx, *, main, package_name, srcs, deps, output, use_base_dill = False):
    """Compiles a custom modular app kernel: the app's own sources plus dependency modules.

    Synthesizes the `package:<package_name>/` mapping for `main`/`srcs` (the same
    mapping the built-in app rules build), compiles them as the entry module
    against the dependency outlines, and links everything with the debug
    `platform_kernel_dill` prepended — the same protocol the built-in
    `flutter_kernel_target` modular path uses.

    By default (`use_base_dill = False`, as in rules_dart's
    `modular_executable_kernel`) the link is complete. With `use_base_dill =
    True` the kernel delta-links against a shared base dill when a dependency
    provides one, and the returned base dill must be kept alongside the kernel
    at run time.

    Args:
      ctx: The custom rule context. Must merge `FLUTTER_MODULAR_KERNEL_ATTRS`
        and resolve `FLUTTER_MODULAR_KERNEL_TOOLCHAINS`. Pass `ctx.attr.deps`
        as `deps` so the eligibility check sees the same closure the aspect ran
        over.
      main: The app's entry-point File.
      package_name: The `package:` name `main`/`srcs` are reachable under.
      srcs: The app's own `.dart` Files (may include `main`).
      deps: The custom rule's dependency Targets.
      output: The linked app `.dill` File to produce.
      use_base_dill: When True, delta-link against the shared base dill and
        return it; otherwise link a complete kernel and return None.

    Returns:
      The shared `base_dill` File if `use_base_dill` is True and a dependency
      provides one, or None.
    """
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    packages = synthesize_app_package(
        ctx.label,
        collect_packages(deps),
        package_name,
        lib_root,
        "",
    )
    sources = [
        struct(
            uri = app_main_location(package_name, lib_root, main).uri,
            file = main,
        ),
    ]
    own_files = [main]
    for f in srcs:
        if f == main:
            continue
        sources.append(struct(
            uri = app_main_location(package_name, lib_root, f).uri,
            file = f,
        ))
        own_files.append(f)
    sources = entry_sources_from_library(sources, entry_point_library(main, deps))
    dep_kernels = _custom_dep_kernels(ctx, deps, "flutter_modular_app_kernel")
    flutter_sdk_info, tools = _flutter_modular_custom_tools(
        ctx,
        deps,
        own_files,
        packages,
        "flutter_modular_app_kernel",
    )
    entry = _compile_flutter_entry_module(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        ctx.label.name + ".flutter_entry.kmod",
        flutter_sdk_info.platform_kernel_dill,
    )
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    base_dill, base_keys, base_kmods = _find_dep_base_dill(dep_kernels) if use_base_dill else (None, None, depset())
    dep_closure = _without_base_kmods(dep_closure, base_dill, base_keys, base_kmods)
    kernel_link_action(
        ctx,
        dep_closure,
        entry,
        output,
        platform_dill = flutter_sdk_info.platform_kernel_dill,
        base_keys = base_keys,
    )
    return base_dill
