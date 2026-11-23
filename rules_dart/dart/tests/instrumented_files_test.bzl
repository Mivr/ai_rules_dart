"""Analysis tests: every rule that owns or forwards Dart sources takes part in `bazel coverage`.

Each case builds a target from `instrumented_files_fixture` and reads the
`InstrumentedFilesInfo` it returns. The provider is built with
`extensions = ["dart"]`, so every instrumented file is a `.dart` file; the
cases name the `.dart` files that must be in the set (the target's own `srcs`
or `main`, a dependency's through `deps`, and `data` where the rule has it) and
a non-Dart file that must stay out.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

visibility(["//dart/..."])

def _instrumented_files_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, InstrumentedFilesInfo in target, "%s returns no InstrumentedFilesInfo" % target.label)
    if InstrumentedFilesInfo not in target:
        return analysistest.end(env)
    files = target[InstrumentedFilesInfo].instrumented_files.to_list()
    names = [f.basename for f in files]
    for name in ctx.attr.expected:
        asserts.true(env, name in names, "%s is not instrumented; got %s" % (name, names))
    for name in ctx.attr.absent:
        asserts.false(env, name in names, "%s must not be instrumented; got %s" % (name, names))
    for f in files:
        asserts.equals(env, "dart", f.extension, "%s is not a Dart source" % f.short_path)
    return analysistest.end(env)

instrumented_files_test = analysistest.make(
    _instrumented_files_test_impl,
    # Instrumented files are only listed when a coverage build asks for them.
    # Test targets are instrumented too, so a `dart_test`'s own files show.
    config_settings = {
        "//command_line_option:collect_code_coverage": True,
        "//command_line_option:instrument_test_targets": True,
        "//command_line_option:instrumentation_filter": "^//dart[/:]",
    },
    attrs = {
        "absent": attr.string_list(
            doc = "Basenames that must not be in the instrumented set.",
        ),
        "expected": attr.string_list(
            doc = "Basenames that must be in the instrumented set.",
            mandatory = True,
        ),
    },
)
