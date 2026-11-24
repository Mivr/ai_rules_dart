"""Flutter web application build.

Produces a deployable web directory containing:
- main.dart.wasm + main.dart.mjs + main.dart.js (WASM mode with JS fallback)
  or main.dart.js (JS-only mode)
- flutter.js (Flutter engine bootstrapper from web SDK)
- canvaskit/ or skwasm/ (renderer engine artifacts)
- flutter_assets/ (AssetManifest.bin.json for web)
- index.html
- flutter_bootstrap.js
- flutter_service_worker.js (written by stock code)

When compiler="dart2wasm", both WASM and JS outputs are produced. The
bootstrap JS lists both builds so the Flutter engine tries WASM first and
falls back to JS on browsers without WASM support (matching `flutter build web`).

Both dart2wasm and dart2js take .dart source directly (not kernel .dill),
so we skip the frontend_server kernel compilation step used by desktop/mobile.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "MODULAR_KERNEL_TOOLCHAINS", "collect_packages", "collect_transitive_srcs", "colocate_packages", "dart_analyzable_info_with_package", "dart_package_identity", "derive_lib_root", "generate_package_config")
load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_scheme_rel_path",
    "compile_kernel_package_config",
    "package_lib_prefix",
    "resolve_wrapper_main_import",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "FLUTTER_APPLICATION_ATTRS",
    "FLUTTER_DEPS_DOC",
    "KERNEL_COMPILE_ATTRS",
    "merge_dart_defines",
    "resolve_exec_dart_vm",
    "resolve_flutter_sdk_info",
)
load("//flutter/private:flutter_info.bzl", "collect_flutter_plugin_deps")
load("//flutter/private:flutter_kernel_module.bzl", "MODULAR_KERNEL_ATTRS", "flutter_kernel_module_aspect")
load("//flutter/private:flutter_bundle.bzl", "BUNDLE_ATTRS", write_web_bundle = "flutter_web_bundle")
load(
    "//flutter/private:flutter_web_compile.bzl",
    "flutter_dart2js_action",
    "flutter_dart2js_cfe_action",
    "flutter_dart2wasm_action",
    "make_dart2js_cfe_request",
    "make_dart2js_request",
    "make_dart2wasm_request",
    "web_build_mode",
    "web_compile_tool_inputs",
    "web_mode_defines",
    "web_renderer_defines",
    "web_sdk_files_for_dart2js",
)
load("//flutter/private:layering_check.bzl", "LAYERING_CHECK_ASPECT", "LAYERING_CHECK_ATTRS", "layering_output_groups", "layering_toolchains")
load("//flutter/private:plugin_registrant.bzl", "generate_dart_plugin_registrant", "make_registrant_content")
load(
    "//flutter/private:validation.bzl",
    "validate_base_href",
    "validate_static_assets_url",
    "validate_web_compiler_renderer",
    "validate_web_wasm_only_attrs",
    "web_renderer",
)
load(
    "//flutter/private:web_stubs.bzl",
    "make_web_plugins_stub_content",
    "make_web_ui_web_stub_content",
    "make_web_wrapper_main_content",
)

visibility(["//flutter/..."])

def _wasm_build(renderer):
    return {
        "compileTarget": "dart2wasm",
        "renderer": renderer,
        "mainWasmPath": "main.dart.wasm",
        "jsSupportRuntimePath": "main.dart.mjs",
    }

_JS_BUILD = {
    "compileTarget": "dart2js",
    "renderer": "canvaskit",
    "mainJsPath": "main.dart.js",
}

def _web_validate_attrs(ctx):
    """Validates the web bundle attrs and returns the resolved renderer."""
    renderer = web_renderer(ctx.attr.compiler, ctx.attr.renderer)
    validate_web_compiler_renderer(ctx.attr.compiler, renderer)
    validate_web_wasm_only_attrs(
        ctx.attr.compiler,
        [
            n
            for n, set_away in [
                ("minify_wasm", ctx.attr.minify_wasm != "auto"),
                ("optimization_level_wasm", ctx.attr.optimization_level_wasm != "auto"),
                ("strip_wasm", not ctx.attr.strip_wasm),
            ]
            if set_away
        ],
        ctx.label,
    )
    validate_base_href(ctx.attr.base_href, ctx.label)
    validate_static_assets_url(ctx.attr.static_assets_url, ctx.label)
    return renderer

def _web_collect_sources(ctx):
    """Collects sources, packages and the app's own library root.

    The app's own library root is the single answer to "what is
    `package:<self>/…` rooted at" for this target. Everything downstream
    that asks the question (package synthesis, the wrapper's import, the
    dev-config entrypoint, the analyzer's source split) takes it from here
    rather than deriving its own, which is how the compile path and the
    analysis path came to disagree: analysis derived it, compilation
    assumed `""`, and a nested app's `package:` URIs silently resolved
    against the workspace root instead of its own package.
    """
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list()
    packages = collect_packages(ctx.attr.deps)
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Register the app's own package (when declared) so `package:<name>/main.dart`
    # is a valid URI for the wrapper to import. Include `main` in the colocate
    # inputs so it ends up inside the same assembled directory as its lib/
    # siblings — that's what lets `main.dart`'s relative imports resolve to
    # the assembled (codegen-co-located) copies of its package siblings.
    packages = synthesize_app_package(ctx.label, packages, ctx.attr.package_name, lib_root, ctx.attr.language_version)
    return struct(all_srcs = all_srcs, packages = packages, lib_root = lib_root)

def _web_inject_registrant(ctx, packages, all_srcs):
    """Generates the web plugin registrant, stubbing flutter_web_plugins.

    Returns:
      A `(plugins, registrant, packages, all_srcs)` tuple.
    """
    plugins = collect_flutter_plugin_deps(ctx.attr.deps).all_plugins
    registrant = generate_dart_plugin_registrant(ctx, plugins, target_platform = "web")

    has_real_web_plugins = any([p.package_name == "flutter_web_plugins" for p in packages])
    if registrant != None and not has_real_web_plugins:
        has_flutter_services = any([
            p.package_name == "flutter" and any([
                app_scheme_rel_path(f) == ((p.lib_root + "/lib/services.dart") if p.lib_root else "lib/services.dart")
                for f in all_srcs
            ])
            for p in packages
        ])
        web_plugins_stub = ctx.actions.declare_file(ctx.label.name + "_flutter_web_plugins_stub/lib/flutter_web_plugins.dart")
        ctx.actions.write(
            web_plugins_stub,
            make_web_plugins_stub_content(has_flutter_services = has_flutter_services),
        )
        stub_rel = app_scheme_rel_path(web_plugins_stub)
        stub_lib_root = stub_rel[:-len("/lib/flutter_web_plugins.dart")]
        stub_pkg = struct(
            package_name = "flutter_web_plugins",
            lib_root = stub_lib_root,
            language_version = "",
        )
        packages = packages + [stub_pkg]
        all_srcs = all_srcs + [web_plugins_stub]
    return plugins, registrant, packages, all_srcs

def _web_build_package_config(ctx, packages, all_srcs, is_debug):
    """Writes the BUILD package_config the debugger reads URIs through (debug only).

    Returns:
      A `(build_package_config, build_package_dirs)` tuple, both empty when
      not debugging.
    """
    if not is_debug:
        return None, []
    dbg_packages, dbg_srcs = colocate_packages(ctx, packages, all_srcs + [ctx.file.main])
    build_package_config = ctx.actions.declare_file(ctx.label.name + "_build_package_config.json")
    ctx.actions.write(build_package_config, generate_package_config(dbg_packages, dbg_srcs, build_package_config))
    return build_package_config, [f for f in dbg_srcs if f.is_directory]

def _web_write_wrapper(ctx, packages, all_srcs, lib_root, plugins, registrant):
    """Writes the engine-bootstrap wrapper main and returns the entrypoint.

    Flutter web ALWAYS needs this wrapper to properly initialize the engine
    (create the implicit view, set up the platform dispatcher, etc.)
    before calling the user's main(). This matches `flutter build web`.

    Returns:
      A `(config_file, all_srcs, entrypoint, entrypoint_salt)` tuple.
    """
    pc = compile_kernel_package_config(
        ctx,
        packages,
        all_srcs + [ctx.file.main],
        roots = {ctx.attr.package_name: True} if ctx.attr.package_name else None,
    )
    config_file = pc.config_file
    all_srcs = pc.srcs

    ui_web_stub = ctx.actions.declare_file(ctx.label.name + "_ui_web_stub.dart")
    ctx.actions.write(ui_web_stub, make_web_ui_web_stub_content())

    wrapper = ctx.actions.declare_file(ctx.label.name + "_wrapper_main.dart")
    wrapper_rel = app_scheme_rel_path(wrapper)
    wrapper_depth = len(wrapper_rel.split("/")) - 1

    # Import the user's main via its `package:` URI when available, or via a
    # relative path within the staged multi-root tree when `main` is outside `lib/`.
    wrapper_content = make_web_wrapper_main_content(
        resolve_wrapper_main_import(
            ctx.attr.package_name,
            lib_root,
            ctx.file.main.short_path,
            app_scheme_rel_path(ctx.file.main),
            wrapper_depth,
        ),
        registrant.basename if registrant else None,
        ui_web_stub_import = ui_web_stub.basename,
    )
    ctx.actions.write(wrapper, wrapper_content)
    entrypoint = wrapper
    all_srcs = all_srcs + [ctx.file.main, wrapper, ui_web_stub]
    if registrant:
        all_srcs = all_srcs + [registrant]
    registrant_key = make_registrant_content(plugins, target_platform = "web")
    return struct(
        config_file = config_file,
        all_srcs = all_srcs,
        entrypoint = entrypoint,
        entrypoint_salt = wrapper_content + "\n" + registrant_key,
    )

def _wasm_options(ctx):
    """The dart2wasm tuning this target asked for, as a `wasm_options` struct."""
    return struct(
        optimization_level = ctx.attr.optimization_level_wasm,
        minify = ctx.attr.minify_wasm,
        strip_wasm = ctx.attr.strip_wasm,
    )

def _js_options(ctx):
    """The dart2js tuning this target asked for, as a `js_options` struct."""
    return struct(
        optimization_level = ctx.attr.optimization_level_js,
        minify = ctx.attr.minify_js,
        native_null_assertions = ctx.attr.native_null_assertions,
        frequency_based_minification = ctx.attr.frequency_based_minification,
        dump_info = ctx.attr.dump_info,
        source_maps = ctx.attr.source_maps,
    )

def _web_compile_wasm(ctx, compile):
    """Compiles the primary dart2wasm output plus the dart2js fallback.

    Outputs are declared under a subdirectory with their canonical bundle
    names: dart2wasm embeds a sourceMappingURL referencing `<output>.map`
    by name, so the compiled name and the shipped name must be the same
    for the browser to find the map.

    Returns:
      A `(builds, compile_outputs, compile_copies, dart2js_dirs)` tuple.
    """
    output_wasm = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm")
    output_mjs = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.mjs")
    output_wasm_map = None
    if ctx.attr.source_maps:
        output_wasm_map = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm.map")
    flutter_dart2wasm_action(ctx, make_dart2wasm_request(
        compile,
        _wasm_options(ctx),
        output_wasm,
        output_mjs,
        output_wasm_map,
    ))

    # Fallback: dart2js (always canvaskit renderer) — tree artifact for deferred loading
    output_js_fallback_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js_fallback")
    flutter_dart2js_action(ctx, make_dart2js_request(
        compile,
        _js_options(ctx),
        "canvaskit",
        output_js_fallback_dir,
    ))
    compile_outputs = [output_wasm, output_mjs]
    compile_copies = [
        {"src": output_wasm.path, "dst": "main.dart.wasm"},
        {"src": output_mjs.path, "dst": "main.dart.mjs"},
    ]
    if output_wasm_map != None:
        compile_outputs.append(output_wasm_map)
        compile_copies.append({"src": output_wasm_map.path, "dst": "main.dart.wasm.map"})
    return [_wasm_build(compile.renderer), _JS_BUILD], compile_outputs, compile_copies, [output_js_fallback_dir]

def _web_compile_js_only(ctx, compile):
    """Compiles the JS-only output (tree artifact for deferred loading).

    Returns:
      A `(builds, compile_outputs, compile_copies, dart2js_dirs)` tuple.
    """
    output_js_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js")
    flutter_dart2js_action(ctx, make_dart2js_request(
        compile,
        _js_options(ctx),
        compile.renderer,
        output_js_dir,
    ))
    return [_JS_BUILD], [], [], [output_js_dir]

def _web_compile_program(ctx, compile):
    """Runs Step 2: compile to WASM (with JS fallback) or JS only.

    `web_template` is compiled against `@rules_flutter//flutter:toolchain_type`
    (`flutter_sdk_kernel_binary`), and its `compile wasm` / `compile js`
    subcommands resolve `dartaotruntime`, `dart2wasm_product.snapshot`,
    `wasm-opt`, and `dart2js_aot.dart.snapshot` relative to the running `dart`
    executable's directory (`File(Platform.resolvedExecutable).parent.path`).
    Pair it with `compile.dart` and `compile.flutter_sdk_info.dart_vm_files`
    so the compile actions always execute within the Flutter engine's bundled
    `dart-sdk/`.

    Returns:
      A struct with `builds`, `compile_outputs`, `compile_copies` and
      `dart2js_dirs`.
    """
    if ctx.attr.compiler == "dart2wasm":
        builds, compile_outputs, compile_copies, dart2js_dirs = _web_compile_wasm(ctx, compile)
    else:
        builds, compile_outputs, compile_copies, dart2js_dirs = _web_compile_js_only(ctx, compile)
    return struct(
        builds = builds,
        compile_outputs = compile_outputs,
        compile_copies = compile_copies,
        dart2js_dirs = dart2js_dirs,
    )

def _web_tree_shake_kernels(ctx, compile, shipped_renderers):
    """Compiles one icon tree-shake kernel per shipped renderer.

    The icon tree-shake kernel must see the web program the dart2js and
    dart2wasm compilers build: conditional imports guarded by
    `dart.library.js_interop`/`dart.library.html` resolve from the
    platform's `dart.library.*` environment. Compiling with
    `--target flutter` against the VM `platform_strong.dill` resolves
    them to the VM branch while the web compilers take the web branch,
    so the tree-shaken font lacks glyphs the shipped bundle draws.
    Compile here with `dart compile js --cfe-only`, which is what
    upstream runs to produce the `app.dill` const_finder reads: the
    kernel resolves web conditionals the way the shipped compilers do,
    and `dart:js_interop`/`dart:ui_web` type-check against the real web
    libraries instead of VM stubs. One dill per shipped renderer, with
    that renderer's defines, merged downstream by const_finder. The
    compile takes the same sources as the shipped programs, so editing
    a web-branch file re-runs it instead of hitting a stale disk-cache
    entry.

    Returns:
      A `(kernel_dills, tree_shake_key_parts)` tuple.
    """
    kernel_dills = []
    tree_shake_key_parts = []
    for idx, r in enumerate(shipped_renderers):
        dill_suffix = "_icon_tree_shaking.dill" if idx == 0 else ("_icon_tree_shaking_%s.dill" % r)
        dill_out = ctx.actions.declare_file(ctx.label.name + dill_suffix)
        deps_out = ctx.actions.declare_file(ctx.label.name + dill_suffix + ".deps")
        renderer_defines = web_renderer_defines(r)

        r_defines = list(compile.defines) + web_mode_defines(compile.mode) + renderer_defines
        r_salt = compile.stage_salt + "\n" + "\n".join(r_defines) + "\n" + "\n".join(ctx.attr.enable_experiments)
        flutter_dart2js_cfe_action(ctx, make_dart2js_cfe_request(
            compile,
            r,
            r_salt,
            dill_out,
            deps_out,
        ))
        kernel_dills.append(dill_out)
        tree_shake_key_parts.append(r + ":" + r_salt)
    return kernel_dills, tree_shake_key_parts

def _web_native_module_files(ctx):
    """Lists the declared native modules' library files."""
    return [
        f
        for dep in ctx.attr.native_modules
        for f in dep[FlutterNativeLibraryInfo].libraries.to_list()
    ]

def _web_write_bundle(ctx, flutter_sdk_info, program, build):
    """Writes the web directory: the asset tool's output, plus the declared native modules.

    Args:
        ctx: The rule context.
        flutter_sdk_info: The resolved Flutter SDK.
        program: The `_web_compile_program` struct (`compile_outputs`,
            `dart2js_dirs`).
        build: `struct(mode, app_dill, renderer, dev_bootstrap)`.

    Returns:
      An `(output_dir, output_groups)` tuple. The dump-info JSON is an
      analysis artifact, not something a deployment needs, so it rides an
      output group: `bazel build //your:app --output_groups=dump_info`.
    """
    native_module_files = _web_native_module_files(ctx)
    extra = bool(native_module_files) or ctx.attr.dump_info
    output_dir = ctx.actions.declare_directory(ctx.label.name + "_web")
    tool_dir = ctx.actions.declare_directory(ctx.label.name + "_web_bundle") if extra else output_dir
    write_web_bundle(
        ctx,
        flutter_sdk_info,
        tool_dir,
        mode = build.mode,
        web_build = program.compile_outputs + program.dart2js_dirs,
        # lint-allow: depset-flatten only flutter.js and the renderer are picked out of the web SDK's files by path, which Args cannot do for inputs
        web_sdk_files = ctx.attr._web_sdk[DefaultInfo].files.to_list() if ctx.attr._web_sdk else [],
        app_dill = build.app_dill,
        base_href = ctx.attr.base_href if ctx.attr.base_href != "/" else None,
        static_assets_url = ctx.attr.static_assets_url if ctx.attr.static_assets_url != "/" else None,
        pwa_strategy = None if ctx.attr.pwa else "none",
        renderer = build.renderer,
        wasm = ctx.attr.compiler == "dart2wasm",
        source_maps = ctx.attr.source_maps,
        web_defines = ctx.attr.web_defines,
        use_local_canvaskit = ctx.attr.use_local_canvaskit,
        dev_bootstrap = build.dev_bootstrap,
    )
    dump_info_file = None
    if extra:
        # The declared native modules are served at their path under the
        # package's `web/` directory, beside what the tool wrote. dart2js
        # writes the dump-info JSON beside its output, which only the
        # compiled files the tool names leave; it is lifted out here.
        copies = []
        for f in native_module_files:
            rel = f.short_path
            if rel.startswith(ctx.label.package + "/"):
                rel = rel[len(ctx.label.package) + 1:]
            if rel.startswith("web/"):
                rel = rel[len("web/"):]
            copies.append({"src": f.path, "dst": rel})
        extracts = []
        if ctx.attr.dump_info:
            dump_info_file = ctx.actions.declare_file(ctx.label.name + "_dart2js_info.json")
            extracts.append({
                "src": program.dart2js_dirs[0].path + "/main.dart.js.info.json",
                "dst": dump_info_file.path,
            })
        config = ctx.actions.declare_file(ctx.label.name + "_web_bundle_config.json")
        ctx.actions.write(config, json.encode({
            "output_dir": output_dir.path,
            "copies": copies,
            "copy_dirs": [{"src": tool_dir.path, "dst": "."}],
            "extracts": extracts,
        }))
        exec_dart, dart_vm_files = resolve_exec_dart_vm(ctx, flutter_sdk_info)
        ctx.actions.run(
            executable = exec_dart,
            arguments = [ctx.executable._bundle_tool.path, "--config", config.path],
            inputs = depset(
                direct = [tool_dir, config, ctx.executable._bundle_tool] + native_module_files + program.dart2js_dirs[:1],
                transitive = [dart_vm_files],
            ),
            outputs = [output_dir] + ([dump_info_file] if dump_info_file else []),
            mnemonic = "FlutterWebNativeModules",
            progress_message = "Adding the native modules of %s" % ctx.label,
            toolchain = "@rules_dart//dart:exec_tools_toolchain_type",
        )
    output_groups = layering_output_groups(ctx, "dump_info", [dump_info_file] if dump_info_file else [])
    return output_dir, output_groups

def _web_analyzable_info(ctx, lib_root):
    """Provides the Dart analysis closure for the web app.

    What lets rules_dart's analysis check a web app. Until this existed the rule handed out no Dart provider at all, so every web
    example had to declare its sources a second time as a `flutter_library`
    purely for the analyzer to stage — and anything the bundle reached that
    the shadow library missed was analyzed by nothing. `dart_web_application`
    upstream already provides the equivalent; this closes the asymmetry.

    Deliberately not offered as a `DartInfo`: `deps` requires one, and an
    application bundle is not a dependency.

    `dart_analyzable_info_with_package`, not `dart_analyzable_info`: this rule
    declares a mandatory `package_name` and its `srcs` are that package's
    `lib/` files, which import each other by `package:<self>/…`. The
    package-less closure the other constructor nests gives the analyzer no
    record to resolve those against and reports every one `uri_does_not_exist`.

    The source split is decided by path, not by attr. A `flutter_test`'s
    `main` is always a `test/` entrypoint outside any `lib/`, so it is always
    package-less; a web app's is usually `lib/main.dart` — inside the package,
    reachable as `package:<self>/main.dart` — and sometimes not, as when it
    sits at the package root beside `web/`. Which one holds is decidable from
    the file's own path, so neither case has to be assumed.
    """
    main_in_package = ctx.file.main.short_path.startswith(package_lib_prefix(lib_root))

    # `_sky_engine` joins the analyzer's closure and nothing else. The web
    # compilers get `dart:ui` from the web SDK; the analyzer resolves it only by
    # following the package_config to `package:sky_engine`'s `lib/_embedder.yaml`,
    # so analysis genuinely needs an entry compilation does not.
    return dart_analyzable_info_with_package(
        label = ctx.label,
        package = dart_package_identity(
            package_name = ctx.attr.package_name,
            lib_root = lib_root,
            # As on the compile path above: the analyzer and the compiler have to
            # agree on the version, or the attr closes the divergence in only one.
            language_version = ctx.attr.language_version,
        ),
        deps = ctx.attr.deps + [ctx.attr._sky_engine],
        srcs = [] if main_in_package else [ctx.file.main],
        package_srcs = ctx.files.srcs + ([ctx.file.main] if main_in_package else []),
    )

def _web_stage_ddc_files(ctx, dev_bootstrap_js):
    """Stages the DDC dev-loop files as top-level debug outputs.

    The dev tool discovers these in the build output list (same pattern as native).
    """
    ddc_files = []

    # DDC outline dill (--platform flag for frontend_server).
    ddc_outline_dill = ctx.actions.declare_file(ctx.label.name + "_ddc_outline.dill")
    ctx.actions.symlink(output = ddc_outline_dill, target_file = ctx.file._ddc_outline_dill)
    ddc_files.append(ddc_outline_dill)

    # DDC libraries spec (--libraries-spec flag).
    ddc_libraries_json = ctx.actions.declare_file(ctx.label.name + "_ddc_libraries.json")
    ctx.actions.symlink(output = ddc_libraries_json, target_file = ctx.file._ddc_libraries_spec)
    ddc_files.append(ddc_libraries_json)

    # DDC-compiled Dart SDK JS.
    ddc_dart_sdk_js = ctx.actions.declare_file(ctx.label.name + "_ddc_dart_sdk.js")
    ctx.actions.symlink(output = ddc_dart_sdk_js, target_file = ctx.file._ddc_dart_sdk_js)
    ddc_files.append(ddc_dart_sdk_js)

    # DDC module loader JS.
    ddc_module_loader_js = ctx.actions.declare_file(ctx.label.name + "_ddc_module_loader.js")
    ctx.actions.symlink(output = ddc_module_loader_js, target_file = ctx.file._ddc_module_loader_js)
    ddc_files.append(ddc_module_loader_js)

    # DDC stack trace mapper JS.
    ddc_stack_trace_mapper_js = ctx.actions.declare_file(ctx.label.name + "_ddc_stack_trace_mapper.js")
    ctx.actions.symlink(output = ddc_stack_trace_mapper_js, target_file = ctx.file._ddc_stack_trace_mapper_js)
    ddc_files.append(ddc_stack_trace_mapper_js)

    # The dev loop's bootstrap, declared a top-level debug output so it is
    # materialized locally for the dev server to read and serve.
    ddc_files.append(dev_bootstrap_js)
    return ddc_files

def _web_debug_result(ctx, debug, output_dir, output_groups, analyzable_info):
    """Assembles the debug-mode providers: the DDC files and the package configs.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        debug: The debug struct (`registrant`, `dev_bootstrap_js`,
            `build_package_config`, `build_package_dirs`, `config_file`).
        output_dir: The bundled web directory.
        output_groups: The bundler's output groups.
        analyzable_info: The Dart analysis closure.
    """
    ddc_files = _web_stage_ddc_files(ctx, debug.dev_bootstrap_js)
    if debug.build_package_config:
        ddc_files.append(debug.build_package_config)
    ddc_files.extend(debug.build_package_dirs)

    # Include package_config in debug outputs.
    ddc_files.append(debug.config_file)

    # The web plugin registrant is otherwise only an input to the
    # dart2wasm/dart2js compile actions; declaring it a top-level debug
    # output guarantees it is materialized locally for the dev tool to
    # stage next to its synthetic entrypoint.
    if debug.registrant:
        ddc_files.append(debug.registrant)

    return [DefaultInfo(files = depset([output_dir] + ddc_files)), output_groups, analyzable_info]

def _flutter_web_bundle_impl(ctx):
    renderer = _web_validate_attrs(ctx)

    flutter_sdk_info = resolve_flutter_sdk_info(ctx)

    # Merged once for all compile actions below (dart2wasm, dart2js, icon
    # tree-shake kernel).
    user_defines = merge_dart_defines(ctx)

    # The build mode drives the mode defines of every compile action below,
    # the same way the native kernel path switches on COMPILATION_MODE.
    mode = web_build_mode(ctx)
    is_debug = mode == "debug"

    # Step 1: Collect sources, generate package config, handle plugin registrant.
    # dart compile wasm/js take .dart source directly (not kernel .dill).
    sources = _web_collect_sources(ctx)
    all_srcs = sources.all_srcs
    packages = sources.packages
    lib_root = sources.lib_root

    # Generate web wrapper main with ui_web.bootstrapEngine().
    plugins, registrant, packages, all_srcs = _web_inject_registrant(ctx, packages, all_srcs)

    build_package_config, build_package_dirs = _web_build_package_config(ctx, packages, all_srcs, is_debug)

    wrapped = _web_write_wrapper(ctx, packages, all_srcs, lib_root, plugins, registrant)
    config_file = wrapped.config_file
    all_srcs = wrapped.all_srcs

    # Step 2: Compile to WASM (with JS fallback) or JS only.
    # dart2js outputs to a tree artifact (directory) to support deferred loading:
    # dart2js may produce main.dart.js + *.part.js files for deferred imports.
    compile = struct(
        dart = flutter_sdk_info.dart,
        flutter_sdk_info = flutter_sdk_info,
        dart2wasm_platform_dill = ctx.file._dart2wasm_platform_dill,
        dart2js_platform_dill = ctx.file._dart2js_platform_dill,
        web_sdk_files = web_sdk_files_for_dart2js(ctx.attr._web_sdk),
        main_dart = wrapped.entrypoint,
        srcs = all_srcs,
        package_config = config_file,
        mode = mode,
        defines = user_defines,
        renderer = renderer,
        stage_salt = wrapped.entrypoint_salt,
        web_compile_tool = ctx.executable._web_template_tool,
        web_compile_inputs = web_compile_tool_inputs(flutter_sdk_info.dart_vm_files),
        web_guard_tool = ctx.executable._web_guard_tool,
        enable_experiments = ctx.attr.enable_experiments,
    )
    program = _web_compile_program(ctx, compile)

    # Step 3: the web directory, written by the Flutter tool's own code
    # around the compiled program, as `flutter build web` writes it: the
    # assets the pubspec names, the project's `web/` files, the templated
    # `index.html` and `flutter_bootstrap.js`, `flutter.js`, the renderer and
    # the service worker. In release and profile the icon fonts are shaken
    # against a kernel of the program, as the tool compiles one for dart2js.
    app_dill = None
    if ctx.attr.tree_shake_icons and not is_debug:
        app_dill = _web_tree_shake_kernels(ctx, compile, [compile.renderer])[0][0]
    dev_bootstrap_js = ctx.actions.declare_file(ctx.label.name + "_dev_flutter_bootstrap.js") if is_debug else None
    output_dir, output_groups = _web_write_bundle(ctx, flutter_sdk_info, program, struct(
        mode = mode,
        app_dill = app_dill,
        renderer = renderer,
        dev_bootstrap = dev_bootstrap_js,
    ))

    analyzable_info = _web_analyzable_info(ctx, lib_root)

    # In debug mode, output DDC dev files alongside the web directory.
    # The dev tool discovers these in the build output list (same pattern as native).
    if is_debug:
        debug = struct(
            registrant = registrant,
            dev_bootstrap_js = dev_bootstrap_js,
            build_package_config = build_package_config,
            build_package_dirs = build_package_dirs,
            config_file = config_file,
        )
        return _web_debug_result(ctx, debug, output_dir, output_groups, analyzable_info)

    return [DefaultInfo(files = depset([output_dir])), output_groups, analyzable_info]

# The web-only additions to the shared compile bundle. Web builds don't use
# native_deps, obfuscate, split_debug_info, extra_gen_snapshot_options, or
# min_os_version, so those stay unnamed.
#
# `profile` is deliberately NOT lifted from there either, even though the web
# rule has one: the shared attr documents itself in gen_snapshot terms ("AOT
# like release, but unstripped"), and a web build has no AOT step to describe.
# It is redeclared below with the meaning it actually has here.
# The compile inputs arrive as a bundle for the reason `KERNEL_COMPILE_ATTRS`
# documents. This rule does not call `flutter_compile_kernel`, so omitting one
# would not crash it — it would go quiet: the bundle is also what
# `synthesize_app_package` and `dart_analyzable_info_with_package` read, and a
# web build that drops one of those compiles the app against something other
# than what it declared. That is exactly how `language_version` was lost here.
_WEB_RELEVANT_KEYS = ["tree_shake_icons", "track_widget_creation"]
_WEB_APPLICATION_ATTRS = KERNEL_COMPILE_ATTRS | {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in _WEB_RELEVANT_KEYS
}
_WEB_APPLICATION_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_kernel_module_aspect, LAYERING_CHECK_ASPECT],
)
_WEB_APPLICATION_ATTRS.update(MODULAR_KERNEL_ATTRS | LAYERING_CHECK_ATTRS | BUNDLE_ATTRS)

# Reaches the analysis closure only — see `analyzable_info` in the impl. No
# BUILD file names it and no compile action's inputs change.
_WEB_APPLICATION_ATTRS["_sky_engine"] = attr.label(
    doc = "Sky engine library in the analyzer closure so `dart:ui` resolves; the compilers use the web SDK instead.",
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

flutter_web_bundle = rule(
    implementation = _flutter_web_bundle_impl,
    attrs = dict(_WEB_APPLICATION_ATTRS, **{
        "compiler": attr.string(
            doc = "Web compiler: 'dart2wasm' (default) or 'dart2js'.",
            default = "dart2wasm",
            values = ["dart2wasm", "dart2js"],
        ),
        "renderer": attr.string(
            doc = "Web renderer: 'skwasm' or 'canvaskit'. Unset, it follows " +
                  "`compiler`: skwasm for dart2wasm, canvaskit for dart2js.",
            default = "",
            values = ["", "skwasm", "canvaskit"],
        ),
        "base_href": attr.string(
            doc = "Base URL path for the app (default: '/'), as `flutter build web " +
                  "--base-href` takes it: substituted for `$FLUTTER_BASE_HREF` in " +
                  "`web/index.html`. Must start and end with '/'.",
            default = "/",
        ),
        "static_assets_url": attr.string(
            doc = "Value substituted for Flutter's `$FLUTTER_STATIC_ASSETS_URL` placeholder " +
                  "in index.html, matching `flutter build web --static-assets-url`. Must end " +
                  "with '/'. Defaults to '/', as upstream does; set it to a CDN origin to " +
                  "serve static assets from elsewhere.",
            default = "/",
        ),
        "web_defines": attr.string_dict(
            doc = "Template variables substituted for `{{NAME}}` placeholders in " +
                  "`web/index.html` and `web/flutter_bootstrap.js`, as " +
                  "`flutter build web --web-define` substitutes them. A placeholder with no " +
                  "value is warned about and left in place, as the Flutter tool does.",
        ),
        "optimization_level_js": attr.string(
            doc = "The `-O` level the dart2js compile runs at, matching " +
                  "`flutter build web --optimization-level`. \"auto\" (default) takes " +
                  "upstream's per-mode default — 1 in debug, 4 in profile and release — and " +
                  "an explicit level holds across every build mode. One attr per compiler " +
                  "because upstream's own defaults disagree: dart2wasm stops at 2 in release " +
                  "while dart2js goes to 4, so a single shared level could not state both. " +
                  "Applies in both `compiler` modes — a dart2wasm target also builds the " +
                  "dart2js fallback. Note upstream's single `--optimization-level` sets " +
                  "BOTH compilers, and its per-compiler default only applies when the flag " +
                  "is absent; here each compiler is asked separately, so setting this one " +
                  "leaves the WASM compile on its own default. " +
                  "\"0\" is accepted but comes with upstream's warning that " +
                  "dart2js level 0 is not well supported, which is why debug defaults to 1. " +
                  "From 2 up the level minifies on its own; `minify_js` is stated to the " +
                  "compiler regardless, so it decides minification here and this does not.",
            default = "auto",
            values = ["auto", "0", "1", "2", "3", "4"],
        ),
        "optimization_level_wasm": attr.string(
            doc = "The `-O` level the dart2wasm compile runs at, matching " +
                  "`flutter build web --optimization-level`. \"auto\" (default) takes " +
                  "upstream's per-mode default — 0 in debug, 2 in profile and release — and " +
                  "an explicit level holds across every build mode. Upstream stops at 2 for " +
                  "release on purpose: it is the highest level using only sound " +
                  "optimizations, and their web benchmarks put the rest at marginal. Debug " +
                  "takes 0 because that is the trade a debug build exists to make — on this " +
                  "repo's own web example it halves the compile at twice the module size. " +
                  "Only the WASM compile takes it, so setting it under " +
                  "`compiler = \"dart2js\"` is refused rather than ignored, and setting it " +
                  "leaves the dart2js fallback on its own default — upstream's single " +
                  "`--optimization-level` reaches both compilers, this attr reaches one.",
            default = "auto",
            values = ["auto", "0", "1", "2", "3", "4"],
        ),
        "minify_js": attr.string(
            doc = "Whether the dart2js output minifies names, matching " +
                  "`flutter build web --minify-js`. \"auto\" (default) minifies in release " +
                  "and not in debug or profile, as upstream does; \"true\" and \"false\" state " +
                  "it outright and hold across every build mode. Applies in both `compiler` " +
                  "modes — a dart2wasm target also builds the dart2js fallback. Always passed " +
                  "to the compiler explicitly rather than left to be inferred from the " +
                  "optimization level, so the two stay independent — `-O2` and above minify " +
                  "on their own, which would otherwise minify a debug build.",
            default = "auto",
            values = ["auto", "true", "false"],
        ),
        "native_null_assertions": attr.bool(
            doc = "Whether the dart2js output checks, at runtime, that values arriving from " +
                  "JS interop and the web libraries actually match the nullability they were " +
                  "declared with. True by default, as `flutter build web` defaults it: a JS " +
                  "value that is null where Dart was promised non-null otherwise surfaces " +
                  "much later, as a failure in code that did nothing wrong. Set False to drop " +
                  "the checks once an interop surface is trusted. Applies to the dart2js " +
                  "compile in both `compiler` modes — a dart2wasm target also builds the JS " +
                  "fallback.",
            default = True,
        ),
        "dump_info": attr.bool(
            doc = "If True, dart2js writes a JSON description of what ended up in the output " +
                  "and why, for `package:dart2js_info` and the size tooling built on it — " +
                  "matching `flutter build web --dump-info`. Note the flag `flutter build " +
                  "web` passes through today is `--stage=dump-info-all`; the bare " +
                  "`--dump-info` it is named after now writes a binary `.info.data` instead. " +
                  "The file is a build diagnostic, not part of the app, so unlike upstream " +
                  "it is kept OUT of the bundle and produced as a named output instead: " +
                  "`bazel build //your:app --output_groups=dump_info` writes " +
                  "`<name>_dart2js_info.json`. It can be megabytes and describes your whole " +
                  "program, so shipping it to visitors is not something to do by default. " +
                  "Note which compilation it describes: only dart2js produces a report, so " +
                  "under the default `compiler = \"dart2wasm\"` it describes the JS " +
                  "*fallback* — not the WASM build most visitors run.",
            default = False,
        ),
        "enable_experiments": attr.string_list(
            doc = "Dart language experiments to enable, by name and without the flag " +
                  "(e.g. [\"records\"]), matching `flutter build web --enable-experiment`. " +
                  "Reaches both web compilers and the kernel compile the icon tree-shaker " +
                  "reads, since an experiment changes how the source parses and every step " +
                  "that parses it has to agree.",
        ),
        "frequency_based_minification": attr.bool(
            doc = "Whether dart2js's minifier may choose short names by how often an " +
                  "identifier occurs. True (default) produces the smallest output. False " +
                  "passes `--no-frequency-based-minification`, matching " +
                  "`flutter build web --no-frequency-based-minification`: names then depend " +
                  "only on the program, so an unrelated edit stops renaming half the output " +
                  "and two builds can be diffed to see what actually changed. Costs some " +
                  "output size. Named for what it enables, so the default reads as the " +
                  "behaviour rather than as a double negative. Only minified output has " +
                  "names to choose, so this does nothing alongside `minify_js = \"false\"`.",
            default = True,
        ),
        "strip_wasm": attr.bool(
            doc = "Whether a release build strips static symbol names from the WASM output, " +
                  "matching `flutter build web --strip-wasm`. Debug and profile builds never " +
                  "strip whatever this says — upstream gates it on release the same way, and " +
                  "those two modes exist to be read. Set False to keep the names in release " +
                  "for a production stack trace, at a cost in bundle size. Only the WASM " +
                  "compile takes it, so setting it False under `compiler = \"dart2js\"` is " +
                  "refused rather than ignored.",
            default = True,
        ),
        "minify_wasm": attr.string(
            doc = "Whether the dart2wasm output minifies the names kept for runtime use " +
                  "(the ones `runtimeType.toString()` reads), matching " +
                  "`flutter build web --minify-wasm`. \"auto\" (default) minifies in release " +
                  "and not in debug or profile; \"true\" and \"false\" hold across every build " +
                  "mode. Only the WASM compile takes it, so setting it away from \"auto\" " +
                  "under `compiler = \"dart2js\"` is refused rather than ignored.",
            default = "auto",
            values = ["auto", "true", "false"],
        ),
        "source_maps": attr.bool(
            doc = "If True, generate source maps alongside compiled output.",
            default = False,
        ),
        "profile": attr.bool(
            doc = "If True, build in profile mode regardless of the Bazel compilation mode, " +
                  "matching `flutter build web --profile`. A profile build carries " +
                  "`dart.vm.profile=true` instead of `dart.vm.product=true`, runs with asserts " +
                  "off, and drops `toString()` bodies the way release does — so it measures " +
                  "what release does — but is left unminified and unstripped so the profile " +
                  "names a frame reports are readable. It is not a debug build: none of the " +
                  "DDC side files are produced.",
            default = False,
        ),
        "native_modules": attr.label_list(
            doc = """Native modules the page instantiates, each declaring what its bindings were generated from.

Each entry is a `flutter_native_library` wrapping a `.wasm` module. The module is
served from the bundle exactly as a `web_assets` entry is — same destination
derivation, so do not list it in both — and its contract is what lets a hot
reload tell an edit the instantiated module can still serve from one it cannot.

Declared rather than detected, and that is the point: the bundle also holds
Flutter's own `main.dart.wasm`, which changes on every Dart edit. Nothing but the
build knows which served file is a native module.
""",
            providers = [FlutterNativeLibraryInfo],
        ),
        "pwa": attr.bool(
            doc = "If True (default), ship flutter_service_worker.js and register it " +
                  "from flutter_bootstrap.js, as `flutter build web` does. False is " +
                  "`--pwa-strategy=none`.",
            default = True,
        ),
        "use_local_canvaskit": attr.bool(
            doc = "If True, load CanvasKit/Skwasm from the app's own server instead of " +
                  "Google's CDN (gstatic.com). Use this for air-gapped deployments or " +
                  "environments that cannot reach external CDNs. The CDN already sends " +
                  "Cross-Origin-Resource-Policy: cross-origin, so COEP does not require " +
                  "this. The canvaskit/ directory is always included in the build output " +
                  "regardless of this setting.\n\n" +
                  "Required to serve under a Content Security Policy: the renderer is a " +
                  "script, so `script-src 'self'` blocks it from the CDN and the app never " +
                  "boots. Note the guarantee stops at `script-src` — the framework still " +
                  "fetches fonts from fonts.gstatic.com, so a `default-src 'self'` policy " +
                  "needs that origin allowed (or the fonts bundled) whatever this is set to.",
            default = False,
        ),
        "_dart2wasm_platform_dill": attr.label(
            doc = "Platform dill the dart2wasm compile builds against.",
            default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2wasm_platform.dill"),
            allow_single_file = True,
            cfg = "exec",
        ),
        "_dart2js_platform_dill": attr.label(
            doc = "Platform dill the dart2js compile builds against.",
            default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2js_platform.dill"),
            allow_single_file = True,
            cfg = "exec",
        ),
        "_ddc_outline_dill": attr.label(
            doc = "DDC outline dill staged as a debug output for the dev loop.",
            default = Label("@flutter_web_sdk//:web-sdk/kernel/ddc_outline.dill"),
            allow_single_file = True,
            cfg = "exec",
        ),
        "_ddc_libraries_spec": attr.label(
            doc = "Libraries spec symlinked next to the staged DDC outputs.",
            default = Label("@flutter_web_sdk//:libraries_json"),
            allow_single_file = True,
            cfg = "exec",
        ),
        "_ddc_dart_sdk_js": attr.label(
            doc = "Prebuilt `dart_sdk.js` staged as a debug output for the DDC dev loop.",
            default = Label("@flutter_web_sdk//:web-sdk/kernel/ddcLibraryBundle-canvaskit/dart_sdk.js"),
            allow_single_file = True,
            cfg = "exec",
        ),
        "_ddc_module_loader_js": attr.label(
            doc = "Prebuilt DDC module loader staged for the dev loop; also anchors the Dart SDK root lookup.",
            default = Label("@flutter_web_sdk//:dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js"),
            allow_single_file = True,
            cfg = "exec",
        ),
        "_ddc_stack_trace_mapper_js": attr.label(
            doc = "Prebuilt DDC stack-trace mapper staged as a debug output for the dev loop.",
            default = Label("@flutter_web_sdk//:dart-sdk/lib/dev_compiler/web/dart_stack_trace_mapper.js"),
            allow_single_file = True,
            cfg = "exec",
        ),
        "_web_sdk": attr.label(
            doc = "Web SDK filegroup that `flutter.js` and the renderer files are collected from.",
            default = Label("@flutter_web_sdk//:web_sdk"),
            cfg = "exec",
        ),
        "_bundle_tool": attr.label(
            doc = "Tool that assembles the compiled output and templates into the web app directory.",
            default = Label("//flutter/private/tools:bundle_app"),
            executable = True,
            cfg = "exec",
        ),
        "_web_template_tool": attr.label(
            doc = "Tool that renders `index.html` and the bootstrap JS from the app templates.",
            default = Label("//flutter/private/tools:web_template"),
            executable = True,
            cfg = "exec",
        ),
    }),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:font_subset_toolchain_type", mandatory = False),
        # The Material icons, and the fallback font a local CanvasKit bundles.
        config_common.toolchain_type("@rules_flutter//flutter/private:material_icons_toolchain_type", mandatory = False),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + layering_toolchains(MODULAR_KERNEL_TOOLCHAINS) + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Builds a Flutter web application (WASM or JS) with all deployment artifacts.",
)
