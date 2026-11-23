"""Direct `rules_testing` analysis tests for the public `//flutter:web.bzl` rules.

Each test's subject is the public rule or macro itself, and each asserts both
the providers the rule documents and the argv and inputs of the action that
does its work, so a dropped provider field, flag or input fails here.
"""

load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:util.bzl", "TestingAspectInfo")
load("//flutter:web.bzl", "flutter_web_app", "flutter_web_bundle", "flutter_web_manifest_gen")
load(":rule_coverage.bzl", "expect_action", "expect_argv_suffixes", "expect_default_outputs")

visibility(["//tests/..."])

_MAIN = "lib/web_fixture_main.dart"

def _expect_web_bundle_providers(env, target):
    """The providers every web bundle hands out: the bundle directory and the analysis closure."""
    expect_default_outputs(env, target, [target.label.name + "_web"])
    env.expect.that_target(target).has_provider(DartAnalyzableInfo)
    env.expect.that_str(
        target[DartAnalyzableInfo].dart_info.package_name,
    ).equals("web_fixture")
    env.expect.that_target(target).output_group("dump_info").contains_exactly([])

def _expect_web_bundle_action(env, target):
    """`FlutterWebBundle` runs the bundler over its config, the page and the manifest."""
    expect_action(
        env,
        target,
        "FlutterWebBundle",
        args = ["--config"],
        inputs = [
            target.label.name + "_web_bundle_config.json",
            target.label.name + "_index.html",
            target.label.name + "_flutter_bootstrap.js",
        ],
    )

def _flutter_web_bundle_wasm_analysis_test_impl(env, target):
    _expect_web_bundle_providers(env, target)
    _expect_web_bundle_action(env, target)

    # dart2wasm compiles `main` to `<name>_wasm/main.dart.wasm`, with the
    # target's `defines` passed as `-D` flags.
    wasm = expect_action(
        env,
        target,
        "FlutterDart2Wasm",
        args = ["compile", "wasm", "-o", "-Dfrom.attr=1"],
        inputs = ["web_fixture_main.dart"],
    )
    expect_argv_suffixes(wasm, ["_wasm/main.dart.wasm", "_wrapper_main.dart"])

def _flutter_web_bundle_wasm_analysis_test(name):
    flutter_web_bundle(
        name = name + "_subject",
        package_name = "web_fixture",
        main = _MAIN,
        defines = ["from.attr=1"],
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _flutter_web_bundle_wasm_analysis_test_impl,
        target = name + "_subject",
    )

def _flutter_web_bundle_dart2js_analysis_test_impl(env, target):
    _expect_web_bundle_providers(env, target)
    _expect_web_bundle_action(env, target)

    # `compiler = "dart2js"` compiles with dart2js and never with dart2wasm.
    js = expect_action(
        env,
        target,
        "FlutterDart2JS",
        args = ["compile", "js"],
        inputs = ["web_fixture_main.dart"],
    )
    expect_argv_suffixes(js, ["_wrapper_main.dart"])
    actions = target[TestingAspectInfo].actions if TestingAspectInfo in target else []
    env.expect.that_collection(
        [action.mnemonic for action in actions],
    ).not_contains("FlutterDart2Wasm")

def _flutter_web_bundle_dart2js_analysis_test(name):
    flutter_web_bundle(
        name = name + "_subject",
        package_name = "web_fixture",
        main = _MAIN,
        compiler = "dart2js",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _flutter_web_bundle_dart2js_analysis_test_impl,
        target = name + "_subject",
    )

def _flutter_web_manifest_gen_analysis_test_impl(env, target):
    # The manifest is `<name>.json`, expanded from the built-in template with
    # `app_name` substituted for `{APP_NAME}`.
    expect_default_outputs(env, target, [target.label.name + ".json"])
    action = expect_action(env, target, "TemplateExpand", inputs = ["manifest.json"])
    action.substitutions().contains_exactly({"{APP_NAME}": "Rule Coverage"})

def _flutter_web_manifest_gen_analysis_test(name):
    flutter_web_manifest_gen(
        name = name + "_subject",
        app_name = "Rule Coverage",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _flutter_web_manifest_gen_analysis_test_impl,
        target = name + "_subject",
    )

def _flutter_web_app_analysis_test_impl(env, target):
    _expect_web_bundle_providers(env, target)
    _expect_web_bundle_action(env, target)

    # With no `web/manifest.json` to discover, the app's manifest is the one
    # `flutter_web_manifest_gen` generates, and it reaches the bundler.
    expect_action(
        env,
        target,
        "FlutterWebBundle",
        inputs = ["__%s_manifest.json" % target.label.name],
    )

    # The macro always compiles with dart2wasm.
    wasm = expect_action(
        env,
        target,
        "FlutterDart2Wasm",
        args = ["compile", "wasm"],
        inputs = ["web_fixture_main.dart"],
    )
    expect_argv_suffixes(wasm, ["_wasm/main.dart.wasm"])

def _flutter_web_app_analysis_test(name):
    flutter_web_app(
        name = name + "_subject",
        package_name = "web_fixture",
        deps = [],
        main = _MAIN,
        # No such directory: nothing is discovered, so every runner file is
        # the built-in default.
        web_dir = name + "_no_web_dir",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _flutter_web_app_analysis_test_impl,
        target = name + "_subject",
    )

def web_rules_test_suite(name):
    """Direct analysis tests for `flutter_web_app`, `flutter_web_bundle` and `flutter_web_manifest_gen`.

    Args:
        name: The test suite's name.
    """
    test_suite(
        name = name,
        tests = [
            _flutter_web_app_analysis_test,
            _flutter_web_bundle_dart2js_analysis_test,
            _flutter_web_bundle_wasm_analysis_test,
            _flutter_web_manifest_gen_analysis_test,
        ],
    )
