"""Spoke repository rule for Flutter SDK packages (package:flutter).

Downloads the Flutter SDK source from GitHub and generates a dart_library
target for the framework. Follows the same hub/spoke pattern as rules_dart's
pub_lock_package, so it integrates seamlessly into the same hub repo.

The framework source tarball is downloaded and extracted once per SDK version
by `flutter_sdk_source_repo`; every spoke (and the gen-l10n repo) reads its
package out of that one extraction instead of unpacking the tarball again.

Like a pub spoke, an SDK spoke declares the language version its own
`environment.sdk` implies, which is what pub writes for these packages too.
Omitting it is not neutral: `package_config.json` reads a missing
`languageVersion` as the current SDK's.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint", "pubspec_sdk_constraint_error")
load("//flutter/private:artifact_urls.bzl", "flutter_source_tarball_url", "require_sha256", "source_strip_prefix")
load("//flutter/private:download.bzl", "pinned_download_and_extract")
load("//flutter/private:flutter_sky_engine_repo.bzl", "list_local_files")
load("//flutter/private:local_sdk.bzl", "link_local_dir", "link_local_file", "resolve_local_sdk_root")
load("//flutter/private:repo_metadata.bzl", "download_mode_metadata")

visibility(["//flutter/..."])

def make_flutter_sdk_build_content(name, deps, language_version):
    """Generate BUILD content for a Flutter SDK spoke.

    The "flutter" package uses flutter_library (not dart_library) so that
    its shader source files are propagated transitively via FlutterInfo.
    Other SDK packages (flutter_test, etc.) use plain dart_library.

    Both branches partition lib/ into `srcs` + `resources`, the same shape
    rules_dart's pub spokes use: everything under lib/ is addressable as
    `package:<name>/<path>` whatever its extension (package:flutter ships
    lib/analysis_options.yaml and lib/fix_data/*.yaml), so the non-Dart
    remainder rides `DartInfo.transitive_resources` rather than being
    dropped. The ink_sparkle .frag appears on both channels by design:
    `shaders` routes it through the impellerc compile into flutter_assets,
    `resources` keeps it a member of the staged package tree.

    Args:
        name: Package name (also the target name).
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.11"`), or
            `""` when no pubspec was read. An empty string reaches the
            generated target as `language_version = ""`, which is what makes
            the `languageVersion` key absent from `package_config.json`
            entries downstream.

    Returns:
        BUILD.bazel content as a string.
    """
    deps_block = ""
    if deps:
        dep_lines = ['        "{}",'.format(dep) for dep in deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    if name == "flutter":
        return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"]),
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
    shaders = glob(["lib/src/material/shaders/*.frag"]),
{deps}    package_name = "{name}",
    language_version = "{language_version}",
    visibility = ["//visibility:public"],
)
""".format(
            name = name,
            deps = deps_block,
            language_version = language_version,
        )

    return """\
load("@rules_dart//dart:defs.bzl", "dart_library")

dart_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"]),
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
{deps}    package_name = "{name}",
    language_version = "{language_version}",
    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        deps = deps_block,
        language_version = language_version,
    )

def copy_sdk_package_from_source(repository_ctx, package_name):
    """Stages `lib/` and `pubspec.yaml` as repo-owned copies from `sdk_source`.

    Args:
        repository_ctx: The repository rule context.
        package_name: The SDK package name under `packages/`.
    """
    source_root = repository_ctx.path(repository_ctx.attr.sdk_source).dirname
    pubspec_src = source_root.get_child("packages/{}/pubspec.yaml".format(package_name))
    if not pubspec_src.exists:
        fail("{}: the Flutter {} source has no packages/{}/pubspec.yaml".format(
            repository_ctx.name,
            repository_ctx.attr.flutter_version,
            package_name,
        ))
    repository_ctx.file("pubspec.yaml", repository_ctx.read(pubspec_src), executable = False)
    lib_src = source_root.get_child("packages/{}/lib".format(package_name))
    if not lib_src.exists:
        fail("{}: the Flutter {} source has no packages/{}/lib".format(
            repository_ctx.name,
            repository_ctx.attr.flutter_version,
            package_name,
        ))
    what = "the {} package sources".format(package_name)
    for rel in list_local_files(lib_src, what, str(lib_src)):
        repository_ctx.file(
            "lib/" + rel,
            repository_ctx.read(lib_src.get_child(rel)),
            executable = False,
        )

def _flutter_sdk_package_impl(repository_ctx):
    package_name = repository_ctx.attr.package_name

    if getattr(repository_ctx.attr, "local_path", ""):
        # The spoke root is the package directory itself (the download mode
        # strips the tarball to it). Only `lib/` and the pubspec are linked:
        # they are everything the spoke BUILD below consumes, and linking the
        # whole directory would drag in per-package tooling the build never
        # references. Both links are watched, so SDK edits invalidate the
        # repository.
        sdk_root = resolve_local_sdk_root(repository_ctx, getattr(repository_ctx.attr, "local_path", ""))
        pkg_rel = "packages/" + package_name
        link_local_dir(
            repository_ctx,
            sdk_root,
            pkg_rel + "/lib",
            "lib",
            "the {} package sources".format(package_name),
        )
        link_local_file(
            repository_ctx,
            sdk_root,
            pkg_rel + "/pubspec.yaml",
            "pubspec.yaml",
            "the {} package pubspec".format(package_name),
        )
    else:
        # The package comes out of the version's one shared extraction (see
        # `flutter_sdk_source_repo`), staged as repo-owned copies so the spoke
        # holds no symlink into another repository and can share one entry in
        # the repo contents cache across output bases.
        copy_sdk_package_from_source(repository_ctx, package_name)

    # Discover deps and the language version from the spoke pubspec.yaml,
    # filtering deps to packages available in the lock file (same pattern as
    # pub_lock_package). Both modes always stage the pubspec (the local fetch
    # links it, the download extracts it), so it is always read here.
    bazel_deps = []
    language_version = ""
    pubspec_path = repository_ctx.path("pubspec.yaml")
    if pubspec_path.exists:
        content = repository_ctx.read(pubspec_path)
        sdk_err = pubspec_sdk_constraint_error(content, package_name + "/pubspec.yaml")
        if sdk_err:
            fail(sdk_err)
        all_deps = parse_pubspec_deps(content)
        available = {p: True for p in repository_ctx.attr.lock_packages}
        bazel_deps = sorted([d for d in all_deps if d in available])
        language_version = derive_language_version(
            parse_pubspec_sdk_constraint(content),
        )

    # Build dep labels pointing to sibling spoke repos (or merged SCC targets).
    scc_targets = repository_ctx.attr.scc_targets if hasattr(repository_ctx.attr, "scc_targets") else {}
    dep_labels = [
        scc_targets[dep] if dep in scc_targets else "@{hub}__{dep}//:{dep}".format(
            hub = repository_ctx.attr.hub_name,
            dep = dep,
        )
        for dep in bazel_deps
    ]

    repository_ctx.file("BUILD.bazel", make_flutter_sdk_build_content(
        name = package_name,
        deps = dep_labels,
        language_version = language_version,
    ))

    # Emit an empty `android/BUILD.bazel` so the hub's aggregator
    # (`@<hub>//android:all_android_plugin_libs`) can depend on every
    # spoke uniformly, including SDK-provided packages like
    # `package:flutter` and `package:flutter_test`. Loaded lazily — only
    # parsed when something queries `@<spoke>//android:lib`, so non-Android
    # workspaces never pay the `@rules_kotlin` cost.
    repository_ctx.file("android/BUILD.bazel", """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

kt_android_library(
    name = "lib",
    srcs = [],
    visibility = ["//visibility:public"],
)
""")

    return download_mode_metadata(repository_ctx)

flutter_sdk_package = repository_rule(
    implementation = _flutter_sdk_package_impl,
    doc = "Downloads a Flutter SDK package (e.g. package:flutter) and generates a dart_library target.",
    attrs = {
        "flutter_version": attr.string(
            doc = "Flutter SDK version, for error messages. Empty means a local " +
                  "SDK (with `local_path`).",
            default = "",
        ),
        "package_name": attr.string(
            doc = "The package name within the Flutter SDK (e.g. 'flutter', 'flutter_test').",
            mandatory = True,
        ),
        "sdk_source": attr.label(
            doc = "The `flutter_sdk_source_repo` extraction of this version " +
                  "(its `BUILD.bazel`), shared by every spoke. Unused with " +
                  "`local_path`.",
            allow_single_file = True,
        ),
        "local_path": attr.string(
            doc = "Optional path to a pre-extracted Flutter SDK " +
                  "(bin/cache layout) to source every artifact from instead " +
                  "of the network. Mutually exclusive with downloading.",
            default = "",
        ),
        "hub_name": attr.string(
            doc = "Name of the hub repo (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All package names in the lock file (for dep filtering).",
            default = [],
        ),
        "scc_targets": attr.string_dict(
            doc = "Package name to merged repository target, for dependencies on cycle members.",
            default = {},
        ),
    },
)

def _flutter_sdk_source_repo_impl(repository_ctx):
    version = repository_ctx.attr.flutter_version
    url = repository_ctx.attr.source_url or flutter_source_tarball_url(version)
    strip_prefix = repository_ctx.attr.source_strip_prefix or "flutter-{}/".format(version)

    # The one extraction of the version's tarball: `packages/` only, which
    # holds every SDK package spoke and flutter_tools (gen-l10n). The
    # content-addressed repository cache shares the download; this rule is what
    # shares the extraction.
    pinned_download_and_extract(
        repository_ctx,
        url = url,
        sha256 = require_sha256(repository_ctx.attr.sha256, url),
        output = "packages",
        stripPrefix = strip_prefix + "packages",
    )
    repository_ctx.file("BUILD.bazel", "# Generated by flutter_sdk_package.bzl\n")
    return repository_ctx.repo_metadata(reproducible = True)

flutter_sdk_source_repo = repository_rule(
    implementation = _flutter_sdk_source_repo_impl,
    doc = "Downloads and extracts the packages/ tree of one Flutter SDK source tarball, once.",
    attrs = {
        "flutter_version": attr.string(doc = "Flutter SDK version tag on GitHub.", mandatory = True),
        "sha256": attr.string(
            doc = "Expected SHA-256 of the source tarball, guaranteed non-empty by the caller " +
                  "(`flutter_source_sha256()` refuses a version with no recorded checksum).",
            mandatory = True,
        ),
        "source_url": attr.string(
            doc = "Optional replacement framework source tarball URL from a custom " +
                  "`flutter.version` registration. Empty means the default GitHub tag tarball.",
            default = "",
        ),
        "source_strip_prefix": attr.string(
            doc = "Top-level directory the source tarball extracts to. Empty means `flutter-{version}/`.",
            default = "",
        ),
    },
)

def declare_sdk_source(toolchain_name, flutter_version, sha256, source_url, rule = flutter_sdk_source_repo):
    """Declares the one shared source repository of a downloaded SDK version.

    Args:
        toolchain_name: The toolchain registration name (`flutter`).
        flutter_version: The Flutter SDK version.
        sha256: The source tarball checksum, from `flutter_source_sha256()`.
        source_url: The custom source tarball URL, or `""`.
        rule: The repository rule to declare; replaceable so a test can count
            the extractions without fetching.

    Returns:
        The label string spokes and gen-l10n use to find the extraction.
    """
    name = toolchain_name + "_sdk_source"
    rule(
        name = name,
        flutter_version = flutter_version,
        sha256 = sha256,
        source_url = source_url,
        source_strip_prefix = source_strip_prefix(flutter_version, source_url),
    )
    return "@{}//:BUILD.bazel".format(name)

def declare_sdk_spokes(plan, packages, sdk, rule = flutter_sdk_package):
    """Declares one `flutter_sdk_package` spoke per SDK package.

    None of them unpacks a tarball: a downloaded version's spokes link into
    the `declare_sdk_source` extraction (`sdk.source_label`), a local SDK's
    into the local tree.

    Args:
        plan: The hub plan, with `hub_name`, `all_package_names`, `scc_targets`.
        packages: The SDK package names that get a spoke.
        sdk: Struct with `version`, `local_path` and `source_label`
            (empty for a local SDK).
        rule: The repository rule to declare; replaceable for tests.
    """
    for name in packages:
        rule(
            name = plan.hub_name + "__" + name,
            package_name = name,
            flutter_version = sdk.version,
            local_path = sdk.local_path,
            sdk_source = sdk.source_label or None,
            hub_name = plan.hub_name,
            lock_packages = plan.all_package_names,
            scc_targets = plan.scc_targets,
        )
