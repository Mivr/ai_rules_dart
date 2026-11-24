"""The BUILD file shape every pub spoke repository carries.

`pub.package()` and `pub.from_lock()` each materialise a pub.dev package as
its own repository holding a single `dart_library`. Both emit that target
through the one generator here, so a field added to the shape reaches both
paths instead of only the one whose template was edited.
"""

visibility(["//dart/..."])

_LOAD = 'load("@rules_dart//dart:defs.bzl", "dart_library")\n'

# The one text every `package_files` attribute uses. The hosted, git and
# explicit repository rules, and the `pub.package` tag, all state the same
# three facts — the default, the opt-in and the opt-out — so they say it once
# here rather than drifting five near-copies apart.
PACKAGE_FILES_ATTR_DOC = """\
Glob patterns for a package's non-`lib/` runtime files, emitted as the generated \
`dart_library`'s `data` and carried to every consumer's runfiles. Defaults to `pubspec.yaml` and \
`LICENSE*` at the package root. Pass a broader list (`["assets/**"]`, say) to opt in to more \
files, or `[]` to opt out. The emitted glob always excludes `lib/**`, `BUILD*` and `WORKSPACE*`.\
"""

_TEST_LIBRARY = "test_library"

_TEST_RUNNER_LOAD = """\
load("@rules_dart//dart:defs.bzl", "dart_binary")
load(
    "@rules_dart//dart:utils.bzl",
    "dart_test_kernel",
    "dart_test_package",
    "dart_test_runner_main",
    "dart_test_runner_snapshot",
)
"""

# `package:test`'s spoke also builds the runner `dart_test` runs tests through,
# from this same package, so the two can never be different versions. Built
# once here and shared by every test that depends on `package:test`. The
# snapshot is trained on `runner_training_test.dart`, compiled against this same
# `package:test`.
_TEST_RUNNER_BLOCK = """\
dart_test_runner_main(name = "test_runner_main")

dart_binary(
    name = "test_runner",
    compile_mode = "kernel",
    main = ":test_runner_main",
    deps = [":{library}"],
)

dart_test_kernel(
    name = "runner_training",
    main = "@rules_dart//dart/private/tools:runner_training_test.dart",
    deps = [":{library}"],
)

dart_test_runner_snapshot(
    name = "test_runner_snapshot",
    runner = ":test_runner",
    training = ":runner_training",
)

dart_test_package(
    name = "test",
    library = ":{library}",
    runner = ":test_runner",
    snapshot = ":test_runner_snapshot",
    visibility = ["//visibility:public"],
)
""".format(library = _TEST_LIBRARY)

def build_yaml_target(name):
    """The name of the file group holding a package's `build.yaml`.

    Every package repository carries it, empty when the package has no
    `build.yaml`, so a hub can name the `build.yaml` of any package without
    knowing whether it exists.

    Args:
      name: The package name.

    Returns:
      The target name, `<name>.build_yaml`.
    """
    return name + ".build_yaml"

def _build_yaml_block(name):
    return """
filegroup(
    name = "{target}",
    srcs = glob(["build.yaml"], allow_empty = True),
    visibility = ["//visibility:public"],
)
""".format(target = build_yaml_target(name))

def _package_files_block(package_files):
    """Renders the `data` glob for a package's non-`lib/` runtime files.

    Empty means the package opted out (`package_files = []`), so no `data`
    attribute is written at all — writing an empty one would be the same
    build, but the absence states the opt-out plainly in the generated file.
    The excludes keep a broad opt-in glob from swallowing the sources or the
    repository files Bazel generates and reads itself.

    Args:
      package_files: The glob patterns a spoke's `dart_library.data` takes.

    Returns:
      BUILD-file text for the `data` attribute, or "" when there is none.
    """
    if not package_files:
        return ""
    patterns = ", ".join(['"{}"'.format(p) for p in package_files])
    return (
        "    data = glob(\n" +
        "        [{}],\n".format(patterns) +
        '        exclude = ["lib/**", "BUILD*", "WORKSPACE*"],\n' +
        "        allow_empty = True,\n" +
        "    ),\n"
    )

def make_dart_library_build_content(
        name,
        deps,
        language_version,
        version = "",
        package_files = ["pubspec.yaml", "LICENSE*"],
        hooks = ""):
    """Generate the BUILD.bazel content for a single `dart_library` spoke.

    The shape — `srcs = glob(["lib/**/*.dart"], allow_empty = True)`, the
    non-Dart remainder of `lib/` as `resources`, a `package_name` matching the
    target name, public visibility, optional deps block — is the canonical
    pub-spoke layout. Resource-only and Swift-only/Kotlin-only Flutter platform
    packages produce empty source globs but must still resolve as labels, hence
    `allow_empty`.

    The two globs partition `lib/` rather than covering only the Dart half of
    it. A published package's `lib/` is addressable as `package:<name>/<path>`
    whatever the extension, so a spoke that keeps only `*.dart` is a package
    with pieces missing — `dwds` without the client JavaScript it serves,
    `lints` without the YAML every `analysis_options.yaml` includes. Whatever
    a future package ships lands in one of the two globs, so nothing is
    dropped for being unanticipated.

    Args:
        name: Target name (also the `package_name` for the dart_library).
        deps: List of fully-qualified Bazel label strings for sibling spokes
            (e.g. `"@hub__dep//:dep"`). Pass an empty list for no deps.
        language_version: Dart language version string (e.g. `"3.0"`),
            usually derived from the package's pubspec SDK constraint via
            `derive_language_version`.
        version: The resolved package version this spoke was fetched at, or
            empty. A trailing keyword with a default because this helper is
            re-exported for rule sets outside //dart/pub — notably
            rules_flutter's `flutter_pub_package` — whose existing calls must
            keep working; a spoke that omits it simply states no version, and
            an unstated version never conflicts with a stated one.
        package_files: Glob patterns for the package's non-`lib/` runtime
            files, emitted as the generated `dart_library`'s `data`. The
            default is deliberately small — `pubspec.yaml` and `LICENSE*` at
            the package root — because every pattern here multiplies every
            dependent test's runfiles tree across hundreds of spokes. Pass a
            broader list to opt in to more files (`["assets/**"]`, say), or
            `[]` to opt out. The emitted glob always excludes `lib/**`,
            `BUILD*` and `WORKSPACE*`. Trailing with a default so
            rules_flutter's existing `make_dart_library_build_content` call is
            unchanged.
        hooks: The package's hook attributes as BUILD text
            (`hook_attrs_block`), or empty for a package without hooks.

    Returns:
        BUILD.bazel content as a string.
    """
    deps_block = ""
    if deps:
        dep_lines = ['        "{}",'.format(dep) for dep in deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    version_block = ""
    if version:
        version_block = '    version = "{}",\n'.format(version)

    library = """\
dart_library(
    name = "{target}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{deps}{hooks}{version}{package_files}    package_name = "{name}",
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
    language_version = "{language_version}",
    visibility = ["{visibility}"],
)
""".format(
        # `package:test` keeps its public name for the target that carries the
        # runner beside it; see `_TEST_RUNNER_BLOCK`.
        target = _TEST_LIBRARY if name == "test" else name,
        name = name,
        deps = deps_block,
        hooks = hooks,
        version = version_block,
        package_files = _package_files_block(package_files),
        language_version = language_version,
        visibility = "//visibility:private" if name == "test" else "//visibility:public",
    )
    if name != "test":
        return _LOAD + "\n" + library + _build_yaml_block(name)
    return _LOAD + _TEST_RUNNER_LOAD + "\n" + library + "\n" + _TEST_RUNNER_BLOCK + _build_yaml_block(name)

_MEMBER_LOAD = 'load("@rules_dart//dart:defs.bzl", "dart_package_member")\n'

# `package:test` merged over a dependency cycle keeps the runner beside its
# member, exactly as its spoke would — but the runner trains against the merged
# library, which is what carries `package:test`'s sources now.
_MEMBER_TEST_RUNNER_LOAD = """\
load("@rules_dart//dart:defs.bzl", "dart_binary", "dart_package_member")
load(
    "@rules_dart//dart:utils.bzl",
    "dart_test_kernel",
    "dart_test_package",
    "dart_test_runner_main",
    "dart_test_runner_snapshot",
)
"""

_MEMBER_TEST_RUNNER_BLOCK = """\
dart_test_runner_main(name = "test_runner_main")

dart_binary(
    name = "test_runner",
    compile_mode = "kernel",
    main = ":test_runner_main",
    deps = ["{merged}"],
)

dart_test_kernel(
    name = "runner_training",
    main = "@rules_dart//dart/private/tools:runner_training_test.dart",
    deps = ["{merged}"],
)

dart_test_runner_snapshot(
    name = "test_runner_snapshot",
    runner = ":test_runner",
    training = ":runner_training",
)

dart_test_package(
    name = "test",
    library = "{merged}",
    runner = ":test_runner",
    snapshot = ":test_runner_snapshot",
    visibility = ["//visibility:public"],
)
"""

def scc_member_hook_error(name, repo):
    """Why a member of a merged dependency cycle cannot run its build hook.

    Args:
      name: The member's package name.
      repo: The merged repository's name.

    Returns:
      The message an executable reaching the member fails with.
    """
    return ("package:%s ships a build hook and is a member of a pub dependency cycle, " +
            "which is compiled as one library (%s). A package inside a dependency cycle " +
            "has no library of its own to run its build hook in, so its native code is " +
            "not built.") % (name, repo)

def make_dart_package_member_build_content(
        name,
        language_version,
        hook_error = "",
        version = "",
        link_hook = "",
        merged_label = "//:merged",
        package_files = ["pubspec.yaml", "LICENSE*"]):
    """Generate the BUILD.bazel content for one member of a merged SCC repository.

    The member lives in its own subdirectory of the merged repository (so its
    `lib/` root stays its own) and declares a `dart_package_member` with the
    sources, identity and hooks a `dart_library` of its own would carry. The
    merged repository's root `dart_library` names it in `members` and compiles
    every member's sources in one module.

    Args:
      name: The member's package name (also its target and subdirectory name).
      language_version: Dart language version string (e.g. `"3.0"`).
      hook_error: Why this member's build hook cannot run, or empty: a member
        of a merged cycle has no library of its own to run it.
      version: The resolved package version this member was fetched at, or
        empty.
      link_hook: Package-relative path of the member's link hook
        (`hook/link.dart`), or empty.
      merged_label: Label of the merged root library, used only when `name`
        is `"test"`: the runner beside it trains against the merged library.
      package_files: Glob patterns for the member's non-`lib/` runtime files,
        emitted as the generated `dart_package_member`'s `data`. The same
        deliberately small default and exclusions as
        `make_dart_library_build_content`; `[]` opts out.

    Returns:
      BUILD.bazel content as a string.
    """
    hook_block = ""
    if hook_error:
        hook_block = "    hook_error = %s,\n" % json.encode(hook_error)

    link_hook_block = ""
    if link_hook:
        link_hook_block = '    link_hook = "{}",\n'.format(link_hook)

    version_block = ""
    if version:
        version_block = '    version = "{}",\n'.format(version)

    member = """\
dart_package_member(
    name = "{target}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{hook}{link_hook}{version}{package_files}    package_name = "{name}",
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
    language_version = "{language_version}",
    visibility = ["//visibility:public"],
)
""".format(
        # `package:test` keeps its public name for the target that carries
        # the runner beside it; see `_MEMBER_TEST_RUNNER_BLOCK`.
        target = _TEST_LIBRARY if name == "test" else name,
        name = name,
        hook = hook_block,
        link_hook = link_hook_block,
        version = version_block,
        package_files = _package_files_block(package_files),
        language_version = language_version,
    )
    if name != "test":
        return _MEMBER_LOAD + "\n" + member + _build_yaml_block(name)
    return (
        _MEMBER_TEST_RUNNER_LOAD + "\n" + member + "\n" +
        _MEMBER_TEST_RUNNER_BLOCK.format(merged = merged_label) +
        _build_yaml_block(name)
    )

def make_scc_merged_build_content(members, dep_labels, repo_name):
    """Generate the root BUILD.bazel content of a merged SCC repository.

    One `dart_library` names every member package and the edges leaving the
    cycle; one `alias` per member (plus one named for the repository itself,
    the default target) points at it, so `@hub//:<member>` and a direct
    dependency on the repository both resolve to the merged closure. The one
    exception is a `test` member: like its spoke, it keeps its public name
    for the `dart_test_package` carrying the runner, which is what its alias
    points at.

    Args:
      members: Sorted list of member package names.
      dep_labels: Sorted list of fully-qualified Bazel label strings for the
        edges leaving the cycle. Empty when the cycle is closed.
      repo_name: The merged repository's own name, for its default-target
        alias.

    Returns:
      BUILD.bazel content as a string.
    """
    deps_block = ""
    if dep_labels:
        dep_lines = ['        "{}",'.format(dep) for dep in dep_labels]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    member_lines = []
    for member in members:
        target = _TEST_LIBRARY if member == "test" else member
        member_lines.append('        "//{member}:{target}",'.format(member = member, target = target))
    members_block = "    members = [\n{}\n    ],\n".format("\n".join(member_lines))

    aliases = []
    for member in members:
        if member == "test":
            actual = "//test:test"
        else:
            actual = ":merged"
        aliases.append("""\
alias(
    name = "{member}",
    actual = "{actual}",
    visibility = ["//visibility:public"],
)""".format(member = member, actual = actual))
    aliases.append("""\
alias(
    name = "{repo}",
    actual = ":merged",
    visibility = ["//visibility:public"],
)""".format(repo = repo_name))

    return (
        _LOAD + "\n" +
        "dart_library(\n" +
        '    name = "merged",\n' +
        members_block +
        deps_block +
        ")\n\n" +
        "\n\n".join(aliases) + "\n"
    )
