"""gen-l10n from the project's `l10n.yaml`, run by the Flutter tool's own code.

A project with an `l10n.yaml` gets its localizations as `flutter build` and
`flutter pub get` write them: the Dart files land in the project at the paths
`l10n.yaml` names, and the library holding the project's `lib/` compiles them.
Nothing is restated in a BUILD file.

Bazel needs the names of the generated files before analysis, and they depend
on `l10n.yaml` and on the `.arb` files there are. The `flutter` module
extension finds each project of a `flutter.pub` lock that has an `l10n.yaml`
(the lock's own directory, and the `path:` packages of the lock), and a
repository rule per project (`flutter_l10n_repo.bzl`) reads `l10n.yaml`, the
list of `.arb` files and their `@@locale` through the pinned `yaml2json`, and
writes the output names. `flutter_library`, `flutter_application`,
`flutter_test` and `flutter_web_app` look the project up when their package
has an `l10n.yaml`, declare one `flutter_gen_l10n` target per package and a
library of its Dart files, and depend on that library (`l10n_attach`).

The action runs `GenerateLocalizationsTarget` of the release's `flutter_tools`
in the asset tool (`flutter_assets_tool.dart gen-l10n`): the tool reads
`l10n.yaml` itself, so every option it knows (`header`, `nullable-getter`,
`untranslated-messages-file`, `format`, ...) applies with the tool's defaults.
It checks what the tool wrote against the declared names and fails, naming the
difference, when they disagree.
"""

load("//flutter/private:flutter_assets_tool.bzl", "flutter_assets_tool_of")
load("//flutter/private:flutter_library.bzl", "flutter_library")

visibility(["//flutter/..."])

# The one gen-l10n target a package gets, and the library of its Dart files.
L10N_TARGET = "_gen_l10n"
L10N_LIBRARY = "_l10n"

def _flutter_gen_l10n_impl(ctx):
    sdk = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    tool = flutter_assets_tool_of(sdk, ctx.label)
    project = ctx.file.pubspec.dirname
    prefix = ctx.label.package + "/" if ctx.label.package else ""
    outs = [ctx.actions.declare_file(rel) for rel in ctx.attr.outputs]

    # The directory the declared files are under at their project paths.
    out_dir = outs[0].path[:-len(ctx.attr.outputs[0])].rstrip("/") if outs else ctx.bin_dir.path

    args = ctx.actions.args()
    args.add("--project", project)
    args.add("--label", str(ctx.label))
    args.add("--flutter-version", sdk.version)
    args.add("--engine-revision", sdk.engine_revision)
    args.add("--out", out_dir)
    inputs = [ctx.file.pubspec, ctx.file.l10n_yaml]
    args.add("--project-file", "pubspec.yaml=" + ctx.file.pubspec.path)
    args.add("--project-file", "l10n.yaml=" + ctx.file.l10n_yaml.path)

    # `dart format` takes the page width and trailing commas from the
    # project's `analysis_options.yaml`, as for stock.
    if ctx.file.analysis_options:
        args.add("--project-file", "analysis_options.yaml=" + ctx.file.analysis_options.path)
        inputs.append(ctx.file.analysis_options)
    for f in ctx.files.srcs:
        if not f.short_path.startswith(prefix):
            fail("%s: %s is not in the project's package %s." % (ctx.label, f.short_path, ctx.label.package))
        args.add("--project-file", f.short_path[len(prefix):] + "=" + f.path)
        inputs.append(f)
    for rel in ctx.attr.outputs:
        args.add("--output", rel)

    # The language version `dart format` formats the files for.
    if ctx.attr.language_version:
        args.add("--language-version", ctx.attr.language_version)

    # `format: true` (the default) runs the release's `dart format` on the
    # files, as `Artifact.engineDartBinary` names it.
    args.add("--sdk", "bin/cache/dart-sdk/bin/" + sdk.dart.basename + "=" + sdk.dart.path)
    inputs.append(sdk.dart)

    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    ctx.actions.run(
        executable = tool.runtime,
        arguments = [tool.snapshot.path, "gen-l10n", args],
        inputs = depset(direct = [tool.snapshot] + inputs, transitive = [sdk.dart_pub_files]),
        outputs = outs,
        mnemonic = "FlutterGenL10n",
        progress_message = "Generating the localizations of %{label}",
        toolchain = None,
    )

    # The Dart files are sources of the library; the untranslated messages
    # file, a report, is built with them and requested by its group.
    return [
        DefaultInfo(files = depset([f for f in outs if f.extension == "dart"])),
        OutputGroupInfo(untranslated_messages = depset([f for f in outs if f.extension != "dart"])),
    ]

flutter_gen_l10n = rule(
    implementation = _flutter_gen_l10n_impl,
    doc = "Runs gen-l10n over a project's `l10n.yaml`, as `flutter build` does. Declared by `flutter_library` and `flutter_application` in a package with an `l10n.yaml`; not written by hand.",
    attrs = {
        "pubspec": attr.label(
            doc = "The project's `pubspec.yaml` (gen-l10n requires `flutter: generate: true`).",
            allow_single_file = [".yaml"],
            mandatory = True,
        ),
        "l10n_yaml": attr.label(
            doc = "The project's `l10n.yaml`.",
            allow_single_file = [".yaml"],
            mandatory = True,
        ),
        "analysis_options": attr.label(
            doc = "The project's `analysis_options.yaml`, whose `formatter:` options `dart format` applies.",
            allow_single_file = [".yaml"],
        ),
        "srcs": attr.label_list(
            doc = "The `.arb` files of `arb-dir`, and the `header-file`, if any.",
            allow_files = True,
        ),
        "outputs": attr.string_list(
            doc = "What gen-l10n writes, by path under the project, as read from `l10n.yaml` and the `.arb` files.",
            mandatory = True,
        ),
        "language_version": attr.string(
            doc = "The project's language version, which `dart format` formats the files for; by default the SDK's.",
        ),
    },
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
)

def _under_lib(value):
    """Whether a `srcs` entry or `main` names a file under `lib/` of this package."""
    if type(value) == "Label":
        return value.repo_name == "" and value.package == native.package_name() and value.name.startswith("lib/")
    return type(value) == "string" and value.startswith("lib/")

# A helper of the macros that sets an argument, not a macro of its own.
# buildifier: disable=unnamed-macro
def project_language_version(kwargs, l10n):
    """Sets `language_version` to the one pub writes for the package's project, unless it is set.

    The project index (`L10N_PROJECTS`) holds, for each project of the main
    repository the `flutter` extension read, the `languageVersion` `pub get`
    writes for it: its pubspec's `environment: sdk:` lower bound. A target
    in that package compiles with it, as stock does, with nothing in the
    BUILD file; `language_version` overrides it.

    Args:
      kwargs: The target's arguments; changed in place.
      l10n: The `L10N_PROJECTS` table of `@flutter_l10n//:index.bzl`.
    """
    if native.repo_name():
        return
    version = language_version_default(kwargs, l10n.get(native.package_name()))
    if version:
        kwargs["language_version"] = version

def _add_project_files(kwargs, attr, files):
    """Appends `files` (package-relative names) to `kwargs[attr]`, skipping those it names already."""
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

# A helper of the macros that sets an argument, not a macro of its own.
# buildifier: disable=unnamed-macro
def project_license(kwargs, l10n):
    """Adds the project's licence file to `pubspec_srcs`, so `NOTICES` holds it as stock's does.

    The tool's `LicenseCollector` reads a `NOTICES` or `LICENSE` file at the
    root of every package of the package config, the project's own included.
    For a target in a project's package (`L10N_PROJECTS`) that has one and
    whose `pubspec` is that package's `pubspec.yaml`, the file is staged with
    the files the pubspec names.

    Args:
      kwargs: The target's arguments; changed in place.
      l10n: The `L10N_PROJECTS` table of `@flutter_l10n//:index.bzl`.
    """
    pubspec = kwargs.get("pubspec")
    if native.repo_name() or type(pubspec) not in ("string", "Label"):
        return
    if native.package_relative_label(pubspec) != native.package_relative_label("pubspec.yaml"):
        return
    project = l10n.get(native.package_name())
    license = getattr(project, "license", "") if project != None else ""
    if license:
        _add_project_files(kwargs, "pubspec_srcs", [license])

# A helper of the macros that sets an argument, not a macro of its own.
# buildifier: disable=unnamed-macro
def project_test_data(kwargs, l10n):
    """Adds the fixtures of the project's test tree to a test's `data`, and its `flutter_test_config.dart` to `srcs`.

    `flutter test` runs a test with the project readable, and a test reads its
    fixtures by a path relative to the project: `test/fixtures/x.json`, the
    goldens next to it. For a test in a project's package (`L10N_PROJECTS`),
    every file under `test/` that is not Dart source and not hidden, and is in
    that package, is `data` by default. A fixture edit reruns every test of
    the package. Files outside `test/` that a test reads (`lib/l10n/*.arb`, a
    platform manifest) are named in `data`.

    `flutter test` also wraps a test in the `flutter_test_config.dart` nearest
    its `main`, in its directory or above up to the project's: that file joins
    `srcs` when `srcs` names none of the project's. What the config imports is
    named in `srcs` as any other source.

    A file under `test/` whose name cannot be a label (a `:`, a `\\` or a
    control character in it) cannot be `data`: the tests of the package then
    fail at analysis, naming those files, as one error.

    Args:
      kwargs: The target's arguments; changed in place.
      l10n: The `L10N_PROJECTS` table of `@flutter_l10n//:index.bzl`.
    """
    if native.repo_name():
        return
    project = l10n.get(native.package_name())
    if project == None:
        return
    _add_project_files(kwargs, "data", getattr(project, "test_data", []))
    config = _nearest_test_config(kwargs.get("main"), getattr(project, "test_configs", []))
    srcs = kwargs.get("srcs", [])
    if config and not (type(srcs) == "list" and [s for s in srcs if type(s) == "string" and s.rpartition(":")[2].rpartition("/")[2] == "flutter_test_config.dart"]):
        _add_project_files(kwargs, "srcs", [config])
    unlabelable = getattr(project, "unlabelable", [])
    if unlabelable:
        name = "flutter_test_unlabelable_fixtures"
        if not native.existing_rule(name):
            _unlabelable_fixtures(
                name = name,
                files = unlabelable,
                visibility = ["//visibility:private"],
            )
        _add_project_files(kwargs, "data", [":" + name])

def _nearest_test_config(main, configs):
    """The config of `configs` (package-relative paths) nearest `main`, or None."""
    if not configs or type(main) != "string" or main.startswith("//") or main.startswith("@"):
        return None
    directory = main.removeprefix(":").rpartition("/")[0]
    for _ in range(main.count("/") + 1):
        candidate = (directory + "/" if directory else "") + "flutter_test_config.dart"
        if candidate in configs:
            return candidate
        if not directory:
            return None
        directory = directory.rpartition("/")[0]
    return None

def _unlabelable_fixtures_impl(ctx):
    fail(("{n} file(s) under the project's test/ cannot be Bazel labels, so no flutter_test of " +
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

def language_version_default(kwargs, project):
    """The language version a target takes from its project, or None to leave its arguments alone.

    Args:
      kwargs: The target's arguments.
      project: The package's entry of `L10N_PROJECTS`, or None.

    Returns:
      The project's language version when `kwargs` states none, else None.
    """
    if "language_version" in kwargs or project == None:
        return None
    return getattr(project, "language_version", "") or None

def l10n_attach(name, kwargs, l10n, always = False):
    """Gives a target in a project with an `l10n.yaml` what gen-l10n writes.

    In a package of the main repository whose `l10n.yaml` the `flutter`
    extension read (`L10N_PROJECTS`), declares once per package the
    `flutter_gen_l10n` target (`_gen_l10n`) and a `flutter_library` of its
    Dart files (`_l10n`, the project's package), and adds that library to the
    `deps` of a target whose `srcs` or `main` is under `lib/`, of a target
    whose `srcs` is a `select()` (which cannot be read here), and of every
    target when `always`. Copies of the generated files in the source tree,
    which the stock tool writes there, are left out of a list `srcs`.

    A package the extension did not read is left alone without reading the
    package: no `glob`, no `existing_rule`, so a target of such a package can
    be declared from a symbolic macro. In a package with localizations the
    per-package targets need `native.existing_rule`, which a symbolic macro
    cannot call: there Bazel fails with "existing_rule() can only be used
    while evaluating a BUILD file, a legacy macro, or a rule finalizer".

    Args:
      name: The calling target's name, for messages.
      kwargs: The calling target's arguments; changed in place.
      l10n: The `L10N_PROJECTS` table of `@flutter_l10n//:index.bzl`.
      always: Whether to add the library whatever `srcs` and `main` are.
    """
    if native.repo_name():
        return
    package = native.package_name()
    project = l10n.get(package)
    if project == None:
        return
    srcs = kwargs.get("srcs")
    readable = srcs == None or type(srcs) == "list"
    under_lib = (readable and [s for s in (srcs or []) if _under_lib(s)]) or _under_lib(kwargs.get("main"))
    if not always and readable and not under_lib:
        return
    if project.error:
        fail("//%s:%s: %s" % (package, name, project.error))
    if not project.outputs:
        return
    if not native.existing_rule(L10N_TARGET):
        flutter_gen_l10n(
            name = L10N_TARGET,
            pubspec = "pubspec.yaml",
            l10n_yaml = "l10n.yaml",
            analysis_options = "analysis_options.yaml" if project.analysis_options else None,
            srcs = project.srcs,
            outputs = project.outputs,
            language_version = kwargs.get("language_version", ""),
            visibility = ["//visibility:private"],
        )
    deps = kwargs.get("deps")
    labels = [native.package_relative_label(d) if type(d) == "string" else d for d in deps] if type(deps) == "list" else []
    library, library_deps = l10n_library_of(project, labels)
    if not native.existing_rule(library):
        flutter_library(
            name = library,
            package_name = project.package,
            srcs = [":" + L10N_TARGET],
            language_version = kwargs.get("language_version", ""),
            deps = library_deps,
            visibility = ["//visibility:private"],
        )
    if type(srcs) == "list":
        generated = {rel: True for rel in project.outputs}
        kwargs["srcs"] = [s for s in srcs if s not in generated]
    kwargs["deps"] = kwargs.get("deps", []) + [":" + library]

def l10n_library_of(project, deps):
    """The library of the generated files a target takes, and its `deps`.

    A project's lock can have several hubs (an iOS plugin mode's twins). The
    generated files import `flutter`, `flutter_localizations` and `intl` from
    the hub the target's own `deps` come from, so the target's closure has
    one copy of each: `_l10n` for the first hub declared with the lock (and
    for a target none of whose `deps` names a hub, or whose `deps` is a
    `select()`), `_l10n_<i>` for the hub declared `i`-th after it.

    Args:
      project: The package's entry of `L10N_PROJECTS`.
      deps: The target's `deps`, as labels.

    Returns:
      `(name, deps)` of the library.
    """
    index = {project.hubs[i][0]: i for i in range(len(project.hubs))}
    chosen = 0
    for label in deps:
        if type(label) == "Label" and label.repo_name in index:
            chosen = index[label.repo_name]
            break
    name = L10N_LIBRARY if chosen == 0 else "%s_%d" % (L10N_LIBRARY, chosen)
    return name, (project.hubs[chosen][1] if project.hubs else [])
