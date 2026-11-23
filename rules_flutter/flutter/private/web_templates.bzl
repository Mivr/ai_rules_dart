"""Web template substitution: the built-ins and the one action that applies them.

Split from `flutter_web_application.bzl`. Every template — the user's or the
rule's default — goes through the same substitution pass, so a `flutter
create` index.html works untouched and the default cannot drift from what a
user template gets.
"""

load("//flutter/private:web_service_worker.bzl", "SERVICE_WORKER_VERSION")

visibility(["//flutter/..."])

# What `flutter_bazel run -d chrome` actually serves, whatever the bundle is.
#
# The dev loop compiles with DDC and serves `main.dart.js` as its own loader
# script, so the page's build config describes that and not the target's
# dart2wasm/dart2js output. `canvaskit` because the DDC loop has no skwasm
# build to boot. Upstream's dev server pins the same three values
# (`isolated/web_asset_server.dart`, `_buildConfigString`).
_DDC_BUILD = {
    "compileTarget": "dartdevc",
    "renderer": "canvaskit",
    "mainJsPath": "main.dart.js",
}

def _build_config_js(engine_revision, builds, use_local_canvaskit):
    """The `{{flutter_build_config}}` built-in, in upstream's exact shape.

    Emitted as JSON assigned to `_flutter.buildConfig` — the same text
    `WebTemplatedFiles.buildConfigString` produces — so a user who copies
    upstream's `flutter_bootstrap.js` into `web/` gets a working bundle.

    Args:
        engine_revision: The engine the app was compiled against.
        builds: Build descriptions, most preferred first.
        use_local_canvaskit: Whether to load the renderer from the app's server.

    Returns:
        A JavaScript snippet.
    """
    config = {"engineRevision": engine_revision, "builds": builds}
    if use_local_canvaskit:
        config["useLocalCanvasKit"] = True
    return """if (!window._flutter) {
  window._flutter = {};
}
_flutter.buildConfig = %s;
""" % json.encode(config)

def web_template_builtins(ctx, flutter_sdk_info, builds, index_template, bootstrap_template, flutter_js_file):
    """Builds the template substitution builtins shared by every template.

    Args:
        ctx: The rule context.
        flutter_sdk_info: The resolved Flutter SDK.
        builds: Build descriptions, most preferred first.
        index_template: The index.html template file.
        bootstrap_template: The flutter_bootstrap.js template file.
        flutter_js_file: The engine's `flutter.js`, or None.

    Returns:
      A struct with `shared_builtins`, `template_inputs`, `index_builtins`
      and `dev_builtins`.
    """
    build_config = _build_config_js(
        flutter_sdk_info.engine_revision,
        builds,
        ctx.attr.use_local_canvaskit,
    )

    # Always supplied, in both states: a user bootstrap copied from upstream
    # references the name unconditionally, and `null` is what upstream
    # substitutes when no worker ships.
    worker_version = "\"%s\"" % SERVICE_WORKER_VERSION if ctx.attr.pwa else "null"
    shared_builtins = {
        "flutter_build_config": {"value": build_config},
        "flutter_service_worker_version": {"value": worker_version},
    }
    template_inputs = [index_template, bootstrap_template]
    if flutter_js_file:
        shared_builtins["flutter_js"] = {"file": flutter_js_file.path}
        template_inputs.append(flutter_js_file)

    index_builtins = dict(shared_builtins)
    index_builtins["flutter_bootstrap_js"] = {"from_output": 0}

    # The dev loop's build config names DDC's output, not this target's. It is
    # fixed rather than derived from the target's compiler/renderer attrs
    # because the dev loop always compiles with DDC and always serves the
    # renderer from the bundle it is serving — the attrs describe the bundle,
    # which a `-d chrome` run does not run.
    dev_builtins = dict(shared_builtins)
    dev_builtins["flutter_build_config"] = {"value": _build_config_js(
        flutter_sdk_info.engine_revision,
        [_DDC_BUILD],
        use_local_canvaskit = True,
    )}

    # No service worker in a dev run, matching upstream's run mode. A template
    # that registers one would install it against `localhost` and outlive the
    # run, serving a stale bundle to the next one.
    dev_builtins["flutter_service_worker_version"] = {"value": "null"}
    return struct(
        shared_builtins = shared_builtins,
        template_inputs = template_inputs,
        index_builtins = index_builtins,
        dev_builtins = dev_builtins,
    )

def web_substitute_templates(ctx, flutter_sdk_info, is_debug, index_template, bootstrap_template, builtins):
    """Runs Step 6b: substitutes the index and bootstrap templates in one action.

    The bootstrap goes first so index.html can inline the *substituted*
    bootstrap through `{{flutter_bootstrap_js}}` — the same ordering
    `WebTemplatedFiles.build` uses upstream.

    Args:
        ctx: The rule context.
        flutter_sdk_info: The resolved Flutter SDK.
        is_debug: Whether this is a debug build.
        index_template: The index.html template file.
        bootstrap_template: The flutter_bootstrap.js template file.
        builtins: The struct `web_template_builtins` returns.

    Returns:
      An `(index_html, bootstrap_js, dev_bootstrap_js)` tuple. The bootstrap
      the dev loop serves comes from the same template as the bundle's.
    """
    index_html = ctx.actions.declare_file(ctx.label.name + "_index.html")
    bootstrap_js = ctx.actions.declare_file(ctx.label.name + "_flutter_bootstrap.js")

    # The bootstrap the dev loop serves, from the same template as the bundle's.
    #
    # `flutter_bazel run -d chrome` serves this target's index.html as built but
    # compiles the app with DDC, so the page cannot boot the bundle's bootstrap:
    # that one names this target's dart2wasm/dart2js output. Upstream has the
    # same split and resolves it the same way — `WebAssetServer` substitutes
    # `web/flutter_bootstrap.js` with the dev server's own build config
    # (`isolated/web_asset_server.dart`) rather than generating a bootstrap that
    # ignores the template.
    #
    # Emitted by the build rather than assembled by the dev tool because the
    # template, the `{{...}}` values and the substitution rules all live here.
    # A dev tool generating its own bootstrap silently dropped both the user's
    # template and every `web_defines` entry that referenced it.
    dev_bootstrap_js = None
    if is_debug:
        dev_bootstrap_js = ctx.actions.declare_file(ctx.label.name + "_dev_flutter_bootstrap.js")

    template_config = {
        "web_defines": ctx.attr.web_defines,
        "keep_placeholders": ctx.attr.keep_placeholders,
        "files": [
            {
                "template": bootstrap_template.path,
                "output": bootstrap_js.path,
                "label": "flutter_bootstrap.js",
                # Upstream substitutes an empty base href into the bootstrap:
                # the page's `<base>` already governs, and a bootstrap that
                # repeated it would resolve URLs against it twice.
                "base_href": "",
                "static_assets_url": None,
                "dev_loop_guard": False,
                "manages_service_worker": ctx.attr.pwa,
                "check_constructs": True,
                "builtins": builtins.shared_builtins,
            },
            {
                "template": index_template.path,
                "output": index_html.path,
                "label": "index.html",
                "base_href": ctx.attr.base_href,
                "static_assets_url": ctx.attr.static_assets_url,
                # In debug the dev tool serves this index.html but generates
                # its own flutter_bootstrap.js, so an index that inlines the
                # boot path would run the built bundle and hot reload would do
                # nothing. Refused there, allowed in a release build.
                "dev_loop_guard": is_debug,
                # With pwa = False the rule ships and registers nothing, so a
                # page registering its own worker is the supported way to have
                # one and must not be refused.
                "manages_service_worker": ctx.attr.pwa,
                "check_constructs": True,
                "builtins": builtins.index_builtins,
            },
        ] + ([
            {
                "template": bootstrap_template.path,
                "output": dev_bootstrap_js.path,
                "label": "flutter_bootstrap.js (dev loop)",
                "base_href": "",
                "static_assets_url": None,
                "dev_loop_guard": False,
                "manages_service_worker": ctx.attr.pwa,
                # The same bytes the entry above already read: reporting a
                # deprecated construct in them twice names one mistake as two.
                "check_constructs": False,
                "builtins": builtins.dev_builtins,
            },
        ] if dev_bootstrap_js else []),
    }
    template_config_file = ctx.actions.declare_file(ctx.label.name + "_web_template_config.json")
    ctx.actions.write(template_config_file, json.encode(template_config))

    ctx.actions.run(
        executable = flutter_sdk_info.dart,
        arguments = [
            ctx.executable._web_template_tool.path,
            "--config",
            template_config_file.path,
        ],
        inputs = depset(
            direct = builtins.template_inputs + [
                index_template,
                bootstrap_template,
                template_config_file,
                ctx.executable._web_template_tool,
            ],
            transitive = [flutter_sdk_info.dart_vm_files],
        ),
        outputs = [index_html, bootstrap_js] + ([dev_bootstrap_js] if dev_bootstrap_js else []),
        mnemonic = "FlutterWebTemplate",
        progress_message = "Substituting web templates for %s" % ctx.label,
        toolchain = None,
    )
    return index_html, bootstrap_js, dev_bootstrap_js

def web_substituted_templates(ctx, flutter_sdk_info, is_debug, builds, templates, flutter_js_file):
    """Runs Step 6b: the built-ins, then the one substitution action.

    Args:
        ctx: The rule context.
        flutter_sdk_info: The resolved Flutter SDK.
        is_debug: Whether this is a debug build.
        builds: The program's build descriptions, most preferred first.
        templates: The struct `_web_write_templates` returns.
        flutter_js_file: The engine's `flutter.js`, or None.

    Returns:
        An `(index_html, bootstrap_js, dev_bootstrap_js)` tuple.
    """
    builtins = web_template_builtins(
        ctx,
        flutter_sdk_info,
        builds,
        templates.index_template,
        templates.bootstrap_template,
        flutter_js_file,
    )
    return web_substitute_templates(
        ctx,
        flutter_sdk_info,
        is_debug,
        templates.index_template,
        templates.bootstrap_template,
        builtins,
    )
