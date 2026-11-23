"""Convenience macros for stacked_generator's six LibraryBuilders.

Each macro wires one of stacked_generator's sub-builders (`router`,
`locator`, `form`, `logger`, `dialog`, `bottomsheet`) through the
`library_builder_library` helper. The `@StackedApp` annotation triggers
five of the six (all except `form`, which uses `@FormView`); Gazelle
emits the corresponding macros per registered sub-builder.
"""

load("@rules_dart//dart/ext/_shared:defs.bzl", "library_builder_library")

visibility("public")

_DEFAULT_RUNTIME_DEP = "@pub_deps//:stacked"

def stacked_router_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by `stackedRouterGenerator`.

    Generates `<src>.router.dart` beside each source with one codegen action per source,
    and wraps the sources and the generated files in a `dart_library`.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@StackedApp` routes. Each one gets its
        own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:stacked`.
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
        shim = "@rules_dart//dart/ext/stacked:shim_router",
        output_suffixes = [".router.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_locator_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by `stackedLocatorGenerator`.

    Generates `<src>.locator.dart` beside each source with one codegen action per
    source, and wraps the sources and the generated files in a `dart_library`.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@StackedApp` dependencies. Each one
        gets its own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:stacked`.
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
        shim = "@rules_dart//dart/ext/stacked:shim_locator",
        output_suffixes = [".locator.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_form_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by `stackedFormGenerator`.

    Generates `<src>.form.dart` beside each source with one codegen action per source,
    and wraps the sources and the generated files in a `dart_library`.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@FormView` annotations. Each one gets
        its own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:stacked`.
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
        shim = "@rules_dart//dart/ext/stacked:shim_form",
        output_suffixes = [".form.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_logger_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by `stackedLoggerGenerator`.

    Generates `<src>.logger.dart` beside each source with one codegen action per source,
    and wraps the sources and the generated files in a `dart_library`.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@StackedApp` loggers. Each one gets its
        own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:stacked`.
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
        shim = "@rules_dart//dart/ext/stacked:shim_logger",
        output_suffixes = [".logger.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_dialog_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by `stackedDialogGenerator`.

    Generates `<src>.dialogs.dart` beside each source with one codegen action per
    source, and wraps the sources and the generated files in a `dart_library`.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@StackedApp` dialogs. Each one gets its
        own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:stacked`.
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
        shim = "@rules_dart//dart/ext/stacked:shim_dialog",
        output_suffixes = [".dialogs.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )

def stacked_bottomsheet_library(
        name,
        srcs,
        package_name = "",
        language_version = "",
        deps = [],
        annotation_dep = _DEFAULT_RUNTIME_DEP,
        config = "",
        **kwargs):
    """Declares a `dart_library` completed by `stackedBottomsheetGenerator`.

    Generates `<src>.bottomsheets.dart` beside each source with one codegen action per
    source, and wraps the sources and the generated files in a `dart_library`.

    Args:
      name: Name of the wrapping `dart_library` target; the per-source codegen targets
        derive their names from it.
      srcs: The `.dart` source files that carry `@StackedApp` bottom sheets. Each one
        gets its own codegen action.
      package_name: Dart package name, matching the consumer's `pubspec.yaml` `name:`.
        Defaults to the last component of the Bazel package path.
      language_version: Dart language version of the package in `<major>.<minor>` form.
        Defaults to empty, which leaves the version unstated, as for a hand-written
        `dart_library`.
      deps: Additional `dart_library` targets the sources import. The annotation
        dependency is added automatically. Defaults to none.
      annotation_dep: Label of the runtime annotation library the sources import; it is
        added to `deps`. Defaults to `@pub_deps//:stacked`.
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
        shim = "@rules_dart//dart/ext/stacked:shim_bottomsheet",
        output_suffixes = [".bottomsheets.dart"],
        annotation_dep = annotation_dep,
        deps = deps,
        config = config,
        **kwargs
    )
