"""The project index: what each project of the main repository says about itself, known before analysis.

A project is a directory with a `pubspec.yaml` that a lock of the root module
names: the lock's own directory, the members of the pub workspace its
pubspec declares, and the lock's relative `path:` packages. One repository
per project reads the pubspec through the pinned `yaml2json` and lists the
project's files, and writes `project.bzl`:

- `name` and `language_version`: the pubspec's `name`, and the
  `languageVersion` pub writes for it (its `environment: sdk:` lower bound);
- `license`: `NOTICES`, else `LICENSE`, at the project's root;
- `test_yaml`: `dart_test.yaml` at the project's root, which `package:test`
  reads from the directory a test runs in;
- `test_data`: every file under `test/` that is not Dart source, not hidden,
  not under a `failures/` directory, and in the project's own Bazel package
  (a directory holding a BUILD file is skipped), which a test reads by a
  path relative to the project;
- `test_configs`: the Dart files of one name a rule set wraps a test in (the
  project root's and those under `test/`), when it asks for them;
- `unlabelable`: the files under `test/` no label can name, made printable.

Directory listings are read with `readdir`, so adding or removing a file
fetches the repository again; `project.bzl` changes only when what it says
does. `project_index` gathers every project's `project.bzl` by Bazel package.
The `pub` extension declares `@dart_projects` for rules_dart's macros, and
the `flutter` extension its own index, whose repositories add what only
Flutter reads (`flutter_l10n_repo.bzl`).
"""

load("//dart/pub/private:language_version.bzl", "derive_language_version")
load("//dart/pub/private:pub_sources.bzl", "lock_dir_segments", "path_package_dir")
load("//dart/pub/private:yaml2json.bzl", "yaml_to_json", "yaml_to_json_or_error")

visibility(["//dart/..."])

_BUILD_FILES = ("BUILD", "BUILD.bazel")

# Directories under `test/` whose files are not fixtures: the stock golden
# comparator writes its failure images to `failures/` next to the test.
_NOT_FIXTURE_DIRS = ("failures",)

# What a Bazel target name cannot hold, besides a character below a space and
# DEL: `glob` returns such a file all the same, and the package then fails to
# load ("invalid label"), every target of it.
_NOT_IN_LABEL = (":", "\\", "\177")

def _labelable(name):
    return not [c for c in name.elems() if c < " " or c in _NOT_IN_LABEL]

def _printable(name):
    # As Bazel's own message spells a character a label cannot hold. A
    # control character's `repr` (`\x01`) is not a Starlark escape.
    return "".join(["<?>" if c < " " or c == "\177" else c for c in name.elems()])

def _test_files(rctx, project_dir, config):
    """The files under `test/` a test reads by default, the `config` files among the Dart ones, and the unlabelable ones."""
    configs = []
    if config:
        top = project_dir.get_child(config)
        rctx.watch(top)
        if top.exists and not top.is_dir:
            configs.append(config)
    root = rctx.path(str(project_dir) + "/test")
    rctx.watch(root)
    if not root.exists or not root.is_dir:
        return struct(test_data = [], test_configs = configs, unlabelable = [])
    found = []
    unlabelable = []
    queue = [("test", root)]
    for _ in range(1000000):
        if not queue:
            break
        rel, directory = queue.pop()
        if [b for b in _BUILD_FILES if directory.get_child(b).exists]:
            continue
        for entry in directory.readdir():
            name = entry.basename
            if name.startswith("."):
                continue
            if entry.is_dir:
                if name not in _NOT_FIXTURE_DIRS:
                    queue.append((rel + "/" + name, entry))
            elif not _labelable(rel + "/" + name):
                unlabelable.append(_printable(rel + "/" + name))
            elif config and name == config:
                configs.append(rel + "/" + name)
            elif not name.endswith(".dart"):
                found.append(rel + "/" + name)
    return struct(test_data = sorted(found), test_configs = sorted(configs), unlabelable = sorted(unlabelable))

def pubspec_language_version(spec):
    """The `languageVersion` pub writes for a project: its `environment: sdk:` lower bound.

    pub's `LanguageVersion.fromSdkConstraint`, as `derive_language_version`
    mirrors it (2.7 for a missing or unbounded constraint).

    Args:
      spec: The project's decoded `pubspec.yaml`.

    Returns:
      A `<major>.<minor>` language version.
    """
    environment = spec.get("environment") if type(spec) == "dict" else None
    sdk = environment.get("sdk") if type(environment) == "dict" else None
    return derive_language_version(sdk if type(sdk) == "string" else "")

def project_facts(rctx, project_dir, spec, test_config = None):
    """What a project says about itself, for `project_bzl`.

    Args:
      rctx: The repository context; the files read are watched.
      project_dir: The project's directory, a path.
      spec: The project's decoded `pubspec.yaml`, or None without one.
      test_config: The name of the Dart file a rule set wraps a test in
        (`flutter_test_config.dart`), listed as `test_configs`; None for none.

    Returns:
      `struct(name, language_version, license, test_yaml, test_data, test_configs, unlabelable)`.
    """
    if spec == None:
        return struct(name = "", language_version = "", license = "", test_yaml = "", test_data = [], test_configs = [], unlabelable = [])
    license = ""
    for name in ("NOTICES", "LICENSE"):
        path = project_dir.get_child(name)
        rctx.watch(path)
        if path.exists and not path.is_dir:
            license = name
            break
    tests = _test_files(rctx, project_dir, test_config)
    test_yaml = project_dir.get_child("dart_test.yaml")
    rctx.watch(test_yaml)
    name = spec.get("name") if type(spec) == "dict" else None
    return struct(
        name = name if type(name) == "string" else "",
        language_version = pubspec_language_version(spec),
        license = license,
        test_yaml = "dart_test.yaml" if test_yaml.exists and not test_yaml.is_dir else "",
        test_data = tests.test_data,
        test_configs = tests.test_configs,
        unlabelable = tests.unlabelable,
    )

def project_bzl(facts, extra = ""):
    """The text of a project's `project.bzl`: `PROJECT`, a struct of `facts` and the `extra` fields.

    Args:
      facts: The project's facts, as `project_facts` returns them.
      extra: More fields, each a line `    <name> = <value>,\\n`.

    Returns:
      The file's text.
    """
    fields = ["name", "language_version", "license", "test_yaml", "test_data", "test_configs", "unlabelable"]
    return "PROJECT = struct(\n%s%s)\n" % ("".join(["    %s = %r,\n" % (f, getattr(facts, f)) for f in fields]), extra)

# The BUILD file of a repository holding a `project.bzl`.
PROJECT_BUILD = """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

bzl_library(
    name = "project",
    srcs = ["project.bzl"],
    visibility = ["//visibility:public"],
)
"""

def _dart_project_repo_impl(rctx):
    project_dir = rctx.path(str(rctx.workspace_root) + ("/" + rctx.attr.project if rctx.attr.project else ""))
    pubspec = project_dir.get_child("pubspec.yaml")
    rctx.watch(pubspec)
    rctx.file("BUILD.bazel", PROJECT_BUILD)
    spec = yaml_to_json(rctx, [pubspec], [(rctx.attr.project + "/" if rctx.attr.project else "") + "pubspec.yaml"])[0] if pubspec.exists else None
    rctx.file("project.bzl", project_bzl(project_facts(rctx, project_dir, spec)))

dart_project_repo = repository_rule(
    implementation = _dart_project_repo_impl,
    doc = "`project.bzl`: what one project of the main repository says about itself (see `project.bzl`).",
    attrs = {"project": attr.string(doc = "The project's directory, relative to the main repository's root.")},
)

def _project_index_impl(rctx):
    loads = []
    entries = []
    for i, package in enumerate(sorted(rctx.attr.projects)):
        loads.append('load("@%s//:project.bzl", _p%d = "PROJECT")' % (rctx.attr.projects[package], i))
        entries.append("    %r: _p%d," % (package, i))
    rctx.file("index.bzl", "\n".join(
        ['"""Each project of the main repository, by Bazel package (rules_dart\'s project.bzl)."""', ""] +
        loads + ["", "PROJECTS = {"] + entries + ["}", ""],
    ))
    rctx.file("projects.json", json.encode(sorted(rctx.attr.projects)))
    rctx.file("BUILD.bazel", """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

bzl_library(
    name = "index",
    srcs = ["index.bzl"],
    visibility = ["//visibility:public"],
    deps = %r,
)
""" % ["@%s//:project" % r for r in sorted(rctx.attr.projects.values())])

project_index = repository_rule(
    implementation = _project_index_impl,
    doc = "`index.bzl`: `PROJECTS`, every project's `PROJECT` by Bazel package; `projects.json`: their packages, for an extension to read.",
    attrs = {"projects": attr.string_dict(doc = "Bazel package of the main repository to the repository holding its `project.bzl`.")},
)

def _norm(path):
    parts = []
    for p in path.replace("\\", "/").split("/"):
        if p in ("", "."):
            continue
        if p == ".." and parts and parts[-1] != "..":
            parts.pop()
        else:
            parts.append(p)
    return "/".join(parts)

def _child(root, rel, name):
    return root.get_child(rel + "/" + name if rel else name)

def project_dirs(module_ctx, locks):
    """The projects the root module's locks name, each with the locks that name it.

    Args:
      module_ctx: The extension's context; the pubspecs read are watched.
      locks: `(Label, packages)` for each lock of the root module, in
        declaration order; `packages` is the lock's decoded `packages`.

    Returns:
      Each project directory with a `pubspec.yaml` (relative to the main
      repository's root) to `struct(is_root, locks)`: whether it is a lock's
      own directory or a member of its pub workspace, rather than a `path:`
      package, and the indices of the locks that name it, in order.
    """
    found = {}
    root = None
    for i, (lock, packages) in enumerate(locks):
        project = "/".join(lock_dir_segments(lock))
        if root == None:
            root = module_ctx.path(lock).dirname
            for _ in project.split("/") if project else []:
                root = root.dirname
        found.setdefault(project, struct(is_root = [], locks = []))
        found[project].is_root.append(True)
        found[project].locks.append(i)
        for name, info in packages.items() if type(packages) == "dict" else []:
            if type(info) == "dict" and info.get("source") == "path":
                path = path_package_dir(name, info, lock).dir
                if path != None:
                    found.setdefault(path, struct(is_root = [], locks = []))
                    found[path].locks.append(i)
    if root == None:
        return {}

    # The members of the workspaces the lock directories' pubspecs declare.
    owners = sorted([p for p in found if found[p].is_root])
    specs = [_child(root, p, "pubspec.yaml") for p in owners]
    for spec in specs:
        module_ctx.watch(spec)
    present = [i for i in range(len(specs)) if specs[i].exists]
    decoded = yaml_to_json_or_error(module_ctx, [specs[i] for i in present])
    for k in range(len(present)):
        data = decoded.data[k] if decoded.data != None else {}
        members = data.get("workspace") if type(data) == "dict" else None
        owner = owners[present[k]]
        for member in members if type(members) == "list" else []:
            if type(member) == "string" and member and "*" not in member and not member.startswith("/") and member[1:2] != ":":
                path = _norm((owner + "/" if owner else "") + member)
                found.setdefault(path, struct(is_root = [], locks = []))
                found[path].is_root.append(True)
                found[path].locks.extend(found[owner].locks)
    result = {}
    for project in sorted(found):
        pubspec = _child(root, project, "pubspec.yaml")
        module_ctx.watch(pubspec)
        if pubspec.exists:
            result[project] = struct(is_root = bool(found[project].is_root), locks = found[project].locks)
    return result

def project_repo_name(prefix, project):
    """The repository name of a project's `project.bzl`: `prefix` and the directory, `root` for the root.

    Args:
      prefix: The rule set's prefix (`dart_project_`).
      project: The project's directory.

    Returns:
      The name.
    """
    return prefix + ("".join([c if c.isalnum() else "_" for c in project.elems()]) if project else "root")

def register_dart_projects(module_ctx, locks):
    """Declares a `dart_project_repo` per project of the root module's locks, and `@dart_projects`.

    Args:
      module_ctx: The `pub` extension's context.
      locks: `(Label, packages)` for each `from_lock` and `project` lock of
        the root module; a project two of them name is one entry.
    """
    projects = project_dirs(module_ctx, locks)
    names = {}
    for project in projects:
        names[project] = project_repo_name("dart_project_", project)
        dart_project_repo(name = names[project], project = project)
    project_index(name = "dart_projects", projects = names)
