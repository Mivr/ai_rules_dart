"""The `dart_analyzer_summary` aspect: an analyzer summary of each Dart package.

Under `//dart:analyzer_summaries`, the `dart_analyze` aspect checks a target's
own files against the summaries of its dependencies, rather than against their
source. This aspect makes those summaries. It propagates along `deps`,
`library`, and `_sky_engine`, and `dart_analyze` requires it, so every
dependency of an analyzed target carries one.

A summary is the declarations of a package's libraries, and what constants they
need. It holds no function bodies, so a body edit leaves a package's summary
unchanged and its dependents are not checked again. It is built by the
`summarize` mode of `//dart/private/tools:analyzer_summary`, with the pinned
`package:analyzer`.

A summary refers to the SDK's libraries, which no package's summary holds, so
every summary-mode action also reads the SDK's own summary, one per SDK,
`analyzer_sdk_summary`. When a closure carries Flutter's `sky_engine` and its
`lib/_embedder.yaml`, the aspect builds an embedder SDK summary (`--embedder-yaml`)
that adds `dart:ui` and the embedder's other `dart:` libraries to the SDK
summary, marks `sky_engine` covered, and propagates that embedder SDK summary to
dependents in `embedder_sdk_summaries`.

With the flag off the aspect declares no actions and provides empty values, so
a build without the flag is as it was. The same holds where summary mode is
unsafe: a toolchain SDK newer than the pinned analyzer supports
(`analyzer_summaries_supported`), and a closure with an unbacked embedder
(`unbacked_embedder_in_closure`).
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "generate_package_config", "kernel_sdk_mismatch_error", "owned_package_records", "writable_home_env")
load("//dart/private:project_staging.bzl", "mangle_package_dir")
load("//dart/private:source_set.bzl", "package_for_index", "package_index")

# Summaries are built on the build machine, with the exec tools SDK, the type
# the codegen rules and `dart_analyze` use for the same reason.
_TOOLCHAIN = "//dart:exec_tools_toolchain_type"

# The newest Dart language version the pinned `package:analyzer` supports, as
# `<major>.<minor>`. Summary mode analyzes with that analyzer, so it is used only
# when the analyzing toolchain's SDK is not newer than this: a newer SDK may
# have language the analyzer cannot parse or type.
#
# Where the value comes from: the analyzer's `ExperimentStatus.currentVersion`,
# which is `_currentVersion` in `lib/src/dart/analysis/experiments.g.dart` of the
# pinned analyzer (14.5.0: `'3.14.0'`). When the pin in `dart/ext/pubspec.lock`
# moves, read the new value there and update this constant. Re-vendor
# `//third_party/dart_linter` from the same release at the same time, as its
# README says. Lowering the value turns summary mode off for the SDKs above it.
ANALYZER_MAX_LANGUAGE_VERSION = "3.14"

def _major_minor(version):
    """Returns `(major, minor)` of an SDK version such as `3.13.5`, or None.

    Args:
      version: A `major.minor[.patch][-prerelease]` string.

    Returns:
      A tuple of two ints, or None when `version` does not start that way.
    """
    core = version.split("-")[0].split(".")
    if len(core) < 2 or not core[0].isdigit() or not core[1].isdigit():
        return None
    return (int(core[0]), int(core[1]))

def analyzer_summaries_supported(sdk_version):
    """Returns whether summary mode may analyze with an SDK of version `sdk_version`.

    True when the SDK is no newer than `ANALYZER_MAX_LANGUAGE_VERSION`, compared
    by `major.minor`. A version that cannot be read is refused, so the build
    falls back to analysis from source.

    Args:
      sdk_version: The analyzing toolchain's `DartSdkInfo.version`.

    Returns:
      A bool.
    """
    sdk = _major_minor(sdk_version)
    if sdk == None:
        return False
    return sdk <= _major_minor(ANALYZER_MAX_LANGUAGE_VERSION)

# Prefixes a package key in `DartAnalyzerSummaryInfo.packages` when the package is
# split across targets: its own summary is not built, and every dependent of the
# target reads the marker as uncovered (see `_summaries_ready`).
CONFLICT_PREFIX = "conflict:"

# A Flutter embedder. `dart:ui` is not in the Dart SDK: the analyzer finds it
# through the `lib/_embedder.yaml` of Flutter's `sky_engine`, which
# `dart_analyzer_summary` turns into an embedder SDK summary. Pre-compiled
# codegen shims cannot take an embedder SDK summary, so `dart_codegen` still
# checks `embedder_in_closure`.
_EMBEDDER_PACKAGE = "sky_engine"
_EMBEDDER_FILE = "_embedder.yaml"

def embedder_in_closure(info):
    """Returns whether a target's closure holds a Flutter embedder.

    Args:
      info: The target's `DartInfo`.

    Returns:
      True when a package named `sky_engine` is in the closure, or any file
      `lib/_embedder.yaml` is in it.
    """
    for pkg in info.transitive_packages.to_list():
        if pkg.package_name == _EMBEDDER_PACKAGE:
            return True
    for f in info.transitive_resources.to_list():
        path = f.short_path
        if path == "lib/" + _EMBEDDER_FILE or path.endswith("/lib/" + _EMBEDDER_FILE):
            return True
    return False

def _own_embedder_yaml(info, files):
    """Returns the `lib/_embedder.yaml` file of `info`'s own `sky_engine` package, or None.

    Args:
      info: The target's `DartInfo`.
      files: Candidate `File`s, typically the target's `DefaultInfo` files.

    Returns:
      The `_embedder.yaml` `File` when `info` is `sky_engine` and carries one, or None.
    """
    if info.package_name != _EMBEDDER_PACKAGE:
        return None
    expected = ((info.lib_root + "/lib/") if info.lib_root else "lib/") + _EMBEDDER_FILE
    for f in files + info.transitive_resources.to_list():
        if f.short_path == expected:
            return f
    return None

def unbacked_embedder_in_closure(info, embedder_sdk_summary):
    """Returns whether `info`'s closure holds a Flutter embedder not backed by `embedder_sdk_summary`.

    A `sky_engine` package with `lib/_embedder.yaml` builds an embedder SDK
    summary (`embedder_sdk_summary`) that adds `dart:ui` and the rest of the
    embedder's `dart:` libraries to the SDK summary. When that summary is
    present, `sky_engine` and its `lib/_embedder.yaml` are backed; any other
    `lib/_embedder.yaml` (or `sky_engine` without an embedder SDK summary) is
    not.

    Args:
      info: The target's `DartInfo`.
      embedder_sdk_summary: The single embedder SDK summary `File` from the
        closure's `DartAnalyzerSummaryInfo.embedder_sdk_summaries`, or None.

    Returns:
      True when the closure has an embedder that `embedder_sdk_summary` does not
      cover.
    """
    if not embedder_in_closure(info):
        return False
    if embedder_sdk_summary == None:
        return True
    sky_embedders = {
        ((pkg.lib_root + "/lib/") if pkg.lib_root else "lib/") + _EMBEDDER_FILE: True
        for pkg in info.transitive_packages.to_list()
        if pkg.package_name == _EMBEDDER_PACKAGE
    }
    for f in info.transitive_resources.to_list():
        path = f.short_path
        if (path == "lib/" + _EMBEDDER_FILE or path.endswith("/lib/" + _EMBEDDER_FILE)) and path not in sky_embedders:
            return True
    return False

DartAnalyzerSummaryInfo = provider(
    doc = "A target's analyzer summaries, for `dart_analyze` in analyzer-summary mode.",
    fields = {
        "summary": "File or None: the summary of this target's own libraries. None when it has none, or the flag is off.",
        "transitive_summaries": "depset[File]: the summaries of this target and of every target it depends on.",
        "packaged_summaries": "depset[(str, File)]: the same summaries as `transitive_summaries`, each paired with the name of the package it summarizes. A consumer drops the pairs of its own package, which it reads from source.",
        "embedder_sdk_summaries": "depset[File]: embedder SDK summaries built from `sky_engine`'s `lib/_embedder.yaml` in this target's closure. When a single one is present, `summarize` and `analyze` read it instead of the plain SDK summary so `dart:ui` resolves.",
        "packages": "depset[str]: the keys (see `package_key`) of this target's own package and of every package its dependencies carry. A package in a closure that is missing here has no summary, so its dependents are analyzed from source.",
        "own_files": "depset[str]: `package_key` and `|` and the `short_path` of each of this target's own `lib/` sources, and of those of every target it depends on. Says which libraries the summaries define, so a target sharing its package with a dependency can tell whether it adds to that package.",
    },
)

def package_key(info):
    """Returns the key that identifies a package record: its name and root.

    Args:
      info: A `DartInfo`, or a `DartPackageInfo` record.

    Returns:
      A string that identifies the package. `dart_analyze` matches a closure's
      packages against the keys its dependencies cover.
    """
    return "%s|%s" % (info.package_name, info.lib_root)

def sdk_root_path(dart_sdk_info):
    """Returns the exec-root path of the SDK root that holds `dart`'s `bin/`.

    Args:
      dart_sdk_info: The `DartSdkInfo` of the exec tools toolchain.

    Returns:
      The SDK's root directory, as an exec-root-relative path.
    """
    return dart_sdk_info.dart.path.rsplit("/", 2)[0]

def _analyzer_sdk_summary_impl(ctx):
    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    mismatch = kernel_sdk_mismatch_error(ctx.label, "_tool", ctx.attr._tool, dart_sdk_info.version)
    if mismatch != None:
        fail(mismatch)
    summary = ctx.actions.declare_file(ctx.label.name + ".sum")
    args = ctx.actions.args()
    args.add("sdk")
    args.add("--sdk", sdk_root_path(dart_sdk_info))
    args.add("--out", summary)
    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [ctx.executable._tool.path, args],
        inputs = depset(
            direct = [ctx.executable._tool, dart_sdk_info.dart],
            transitive = [dart_sdk_info.analyze_files, dart_sdk_info.runtime_files],
        ),
        tools = depset(
            direct = [ctx.executable._tool, dart_sdk_info.dart],
            transitive = [dart_sdk_info.runtime_files],
        ),
        outputs = [summary],
        mnemonic = "DartAnalyzerSdkSummary",
        progress_message = "Summarizing the Dart SDK for analysis",
        env = writable_home_env(dart_sdk_info.dart, summary),
    )
    return [DefaultInfo(files = depset([summary]))]

analyzer_sdk_summary = rule(
    implementation = _analyzer_sdk_summary_impl,
    attrs = {
        "_tool": attr.label(
            default = "//dart/private/tools:analyzer_summary",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [_TOOLCHAIN],
    doc = """The summary of the SDK's own libraries, which every summary-mode action reads.

A dependency's summary refers to the SDK libraries it uses, and those are not in
any package's summary, so a summary-mode action needs this one as well. Built
once per SDK; `dart/private/BUILD.bazel` declares the instance the aspects use.
""",
)

def closure_attrs(ctx):
    """Returns the targets a rule's closure is built from: `deps`, `library`, and `_sky_engine`.

    The aspect propagates along the same three attributes, so every target here
    carries the provider, unless it is not a Dart target at all.

    Args:
      ctx: The rule or aspect context.

    Returns:
      A list of `Target`s.
    """
    targets = list(getattr(ctx.rule.attr, "deps", []))
    library = getattr(ctx.rule.attr, "library", None)
    if library != None:
        targets.append(library)
    sky_engine = getattr(ctx.rule.attr, "_sky_engine", None)
    if sky_engine != None:
        targets.append(sky_engine)
    return targets

def _own_record_for(own_records, short_path):
    """Returns the first owned record whose `lib/` contains `short_path`, or None.

    A one-package library matches its one record; a merged multi-package
    library matches the member package the file belongs to.

    Args:
      own_records: The target's own `DartPackageInfo` records, in order.
      short_path: A `File.short_path`.

    Returns:
      The matching record, or None.
    """
    for record in own_records:
        prefix = (record.lib_root + "/lib/") if record.lib_root else "lib/"
        if short_path.startswith(prefix):
            return record
    return None

def _own_sources(info, files):
    """Returns the `.dart` files of `files` that are `info`'s package's `lib/` files.

    Args:
      info: The target's `DartInfo`.
      files: Candidate `File`s, typically the target's `DefaultInfo` files.

    Returns:
      The package's library files, in the order given.
    """
    records = owned_package_records(info)
    if not records:
        return []
    return [
        f
        for f in files
        if f.extension == "dart" and _own_record_for(records, f.short_path) != None
    ]

def own_lib_sources(info, files):
    """Returns the `.dart` files among `files` that are in a package's `lib/`.

    Public form of `_own_sources`, for the `dart_analyze` aspect: a target whose
    own package is covered by a dependency conflicts with it only when it stages
    `lib/` files of its own. When `info` names its own package, checks that
    package's `lib/`; when `info` has no package of its own (an executable
    without `package_name`), checks the in-repo packages in its closure. A test
    or executable under `test/` or `bin/` stages none, and resolves its imports
    from the dependency's summary.

    Args:
      info: The target's `DartInfo`, or the closure of an executable.
      files: The target's own files.

    Returns:
      A list of the `lib/` library files.
    """
    if info.package_name:
        return _own_sources(info, files)
    prefixes = [
        (pkg.lib_root + "/lib/") if pkg.lib_root else "lib/"
        for pkg in info.transitive_packages.to_list()
        if pkg.package_name and not pkg.lib_root.startswith("../")
    ]
    if not prefixes:
        return []
    return [
        f
        for f in files
        if f.extension == "dart" and any([f.short_path.startswith(p) for p in prefixes])
    ]

def _has_own_sources(files):
    """Returns whether `files` hold Dart sources, or a directory of them (`srcs_dir`).

    Args:
      files: The target's `DefaultInfo` files.

    Returns:
      True when a `.dart` file or a directory is among them.
    """
    return any([f.is_directory or f.extension == "dart" for f in files])

def _package_uri(info, f):
    """Returns the `package:` URI of library `f` of the target's own package(s)."""
    for record in owned_package_records(info):
        prefix = (record.lib_root + "/lib/") if record.lib_root else "lib/"
        if f.short_path.startswith(prefix):
            return "package:%s/%s" % (record.package_name, f.short_path[len(prefix):])
    fail("summary source `%s` is in none of the target's packages." % f.short_path)

def _dart_analyzer_summary_impl(target, ctx):
    if DartInfo not in target:
        return []
    deps = closure_attrs(ctx)
    dependencies = depset(transitive = [
        d[DartAnalyzerSummaryInfo].transitive_summaries
        for d in deps
        if DartAnalyzerSummaryInfo in d
    ])
    info = target[DartInfo]
    if not ctx.attr._enabled[BuildSettingInfo].value or not analyzer_summaries_supported(ctx.toolchains[_TOOLCHAIN].dart_sdk_info.version):
        return [DartAnalyzerSummaryInfo(
            summary = None,
            transitive_summaries = depset(),
            packaged_summaries = depset(),
            embedder_sdk_summaries = depset(),
            packages = depset(),
            own_files = depset(),
        )]

    # A target's own package is covered only by a summary that covers it. A
    # target with sources of its own gets one below, or, for an opaque `srcs_dir`
    # directory, gets none, so its package stays uncovered and a dependent is
    # analyzed from source. A target with no sources of its own (a façade of
    # `deps`) has nothing to cover, so its package is covered. `sky_engine` with
    # `lib/_embedder.yaml` builds an embedder SDK summary that covers `sky_engine`
    # and gives its dependents `dart:ui`; a closure with an unbacked embedder gets
    # no summary of its own, and its package stays uncovered.
    files = target[DefaultInfo].files.to_list()
    srcs = _own_sources(info, files)
    inherited_embedder_sdks = depset(transitive = [
        d[DartAnalyzerSummaryInfo].embedder_sdk_summaries
        for d in deps
        if DartAnalyzerSummaryInfo in d
    ])
    # One key per owned package: a merged multi-package target summarizes all
    # of its members' files in this one summary. A target owning no package
    # keeps the empty package's key, as before.
    own_records = owned_package_records(info)
    own_keys = [package_key(record) for record in own_records] or [package_key(info)]
    own_key_by_path = {}
    for f in srcs:
        record = _own_record_for(own_records, f.short_path)
        if record != None:
            own_key_by_path[f.short_path] = package_key(record)
    lib_keys = [own_key_by_path.get(f.short_path, own_keys[0]) + "|" + f.short_path for f in srcs]
    own_files = depset(
        lib_keys,
        transitive = [d[DartAnalyzerSummaryInfo].own_files for d in deps if DartAnalyzerSummaryInfo in d],
    )
    packaged = depset(
        transitive = [d[DartAnalyzerSummaryInfo].packaged_summaries for d in deps if DartAnalyzerSummaryInfo in d],
    )

    embedder_yaml = _own_embedder_yaml(info, files)
    if embedder_yaml != None:
        dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
        mismatch = kernel_sdk_mismatch_error(ctx.label, "_tool", ctx.attr._tool, dart_sdk_info.version)
        if mismatch != None:
            fail(mismatch)
        embedder_sdk = ctx.actions.declare_file(ctx.label.name + ".embedder_sdk.sum")
        args = ctx.actions.args()
        args.add("sdk")
        args.add("--sdk", sdk_root_path(dart_sdk_info))
        args.add("--embedder-yaml", embedder_yaml)
        args.add("--out", embedder_sdk)
        ctx.actions.run(
            executable = dart_sdk_info.dart,
            arguments = [ctx.executable._tool.path, args],
            inputs = depset(
                direct = [ctx.executable._tool, dart_sdk_info.dart] + files,
                transitive = [dart_sdk_info.analyze_files, dart_sdk_info.runtime_files, info.transitive_srcs, info.transitive_resources],
            ),
            tools = depset(
                direct = [ctx.executable._tool, dart_sdk_info.dart],
                transitive = [dart_sdk_info.runtime_files],
            ),
            outputs = [embedder_sdk],
            mnemonic = "DartAnalyzerSdkSummary",
            progress_message = "Summarizing Dart embedder SDK %{label}",
            env = writable_home_env(dart_sdk_info.dart, embedder_sdk),
        )
        return [DartAnalyzerSummaryInfo(
            summary = None,
            transitive_summaries = dependencies,
            packaged_summaries = packaged,
            embedder_sdk_summaries = depset([embedder_sdk], transitive = [inherited_embedder_sdks]),
            packages = depset([key], transitive = [d[DartAnalyzerSummaryInfo].packages for d in deps if DartAnalyzerSummaryInfo in d]),
            own_files = own_files,
        )]

    embedder_sdk_list = inherited_embedder_sdks.to_list()
    embedder_sdk_summary = embedder_sdk_list[0] if len(embedder_sdk_list) == 1 else None
    embedder = unbacked_embedder_in_closure(info, embedder_sdk_summary)

    # A package split across targets: a dependency covers this target's own
    # package too, as `split` does through its wrapper, or a `dart_library` lists
    # a file another one lists. The dependency's summary and the target's own
    # sources define the same libraries, which the analyzer cannot check against
    # each other. This target builds no summary, and its package is marked as
    # conflicting, which every dependent reads as uncovered. Its dependents are
    # then analyzed from source, as they were before the flag existed.
    inherited = {
        k: True
        for d in deps
        if DartAnalyzerSummaryInfo in d
        for k in d[DartAnalyzerSummaryInfo].packages.to_list()
    }
    sibling_conflicts = []
    seen_pkg_files = {}
    for d in deps:
        if DartAnalyzerSummaryInfo not in d:
            continue
        d_by_pkg = {}
        for entry in d[DartAnalyzerSummaryInfo].own_files.to_list():
            pkg_k, _, _ = entry.rpartition("|")
            if pkg_k:
                d_by_pkg.setdefault(pkg_k, {})[entry] = True
        for pkg_k, file_map in d_by_pkg.items():
            if pkg_k in seen_pkg_files:
                if seen_pkg_files[pkg_k] != file_map and (CONFLICT_PREFIX + pkg_k) not in sibling_conflicts:
                    sibling_conflicts.append(CONFLICT_PREFIX + pkg_k)
            else:
                seen_pkg_files[pkg_k] = file_map
    split = False
    redundant = False
    if srcs and any([k in inherited for k in own_keys]):
        # A dependency covers one of this target's packages. Whether this
        # target adds to it depends on its own `lib/` files: one that no
        # dependency defines makes the package split (a `part` in this target,
        # or a file listed by two targets). When every one is defined already,
        # the target re-lists its dependency's library (a `dart_test_package`
        # over its `test_library`, say) and adds nothing.
        defined = {
            k: True
            for k in depset(transitive = [d[DartAnalyzerSummaryInfo].own_files for d in deps if DartAnalyzerSummaryInfo in d]).to_list()
        }
        split = any([k not in defined for k in lib_keys])
        redundant = not split
    own = list(own_keys) if (not embedder and not split and not sibling_conflicts and not redundant and (srcs or not _has_own_sources(files))) else []
    if split:
        own = [CONFLICT_PREFIX + k for k in own_keys]
    own = own + sibling_conflicts
    packages = depset(
        own,
        transitive = [d[DartAnalyzerSummaryInfo].packages for d in deps if DartAnalyzerSummaryInfo in d],
    )
    if not srcs or embedder or split or sibling_conflicts or redundant:
        return [DartAnalyzerSummaryInfo(
            summary = None,
            transitive_summaries = dependencies,
            packaged_summaries = packaged,
            embedder_sdk_summaries = inherited_embedder_sdks,
            packages = packages,
            own_files = own_files,
        )]

    name = ctx.label.name + ".dart_analyzer_summary"
    summary = ctx.actions.declare_file(name + ".sum")
    config = ctx.actions.declare_file(name + ".package_config.json")

    # Always stage the package's own libraries under `.summary_root` so
    # `package_config.json` never points at the real source tree where
    # undeclared files might exist on disk. A merged library stages each
    # member under its own directory: two members may ship the same
    # `lib/`-relative path, and one shared `lib/` could hold only one of them.
    staged = []
    own_staged_roots = {}
    if len(own_records) == 1:
        prefix = (info.lib_root + "/lib/") if info.lib_root else "lib/"
        stage_root = config.dirname + "/" + name + ".summary_root"
        for f in srcs:
            link = ctx.actions.declare_file(name + ".summary_root/lib/" + f.short_path[len(prefix):])
            ctx.actions.symlink(output = link, target_file = f)
            staged.append(link)
        own_root = stage_root
    else:
        stage_root = config.dirname + "/" + name + ".summary_root"
        for f in srcs:
            record = _own_record_for(own_records, f.short_path)
            member_prefix = (record.lib_root + "/lib/") if record.lib_root else "lib/"
            member_dir = name + ".summary_root/_own/" + mangle_package_dir(record.package_name)
            own_staged_roots[record.package_name] = stage_root + "/_own/" + mangle_package_dir(record.package_name)
            link = ctx.actions.declare_file(member_dir + "/lib/" + f.short_path[len(member_prefix):])
            ctx.actions.symlink(output = link, target_file = f)
            staged.append(link)
        own_root = stage_root

    # Covered dependency packages come from their `.sum` files, so their `rootUri`
    # must not point at undeclared real execroot directories where unsandboxed
    # workers could probe `pubspec.yaml` or `.dart` files. Uncovered dependency
    # packages (e.g. `srcs_dir` or split packages) have no summary, so their
    # declared files are staged under `.summary_root/_deps/` as well.
    all_pkgs = info.transitive_packages.to_list()
    if len(own_records) == 1:
        roots = {info.package_name: own_root}
    else:
        roots = dict(own_staged_roots)
    own_names = {record.package_name: True for record in own_records}
    uncovered_pkgs = {}
    conflicted_names = {}
    for pkg in all_pkgs:
        if pkg.package_name in own_names:
            continue
        pkey = package_key(pkg)
        if pkey in inherited and (CONFLICT_PREFIX + pkey) not in inherited:
            roots[pkg.package_name] = stage_root + "/_deps/" + mangle_package_dir(pkg.package_name)
        else:
            uncovered_pkgs[pkg.package_name] = pkg
            if (CONFLICT_PREFIX + pkey) in inherited:
                conflicted_names[pkg.package_name] = True

    uncovered_inputs = []
    uncovered_staged = []
    if uncovered_pkgs:
        if len(own_records) == 1:
            others = [f for f in info.transitive_srcs.to_list() if not f.short_path.startswith(prefix)]
        else:
            others = [f for f in info.transitive_srcs.to_list() if _own_record_for(own_records, f.short_path) == None]
        pkg_index = package_index(all_pkgs)
        by_pkg = {}
        for f in others:
            owner = package_for_index(f.short_path, pkg_index)
            if owner != None and owner in uncovered_pkgs:
                by_pkg.setdefault(owner, []).append(f)
        for pkg_name, pkg in uncovered_pkgs.items():
            pfiles = by_pkg.get(pkg_name, [])
            dep_mangled = mangle_package_dir(pkg_name)
            if not pfiles:
                roots[pkg_name] = stage_root + "/_deps/" + dep_mangled
            elif len(pfiles) == 1 and pfiles[0].is_directory:
                dir_link = ctx.actions.declare_directory(name + ".summary_root/_deps/" + dep_mangled)
                ctx.actions.symlink(output = dir_link, target_file = pfiles[0])
                uncovered_inputs.append(dir_link)
                uncovered_inputs.extend(pfiles)
                roots[pkg_name] = stage_root + "/_deps/" + dep_mangled
            else:
                dep_prefix = (pkg.lib_root + "/lib/") if pkg.lib_root else "lib/"
                for f in pfiles:
                    if f.is_directory or not f.short_path.startswith(dep_prefix):
                        continue
                    rel = f.short_path[len(dep_prefix):]
                    link = ctx.actions.declare_file(name + ".summary_root/_deps/" + dep_mangled + "/lib/" + rel)
                    ctx.actions.symlink(output = link, target_file = f)
                    uncovered_inputs.append(link)
                    uncovered_staged.append(link)
                uncovered_inputs.extend(pfiles)
                roots[pkg_name] = stage_root + "/_deps/" + dep_mangled

    ctx.actions.write(
        output = config,
        content = generate_package_config(
            all_pkgs,
            [],
            config,
            roots = roots,
        ),
    )

    summary_inputs = (
        depset([s for (pname, s) in packaged.to_list() if pname not in conflicted_names]) if conflicted_names else dependencies
    )

    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    mismatch = kernel_sdk_mismatch_error(ctx.label, "_tool", ctx.attr._tool, dart_sdk_info.version)
    if mismatch != None:
        fail(mismatch)
    sdk_summary = embedder_sdk_summary or ctx.file._sdk_summary
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("summarize")
    args.add("--sdk", sdk_root_path(dart_sdk_info))
    args.add("--packages", config)
    args.add("--out", summary)
    args.add("--sdk-summary", sdk_summary)
    for f, link in zip(srcs, staged):
        args.add("--source", link)
        args.add("--uri", _package_uri(info, f))
    if uncovered_staged:
        args.add_all(uncovered_staged, before_each = "--dep-source")
    args.add_all(summary_inputs, before_each = "--summary")
    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [ctx.executable._tool.path, args],
        inputs = depset(
            direct = [ctx.executable._tool, dart_sdk_info.dart, config, sdk_summary] + srcs + staged + uncovered_inputs,
            transitive = [dart_sdk_info.analyze_files, dart_sdk_info.runtime_files, summary_inputs],
        ),
        tools = depset(
            direct = [ctx.executable._tool, dart_sdk_info.dart],
            transitive = [dart_sdk_info.runtime_files],
        ),
        outputs = [summary],
        mnemonic = "DartAnalyzerSummary",
        progress_message = "Summarizing Dart library %{label}",
        env = writable_home_env(dart_sdk_info.dart, summary),
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
    )
    return [DartAnalyzerSummaryInfo(
        summary = summary,
        transitive_summaries = depset([summary], transitive = [dependencies]),
        packaged_summaries = depset(
            [(record.package_name, summary) for record in own_records] or [(info.package_name, summary)],
            transitive = [packaged],
        ),
        embedder_sdk_summaries = inherited_embedder_sdks,
        packages = packages,
        own_files = own_files,
    )]

dart_analyzer_summary = aspect(
    implementation = _dart_analyzer_summary_impl,
    # `deps` is what rules_dart builds a closure from. `library` is where
    # `dart_test_package` names its library, and `_sky_engine` is where
    # rules_flutter's library, plugin, test, and web rules attach Flutter's
    # `sky_engine` embedder package.
    attr_aspects = ["deps", "library", "_sky_engine"],
    attrs = {
        "_enabled": attr.label(
            default = "//dart:analyzer_summaries",
            providers = [BuildSettingInfo],
        ),
        "_sdk_summary": attr.label(
            default = "//dart/private:analyzer_sdk_summary_input",
            allow_single_file = True,
        ),
        "_tool": attr.label(
            default = "//dart/private:analyzer_summary_tool",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [_TOOLCHAIN],
    doc = "Summarizes each Dart package for `dart_analyze`'s analyzer-summary mode; see `//dart/private/dart_analyzer_summary.bzl`.",
)
