"""What gen-l10n writes for each project of the main repository, known before analysis.

The `flutter` module extension calls `register_l10n_repos`: for every
`flutter.pub` lock of the root module it takes the lock's directory, the
members of the pub workspace that directory's `pubspec.yaml` declares, and the
lock's `path:` packages, and declares a `flutter_l10n_repo` for each of them
that has an `l10n.yaml`. Each reads `l10n.yaml`, the project's `pubspec.yaml`
and the `.arb` files of `arb-dir` through the pinned `yaml2json`, and writes
`l10n.bzl`: the files gen-l10n will write, by path under the project, and the
files it reads. `@flutter_l10n//:index.bzl` gathers them by Bazel package for
`flutter_library` and `flutter_application` (`flutter_gen_l10n.bzl`).

The names follow the Flutter tool: `output-dir` (by default `arb-dir`, by
default `lib/l10n`) holds `output-localization-file` (by default
`app_localizations.dart`) and one `<stem>_<language>.<extension>` per language
of the `.arb` files; `untranslated-messages-file` is written under the project.
An `.arb` file's language is that of its `@@locale`, or, without one, of its
name: the first `_`-separated part of two letters that the rest of the name can
follow as script, region and variants (`app_en`, `app_pt_BR`, `app_zh_Hant`).
The tool's own parser decides at build time; the action fails, naming the file,
when the two disagree, and `@@locale` settles it.

The repository is fetched again when `l10n.yaml`, `pubspec.yaml` or anything in
`arb-dir` changes. Its `l10n.bzl` changes only when the names do, so an edit
to the text of an `.arb` file reruns the action and nothing else.

`l10n.bzl` also names two kinds of project files the macros add by default:
the project's licence file (`NOTICES`, else `LICENSE`, as the tool's
`LicenseCollector` looks for it), which `NOTICES` holds for the project's own
package; and the fixtures of the test tree, every file under `test/` that is
not Dart source and is in the project's own Bazel package, which a
`flutter_test` reads at run time as `flutter test` lets it. Adding or removing
a file under `test/` fetches the repository again; `l10n.bzl` changes only
when the list of fixtures does, and an edit to a fixture's content changes
nothing here.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version")
load("@rules_dart//dart/pub:yaml.bzl", "yaml_to_json", "yaml_to_json_or_error")
load("//flutter/private:flutter_pub_path.bzl", "is_absolute_lock_path", "is_relative_path_dependency", "workspace_relative_lock_path")

visibility(["//flutter/..."])

_BUILD_FILES = ("BUILD", "BUILD.bazel")

def _is_word(c):
    return c.isalnum() or c == "_"

def _is_arb(name):
    # The tool lists `arb-dir` for names matching `(\w+)\.arb$`.
    return name.endswith(".arb") and len(name) > 4 and _is_word(name[-5])

def _follows_language(tokens):
    """Whether `tokens` can follow a language subtag: script, region, variants."""
    i = 0
    if i < len(tokens) and len(tokens[i]) == 4 and tokens[i].isalpha():
        i += 1
    if i < len(tokens) and ((len(tokens[i]) == 2 and tokens[i].isalpha()) or (len(tokens[i]) == 3 and tokens[i].isdigit())):
        i += 1
    for t in tokens[i:]:
        if not t.isalnum() or not ((5 <= len(t) and len(t) <= 8) or (len(t) == 4 and t[0].isdigit())):
            return False
    return True

# The languages of the tool's `_iso639Languages` (gen_l10n_types.dart) that
# are not two letters; every two-letter one is an ISO 639-1 code.
_THREE_LETTER_LANGUAGES = ["fil", "gsw"]

def _language_of_name(stem):
    """The language an `.arb` file's name gives, or None."""
    tokens = stem.replace("-", "_").split("_")
    for i in range(len(tokens)):
        t = tokens[i]
        is_language = (len(t) == 2 and t.isalpha()) or t.lower() in _THREE_LETTER_LANGUAGES
        if is_language and _follows_language(tokens[i + 1:]):
            return t.lower()
    return None

def _norm(path):
    """`path` as the tool normalises a file path option: no `.` or empty parts, `..` resolved."""
    parts = []
    for p in path.replace("\\", "/").split("/"):
        if p in ("", "."):
            continue
        if p == ".." and parts and parts[-1] != "..":
            parts.pop()
        else:
            parts.append(p)
    return "/".join(parts)

def _option(data, key, default = None):
    value = data.get(key)
    if value == None:
        return default
    if type(value) != "string":
        return None
    return _norm(value)

def _package_boundary(project_dir, rel_dir):
    """The first directory between the project and `rel_dir` that holds a BUILD file, or None."""
    path = project_dir
    walked = []
    for part in rel_dir.split("/") if rel_dir else []:
        path = path.get_child(part)
        walked.append(part)
        for b in _BUILD_FILES:
            if path.get_child(b).exists:
                return "/".join(walked)
    return None

# What the generated files import.
_IMPORTED = ("flutter", "flutter_localizations", "intl")

def _hub_deps(rctx, hub):
    return "[%s]" % ", ".join(["Label(%r)" % ("@%s//:%s" % (hub, p)) for p in _IMPORTED if p in rctx.attr.hub_packages])

def _l10n_bzl(rctx, language_version, outputs = [], srcs = [], error = "", package = "", analysis_options = False, files = None):
    # `hubs`: each hub of the project's lock, in declaration order, as its
    # canonical repository name and the packages the generated files import
    # from it; a target takes the one its own `deps` come from (`l10n_attach`).
    # `license`, `test_data`, `test_configs` and `unlabelable`: the project
    # files the macros add by default, and the ones they cannot
    # (`_project_files`).
    hubs = ["(Label(%r).repo_name, %s)" % ("@%s//:flutter" % hub, _hub_deps(rctx, hub)) for hub in rctx.attr.hubs]
    files = files or struct(license = "", test_data = [], test_configs = [], unlabelable = [])
    return "L10N = struct(\n    outputs = %r,\n    srcs = %r,\n    error = %r,\n    package = %r,\n    analysis_options = %r,\n    language_version = %r,\n    hubs = [%s],\n    license = %r,\n    test_data = %r,\n    test_configs = %r,\n    unlabelable = %r,\n)\n" % (
        outputs,
        srcs,
        error,
        package,
        analysis_options,
        language_version,
        ", ".join(hubs),
        files.license,
        files.test_data,
        files.test_configs,
        files.unlabelable,
    )

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

def _test_data(rctx, project_dir):
    """The files under `test/` a test of the project's package reads by default.

    Every file that is not Dart source, not hidden (a name starting with `.`),
    and in the project's own Bazel package: a directory holding a BUILD file
    is a package of its own, and its files are not listed. Each directory's
    listing is watched, so adding or removing a file fetches the repository
    again.

    Returns:
      `struct(test_data, test_configs, unlabelable)`: those files; the
      `flutter_test_config.dart` files among the Dart sources (the project
      root's included), which `flutter test` wraps the tests of their
      directory in; and the files that cannot be a label (a `:`, a `\\`, a
      control character in the name), with their names made printable.
    """
    configs = []
    top = project_dir.get_child("flutter_test_config.dart")
    rctx.watch(top)
    if top.exists and not top.is_dir:
        configs.append("flutter_test_config.dart")
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
            elif name == "flutter_test_config.dart":
                configs.append(rel + "/" + name)
            elif not name.endswith(".dart"):
                found.append(rel + "/" + name)
    return struct(test_data = sorted(found), test_configs = sorted(configs), unlabelable = sorted(unlabelable))

def _project_files(rctx, project_dir):
    """The project files the macros add to a target by default: the licence file and the test fixtures."""
    license = ""
    for name in ("NOTICES", "LICENSE"):
        path = project_dir.get_child(name)
        rctx.watch(path)
        if path.exists and not path.is_dir:
            license = name
            break
    tests = _test_data(rctx, project_dir)
    return struct(license = license, test_data = tests.test_data, test_configs = tests.test_configs, unlabelable = tests.unlabelable)

def pubspec_language_version(spec):
    """The `languageVersion` pub writes for the project: its `environment: sdk:` lower bound.

    pub's `LanguageVersion.fromSdkConstraint`, as rules_dart's
    `derive_language_version` mirrors it (2.7 for a missing or unbounded
    constraint).

    Args:
      spec: The project's decoded `pubspec.yaml`.

    Returns:
      A `<major>.<minor>` language version.
    """
    environment = spec.get("environment") if type(spec) == "dict" else None
    sdk = environment.get("sdk") if type(environment) == "dict" else None
    return derive_language_version(sdk if type(sdk) == "string" else "")

def _flutter_l10n_repo_impl(rctx):
    project_dir = rctx.workspace_root
    if rctx.attr.project:
        project_dir = rctx.path(str(project_dir) + "/" + rctx.attr.project)
    l10n = project_dir.get_child("l10n.yaml")
    pubspec = project_dir.get_child("pubspec.yaml")
    rctx.watch(l10n)
    rctx.watch(pubspec)
    rctx.file("BUILD.bazel", "")
    if not pubspec.exists:
        rctx.file("l10n.bzl", _l10n_bzl(rctx, ""))
        return
    files = _project_files(rctx, project_dir)
    shown = (rctx.attr.project + "/" if rctx.attr.project else "") + "l10n.yaml"
    if not l10n.exists:
        spec = yaml_to_json(rctx, [pubspec], [shown[:-len("l10n.yaml")] + "pubspec.yaml"])[0]
        rctx.file("l10n.bzl", _l10n_bzl(rctx, pubspec_language_version(spec), files = files))
        return
    config, spec = yaml_to_json(rctx, [l10n, pubspec], [shown, shown[:-len("l10n.yaml")] + "pubspec.yaml"])
    language_version = pubspec_language_version(spec)
    flutter = spec.get("flutter")
    generate = type(flutter) == "dict" and flutter.get("generate") == True
    if not generate and not rctx.attr.is_root:
        # A dependency's localizations are its own: the tool generates only
        # the project it builds and the members of its workspace.
        rctx.file("l10n.bzl", _l10n_bzl(rctx, language_version, files = files))
        return

    arb_dir = _option(config, "arb-dir", "lib/l10n")
    output_dir = _option(config, "output-dir", arb_dir)
    output_file = _option(config, "output-localization-file", "app_localizations.dart")
    untranslated = _option(config, "untranslated-messages-file")
    header_file = _option(config, "header-file")
    if arb_dir == None or output_dir == None or output_file == None:
        # A value of the wrong type. The action still runs, so the tool
        # reports it in its own words.
        rctx.file("l10n.bzl", _l10n_bzl(rctx, language_version, outputs = ["lib/l10n/app_localizations.dart"], package = str(spec.get("name", "")), files = files))
        return
    for what, rel in (("arb-dir", arb_dir), ("output-dir", output_dir)):
        if rel.startswith("..") or is_absolute_lock_path(rel):
            rctx.file("l10n.bzl", _l10n_bzl(rctx, language_version, error = "l10n.yaml: `%s: %s` is outside the project; Bazel builds a project's localizations inside it." % (what, rel), files = files))
            return
        boundary = _package_boundary(project_dir, rel)
        if boundary:
            rctx.file("l10n.bzl", _l10n_bzl(rctx, language_version, error = (
                "l10n.yaml: `%s: %s` is inside %s, which holds a BUILD file and so is a Bazel package of its own; " +
                "gen-l10n reads and writes the project's own package. Remove that BUILD file."
            ) % (what, rel, boundary), files = files))
            return

    arb_path = project_dir.get_child(arb_dir) if arb_dir else project_dir
    rctx.watch_tree(arb_path)
    arbs = sorted([
        entry.basename
        for entry in (arb_path.readdir() if arb_path.exists and arb_path.is_dir else [])
        if _is_arb(entry.basename) and not entry.is_dir
    ])
    prefix = arb_dir + "/" if arb_dir else ""
    decoded = yaml_to_json_or_error(rctx, [arb_path.get_child(a) for a in arbs], [prefix + a for a in arbs])

    languages = {}
    for i in range(len(arbs)):
        data = decoded.data[i] if decoded.data != None else {}
        locale = data.get("@@locale") if type(data) == "dict" else None
        if type(locale) == "string" and locale:
            language = locale.split("_")[0]
        else:
            language = _language_of_name(arbs[i][:-len(".arb")])
        if language:
            languages[language] = True

    dot = output_file.rfind("/")
    base = output_file[dot + 1:]
    stem, _, extension = base.partition(".")
    out_prefix = output_dir + "/" if output_dir else ""
    outputs = [out_prefix + output_file]
    if stem and extension:
        outputs.extend([out_prefix + stem + "_" + language + "." + extension for language in sorted(languages)])
    if untranslated:
        outputs.append(untranslated)
    srcs = [prefix + a for a in arbs]
    if header_file:
        srcs.append(_norm(prefix + header_file))

    # `dart format` reads the project's `formatter:` options from it.
    options = project_dir.get_child("analysis_options.yaml")
    rctx.watch(options)
    rctx.file("l10n.bzl", _l10n_bzl(
        rctx,
        language_version,
        outputs = sorted(outputs),
        srcs = srcs,
        package = str(spec.get("name", "")),
        analysis_options = options.exists,
        files = files,
    ))

flutter_l10n_repo = repository_rule(
    implementation = _flutter_l10n_repo_impl,
    doc = "The files gen-l10n writes and reads for one project of the main repository, from its `l10n.yaml`.",
    attrs = {
        "project": attr.string(
            doc = "The project's directory, relative to the main repository's root.",
        ),
        "hubs": attr.string_list(
            doc = "The `flutter.pub` hubs of the project's lock, in declaration order, whose packages the generated files import.",
        ),
        "hub_packages": attr.string_list(
            doc = "Which of `flutter`, `flutter_localizations` and `intl` the lock holds.",
        ),
        "is_root": attr.bool(
            doc = "Whether the project is one the Flutter tool generates for (a lock's own project, or a member of its workspace), rather than a `path:` dependency.",
        ),
    },
)

def _flutter_l10n_index_impl(rctx):
    loads = []
    entries = []
    for i, package in enumerate(sorted(rctx.attr.projects)):
        loads.append('load("@%s//:l10n.bzl", _p%d = "L10N")' % (rctx.attr.projects[package], i))
        entries.append("    %r: _p%d," % (package, i))
    rctx.file("index.bzl", "\n".join([
        '"""The localizations of each project of the main repository, by Bazel package (see rules_flutter\'s flutter_l10n_repo.bzl)."""',
        "",
    ] + loads + [
        "",
        "L10N_PROJECTS = {",
    ] + entries + ["}", ""]))
    rctx.file("BUILD.bazel", """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

bzl_library(
    name = "index",
    srcs = ["index.bzl"],
    visibility = ["//visibility:public"],
)
""")

flutter_l10n_index = repository_rule(
    implementation = _flutter_l10n_index_impl,
    doc = "`index.bzl`: every project's `l10n.bzl`, by Bazel package.",
    attrs = {
        "projects": attr.string_dict(
            doc = "Bazel package of the main repository to the name of its `flutter_l10n_repo`.",
        ),
    },
)

def _lock_dir(lock):
    """The lock file's directory, relative to the main repository's root."""
    parts = [lock.package] if lock.package else []
    head = lock.name.rpartition("/")[0]
    if head:
        parts.append(head)
    return "/".join(parts)

def _repo_name(project):
    return "flutter_l10n_" + ("".join([c if c.isalnum() else "_" for c in project.elems()]) if project else "root")

def _child(root, rel, name):
    return root.get_child(rel + "/" + name if rel else name)

def _workspace_members(module_ctx, root, projects):
    """The member directories of the pub workspaces the projects' pubspecs declare, each with its project."""
    specs = [_child(root, p, "pubspec.yaml") for p in projects]
    for spec in specs:
        module_ctx.watch(spec)
    present = [i for i in range(len(specs)) if specs[i].exists]
    decoded = yaml_to_json_or_error(module_ctx, [specs[i] for i in present])
    members = []
    for k in range(len(present)):
        data = decoded.data[k] if decoded.data != None else {}
        entries = data.get("workspace") if type(data) == "dict" else None
        for member in entries if type(entries) == "list" else []:
            if type(member) == "string" and member and "*" not in member and not is_absolute_lock_path(member):
                rel = projects[present[k]]
                members.append((_norm((rel + "/" if rel else "") + member), rel))
    return members

def add_project_hub(hubs, project, hub):
    """Adds `hub` to the project's hubs, after the ones declared before it.

    The first one is the project's default, as for `PUB_HUBS`: the first hub
    declared with the lock.

    Args:
      hubs: Each project's list of hub structs; changed in place.
      project: The project's directory.
      hub: The hub, a struct with `name` and `packages`.
    """
    own = hubs.setdefault(project, [])
    if hub.name not in [h.name for h in own]:
        own.append(hub)

def register_l10n_repos(module_ctx, pub_yaml):
    """Declares a `flutter_l10n_repo` per project with an `l10n.yaml`, and `flutter_l10n`.

    Args:
      module_ctx: The `flutter` extension's context.
      pub_yaml: Each `flutter.pub` tag's decoded lock, by label string.
    """
    is_root = {}
    hubs = {}
    root = None
    for mod in module_ctx.modules:
        if not mod.is_root:
            continue
        for tag in mod.tags.pub:
            lock = tag.lock
            project = _lock_dir(lock)
            if root == None:
                root = module_ctx.path(lock).dirname
                for _ in project.split("/") if project else []:
                    root = root.dirname
            is_root[project] = True
            packages = pub_yaml.get(str(lock), {}).get("packages")
            hub = struct(name = tag.name, packages = [p for p in _IMPORTED if type(packages) == "dict" and p in packages])
            add_project_hub(hubs, project, hub)
            for name, info in (packages if type(packages) == "dict" else {}).items():
                desc = info.get("description") if type(info) == "dict" and info.get("source") == "path" else None
                entry = desc.get("path") if type(desc) == "dict" else None
                if type(entry) != "string" or not entry or is_absolute_lock_path(entry) or not is_relative_path_dependency(desc.get("relative", False)):
                    continue
                path = workspace_relative_lock_path("", name, lock, entry)
                is_root.setdefault(path, False)
                add_project_hub(hubs, path, hub)
    projects = {}
    if root != None:
        for member, owner in _workspace_members(module_ctx, root, sorted([p for p in is_root if is_root[p]])):
            is_root[member] = True
            hubs[member] = hubs[owner]
        for project in sorted(is_root):
            pubspec = _child(root, project, "pubspec.yaml")
            module_ctx.watch(pubspec)
            if pubspec.exists:
                projects[project] = _repo_name(project)
                flutter_l10n_repo(
                    name = projects[project],
                    project = project,
                    is_root = is_root[project],
                    hubs = [h.name for h in hubs[project]],
                    hub_packages = hubs[project][0].packages,
                )
    flutter_l10n_index(name = "flutter_l10n", projects = projects)
