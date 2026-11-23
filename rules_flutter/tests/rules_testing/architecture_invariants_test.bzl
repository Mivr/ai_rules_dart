"""FF6 provider invariants of the Flutter rules, as `rules_testing` analysis tests.

Gate 13 section D (FF6) says every Dart-library `deps` attribute requires
`DartInfo`, and that each rule repository holds that invariant as an analysis
test. `//flutter/tests:architecture_invariants_test` is the one command that
runs it all: these cases plus the production-`.bzl` source scan.

The subjects are the `manual` fixtures declared by
`//flutter/tests:architecture_fixtures.bzl`. Each case fails when its invariant
regresses:

* provider cases fail when a rule stops publishing, or starts publishing, a
  provider;
* contract cases fail when a `deps` entry that provides no `DartInfo` is
  accepted, because the intentionally invalid fixture then analyses cleanly.
"""

load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("//flutter:providers.bzl", "FlutterInfo")

visibility(["//tests/..."])

_FIXTURES = "//flutter/tests:"

def _has(env, target, provider, name, expected):
    """Asserts whether `target` publishes `provider`."""
    env.expect.that_bool(provider in target, expr = name + " published").equals(expected)

def _library_providers_impl(env, target):
    """A `flutter_library` publishes DartInfo and FlutterInfo."""
    _has(env, target, DartInfo, "DartInfo", True)
    _has(env, target, FlutterInfo, "FlutterInfo", True)

def _plugin_providers_impl(env, target):
    """A `flutter_plugin` publishes DartInfo."""
    _has(env, target, DartInfo, "DartInfo", True)

def _test_providers_impl(env, target):
    """A `flutter_test` publishes DartAnalyzableInfo and no DartInfo."""
    _has(env, target, DartAnalyzableInfo, "DartAnalyzableInfo", True)
    _has(env, target, DartInfo, "DartInfo", False)

def _bundle_providers_impl(env, target):
    """A `flutter_asset_bundle` publishes neither DartInfo nor FlutterInfo."""
    _has(env, target, DartInfo, "DartInfo", False)
    _has(env, target, FlutterInfo, "FlutterInfo", False)

def _contract_impl(env, target):
    """A `deps` entry without DartInfo fails analysis naming the provider contract."""
    env.expect.that_target(target).failures().contains_predicate(
        matching.str_matches("*mandatory provider*DartInfo*"),
    )

def architecture_invariants_analysis_tests(name, fixtures):
    """Declares the FF6 analysis cases and returns their labels.

    Args:
        name: Prefix for every declared target.
        fixtures: The prefix the fixtures were declared with in `//flutter/tests`.

    Returns:
        The labels of the declared analysis tests.
    """
    cases = {
        "_lib_providers": (_library_providers_impl, "_lib", False),
        "_plugin_providers": (_plugin_providers_impl, "_plugin", False),
        "_test_providers": (_test_providers_impl, "_test", False),
        "_bundle_providers": (_bundle_providers_impl, "_bundle", False),
        "_lib_deps_contract": (_contract_impl, "_lib_bad_dep", True),
        "_test_deps_contract": (_contract_impl, "_test_bad_dep", True),
        "_bundle_deps_contract": (_contract_impl, "_bundle_bad_dep", True),
    }
    labels = []
    for suffix, (impl, subject, fails) in cases.items():
        analysis_test(
            name = name + suffix,
            impl = impl,
            target = _FIXTURES + fixtures + subject,
            expect_failure = fails,
        )
        labels.append(":" + name + suffix)
    return labels
