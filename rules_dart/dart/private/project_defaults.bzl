"""What the macros of `//dart:defs.bzl` take from the project index by default.

`@dart_projects//:index.bzl` holds, for each project of the main repository
that a `pub.from_lock` lock of the root module names (see
`//dart/pub/private:project.bzl`), its pubspec's name and language version and
the fixtures of its test tree. A target in that project's Bazel package gets
them with nothing in the BUILD file, as under `dart test`: a library compiles
with the pubspec's language version, a binary or a test is a member of the
pubspec's package, and a test runs in the project's directory with the files
under `test/` as `data`. What a target states wins. A package outside the
index is left alone without reading the package (no `glob`, no
`existing_rule`), so such a target can be declared from a symbolic macro.
"""

visibility(["//dart/..."])

# A helper of the macros, not a macro of its own.
# buildifier: disable=unnamed-macro
def project_of(projects):
    """The index entry of the package being evaluated, or None.

    Args:
      projects: The `PROJECTS` table of a project index.

    Returns:
      The package's `PROJECT` struct, or None outside the main repository or the index.
    """
    if native.repo_name():
        return None
    return projects.get(native.package_name())

def _local(value):
    """Whether a `main` or `srcs` entry names a file of the package being evaluated."""
    if type(value) == "Label":
        return value.repo_name == "" and value.package == native.package_name()
    return type(value) == "string" and not value.startswith("//") and not value.startswith("@")

def project_language_version(kwargs, project):
    """Sets a library's `language_version` to its project's, unless it states its identity.

    Args:
      kwargs: The target's arguments; changed in place.
      project: The package's index entry, or None.
    """
    if project == None or not project.language_version or [k for k in ("language_version", "package", "members") if k in kwargs]:
        return
    kwargs["language_version"] = project.language_version

def project_identity(kwargs, project):
    """Makes a binary or test a member of its project's package: the pubspec's name and language version.

    Left alone when the target states `package`, `package_name` or
    `language_version`, or names a source of another package (which the
    package could not contain).

    Args:
      kwargs: The target's arguments; changed in place.
      project: The package's index entry, or None.
    """
    if project == None or not project.name or [k for k in ("language_version", "package", "package_name") if k in kwargs]:
        return
    srcs = kwargs.get("srcs", [])
    if not _local(kwargs.get("main")) or type(srcs) != "list" or [s for s in srcs if not _local(s)]:
        return
    kwargs["package_name"] = project.name
    kwargs["language_version"] = project.language_version

# A helper of the macros, not a macro of its own.
# buildifier: disable=unnamed-macro
def add_project_files(kwargs, attr, files):
    """Appends `files` (package-relative names) to `kwargs[attr]`, skipping those it names already.

    Args:
      kwargs: The target's arguments; changed in place.
      attr: The attribute (`data`, `srcs`).
      files: The names to add.
    """
    if not files:
        return
    value = kwargs.get(attr, [])
    if type(value) == "list":
        named = {native.package_relative_label(v) if type(v) == "string" else v: True for v in value}
        files = [f for f in files if native.package_relative_label(f) not in named]
        if files:
            kwargs[attr] = value + files
    else:
        kwargs[attr] = value + files

# A helper of the macros, not a macro of its own.
# buildifier: disable=unnamed-macro
def project_test_files(kwargs, project, rule_name):
    """Adds the fixtures of the project's test tree to a test's `data`.

    A test reads its fixtures by a path relative to its project, as `dart
    test` and `flutter test` let it: every file under `test/` that is not
    Dart source and not hidden, and is in the project's package, is `data`.
    A fixture edit reruns every test of the package. A file whose name
    cannot be a label (a `:`, a `\\` or a control character in it) cannot be
    `data`: the tests of the package then fail at analysis, naming those
    files, as one error.

    Args:
      kwargs: The target's arguments; changed in place.
      project: The package's index entry, or None.
      rule_name: The test rule's name (`dart_test`), for the target that reports unlabelable files.
    """
    if project == None:
        return
    add_project_files(kwargs, "data", project.test_data)
    if project.unlabelable:
        name = rule_name + "_unlabelable_fixtures"
        if not native.existing_rule(name):
            _unlabelable_fixtures(name = name, files = project.unlabelable, visibility = ["//visibility:private"])
        add_project_files(kwargs, "data", [":" + name])

def project_test_dir(kwargs, project):
    """Runs a test in its project's directory: `pubspec` is the project's `pubspec.yaml`.

    Args:
      kwargs: The target's arguments; changed in place.
      project: The package's index entry, or None.
    """
    if project != None and "pubspec" not in kwargs and _local(kwargs.get("main")):
        kwargs["pubspec"] = "pubspec.yaml"

def _unlabelable_fixtures_impl(ctx):
    fail(("{n} file(s) under the project's test/ cannot be Bazel labels, so no test of " +
          "package //{pkg} has them as data: {files}. A target name cannot hold ':', '\\' or a control " +
          "character. Rename them, or move them into a directory with a BUILD file of its own, " +
          "whose files the default leaves out.").format(
        n = len(ctx.attr.files),
        pkg = ctx.label.package,
        files = ", ".join(["'%s'" % f for f in ctx.attr.files]),
    ))

# The tests of a package whose `test/` holds a file no label can name depend
# on this target, which fails at analysis naming the files: one error for the
# package, rather than every target of it failing to load.
_unlabelable_fixtures = rule(
    implementation = _unlabelable_fixtures_impl,
    attrs = {"files": attr.string_list()},
)
