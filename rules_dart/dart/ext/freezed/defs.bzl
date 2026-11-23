"""Convenience macro for the freezed builder (produces `<src>.freezed.dart`)."""

load("@rules_dart//dart/ext/_shared:defs.bzl", "library_builder_library")

visibility("public")

def freezed_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = "@pub_deps//:freezed_annotation",
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by the `freezed` builder.

    Generates `<src>.freezed.dart` beside each source with one codegen action per
    source, and wraps the sources and the generated files in a `dart_library`.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@freezed` annotations. Each one gets
        its own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:freezed_annotation`.
      config: Builder options as a JSON string handed to the generator. Defaults to
        empty, which uses the builder's own defaults.
      **kwargs: Further attributes forwarded to the wrapping `dart_library`, such as
        `visibility` or `tags`.
    """
    library_builder_library(
        name = name,
        srcs = srcs,
        package_name = package_name,
        language_version = language_version,
        shim = "@rules_dart//dart/ext/freezed:shim",
        output_suffixes = [".freezed.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
