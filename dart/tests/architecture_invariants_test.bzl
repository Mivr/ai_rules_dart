"""Analysis half of `//dart/tests:architecture_invariants_test`.

`docs/ARCHITECTURE.md` states which provider each rule publishes and why:
`DartInfo` means "valid as a dep", so `dart_library` publishes it, while
`dart_binary`, `dart_test`, `dart_js_binary` and `dart_wasm_binary` publish
`DartAnalyzableInfo` and never `DartInfo`; and every `deps` attribute gates on
`providers = [DartInfo]`, so a target without it fails analysis. The tests
below analyze the subjects in `//dart/tests/arch_invariants_fixture` and fail
when a rule regresses on either. The source half (provider fields, hand-built
`DartInfo(` calls, `deps` declarations) is `architecture_invariants_scan_test`.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")

_FIXTURE = "//dart/tests/arch_invariants_fixture:"

# Rule name, as the test reports it, mapped to its fixture subject.
_EXECUTABLES = {
    "dart_binary": "binary",
    "dart_test": "test",
    "dart_js_binary": "js_binary",
    "dart_wasm_binary": "wasm_binary",
}

# Subjects whose `deps` name a target without `DartInfo`, keyed by test suffix.
_REJECTED_DEPS = {
    "library_rejects_filegroup": "library_on_filegroup",
    "library_rejects_binary": "library_on_binary",
    "binary_rejects_filegroup": "binary_on_filegroup",
    "test_rejects_filegroup": "test_on_filegroup",
}

def _providers_test(env, targets):
    """Asserts `dart_library` publishes `DartInfo` and no executable rule does."""
    env.expect.that_target(targets.dart_library).has_provider(DartInfo, "DartInfo")
    for rule in _EXECUTABLES:
        target = getattr(targets, rule)
        env.expect.that_target(target).has_provider(DartAnalyzableInfo, "DartAnalyzableInfo")
        env.expect.that_bool(
            DartInfo in target,
            expr = "{} publishes DartInfo".format(rule),
        ).equals(False)

def _rejected_dep_test(env, target):
    """Asserts the subject failed analysis on the `providers = [DartInfo]` contract of `deps`."""
    env.expect.that_target(target).failures().contains_predicate(
        matching.str_matches("*does not have mandatory providers: 'DartInfo'*"),
    )

def architecture_invariants_test_suite(name, scan):
    """Declares the provider invariant analysis tests and the suite running them with the source scan.

    Args:
      name: Name of the generated `test_suite`; the analysis tests are named
        after it, without its `_test` suffix.
      scan: Label of the `dart_test` scanning the live source tree.
    """
    base = name.removesuffix("_test")
    targets = {rule: _FIXTURE + subject for rule, subject in _EXECUTABLES.items()}
    targets["dart_library"] = _FIXTURE + "library"
    analysis_test(
        name = base + "_providers_test",
        attr_values = {"size": "small"},
        impl = _providers_test,
        targets = targets,
    )
    tests = [":" + base + "_providers_test"]
    for suffix, subject in _REJECTED_DEPS.items():
        analysis_test(
            name = base + "_" + suffix + "_test",
            attr_values = {"size": "small"},
            expect_failure = True,
            impl = _rejected_dep_test,
            target = _FIXTURE + subject,
        )
        tests.append(":" + base + "_" + suffix + "_test")
    native.test_suite(name = name, tests = tests + [scan])
