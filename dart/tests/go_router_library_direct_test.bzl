"""Direct `rules_testing` test for the `go_router_library` macro.

`go_router_library` wraps a `dart_library` around two `dart_codegen` targets per source:
one runs the go_router_builder shim and emits the `.go_router.g.part` shard, the other
merges that shard into `<src>.g.dart`. The test pins the wrapping library's
providers and both codegen targets' providers and actions.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/go_router:defs.bzl", "go_router_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_shared_part", "shared_part_targets", "source_of")

visibility(["//dart/..."])

def _go_router_library_test(env, targets):
    """Asserts the providers and the codegen actions `go_router_library` declares."""
    expect_shared_part(env, targets, "go_router", ".go_router.g.part", "*go_router/shim*")

def go_router_library_direct_test_suite(name):
    """Declares the direct test of `go_router_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    go_router_library(
        name = name + "_subject",
        srcs = [source_of("go_router")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _go_router_library_test,
        targets = shared_part_targets(name, "go_router"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
