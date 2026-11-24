"""The Flutter project index: rules_dart's project facts, and what gen-l10n writes, known before analysis.

The `flutter` module extension calls `register_l10n_repos`: for every project
the root module's `flutter.pub` locks name (rules_dart's `project_dirs`: each
lock's directory, the members of the pub workspace its `pubspec.yaml`
declares, and the lock's `path:` packages) it declares a `flutter_l10n_repo`,
which writes `project.bzl`. That holds rules_dart's facts (`project_facts`:
the pubspec's name and language version, the licence file, the fixtures of
the test tree, unlabelable files) with the `flutter_test_config.dart` files as
`test_configs`, and, for a project with an `l10n.yaml`, the files gen-l10n
will write, by path under the project, and the files it reads, through the
pinned `yaml2json`. `@flutter_projects//:index.bzl` gathers them by Bazel
package for the macros (`flutter_gen_l10n.bzl`).

The names follow the Flutter tool: `output-dir` (by default `arb-dir`, by
default `lib/l10n`) holds `output-localization-file` (by default
`app_localizations.dart`) and one `<stem>_<language>.<extension>` per language
of the `.arb` files; `untranslated-messages-file` is written under the project.
An `.arb` file's language is that of its `@@locale`, or, without one, of its
name: the first `_`-separated part of two letters that the rest of the name can
follow as script, region and variants (`app_en`, `app_pt_BR`, `app_zh_Hant`).
The tool's own parser decides at build time; the action fails, naming the file,
when the two disagree, and `@@locale` settles it.

The repository is fetched again when `l10n.yaml`, `pubspec.yaml`, anything in
`arb-dir` or a listing under `test/` changes. Its `project.bzl` changes only
when the names do, so an edit to the text of an `.arb` file or a fixture
reruns the actions that read it and nothing else.
"""

load("@rules_dart//dart/pub:project.bzl", "DART_PROJECTS_JSON", "PROJECT_BUILD", "project_bzl", "project_dirs", "project_facts", "project_index", "project_repo_name")
load("@rules_dart//dart/pub:yaml.bzl", "lock_packages_or_error", "yaml_to_json", "yaml_to_json_or_error")
load("//flutter/private:flutter_pub_path.bzl", "is_absolute_lock_path")

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

# The file `flutter test` wraps the tests of its directory and below in.
_TEST_CONFIG = "flutter_test_config.dart"

def _project_bzl(rctx, facts, outputs = [], srcs = [], error = "", package = "", analysis_options = False):
    # rules_dart's project facts, and what gen-l10n writes and reads.
    # `hubs`: each hub of the project's lock, in declaration order, as its
    # canonical repository name and the packages the generated files import
    # from it; a target takes the one its own `deps` come from (`l10n_attach`).
    hubs = ["(Label(%r).repo_name, %s)" % ("@%s//:flutter" % hub, _hub_deps(rctx, hub)) for hub in rctx.attr.hubs]
    return project_bzl(facts, "    outputs = %r,\n    srcs = %r,\n    error = %r,\n    package = %r,\n    analysis_options = %r,\n    hubs = [%s],\n" % (
        outputs,
        srcs,
        error,
        package,
        analysis_options,
        ", ".join(hubs),
    ))

def _flutter_l10n_repo_impl(rctx):
    project_dir = rctx.workspace_root
    if rctx.attr.project:
        project_dir = rctx.path(str(project_dir) + "/" + rctx.attr.project)
    l10n = project_dir.get_child("l10n.yaml")
    pubspec = project_dir.get_child("pubspec.yaml")
    rctx.watch(l10n)
    rctx.watch(pubspec)
    rctx.file("BUILD.bazel", PROJECT_BUILD)
    if not pubspec.exists:
        rctx.file("project.bzl", _project_bzl(rctx, project_facts(rctx, project_dir, None)))
        return
    shown = (rctx.attr.project + "/" if rctx.attr.project else "") + "l10n.yaml"
    if not l10n.exists:
        spec = yaml_to_json(rctx, [pubspec], [shown[:-len("l10n.yaml")] + "pubspec.yaml"])[0]
        rctx.file("project.bzl", _project_bzl(rctx, project_facts(rctx, project_dir, spec, _TEST_CONFIG)))
        return
    config, spec = yaml_to_json(rctx, [l10n, pubspec], [shown, shown[:-len("l10n.yaml")] + "pubspec.yaml"])
    facts = project_facts(rctx, project_dir, spec, _TEST_CONFIG)
    flutter = spec.get("flutter")
    generate = type(flutter) == "dict" and flutter.get("generate") == True
    if not generate and not rctx.attr.is_root:
        # A dependency's localizations are its own: the tool generates only
        # the project it builds and the members of its workspace.
        rctx.file("project.bzl", _project_bzl(rctx, facts))
        return

    arb_dir = _option(config, "arb-dir", "lib/l10n")
    output_dir = _option(config, "output-dir", arb_dir)
    output_file = _option(config, "output-localization-file", "app_localizations.dart")
    untranslated = _option(config, "untranslated-messages-file")
    header_file = _option(config, "header-file")
    if arb_dir == None or output_dir == None or output_file == None:
        # A value of the wrong type. The action still runs, so the tool
        # reports it in its own words.
        rctx.file("project.bzl", _project_bzl(rctx, facts, outputs = ["lib/l10n/app_localizations.dart"], package = str(spec.get("name", ""))))
        return
    for what, rel in (("arb-dir", arb_dir), ("output-dir", output_dir)):
        if rel.startswith("..") or is_absolute_lock_path(rel):
            rctx.file("project.bzl", _project_bzl(rctx, facts, error = "l10n.yaml: `%s: %s` is outside the project; Bazel builds a project's localizations inside it." % (what, rel)))
            return
        boundary = _package_boundary(project_dir, rel)
        if boundary:
            rctx.file("project.bzl", _project_bzl(rctx, facts, error = (
                "l10n.yaml: `%s: %s` is inside %s, which holds a BUILD file and so is a Bazel package of its own; " +
                "gen-l10n reads and writes the project's own package. Remove that BUILD file."
            ) % (what, rel, boundary)))
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
    rctx.file("project.bzl", _project_bzl(
        rctx,
        facts,
        outputs = sorted(outputs),
        srcs = srcs,
        package = str(spec.get("name", "")),
        analysis_options = options.exists,
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

def _uses_flutter(spec):
    for key in ("dependencies", "dev_dependencies"):
        deps = spec.get(key) if type(spec) == "dict" else None
        for dep in deps.values() if type(deps) == "dict" else []:
            if type(dep) == "dict" and dep.get("sdk") == "flutter":
                return True
    return False

def _check_dart_projects(module_ctx, found, tags):
    """Fails naming the `pub.project` tag for a pure-Dart project with a `test/` that `@dart_projects` lacks.

    Its `dart_test` comes from rules_dart, whose macros read only
    `@dart_projects`. `@dart_projects` is read only when such a project exists.
    """
    root = module_ctx.path(Label("@@//:MODULE.bazel")).dirname
    dirs = list(found)
    tests = [root.get_child(p + "/test" if p else "test") for p in dirs]
    for path in tests:
        module_ctx.watch(path)
    dirs = [dirs[i] for i in range(len(dirs)) if tests[i].exists]
    specs = yaml_to_json_or_error(module_ctx, [root.get_child(p + "/pubspec.yaml" if p else "pubspec.yaml") for p in dirs]).data or []
    dart = [dirs[i] for i in range(len(specs)) if not _uses_flutter(specs[i])]
    known = json.decode(module_ctx.read(DART_PROJECTS_JSON)) if dart else []
    missing = {}
    for p in dart:
        if p not in known:
            lock = tags[found[p].locks[0]].lock
            missing.setdefault("//%s:%s" % (lock.package, lock.name), []).append("//" + p)
    if missing:
        fail("".join([
            "flutter.pub: the lock %s names the pure-Dart package %s (no Flutter SDK dependency, a test/ directory), which rules_dart's macros do not know: its dart_test would run outside its package's directory, without its test fixtures and at the default language version. Add to MODULE.bazel:\n\n" % (lock, ", ".join(pkgs)) +
            '    pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")\n' +
            '    pub.project(lock = "%s")\n\n' % lock
            for lock, pkgs in sorted(missing.items())
        ]))

def register_l10n_repos(module_ctx, pub_yaml):
    """Declares a `flutter_l10n_repo` per project of the root module's locks, and `flutter_projects`.

    Args:
      module_ctx: The `flutter` extension's context.
      pub_yaml: Each `flutter.pub` tag's decoded lock, by label string.
    """
    tags = [tag for mod in module_ctx.modules if mod.is_root for tag in mod.tags.pub]
    locks = [(tag.lock, lock_packages_or_error(pub_yaml.get(str(tag.lock), {})).packages) for tag in tags]
    found_dirs = project_dirs(module_ctx, locks)
    _check_dart_projects(module_ctx, found_dirs, tags)
    projects = {}
    for project, found in found_dirs.items():
        hubs = {}
        for i in found.locks:
            packages = locks[i][1] or {}
            add_project_hub(hubs, project, struct(name = tags[i].name, packages = [p for p in _IMPORTED if p in packages]))
        projects[project] = project_repo_name("flutter_project_", project)
        flutter_l10n_repo(
            name = projects[project],
            project = project,
            is_root = found.is_root,
            hubs = [h.name for h in hubs[project]],
            hub_packages = hubs[project][0].packages,
        )
    project_index(name = "flutter_projects", projects = projects)
