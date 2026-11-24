"""Flutter rules for web builds.

Two tiers of API:

    Tier 1 — flutter_web_app (recommended):

        load("@rules_flutter//flutter:web.bzl", "flutter_web_app")

        flutter_web_app(
            name = "my_web_app",
            package_name = "my_app",
            deps = [":lib"],
        )

    The project's `pubspec.yaml` and its `web/` directory (`flutter create
    --platforms=web .` writes it) are read as `flutter build web` reads them:
    the assets the pubspec names, `web/index.html` and
    `web/flutter_bootstrap.js` substituted, the rest of `web/` copied.

    Tier 2 — the rule itself:

        load("@rules_flutter//flutter:web.bzl", "flutter_web_bundle")

        flutter_web_bundle(
            name = "my_web_app",
            main = "lib/main.dart",
            deps = [":lib"],
            pubspec = "pubspec.yaml",
            pubspec_srcs = glob(["web/**", "assets/**"]),
            base_href = "/myapp/",
            web_defines = {"API_URL": "https://api.example.com"},
        )

Unlike other platform rules, web rules take `main` + `deps` (Dart source)
directly — NOT a `flutter_application` target. This is because web compilation
uses dart2wasm/dart2js which consume Dart source directly, so the compilation
pipeline is structurally different from AOT platforms.
"""

load("@flutter_l10n//:index.bzl", "L10N_PROJECTS")
load("//flutter/private:flutter_bundle.bzl", "project_pub_packages")
load("//flutter/private:flutter_gen_l10n.bzl", "l10n_attach")
load("//flutter/private:flutter_integration_test.bzl", _flutter_integration_test = "flutter_integration_test")
load("//flutter/private:flutter_web_application.bzl", _flutter_web_bundle_rule = "flutter_web_bundle")

visibility("public")

flutter_integration_test = _flutter_integration_test

# -- Low-level assembler (Tier 2) --------------------------------------------

def flutter_web_bundle(name, web_sdk = None, **kwargs):
    """Builds a Flutter web application (WASM or JS) with all deployment artifacts.

    This is the low-level assembler rule. For most projects, prefer
    flutter_web_app which auto-discovers runner files.

    Args:
        name: Name of the target that builds the web bundle with its deployment artifacts.
        web_sdk: Optional web SDK repo name (e.g. "@my_flutter_web_sdk").
            Defaults to "@flutter_web_sdk".
        **kwargs: All other arguments forwarded to the underlying rule.
    """
    if web_sdk:
        repo = web_sdk.lstrip("@")
        kwargs["_dart2wasm_platform_dill"] = Label("@%s//:web-sdk/kernel/dart2wasm_platform.dill" % repo)
        kwargs["_dart2js_platform_dill"] = Label("@%s//:web-sdk/kernel/dart2js_platform.dill" % repo)
        kwargs["_web_sdk"] = Label("@%s//:web_sdk" % repo)

    _flutter_web_bundle_rule(
        name = name,
        **kwargs
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_web_app(
        name,
        package_name,
        deps,
        main = "lib/main.dart",
        base_href = "/",
        static_assets_url = "/",
        web_sdk = None,
        **kwargs):
    """Builds a Flutter web application from the project's `pubspec.yaml` and `web/`.

    `pubspec` defaults to the package's `pubspec.yaml`, and the files under
    `web/` are added to `pubspec_srcs`: the tool copies that directory and
    substitutes its `index.html` and `flutter_bootstrap.js`, as
    `flutter build web` does.

    This macro always uses dart2wasm + skwasm (modern defaults). For dart2js
    or canvaskit, use flutter_web_bundle directly.

    Args:
        name: Name of the web application target.
        package_name: Dart package name (same value as `pubspec.yaml`'s `name:`).
            Required: keys the web bootstrap's `package:` URI for `main` and
            anchors codegen sibling co-location.
        deps: dart_library or flutter_library dependencies.
        main: The main .dart entry point (default "lib/main.dart").
        base_href: `--base-href` (default "/"). Must start and end with "/".
        static_assets_url: `--static-assets-url` (default "/"). Must end with "/".
        web_sdk: Optional web SDK repo name (e.g. "@my_flutter_web_sdk").
        **kwargs: Additional arguments forwarded to flutter_web_bundle
            (e.g. pubspec_srcs, pub_packages, defines, pwa, web_defines,
            tags, visibility). The compiler settings live there too:
            `profile`, `optimization_level_js`, `optimization_level_wasm`,
            `minify_js`, `minify_wasm`, `strip_wasm`, `native_null_assertions`,
            `frequency_based_minification`, `enable_experiments`, `dump_info`
            and `source_maps`. Note this macro always compiles with dart2wasm,
            so `minify_wasm`, `optimization_level_wasm` and `strip_wasm` are
            live here while a `compiler = "dart2js"` bundle refuses them.
    """
    if "pubspec" not in kwargs and native.glob(["pubspec.yaml"], allow_empty = True):
        kwargs["pubspec"] = "pubspec.yaml"
    srcs = list(kwargs.pop("pubspec_srcs", []))
    for f in native.glob(["web/**"], allow_empty = True):
        if f not in srcs:
            srcs.append(f)
    l10n = {"deps": deps, "main": main}
    if "srcs" in kwargs:
        l10n["srcs"] = kwargs["srcs"]
    l10n_attach(name, l10n, L10N_PROJECTS)
    if "srcs" in l10n:
        kwargs["srcs"] = l10n["srcs"]
    project_pub_packages(kwargs)
    flutter_web_bundle(
        name = name,
        package_name = package_name,
        main = main,
        deps = l10n["deps"],
        base_href = base_href,
        static_assets_url = static_assets_url,
        web_sdk = web_sdk,
        pubspec_srcs = srcs,
        **kwargs
    )
