"""Convenience macro for the mockito builder.

mockito's `@GenerateMocks` typically lives in test files and generates
`<file>.mocks.dart` directly (no SharedPart shards). Any types being
mocked (`MockFoo`) must live in a `dart_library` passed via `deps` so the
Resolver can read them.
"""

load("@rules_dart//dart/ext/_shared:defs.bzl", "library_builder_library")

visibility("public")

def mockito_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = "@pub_deps//:mockito",
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by the `mockito` builder.

    Generates `<src>.mocks.dart` beside each source with one codegen action per source,
    and wraps the sources and the generated files in a `dart_library`. The types being
    mocked must come from a `dart_library` in `deps` so the generator can resolve them.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@GenerateMocks` annotations. Each one
        gets its own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:mockito`.
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
        shim = "@rules_dart//dart/ext/mockito:shim",
        output_suffixes = [".mocks.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
