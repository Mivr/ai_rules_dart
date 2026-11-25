"""Helper functions for `flutter.pub` package and spoke generation.

Extracted helpers for pubspec identity validation, the `data` a spoke lists
for the files its pubspec names, and `package:test` runner wrappers.
"""

load(
    "//flutter/private:flutter_pub_semver.bzl",
    "parse_pub_version",
    "pub_version_text",
)
load("//flutter/private:starlark_literal.bzl", "starlark_string_literal")

visibility(["//flutter/..."])

# The package's own files an app's asset bundle reads, besides what its
# pubspec names and `lib/` (the spoke's `srcs` and `resources`, which an
# app's `packages/<name>/...` entry reaches through the package config): the
# pubspec, and the licence `NOTICES` collects (the tool reads `NOTICES`, else
# `LICENSE`, at the package root).
_SPOKE_PACKAGE_FILES = ["pubspec.yaml", "LICENSE*", "NOTICES"]

# What a spoke's `data` leaves out: its own BUILD files, `lib/` (its `srcs`
# and `resources`), and names no label can hold (`glob` would return them and
# the spoke would fail to load).
_SPOKE_DATA_EXCLUDE = [
    "BUILD.bazel",
    "REPO.bazel",
    "lib/**",
    "**/*:*",
    "**/*:*/**",
    "**/*\\*",
    "**/*\\*/**",
]

def spoke_data_patterns(roots):
    """The glob patterns of the files a spoke offers an app's asset bundle, for its `data`.

    The Flutter tool finds a named file, its variants, a directory's files and
    a shader's includes itself, as `flutter build` does; the spoke lists the
    directories they live in (`pubspec_file_roots`), a top-level file with its
    variants (`*/<name>`), or the whole package.

    Args:
        roots: The package's `pubspec_file_roots`.

    Returns:
        The sorted, deduplicated patterns.
    """
    if roots.whole:
        return ["**"]
    patterns = {p: True for p in _SPOKE_PACKAGE_FILES}
    for directory in roots.dirs:
        patterns[directory + "/**"] = True
    for name in roots.files:
        patterns[name] = True
        patterns["*/" + name] = True
    return sorted(patterns.keys())

def format_spoke_data_attr(patterns):
    """The `data` attribute of a spoke, globbing `patterns`.

    Args:
        patterns: Patterns from `spoke_data_patterns`.

    Returns:
        The attribute's BUILD lines.
    """
    lines = ["        " + starlark_string_literal(p) + "," for p in patterns]
    exclude = ["        " + starlark_string_literal(p) + "," for p in _SPOKE_DATA_EXCLUDE]
    return "    data = glob(\n        [\n{}\n        ],\n        allow_empty = True,\n        exclude = [\n{}\n        ],\n    ),\n".format("\n".join(lines), "\n".join(exclude))

def parse_pubspec_identity(pubspec):
    """The `(name, version)` identity a path spoke verifies against its lock entry.

    A path package's overlays and hook settings are selected by the
    lock key and the lock's version, so the spoke must check that the
    package's own pubspec.yaml agrees — otherwise a directory whose
    pubspec names another package, or whose version moved since the lock
    was resolved, gets another package's overlay and native code assets.

    A pubspec with no `version:` field (or an empty one) reads as
    `"0.0.0"` — exactly how `pub get` locks it (pub's `Version.none`), so
    unversioned `publish_to: none` packages agree with the lock. The
    comparison itself is semantic (see `parse_pub_version`): quoting,
    surrounding whitespace and the YAML scalar type do not matter.

    Args:
        pubspec: The decoded pubspec.yaml mapping (`{}` when there is none).

    Returns:
        A `struct(name, version)` of strings; the name is `""` when
        absent or empty, and the version is `"0.0.0"` when unstated. A
        missing pubspec therefore never matches a lock key and fails closed
        at the caller's comparison.
    """
    name = pubspec.get("name", "")
    version = pub_version_text(pubspec.get("version", ""))
    return struct(
        name = "" if name == None else str(name),
        version = "0.0.0" if version == "" else version,
    )

def missing_pubspec_refusal(hub_name, package_name):
    """The fetch refusal for a path package with no readable pubspec name.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub and the lock key.

    Args:
        hub_name: Name of the pub hub being fetched, shown in the message.
        package_name: Lock key of the path package lacking a readable pubspec.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" has no readable pubspec.yaml naming the " +
        "package. Overlays and code assets are selected by lock name; " +
        "re-resolve the lock so the package carries a pubspec that " +
        "agrees with it."
    )

def pubspec_name_refusal(hub_name, package_name, actual):
    """The fetch refusal for a path package whose pubspec names another package.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub, the lock key, and both values.

    Args:
        hub_name: Name of the pub hub being fetched, shown in the message.
        package_name: Lock key of the path package.
        actual: Package name found in the pubspec.yaml.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" names itself \"" + actual + "\" in its " +
        "pubspec.yaml but the lock calls it \"" + package_name + "\". " +
        "Overlays and code assets are selected by lock name; re-resolve " +
        "the lock (or rename the package) so the two agree."
    )

def pubspec_version_refusal(hub_name, package_name, locked, actual):
    """The fetch refusal for a path package whose version moved since the lock.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub, the lock key, and both values.
    A pubspec with no `version:` field reads as `0.0.0` (the way `pub get`
    locks it), so an unversioned package shows `0.0.0` on the pubspec side
    here when the lock moved on.

    Args:
        hub_name: Name of the pub hub being fetched, shown in the message.
        package_name: Lock key of the path package.
        locked: Version recorded in the lock entry.
        actual: Version found in the pubspec.yaml.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" locks version \"" + locked + "\" but its " +
        "pubspec.yaml says \"" + actual + "\" (a pubspec with no " +
        "`version:` field reads as \"0.0.0\", the way `pub get` locks " +
        "it). Overlays and code assets are selected by lock version; " +
        "re-resolve the lock so the two agree."
    )

def malformed_pub_version_refusal(hub_name, package_name, bad_value):
    """The fetch refusal for a path package with an unparsable version.

    Either side can be bad: the lock entry or the package's own pubspec.
    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub, the lock key, and the bad value.

    Args:
        hub_name: Name of the pub hub being fetched, shown in the message.
        package_name: Lock key of the path package.
        bad_value: The version string that failed to parse.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" has malformed version \"" + bad_value + "\" " +
        "in its pubspec.yaml or the lock entry. Versions are " +
        "major.minor.patch with optional -pre-release and +build (a " +
        "pubspec with no `version:` field reads as \"0.0.0\"); fix the " +
        "version or re-resolve the lock."
    )

def check_pubspec_identity_mismatch(hub_name, package_name, lock_version, pubspec):
    """Fail when the package's pubspec name or version disagrees with the lock.

    Overlays and hook settings are selected by the lock key and the
    lock's version, so a directory whose pubspec names another package, or
    whose version moved since the lock was resolved, must not silently get
    another package's overlay and native code assets. Each mismatch fails
    naming the hub, the lock key, and both values, telling the user to
    re-resolve. The two versions compare as parsed semantic versions (a
    missing pubspec version reads as `0.0.0`, like `pub get` locks it); an
    unparsable version on either side fails naming the bad value.

    Args:
        hub_name: The name of the pub hub.
        package_name: The expected package name from the lockfile.
        lock_version: The locked version string.
        pubspec: The decoded pubspec.yaml mapping (`{}` when there is none).
    """
    identity = parse_pubspec_identity(pubspec)
    if not identity.name:
        fail(missing_pubspec_refusal(hub_name, package_name))
    if identity.name != package_name:
        fail(pubspec_name_refusal(hub_name, package_name, identity.name))
    locked = parse_pub_version(lock_version)
    if not locked.ok:
        fail(malformed_pub_version_refusal(hub_name, package_name, locked.text))
    actual = parse_pub_version(identity.version)
    if not actual.ok:
        fail(malformed_pub_version_refusal(hub_name, package_name, actual.text))
    if actual.canonical != locked.canonical:
        fail(pubspec_version_refusal(hub_name, package_name, locked.text, actual.text))

def make_flutter_test_package_bzl_content(forward_flutter_providers = False, ctx = None):
    """Generates `flutter_test_package.bzl` content for a `package:test` spoke.

    Args:
        forward_flutter_providers: When True (merged SCC spokes), forwards
            `DartKernelInfo`, `DartAnalyzableInfo`, and `FlutterInfo` from
            `library` when present. When False (single-package spokes),
            preserves the exact single-package spoke content.
        ctx: The repository or module context. Unused now that
            `DartTestRunnerInfo` and `DartTestRunnerSnapshotInfo` are exported
            on `@rules_dart//dart:providers.bzl`.

    Returns:
        The Starlark source string for `flutter_test_package.bzl`.
    """
    _ = ctx
    if forward_flutter_providers:
        providers_load = (
            'load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", ' +
            '"DartInfo", "DartKernelInfo", "DartTestRunnerInfo", ' +
            '"DartTestRunnerSnapshotInfo")'
        )
    else:
        providers_load = (
            'load("@rules_dart//dart:providers.bzl", "DartInfo", ' +
            '"DartTestRunnerInfo", "DartTestRunnerSnapshotInfo")'
        )
    extra_load = (
        '\nload("@rules_flutter//flutter:providers.bzl", "FlutterInfo")' if forward_flutter_providers else ""
    )
    return_block = """\
    providers = [
        library[DefaultInfo],
        library[DartInfo],
        DartTestRunnerInfo(runner = runner),
    ]
    for p in (DartKernelInfo, DartAnalyzableInfo, FlutterInfo):
        if p in library:
            providers.append(library[p])
    return providers""" if forward_flutter_providers else """\
    return [
        library[DefaultInfo],
        library[DartInfo],
        DartTestRunnerInfo(runner = runner),
    ]"""
    return """\
{providers_load}{extra_load}

def _flutter_test_package_impl(ctx):
    library = ctx.attr.library
    dills = [f for f in ctx.attr.runner[DefaultInfo].files.to_list() if f.extension == "dill"]
    if len(dills) != 1:
        fail("%s: `runner` must produce exactly one `.dill`, got %s" % (ctx.label, dills))
    runner = dills[0]
    if ctx.attr.snapshot != None:
        snapshot = ctx.attr.snapshot[DartTestRunnerSnapshotInfo].snapshot
        if snapshot != None:
            runner = snapshot
{return_block}

flutter_test_package = rule(
    implementation = _flutter_test_package_impl,
    attrs = {{
        "library": attr.label(
            doc = "The `package:test` `dart_library`.",
            mandatory = True,
            providers = [DartInfo],
        ),
        "runner": attr.label(
            doc = "A kernel-mode `dart_binary` built from `library`.",
            mandatory = True,
        ),
        "snapshot": attr.label(
            doc = (
                "A `dart_test_runner_snapshot` of `runner`. Its snapshot " +
                "runs in place of the kernel when one was built."
            ),
            providers = [DartTestRunnerSnapshotInfo],
        ),
    }},
    doc = "`package:test` as a dependency, carrying the runner built from it.",
)
""".format(
        providers_load = providers_load,
        extra_load = extra_load,
        return_block = return_block,
    )
