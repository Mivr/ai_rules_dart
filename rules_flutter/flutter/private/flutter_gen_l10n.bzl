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
    args.add("--sdk", "bin/cache/dart-sdk/bin/dart=" + sdk.dart.path)
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
        flutter_library(
            name = L10N_LIBRARY,
            package_name = project.package,
            srcs = [":" + L10N_TARGET],
            language_version = kwargs.get("language_version", ""),
            deps = project.deps,
            visibility = ["//visibility:private"],
        )
    if type(srcs) == "list":
        generated = {rel: True for rel in project.outputs}
        kwargs["srcs"] = [s for s in srcs if s not in generated]
    kwargs["deps"] = kwargs.get("deps", []) + [":" + L10N_LIBRARY]
