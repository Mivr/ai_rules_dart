"""The `platform = "web"` rule of `flutter_integration_test`.

Compiles the app and its in-app test to JS or WASM with local CanvasKit or
Skwasm, bundles it with `flutter_assets/`, and runs the bundle under the
hermetic `chrome-headless-shell` through `flutter_integration_test_runner`.
`flutter_integration_test.bzl` dispatches to `web_integration_test_rule`.
"""

load(
    "@rules_dart//dart:providers.bzl",
    "DartInfo",
)
load(
    "@rules_dart//dart:utils.bzl",
    "MODULAR_KERNEL_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "derive_lib_root",
    "runfiles_path",
)
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_scheme_rel_path",
    "compile_kernel_package_config",
    "resolve_wrapper_main_import",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "FLUTTER_DEPS_DOC",
    "merge_dart_defines",
    "resolve_flutter_sdk_info",
)
load(
    "//flutter/private:flutter_integration_test_bootstrap.bzl",
    "make_web_integration_bootstrap_content",
)
load(
    "//flutter/private:flutter_integration_test_common.bzl",
    "COMMON_INTEGRATION_TEST_ATTRS",
    "integration_test_env",
    "integration_test_plugins",
    "integration_test_providers",
    "integration_test_runner_executable",
)
load(
    "//flutter/private:flutter_integration_test_ios.bzl",
    "exposes_package",
    "resolve_main_and_srcs",
)
load(
    "//flutter/private:flutter_integration_web_bundle.bzl",
    "BOOTSTRAP_JS_TEMPLATE",
    "INDEX_HTML_TEMPLATE",
    "JS_BUILD",
    "MANIFEST_JSON_TEMPLATE",
    "wasm_build",
)
load("//flutter/private:flutter_bundle.bzl", write_web_bundle = "flutter_web_bundle")
load("//flutter/private:flutter_kernel_module.bzl", "flutter_kernel_module_aspect")
load(
    "//flutter/private:flutter_web_compile.bzl",
    "flutter_dart2js_action",
    "flutter_dart2wasm_action",
    "make_dart2js_request",
    "make_dart2wasm_request",
    "web_build_mode",
    "web_compile_tool_inputs",
    "web_sdk_files_for_dart2js",
)
load("//flutter/private:layering_check.bzl", "LAYERING_CHECK_ASPECT")
load(
    "//flutter/private:plugin_registrant.bzl",
    "generate_dart_plugin_registrant",
)
load(
    "//flutter/private:validation.bzl",
    "escape_html",
    "validate_web_compiler_renderer",
    "web_renderer",
)
load("//flutter/private:web_stubs.bzl", "make_web_wrapper_main_content")

visibility(["//flutter/..."])

def _web_sdk_file_list(ctx):
    """All files the web SDK target carries (renderer/template lookup)."""
    return ctx.attr._web_sdk.files.to_list() if ctx.attr._web_sdk else []

def _web_integration_test_setup(ctx):
    """Validates a web target and resolves its compile inputs.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        A struct with `main_file`, `extra_srcs`, `renderer`, `sdk`,
        `user_defines`, `mode`, `is_debug`, `package_name`, `lib_root`,
        `srcs` and `package_config`.
    """
    if ctx.attr.platform != "web":
        fail(
            "%s: flutter_integration_test does not yet support platform = %r " % (
                ctx.label,
                ctx.attr.platform,
            ) + "(supported: \"web\", \"linux\", \"android\").",
        )

    if not exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, extra_srcs = resolve_main_and_srcs(ctx)

    renderer = web_renderer(ctx.attr.compiler, ctx.attr.renderer)
    validate_web_compiler_renderer(ctx.attr.compiler, renderer)

    flutter_sdk_info = resolve_flutter_sdk_info(ctx)
    user_defines = merge_dart_defines(ctx)
    mode = web_build_mode(ctx)

    package_name = ctx.attr.package_name or ctx.label.name
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Collect sources and synthesize the package config.
    all_srcs = list(extra_srcs) + collect_transitive_srcs(ctx.attr.deps).to_list()
    packages = collect_packages(ctx.attr.deps)
    packages = synthesize_app_package(
        ctx.label,
        packages,
        package_name,
        lib_root,
        ctx.attr.language_version,
    )

    pc = compile_kernel_package_config(
        ctx,
        packages,
        all_srcs + [main_file],
        roots = {package_name: True} if package_name else None,
    )
    return struct(
        extra_srcs = extra_srcs,
        is_debug = mode == "debug",
        lib_root = lib_root,
        main_file = main_file,
        mode = mode,
        package_config = pc.config_file,
        package_name = package_name,
        renderer = renderer,
        sdk = flutter_sdk_info,
        srcs = pc.srcs,
        user_defines = user_defines,
    )

def _web_integration_test_bootstrap(ctx, setup):
    """Generates the bootstrap, its engine wrapper and the plugin registrant.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_web_integration_test_setup` struct.

    Returns:
        A struct with `entrypoint` (the wrapper) and `srcs` (the compile set).
    """
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    bootstrap_rel = app_scheme_rel_path(bootstrap)
    bootstrap_depth = len(bootstrap_rel.split("/")) - 1
    test_import = resolve_wrapper_main_import(
        setup.package_name,
        setup.lib_root,
        setup.main_file.short_path,
        app_scheme_rel_path(setup.main_file),
        bootstrap_depth,
    )
    has_integration_test = exposes_package(ctx.attr.deps, ["integration_test"])
    ctx.actions.expand_template(
        template = ctx.file._bootstrap_template,
        output = bootstrap,
        substitutions = make_web_integration_bootstrap_content(
            test_import = test_import,
            has_integration_test = has_integration_test,
        ),
    )

    # Wrap `<name>_bootstrap.dart` with `ui_web.bootstrapEngine()` so the
    # Flutter web engine creates its implicit view before running the test.
    plugins = integration_test_plugins(ctx).all_plugins
    registrant = generate_dart_plugin_registrant(ctx, plugins, target_platform = "web")

    wrapper = ctx.actions.declare_file(ctx.label.name + "_wrapper_main.dart")
    wrapper_content = make_web_wrapper_main_content(
        bootstrap.basename,
        registrant.basename if registrant else None,
    )
    ctx.actions.write(wrapper, wrapper_content)
    extra_wrapper_srcs = [setup.main_file, bootstrap, wrapper]
    if registrant:
        extra_wrapper_srcs.append(registrant)
    return struct(
        entrypoint = wrapper,
        srcs = setup.srcs + extra_wrapper_srcs,
    )

def _web_integration_test_compile(ctx, setup, entrypoint):
    """Compiles the wrapped test for dart2wasm or dart2js.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_web_integration_test_setup` struct.
        entrypoint: The `_web_integration_test_bootstrap` struct.

    Returns:
        A struct with `outputs`, `copies`, `dart2js_dirs` and `builds`.
    """
    compile = struct(
        dart = setup.sdk.dart,
        flutter_sdk_info = setup.sdk,
        dart2wasm_platform_dill = ctx.file._dart2wasm_platform_dill,
        dart2js_platform_dill = ctx.file._dart2js_platform_dill,
        web_sdk_files = web_sdk_files_for_dart2js(ctx.attr._web_sdk),
        main_dart = entrypoint.entrypoint,
        srcs = entrypoint.srcs,
        package_config = setup.package_config,
        mode = setup.mode,
        defines = setup.user_defines,
        renderer = setup.renderer,
        stage_salt = "",
        web_compile_tool = ctx.executable._web_template_tool,
        web_compile_inputs = web_compile_tool_inputs(setup.sdk.dart_vm_files),
        web_guard_tool = ctx.executable._web_guard_tool,
        enable_experiments = ctx.attr.enable_experiments,
    )
    compile_outputs = []
    compile_copies = []
    dart2js_dirs = []
    if ctx.attr.compiler == "dart2wasm":
        output_wasm = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm")
        output_mjs = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.mjs")
        output_wasm_map = None
        if ctx.attr.source_maps:
            output_wasm_map = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm.map")
        flutter_dart2wasm_action(ctx, make_dart2wasm_request(
            compile,
            struct(
                optimization_level = ctx.attr.optimization_level_wasm,
                minify = ctx.attr.minify_wasm,
                strip_wasm = ctx.attr.strip_wasm,
            ),
            output_wasm,
            output_mjs,
            output_wasm_map,
        ))
        compile_outputs = [output_wasm, output_mjs]
        compile_copies = [
            {"src": output_wasm.path, "dst": "main.dart.wasm"},
            {"src": output_mjs.path, "dst": "main.dart.mjs"},
        ]
        if output_wasm_map != None:
            compile_outputs.append(output_wasm_map)
            compile_copies.append({"src": output_wasm_map.path, "dst": "main.dart.wasm.map"})
        builds = [wasm_build(setup.renderer)]
    else:
        output_js_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js")
        flutter_dart2js_action(ctx, make_dart2js_request(
            compile,
            struct(
                optimization_level = ctx.attr.optimization_level_js,
                minify = ctx.attr.minify_js,
                native_null_assertions = ctx.attr.native_null_assertions,
                frequency_based_minification = ctx.attr.frequency_based_minification,
                dump_info = False,
                source_maps = ctx.attr.source_maps,
            ),
            setup.renderer,
            output_js_dir,
        ))
        dart2js_dirs = [output_js_dir]
        builds = [JS_BUILD]
    return struct(
        builds = builds,
        copies = compile_copies,
        dart2js_dirs = dart2js_dirs,
        outputs = compile_outputs,
    )

def _web_integration_test_template_files(ctx, setup):
    """Writes the harness's `web/` files: the page, its bootstrap and its manifest.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_web_integration_test_setup` struct.

    Returns:
        A struct with `index_template`, `bootstrap_template` and `manifest_json`.
    """
    safe_title = escape_html(ctx.label.name)
    index_template = ctx.actions.declare_file(ctx.label.name + "_index_template.html")
    ctx.actions.write(index_template, INDEX_HTML_TEMPLATE.format(title = safe_title))

    bootstrap_template = ctx.actions.declare_file(ctx.label.name + "_bootstrap_template.js")
    ctx.actions.write(bootstrap_template, BOOTSTRAP_JS_TEMPLATE)

    manifest_json = ctx.actions.declare_file(ctx.label.name + "_manifest.json")
    ctx.actions.write(manifest_json, MANIFEST_JSON_TEMPLATE.format(name = safe_title))

    return struct(
        bootstrap_template = bootstrap_template,
        index_template = index_template,
        manifest_json = manifest_json,
    )

def _web_integration_test_run(ctx, setup, output_dir):
    """Wires the runner executable, environment and runfiles for the web bundle.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.
        setup: The `_web_integration_test_setup` struct.
        output_dir: The web bundle directory the runner serves.

    Returns:
        The provider list.
    """
    executable = integration_test_runner_executable(ctx)
    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": ctx.attr.platform,
        "FLUTTER_INTEGRATION_TEST_WEB_DIR": runfiles_path(output_dir, workspace_name),
        "FLUTTER_INTEGRATION_TEST_BROWSER": runfiles_path(ctx.file._chrome_headless_shell, workspace_name),
        "FLUTTER_INTEGRATION_TEST_FONTCONFIG": runfiles_path(ctx.file._chrome_fontconfig, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ROBOTO_FONT": runfiles_path(ctx.file._roboto_font, workspace_name),
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
                output_dir,
                ctx.file._chrome_headless_shell,
                ctx.file._chrome_fontconfig,
                ctx.file._roboto_font,
                library_tags,
            ] + ctx.attr._chrome_all_files.files.to_list(),
        ),
    )

def _flutter_integration_test_impl(ctx):
    """Compiles, bundles and runs a web integration test in a headless browser.

    Args:
        ctx: The rule context of the rule implementation that calls this helper.

    Returns:
        The provider list.
    """
    setup = _web_integration_test_setup(ctx)
    entrypoint = _web_integration_test_bootstrap(ctx, setup)
    compile = _web_integration_test_compile(ctx, setup, entrypoint)
    # The harness's own page, bootstrap and manifest are the project's `web/`
    # files; the Flutter tool's own web code writes the directory around the
    # compiled program from them and the pubspec, as `flutter build web` does.
    template_files = _web_integration_test_template_files(ctx, setup)
    output_dir = ctx.actions.declare_directory(ctx.label.name + "_web")
    write_web_bundle(
        ctx,
        setup.sdk,
        output_dir,
        mode = "debug" if setup.is_debug else "release",
        web_build = compile.outputs + compile.dart2js_dirs,
        web_sdk_files = _web_sdk_file_list(ctx),
        renderer = compile.builds[-1]["renderer"],
        wasm = ctx.attr.compiler == "dart2wasm",
        pwa_strategy = "none",
        # The browser runs offline: the renderer comes from the bundle.
        use_local_canvaskit = True,
        extra_project_files = {
            "web/flutter_bootstrap.js": template_files.bootstrap_template,
            "web/index.html": template_files.index_template,
            "web/manifest.json": template_files.manifest_json,
        },
    )
    return _web_integration_test_run(ctx, setup, output_dir)

_INTEGRATION_TEST_ATTRS = dict(COMMON_INTEGRATION_TEST_ATTRS)
_INTEGRATION_TEST_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_kernel_module_aspect, LAYERING_CHECK_ASPECT],
)
_INTEGRATION_TEST_ATTRS["compiler"] = attr.string(
    doc = "Web compiler: 'dart2js' (default) or 'dart2wasm'.",
    default = "dart2js",
    values = ["dart2js", "dart2wasm"],
)
_INTEGRATION_TEST_ATTRS["renderer"] = attr.string(
    doc = "Web renderer: 'canvaskit' or 'skwasm'. Defaults to matching `compiler`.",
    default = "",
    values = ["", "canvaskit", "skwasm"],
)
_INTEGRATION_TEST_ATTRS["optimization_level_js"] = attr.string(
    doc = "The `-O` level for dart2js compilation.",
    default = "1",
    values = ["auto", "0", "1", "2", "3", "4"],
)
_INTEGRATION_TEST_ATTRS["optimization_level_wasm"] = attr.string(
    doc = "The `-O` level for dart2wasm compilation.",
    default = "0",
    values = ["auto", "0", "1", "2", "3", "4"],
)
_INTEGRATION_TEST_ATTRS["minify_js"] = attr.string(
    doc = "Whether dart2js minifies identifiers.",
    default = "false",
    values = ["auto", "true", "false"],
)
_INTEGRATION_TEST_ATTRS["minify_wasm"] = attr.string(
    doc = "Whether dart2wasm minifies runtime type names.",
    default = "false",
    values = ["auto", "true", "false"],
)
_INTEGRATION_TEST_ATTRS["strip_wasm"] = attr.bool(
    doc = "Whether to strip static symbol names from WASM output.",
    default = False,
)
_INTEGRATION_TEST_ATTRS["native_null_assertions"] = attr.bool(
    doc = "Whether to check JS interop nullability at runtime.",
    default = True,
)
_INTEGRATION_TEST_ATTRS["frequency_based_minification"] = attr.bool(
    doc = "Whether dart2js uses frequency-based minification.",
    default = True,
)
_INTEGRATION_TEST_ATTRS["enable_experiments"] = attr.string_list(
    doc = "Dart language experiments to enable.",
)
_INTEGRATION_TEST_ATTRS["source_maps"] = attr.bool(
    doc = "Whether to generate source maps.",
    default = False,
)
_INTEGRATION_TEST_ATTRS["_chrome_headless_shell"] = attr.label(
    doc = "The pinned `chrome-headless-shell` binary that runs the web bundle.",
    default = Label("@flutter_chrome_headless_shell//:browser/chrome-headless-shell"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_chrome_fontconfig"] = attr.label(
    doc = "The fontconfig file the headless browser loads.",
    default = Label("@flutter_chrome_headless_shell//:fonts/fonts.conf"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_chrome_all_files"] = attr.label(
    doc = "Every file of the headless browser runtime, made available in runfiles.",
    default = Label("@flutter_chrome_headless_shell//:all_files"),
)
_INTEGRATION_TEST_ATTRS["_roboto_font"] = attr.label(
    doc = "The Roboto font the headless browser renders text with.",
    default = Label("@flutter_material_fonts//:material-fonts/Roboto-Regular.ttf"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_dart2wasm_platform_dill"] = attr.label(
    doc = "The platform dill `dart2wasm` compiles against.",
    default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2wasm_platform.dill"),
    allow_single_file = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_dart2js_platform_dill"] = attr.label(
    doc = "The platform dill `dart2js` compiles against.",
    default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2js_platform.dill"),
    allow_single_file = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_web_sdk"] = attr.label(
    doc = "The Flutter web SDK files (renderer, `flutter.js`, CanvasKit) the bundle copies.",
    default = Label("@flutter_web_sdk//:web_sdk"),
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_web_template_tool"] = attr.label(
    doc = "The `web_template` tool that substitutes the web bootstrap templates.",
    default = Label("//flutter/private/tools:web_template"),
    executable = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_bootstrap_template"] = attr.label(
    default = Label("//flutter/private/integration_test_bootstrap:web_bootstrap.dart.tpl"),
    allow_single_file = True,
    doc = "The Dart bootstrap program expanded into the test's `_bootstrap.dart`.",
)

_flutter_integration_test = rule(
    implementation = _flutter_integration_test_impl,
    attrs = _INTEGRATION_TEST_ATTRS,
    test = True,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:product_tools_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:font_subset_toolchain_type",
            mandatory = False,
        ),
        # The Material icons, and the fallback font a local CanvasKit bundles.
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:material_icons_toolchain_type",
            mandatory = False,
        ),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter app with an in-app integration test and runs it on the web platform.",
)

web_integration_test_rule = _flutter_integration_test
