"""Direct `rules_testing` test for the `drift_library` macro.

`drift_library` wraps a `dart_library` around drift_dev's staged pipeline: a
`dart_sqlcodegen` stage per `.drift` schema, a `dart_codegen` shard per Dart
source that reads those stages' outputs, and a combining step into
`<src>.g.dart`. The test pins the wrapping library's providers, and the
providers and actions of the schema's first stage, the shard and the combining
step.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/drift:defs.bzl", "drift_library")
load(":ext_direct_helpers.bzl", "LANGUAGE_VERSION", "PACKAGE", "expect_generator", "expect_library", "generator_spec", "shared_part_targets", "source_of")

visibility(["//dart/..."])

# The drift shims resolve `package:drift`, so a stand-in annotation library will not do.
_ANNOTATIONS = "@ext_pub_deps//:drift"
_ANNOTATION_INPUT = "*dart_pub__drift/lib/drift.dart"
_SCHEMA = "lib/ext/drift_schema.drift"
_SOURCE = "lib/ext/drift.dart"

def _expect_prep(env, prep):
    """Asserts the schema's preprocessing stage, a `dart_sqlcodegen` target."""
    outputs = ["lib/ext/drift_schema.drift_prep.json", "lib/ext/drift_schema.expr.temp.dart"]
    spec = generator_spec(_SCHEMA, outputs, "*drift/shim_prep*", "DartSqlCodegen", [_ANNOTATION_INPUT])
    expect_generator(env, prep, spec)

def _expect_shard(env, part):
    """Asserts the shard reads the schema stages' outputs besides its own source."""
    reads = [
        _ANNOTATION_INPUT,
        "*" + _SCHEMA,
        "*lib/ext/drift_schema.drift_prep.json",
        "*lib/ext/drift_schema.drift.drift_elements.json",
    ]
    expect_generator(env, part, generator_spec(_SOURCE, ["lib/ext/drift.drift.g.part"], "*drift/shim_drift*", inputs = reads))

def _drift_library_test(env, targets):
    """Asserts the providers and the codegen actions `drift_library` declares."""
    expect_library(env, targets.library, "drift", [".g.dart"], "drift")
    _expect_prep(env, targets.prep)
    _expect_shard(env, targets.part)
    combined = generator_spec(_SOURCE, ["lib/ext/drift.g.dart"], "*combining_shim/bin*", inputs = ["*lib/ext/drift.drift.g.part"])
    expect_generator(env, targets.combined, combined)

def drift_library_direct_test_suite(name):
    """Declares the direct test of `drift_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    drift_library(
        name = name + "_subject",
        srcs = [source_of("drift")],
        annotation_dep = _ANNOTATIONS,
        drift_srcs = [":" + _SCHEMA],
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        tags = ["manual"],
    )
    targets = shared_part_targets(name, "drift")
    targets["prep"] = ":_%s_subject_lib_ext_drift_schema_drift_prep" % name
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _drift_library_test,
        targets = targets,
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
