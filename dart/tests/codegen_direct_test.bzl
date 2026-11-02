"""Direct `rules_testing` tests for `dart_codegen`, `dart_aggregate_codegen` and `dart_sqlcodegen`.

Each test analyzes one instance of the rule and asserts both halves of what the
rule publishes: the providers (`DefaultInfo` outputs and the effective
`DartPackageMetadataInfo`) and the one codegen action it registers (the flags
the generator contract requires, and the files the action reads). The
hermeticity and staging assertions stay with `codegen_test.bzl`.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching", "subjects")
load("//dart:defs.bzl", "dart_aggregate_codegen", "dart_codegen", "dart_sqlcodegen")
load("//dart:providers.bzl", "DartPackageMetadataInfo")
load(":truth_helpers.bzl", "action_of", "expect_default_outputs", "expect_inputs", "provider_of")

_MODEL = ":lib/direct_model.dart"
_SCHEMA = ":lib/direct_schema.drift"
_PACKAGE = "direct_fixture"
_LANGUAGE_VERSION = "3.11"
_METADATA_ATTRS = {
    "package_name": subjects.str,
    "language_version": subjects.str,
}

def _expect_metadata(env, target):
    """Asserts the effective package identity the codegen target publishes."""
    metadata = provider_of(env, target, DartPackageMetadataInfo, "DartPackageMetadataInfo", _METADATA_ATTRS)
    metadata.package_name().equals(_PACKAGE)
    metadata.language_version().equals(_LANGUAGE_VERSION)

def _expect_generator_contract(action, outputs):
    """Asserts the flags every shim-contract codegen action must pass."""
    action.contains_flag_values([
        ("--package", _PACKAGE),
        ("--root-language-version", _LANGUAGE_VERSION),
    ])
    action.argv().contains_at_least(["--input", "--input-asset", "--output"])
    for output in outputs:
        action.argv().contains_predicate(_ends_with(output))

def _ends_with(suffix):
    """Returns a matcher for an argv element ending in `suffix`."""
    return matching.str_endswith(suffix)

def _dart_codegen_test(env, target):
    """Asserts the providers and the `DartCodegen` action of `dart_codegen`."""
    _expect_metadata(env, target)
    expect_default_outputs(env, target, ["dart/tests/lib/direct_model.g.dart"])
    action = action_of(env, target, "DartCodegen")
    _expect_generator_contract(action, ["lib/direct_model.g.dart", "lib/direct_model.dart"])
    expect_inputs(action, ["*dart/tests/lib/direct_model.dart", "*dart/private/tools/noop"])

def _dart_aggregate_codegen_test(env, target):
    """Asserts the providers and the `DartAggregateCodegen` action of `dart_aggregate_codegen`."""
    _expect_metadata(env, target)
    expect_default_outputs(env, target, ["dart/tests/lib/direct_aggregate.g.dart"])
    action = action_of(env, target, "DartAggregateCodegen")
    _expect_generator_contract(action, ["lib/direct_aggregate.g.dart", "lib/direct_model.dart"])
    action.argv().contains_predicate(_ends_with("lib/direct_schema.drift|lib/direct_schema.drift"))
    expect_inputs(action, ["*dart/tests/lib/direct_model.dart", "*dart/tests/lib/direct_schema.drift"])

def _dart_sqlcodegen_test(env, target):
    """Asserts the providers and the `DartSqlCodegen` action of `dart_sqlcodegen`."""
    _expect_metadata(env, target)
    expect_default_outputs(env, target, ["dart/tests/lib/direct_schema.drift.dart"])
    action = action_of(env, target, "DartSqlCodegen")
    _expect_generator_contract(action, ["lib/direct_schema.drift.dart", "lib/direct_schema.drift"])
    expect_inputs(action, ["*dart/tests/lib/direct_schema.drift", "*dart/private/tools/noop"])

def codegen_direct_test_suite(name):
    """Declares the direct tests of the three codegen rules.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_codegen(
        name = name + "_codegen_subject",
        src = _MODEL,
        generator_bin = "//dart/private/tools:noop",
        language_version = _LANGUAGE_VERSION,
        output_suffixes = [".g.dart"],
        package_name = _PACKAGE,
        tags = ["manual"],
    )
    dart_aggregate_codegen(
        name = name + "_aggregate_subject",
        srcs = [_MODEL, _SCHEMA],
        generator_bin = "//dart/private/tools:noop",
        language_version = _LANGUAGE_VERSION,
        outputs = ["lib/direct_aggregate.g.dart"],
        package_name = _PACKAGE,
        tags = ["manual"],
    )
    dart_sqlcodegen(
        name = name + "_sql_subject",
        src = _SCHEMA,
        generator_bin = "//dart/private/tools:noop",
        language_version = _LANGUAGE_VERSION,
        output_suffixes = [".drift.dart"],
        package_name = _PACKAGE,
        tags = ["manual"],
    )
    tests = {
        "codegen": _dart_codegen_test,
        "aggregate": _dart_aggregate_codegen_test,
        "sql": _dart_sqlcodegen_test,
    }
    for kind, impl in tests.items():
        analysis_test(
            name = "%s_%s_test" % (name, kind),
            attr_values = {"size": "small"},
            impl = impl,
            target = ":%s_%s_subject" % (name, kind),
        )
    native.test_suite(
        name = name,
        tests = [":%s_%s_test" % (name, kind) for kind in tests],
    )
