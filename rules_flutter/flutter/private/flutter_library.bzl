"""Implementation of the flutter_library rule."""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "MODULAR_KERNEL_TOOLCHAINS", "dart_analyzable_info_with_package", "dart_info", "dart_package_identity", "derive_lib_root", "derive_package_name", "native_defines_reset")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_info.bzl", "LINK_HOOK_ATTR", "flutter_info")
load("//flutter/private:flutter_kernel_tools.bzl", "check_library_module_compiler")

visibility(["//flutter/..."])

# Analysis-only: `package:sky_engine`'s `lib/_embedder.yaml` is the only way the
# analyzer resolves `dart:ui`. Reaches `flutter_analyzable_info` alone.
SKY_ENGINE_ATTR = attr.label(
    doc = "Analysis-only: supplies `lib/_embedder.yaml`, the only way the analyzer resolves `dart:ui`.",
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

def flutter_analyzable_info(ctx, package_name, lib_root):
    """The package a Flutter library rule declares, as the analyzer sees it.

    The same package its `DartInfo` records, with `package:sky_engine` added.
    Compilation gets `dart:ui` from the patched SDK; the analyzer resolves it
    only through `sky_engine`'s `lib/_embedder.yaml`, so without this every
    `dart:ui` import is unresolved. `DartInfo` is untouched, so no compile input
    changes, and the analyzer prefers this provider when a target has both.

    Args:
      ctx: The rule context. Reads `deps`, `srcs`, `resources`, `code_assets`,
        `language_version`, `version` and `_sky_engine` (`SKY_ENGINE_ATTR`).
      package_name: The Dart package name the rule's `DartInfo` uses.
      lib_root: The package root the rule's `DartInfo` uses.

    Returns:
      A `DartAnalyzableInfo` whose package map adds `package:sky_engine` to the `DartInfo` one.
    """
    return dart_analyzable_info_with_package(
        label = ctx.label,
        package = dart_package_identity(
            package_name = package_name,
            lib_root = lib_root,
            language_version = ctx.attr.language_version,
            version = ctx.attr.version,
        ),
        deps = ctx.attr.deps + [ctx.attr._sky_engine],
        package_srcs = ctx.files.srcs,
        resources = ctx.files.resources,
        code_assets = ctx.attr.code_assets,
    )

def _flutter_library_impl(ctx):
    """Rule implementation for `flutter_library`."""
    check_library_module_compiler(ctx)
    package_name = derive_package_name(
        ctx.attr.package_name,
        ctx.label.package,
        ctx.label.name,
    )
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # `resources` names the non-Dart remainder of `lib/`; a Dart source there
    # is a mis-filed `srcs` entry, and identical paths with identical
    # extensions would otherwise collide silently. Mirrors `dart_library`.
    for f in ctx.files.resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the non-Dart remainder of `lib/`; Dart sources belong in " +
                 "`srcs`.") % (ctx.label, f.short_path),
            )

    # Both providers are built by their own constructor, and each merges its
    # dependencies' closures itself. This rule states only what a
    # `flutter_library` contributes.
    #
    # `data` is the package's own non-`lib/` files: its `pubspec.yaml`, its
    # licence and the files its pubspec names. An app's asset bundle reads
    # them from where they are, as `flutter build` reads a package's files
    # through the package config.
    #
    # Code assets go on the package record, which is what makes them propagate
    # the way pub does: depending on a package that owns one is enough.
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs + ctx.files.resources),
            runfiles = ctx.runfiles(files = ctx.files.srcs + ctx.files.resources + ctx.files.data),
        ),
        dart_info(
            label = ctx.label,
            package = dart_package_identity(
                package_name = package_name,
                lib_root = lib_root,
                language_version = ctx.attr.language_version,
                version = ctx.attr.version,
                package_files = ctx.files.data,
            ),
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            resources = ctx.files.resources,
            code_assets = ctx.attr.code_assets,
            has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
            link_hook = ctx.file.link_hook,
        ),
        flutter_analyzable_info(ctx, package_name, lib_root),
        flutter_info(deps = ctx.attr.deps),
    ]

# rule_test_coverage: no-actions
flutter_library = rule(
    implementation = _flutter_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Dart source files for this library.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Other `dart_library` or `flutter_library` targets this library depends on.",
            providers = [DartInfo],
        ),
        "data": attr.label_list(
            doc = "The package's own files outside `lib/`: its `pubspec.yaml`, its licence, and " +
                  "the files its pubspec names (assets, fonts, shaders). An app that depends on " +
                  "the package bundles what the pubspec names from these, as `flutter build` " +
                  "does. Runtime-only: they reach no compile action.",
            allow_files = True,
        ),
        "resources": attr.label_list(
            doc = "Non-Dart files this package ships inside `lib/` — part of its published surface, but never compiled. Anything under `lib/` is addressable as `package:<name>/<path>` whatever its extension, so these are members of the package: they ride `DartInfo.transitive_resources` and are staged wherever the whole package is staged (the analyzer's project tree, `dart_test`/`dart_binary` runfiles), mirroring `dart_library`. `.dart` files belong in `srcs`.",
            allow_files = True,
        ),
        "package_name": attr.string(
            doc = "The Dart package name. If omitted, defaults to the last component of the Bazel package path.",
        ),
        "code_assets": attr.label_list(
            doc = "`dart_code_asset` targets standing in for this package's " +
                  "`hook/build.dart` output. Declared on the owning package " +
                  "rather than on the consuming application so they propagate " +
                  "the way pub's own do — depending on the package is enough.",
            providers = [DartCodeAssetInfo],
            cfg = native_defines_reset,
        ),
        "has_unreplaced_hook": attr.string(
            doc = "Path of a build hook this package ships that nothing " +
                  "replaces, or empty. Recorded at repo generation; the " +
                  "application that depends on the package fails on it.",
        ),
        "version": attr.string(
            doc = "The package's own version, as resolved by pub (e.g. `2.2.0`). " +
                  "Set automatically by the generated pub spokes; leave it empty on " +
                  "hand-written targets, which have no resolved version to state. " +
                  "Mirrors `dart_library`'s attribute, and has its one use: when a " +
                  "single package name arrives from two hubs, two records stating " +
                  "different versions fail the build instead of the first one " +
                  "silently standing in for the second. An empty version never " +
                  "conflicts.",
        ),
        "link_hook": LINK_HOOK_ATTR,
        "language_version": attr.string(
            doc = "Dart language version (`<major>.<minor>`) for this package's `package_config.json` entry. Mirrors `dart_library`'s attribute. Empty string means defer to the toolchain default.",
        ),
        "_sky_engine": SKY_ENGINE_ATTR,
    },
    # Optional: only to refuse a Flutter toolchain whose Dart SDK has no module compiler.
    toolchains = [
        config_common.toolchain_type("@rules_flutter//flutter:toolchain_type", mandatory = False),
    ] + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Collects Flutter sources and the package's own files, propagates DartInfo and FlutterInfo. Does not compile.",
)

