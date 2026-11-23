"""Convenience macro for the go_router_builder builder."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "shared_part_library")

visibility("public")

def go_router_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = "@pub_deps//:go_router",
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by the `go_router_builder` builder.

    Generates one `.go_router.g.part` shard per source, merges the shards into
    `<src>.g.dart`, and wraps the sources and the merged output in a `dart_library`.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@TypedGoRoute` annotations. Each one
        gets its own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:go_router`.
      config: Builder options as a JSON string handed to the generator. Defaults to
        empty, which uses the builder's own defaults.
      **kwargs: Further attributes forwarded to the wrapping `dart_library`, such as
        `visibility` or `tags`.
    """
    shared_part_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/go_router:shim",
        part_suffix = ".go_router.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
