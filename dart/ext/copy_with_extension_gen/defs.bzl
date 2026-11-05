"""Convenience macro for the copy_with_extension_gen builder."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "shared_part_library")

visibility("public")

def copy_with_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = "@pub_deps//:copy_with_extension",
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by the `copy_with_extension_gen` builder.

    Generates one `.copy_with_extension_gen.g.part` shard per source, merges the shards
    into `<src>.g.dart`, and wraps the sources and the merged output in a
    `dart_library`.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@CopyWith` annotations. Each one gets
        its own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:copy_with_extension`.
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
        shim = "@rules_dart//dart/ext/copy_with_extension_gen:shim",
        part_suffix = ".copy_with_extension_gen.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
