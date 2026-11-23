"""Web bundle scaffolding for `flutter_integration_test`.

Moved out of `flutter_integration_test.bzl` so iOS support can extend that
file without growing it.
"""

visibility(["//flutter/..."])

INDEX_HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
  <base href="$FLUTTER_BASE_HREF">
  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">
  <title>{title}</title>
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
"""

BOOTSTRAP_JS_TEMPLATE = """\
{{flutter_build_config}}
{
  let script = document.createElement("script");
  script.src = "flutter.js";
  script.addEventListener("load", function() {
    _flutter.loader.load();
  });
  document.head.appendChild(script);
}
"""

MANIFEST_JSON_TEMPLATE = """\
{{
    "name": "{name}",
    "short_name": "{name}",
    "start_url": ".",
    "display": "standalone",
    "background_color": "#0175C2",
    "theme_color": "#0175C2",
    "description": "A Flutter web integration test.",
    "orientation": "portrait-primary",
    "prefer_related_applications": false
}}
"""

VERSION_JSON_TEMPLATE = """\
{{
    "app_name": "{app_name}",
    "version": "1.0.0",
    "build_number": "1",
    "package_name": "{app_name}"
}}
"""

def build_config_js(engine_revision, builds):
    """Render the `_flutter.buildConfig` bootstrap script for a web bundle.

    Args:
      engine_revision: The Flutter engine revision string recorded in the config.
      builds: List of build entry dicts (such as `JS_BUILD` or `wasm_build(...)`) the loader may pick from.

    Returns:
      The JavaScript source text that assigns `_flutter.buildConfig`.
    """
    config = {
        "engineRevision": engine_revision,
        "builds": builds,
        "useLocalCanvasKit": True,
    }
    return """if (!window._flutter) {
  window._flutter = {};
}
_flutter.buildConfig = %s;
""" % json.encode(config)

def wasm_build(renderer):
    """Build the `buildConfig` entry describing a dart2wasm web build.

    Args:
      renderer: The renderer name the loader selects for this build, such as `"skwasm"`.

    Returns:
      A dict with the dart2wasm compile target, the renderer and the wasm/mjs output paths.
    """
    return {
        "compileTarget": "dart2wasm",
        "renderer": renderer,
        "mainWasmPath": "main.dart.wasm",
        "jsSupportRuntimePath": "main.dart.mjs",
    }

JS_BUILD = {
    "compileTarget": "dart2js",
    "renderer": "canvaskit",
    "mainJsPath": "main.dart.js",
}
