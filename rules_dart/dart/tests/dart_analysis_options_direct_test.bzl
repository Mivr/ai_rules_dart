"""Direct `rules_testing` test for `dart_analysis_options`.

The rule registers no action: it bundles an options file with the packages its
`include:` directives resolve against. The test pins what it publishes: the file
as its only default output, the `DartAnalysisOptionsInfo` carrying that file and
the `deps` closure, and no `DartInfo` — the ruleset must never reach an analyzed
library's closure.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "subjects")
load("//dart:defs.bzl", "dart_analysis_options", "dart_library")
load("//dart:providers.bzl", "DartAnalysisOptionsInfo", "DartInfo")
load(":truth_helpers.bzl", "expect_default_outputs", "package_names", "provider_of", "short_path_subject")

visibility(["//dart/..."])

_OPTIONS = ":direct_options/analysis_options.yaml"
_ATTRS = {
    "file": short_path_subject,
    "packages": package_names,
    "transitive_srcs": subjects.depset_file,
    "transitive_resources": subjects.depset_file,
}

def _dart_analysis_options_test(env, target):
    """Asserts the providers `dart_analysis_options` publishes."""
    expect_default_outputs(env, target, ["dart/tests/direct_options/analysis_options.yaml"])
    options = provider_of(env, target, DartAnalysisOptionsInfo, "DartAnalysisOptionsInfo", _ATTRS)
    options.file().equals("dart/tests/direct_options/analysis_options.yaml")
    options.packages().contains_exactly(["direct_ruleset"])
    options.transitive_srcs().contains_exactly(["dart/tests/lib/direct_model.dart"])
    options.transitive_resources().contains_exactly([])
    env.expect.that_bool(DartInfo in target, "DartInfo published").equals(False)

def dart_analysis_options_direct_test_suite(name):
    """Declares the direct test of `dart_analysis_options`.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_library(
        name = name + "_ruleset",
        srcs = [":lib/direct_model.dart"],
        package_name = "direct_ruleset",
        tags = ["manual"],
    )
    dart_analysis_options(
        name = name + "_subject",
        src = _OPTIONS,
        tags = ["manual"],
        deps = [":" + name + "_ruleset"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _dart_analysis_options_test,
        target = ":" + name + "_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
