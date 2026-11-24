"""Bootstrap template substitutions for `flutter_integration_test`.

The web, Linux and Android bootstrap generators expand their Dart templates
through the same binding and harness-URL substitutions. They live here so the
per-platform rule files and the iOS bootstrap rule load one definition.
"""

load(
    "//flutter/private:integration_test_bootstrap_snippets.bzl",
    "LINUX_HARNESS_URL_PROLOGUE",
    "integration_test_binding_substitutions",
)

visibility(["//flutter/..."])

def make_web_integration_bootstrap_content(test_import, has_integration_test = False):
    """Build the substitutions for the web integration test bootstrap template.

    The program is `web_bootstrap.dart.tpl`, expanded per target by the rule
    with `ctx.actions.expand_template`. `make_web_wrapper_main_content` wraps
    the result so `ui_web.bootstrapEngine` initializes the Flutter web engine
    and implicit view before calling its `main()`. The bootstrap dials the
    harness back over a WebSocket carrying the run's token (from the page URL
    the launcher opens), so the harness adopts only this run's app.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        A `{placeholder: replacement}` dict for `ctx.actions.expand_template`.
    """
    return _bootstrap_substitutions(test_import, has_integration_test)

def make_linux_integration_bootstrap_content(test_import, has_integration_test = False):
    """Build the substitutions for the Linux desktop bootstrap template.

    The program is `linux_bootstrap.dart.tpl`. It initializes the live
    integration test binding (`IntegrationTestWidgetsFlutterBinding` when
    `package:integration_test` is in `deps`, or a built-in
    `LiveTestWidgetsFlutterBinding` subclass otherwise), connects to the host
    runner over the WebSocket URL in `FLUTTER_INTEGRATION_TEST_HARNESS_URL`,
    forwards uncaught errors, and drives the suite via `RemoteListener`.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        A `{placeholder: replacement}` dict for `ctx.actions.expand_template`.
    """
    return _bootstrap_substitutions(
        test_import,
        has_integration_test,
        harness_url_prologue = LINUX_HARNESS_URL_PROLOGUE,
    )

def make_android_integration_bootstrap_content(test_import, has_integration_test = False):
    """Build the substitutions for the Android bootstrap template.

    The program is `android_bootstrap.dart.tpl`. It initializes the live
    integration test binding (`IntegrationTestWidgetsFlutterBinding` when
    `package:integration_test` is in `deps`, or a built-in
    `LiveTestWidgetsFlutterBinding` subclass otherwise), connects to the host
    runner over a localhost WebSocket forwarded via `adb reverse` (accepting
    the harness URL via `dart_entrypoint_args`,
    `FLUTTER_INTEGRATION_TEST_HARNESS_URL`, or the default
    `ws://127.0.0.1:38427/__flutter_integration_ws__`), forwards uncaught
    errors, and drives the suite via `RemoteListener`.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        A `{placeholder: replacement}` dict for `ctx.actions.expand_template`.
    """
    return _bootstrap_substitutions(test_import, has_integration_test)

def _bootstrap_substitutions(test_import, has_integration_test, harness_url_prologue = None):
    """The template substitutions the platform bootstrap generators share.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.
        harness_url_prologue: The URL prologue the template substitutes, or
            `None` for a template that resolves the harness URL itself.

    Returns:
        A `{placeholder: replacement}` dict for `ctx.actions.expand_template`.
    """
    binding = integration_test_binding_substitutions(has_integration_test)
    substitutions = {
        "{binding_import}": binding.import_stmt,
        "{binding_decl}": binding.decl,
        "{binding_init}": binding.init,
        "{test_import}": test_import,
    }
    if harness_url_prologue != None:
        substitutions["{harness_url_prologue}"] = harness_url_prologue
    return substitutions
