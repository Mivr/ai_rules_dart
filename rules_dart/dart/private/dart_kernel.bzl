"""Modular kernel compilation for `dart_library`, `dart_binary(compile_mode = "kernel")`, and `dart_test`.

Whole-program compilation puts every package in an executable's closure into that
executable's own kernel. With 30 tests, `package:test` is compiled 30 times, and a
one-line edit in a leaf library recompiles every test that reaches it.

Every `dart_test` and `dart_binary(compile_mode = "kernel")` (including
`package:test`'s `test_runner`) compiles this way, splitting the work along
`dart_library` boundaries; only a `dart_binary` with `modular_kernel = False`
(the rule set's own tools) compiles from sources. Each library
compiles its own sources into a module: a `.kmod` directory of one kernel per
component of its sources (without the source text), a `.koutline` directory
holding the module's outline, which is what a dependant compiles against, and an
index in each. The outline is the compiled module without executable code; a
class that can be used as a mixin (`mixin`, `mixin class`, and every class in a
library whose language version is below 3.0) stays whole in it. Both are written
by the module compiler, a program built on the SDK's own front end at the tag of
the SDK that runs it (see `module_compiler.bzl`), so nothing in the rules reads
or writes the kernel format. An executable compiles only its entry module, and
links the `.kmod` kernels it reaches through the indexes, in dependency order,
which the VM runs as one program. A kernel nothing reaches is never linked.

A module's package config names every package by a multi-root URI,
`org-dartlang-root:///<path>`. The compiler resolves that against the source tree
and the output tree alike, so a package split between the two (a generated
part) is read where it lies and never copied.

A module compiles the sources its library declares that compile for the target.
The module compiler decides which those are from the front end's own result: a
library that does not compile (it imports a `dart:` library the VM lacks, say),
one that imports a library no dependency module defines, and every library that
imports one of those are left out, and the module compiles once more with exactly
the libraries it keeps. The sources left out are listed, with the reason, in the
module's `.vm_excluded.txt` sidecar and in its outline directory, which stages
them. An executable whose entry module reaches one compiles it from source, so it
fails exactly as a whole-program compile would when the VM cannot run it, and
names the module that left it out and why. An import of a file that is not a
declared input is not a reason to leave a library out: it fails the module.

A kernel executable has one path: its entry module and the link. A shape that
path cannot take fails the build where it is found, naming the target and the
reason, rather than compiling the program another way. The actions are built
only when a consumer needs them, so a library used only by AOT binaries never
compiles its module.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartInfo", _DartKernelInfo = "DartKernelInfo")
load("//dart/private:aot_tool.bzl", "aot_tool_launch")
load(
    "//dart/private:build_settings.bzl",
    "EXECUTABLE_DEFINES_ATTRS",
    "EXTRA_DART_DEFINES_ATTR",
    "REFUSED_DART_LIBRARIES_ATTR",
    "canonical_dart_defines",
    "executable_dart_defines",
    "validate_dart_defines",
    _global_dart_defines = "global_dart_defines",
)
load(
    "//dart/private:common.bzl",
    "STABLE_SCHEME",
    "collect_transitive_srcs",
    "generate_stable_package_config",
    "sdk_path_from_dart",
    "stable_path",
    "writable_home_env",
)
load("//dart/private:closure_facts.bzl", "lib_roots_of", "root_key")
load("//dart/private:dart_info.bzl", "package_lib_prefix")
load("//dart/private:kernel_exec_link.bzl", "exec_base_dill", "exec_link_closure")
load(
    "//dart/private:kernel_library_state.bzl",
    "DartKernelCycleInfo",
    "LAYERING_FEATURE",
    "add_package_records",
    "direct_packages",
    "lib_has_cross",
    "lib_kernel_base",
    "lib_kernel_facade",
    "lib_kernel_fast_state",
    "lib_kernel_graph",
    "lib_kernel_needs_graph",
    "lib_kernel_plain_srcs",
    "lib_owns_compatible",
    "library_module_inputs",
    "own_packages",
)
load(
    "//dart/private:kernel_params.bzl",
    "VM_PRODUCT_ATTR",
    "kernel_compile_settings",
    "kernel_module_inputs",
    "kernel_module_options",
    "kernel_module_outputs",
    "library_kernel_options",
    "library_kernel_sources",
)

visibility(["//dart/..."])

# The `org-dartlang-root` scheme `--multi-root` maps onto the exec root (`.`) and
# the output directory (`ctx.bin_dir`). Its URIs are the exec-root-relative paths
# a `File.short_path` already gives, so no path is copied or rewritten to make a
# generated file reachable.

_TOOLCHAIN_TYPE = Label("//dart:toolchain_type")
EXEC_TOOLS_TOOLCHAIN = Label("//dart:exec_tools_toolchain_type")

DartKernelInfo = _DartKernelInfo

def _kernel_link_for_mode(compile_mode, modular_kernel):
    if compile_mode in ("kernel", "exe", "aot-snapshot") and modular_kernel:
        return Label("//dart/private/tools:kernel_link")
    return None

# The link tool. `dart_library` takes these (its module), `dart_test` takes
# `MODULAR_KERNEL_ATTRS`, and `dart_binary` takes `BINARY_MODULAR_KERNEL_ATTRS`
# (which resolves the link tool only for the modes that link modules, `kernel`,
# `exe` and `aot-snapshot`, and only when `modular_kernel` is on: the tools set
# it to `False`, so none depends on itself).
#
# The module compiler is not an attribute: it is built per SDK and comes with the
# exec tools toolchain (`DartSdkInfo.module_compiler`).
KERNEL_MODULE_ATTRS = {
    "_kernel_link": attr.label(
        doc = "The tool that links an executable's kernel from the kernels its entry reaches. See `kernel_link.dart`.",
        default = Label("//dart/private/tools:kernel_link"),
        executable = True,
        cfg = "exec",
    ),
} | VM_PRODUCT_ATTR | EXECUTABLE_DEFINES_ATTRS | REFUSED_DART_LIBRARIES_ATTR

MODULAR_KERNEL_ATTRS = dict(KERNEL_MODULE_ATTRS)

BINARY_MODULAR_KERNEL_ATTRS = {
    "modular_kernel": attr.bool(
        default = True,
        doc = "Whether `compile_mode = \"kernel\"` compiles as kernel modules linked into one kernel (`exe` and `aot-snapshot` compile from sources unless `link_modules = True` opts them in, see `compile_mode`). `True` by default; a shape the modules cannot take then fails the build, naming the reason. `False` compiles the whole program from sources with `gen_kernel`: only the rule set's own tools do, because the link tool cannot link itself.",
    ),
    "_kernel_link": attr.label(
        doc = "The tool that links an executable's kernel from the kernels its entry reaches, when `compile_mode` is `kernel`, `exe` or `aot-snapshot`.",
        default = _kernel_link_for_mode,
        executable = True,
        cfg = "exec",
    ),
}

# Optional, so a rule that compiles no module (an AOT binary, a library only AOT
# binaries reach) builds without it. A kernel executable, and a library, whose
# exec tools toolchain is absent or names an SDK version with no pinned module
# compiler sources fail at analysis. See `kernel_tools_for`.
MODULAR_KERNEL_TOOLCHAINS = [
    config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
]

def multi_root_uri(short_path, scheme = STABLE_SCHEME):
    """The multi-root URI for a path, or for a package root.

    The URI is the shared stable URI of `common.bzl`, so the module compile and the
    whole-program compile name a file the same way. The root package's empty
    `lib_root` maps to the bare scheme root, which the scheme's roots resolve to the
    exec root and the output directory.

    Args:
        short_path: A `File.short_path`, or a `DartPackageInfo.lib_root`.
        scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).

    Returns:
        The URI string, e.g. `org-dartlang-root:///pkg/a`.
    """
    return scheme + ":///" + stable_path(short_path)

def entry_source_uri(short_path, scheme = STABLE_SCHEME):
    """The URI an entry module's source is compiled under.

    Entry sources are addressed by where they sit, not by `package:` name, because
    a test reaches its own files by relative path and that path has to resolve the
    way it does in the monolithic compile.

    Args:
      short_path: The source's `File.short_path`.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).

    Returns:
      The URI string.
    """
    return multi_root_uri(short_path, scheme = scheme)

def _owned_source_uri(short_path, packages):
    """The `package:` URI of an owned source of a multi-package library.

    The library owns several packages, so the single-package
    `library_source_uri` cannot name the file: the package is the one of the
    library's records whose `lib/` contains it.

    Args:
      short_path: The source's `File.short_path`.
      packages: The library's deduplicated `DartPackageInfo` records.

    Returns:
      The URI string, e.g. `package:dio/dio.dart`.
    """
    name = package_of_source(short_path, packages)
    if name == None:
        fail("kernel module source `%s` is in none of the library's packages: %s." % (
            short_path,
            ", ".join(sorted([pkg.package_name for pkg in packages])),
        ))
    for pkg in packages:
        if pkg.package_name == name:
            return library_source_uri(pkg.package_name, pkg.lib_root, short_path)
    fail("kernel module source `%s` names package \"%s\", which has no record." % (short_path, name))

def library_source_uri(package_name, lib_root, short_path):
    """The `package:` URI of a library's own source.

    The file's `short_path` lies under `<lib_root>/lib/`, which `dart_library`
    enforces. The URI is that path relative to `lib/`, so the package config's
    root for the package turns it back into the same file.

    Args:
      package_name: The package the library declares.
      lib_root: The package's `lib_root`; empty for the root package.
      short_path: The source's `File.short_path`.

    Returns:
      The URI string, e.g. `package:a/src/x.dart`.
    """
    prefix = package_lib_prefix(lib_root)
    return "package:%s/%s" % (package_name, short_path[len(prefix):])

def library_module_source(package_name, lib_root, f):
    """One source of a single-package library's module, as `kernel_module_inputs` takes it.

    A source directory (a `srcs_dir`, assembled by `dart_source_set`) is the
    package root: the module compiler compiles each `.dart` file under its
    `lib/`, under `package:<name>/` plus the file's path, finding the files when
    it runs. A file is named by `library_source_uri`.

    Args:
      package_name: The package the library declares.
      lib_root: The package's `lib_root`; for a source directory, its short path.
      f: The source File, or the source directory.

    Returns:
      A `struct(uri, file)`, with `dir` (the directory whose files are the sources) for a directory.
    """
    if f.is_directory:
        return struct(uri = "package:%s/" % package_name, file = f, dir = f.path + "/lib")
    return struct(uri = library_source_uri(package_name, lib_root, f.short_path), file = f)

def add_module_source_args(args, sources, own_files):
    """Adds a module's sources to its compile request. Returns None.

    Args:
      args: The request `Args`.
      sources: The `struct(uri, file)` sources (`dir` set for a source directory).
      own_files: Whether to name each source file as the module's own (`--own-source-file`), which the
        unused-inputs list never names.
    """
    for s in sources:
        if getattr(s, "dir", None) != None:
            args.add("--source-dir", s.uri)
            args.add(s.dir)
            continue
        args.add("--source", s.uri)
        args.add("--input-source", s.file)
        if own_files:
            args.add("--own-source-file", s.file)

def kernel_package_config(packages, scheme = STABLE_SCHEME):
    """The package config a module or an entry compiles against.

    `generate_stable_package_config` with every package kept. Its filter drops a
    package no file of `all_srcs` lives in, and a module must keep every package its
    own sources may import, whichever files they are, so every name is given as a
    root.

    Args:
        packages: `DartPackageInfo` records, one per package name.
        scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).

    Returns:
        The `package_config.json` content.
    """
    return generate_stable_package_config(
        packages,
        [],
        roots = {pkg.package_name: True for pkg in packages},
        scheme = scheme,
    )

def kernel_packages_consistent(records):
    """Whether a closure's package records fit one multi-root URI per name.

    A package config holds one `rootUri` per name. Two `lib_root`s under one name
    (a package split across targets that sit in different directories, or two pub
    hubs) cannot both be named, so the closure must compile whole-program. Two
    root packages cannot share the bare scheme root either.

    Args:
      records: `DartPackageInfo` records, duplicates kept.

    Returns:
      True when every name has one `lib_root` and at most one package is the root.
    """
    root_of = {}
    root_names = {}
    for pkg in records:
        seen = root_of.get(pkg.package_name)
        if seen == None:
            root_of[pkg.package_name] = pkg.lib_root
        elif seen != pkg.lib_root:
            return False
        if not pkg.lib_root:
            root_names[pkg.package_name] = True
    return len(root_names) <= 1

def first_per_package(records):
    """Keeps the first record for each package name, in order.

    Used for a module's package config, after `kernel_packages_consistent` has
    confirmed that a name never appears with two roots. Unlike
    `merge_package_records` this does not compare versions: a library analysed
    alone should not fail on a disagreement that only an executable reaching both
    could see, and that executable's own `merge_package_records` still reports it.

    Args:
      records: `DartPackageInfo` records, duplicates kept.

    Returns:
      One record per package name.
    """
    seen = {}
    out = []
    for pkg in records:
        if pkg.package_name in seen:
            continue
        seen[pkg.package_name] = True
        out.append(pkg)
    return out

def _edge_list(edges):
    """The `(label, dep_label)` edge list, flattened only when asked for.

    Callers that may not need the edges pass a depset, or a function returning
    the list (see `_closure_scan`), so the closure-sized flatten runs only on
    the shapes that read them.

    Args:
      edges: A list, a depset, or a function of no arguments returning a list.

    Returns:
      The list of edges.
    """
    if type(edges) == "function":
        return edges()
    if type(edges) == "depset":
        return edges.to_list()
    return edges

def duplicated_source(own_paths, owned, edges):
    """The source a modular executable cannot compile, or None.

    Each `dart_library` compiles the sources it lists into its module, and the
    executable links the modules it reaches. Within one dependency chain the module
    compiler keeps one definition of a source: a library whose dependency module
    already defines the source does not compile it again. Two
    libraries that do not depend on each other each compile their own copy, and the
    executable would link two kernels that define one library. The frontend refuses
    that, and a whole-program compile merges the copies by file, so it never saw the
    problem. Such an executable falls back to whole-program compilation.

    The executable's own sources are compiled by its entry module, which does not
    dedupe against the libraries, so a source it shares with a library falls back too.

    Args:
      own_paths: The `short_path` of each of the executable's own sources.
      owned: The `(label, short_path)` of each source of each library in its closure.
      edges: The `(label, dep_label)` of each `dart_library` dependency in its
        closure: a list, or a depset or function (see `_edge_list`) that is
        flattened only when some source has two owners.

    Returns:
      The `short_path` of the first source that cannot compile modularly, or None.
    """
    found = duplicated_source_owners(own_paths, owned, edges)
    return found.path if found != None else None

def duplicated_source_owners(own_paths, owned, edges):
    """The source a modular executable cannot compile, and the targets that list it, or None.

    See `duplicated_source`.

    Args:
      own_paths: The `short_path` of each of the executable's own sources.
      owned: The `(label, short_path)` of each source of each library in its closure.
      edges: The `(label, dep_label)` of each `dart_library` dependency in its closure.

    Returns:
      `struct(path, own, owners)`, or None: `path` is the source's `short_path`;
      `own` is True when the executable lists it too; `owners` the sorted labels
      of the libraries that list it (both of them when `own` is False).
    """
    own = {}
    for path in own_paths:
        own[path] = True
    owners = {}
    shared = False
    for label, path in owned:
        if path in own:
            listing = sorted({lbl: True for lbl, p in owned if p == path}.keys())
            return struct(path = path, own = True, owners = listing)
        labels = owners.setdefault(path, {})
        labels[label] = True
        if len(labels) > 1:
            shared = True
    if not shared:
        # Every source has one owner: no pair to test, so the edges are not read.
        return None
    reaches = {}
    for label, dep in _edge_list(edges):
        reaches.setdefault(label, {})[dep] = True
    for path in sorted(owners.keys()):
        labels = sorted(owners[path].keys())
        for i in range(len(labels)):
            for j in range(i + 1, len(labels)):
                first = labels[i]
                second = labels[j]
                if not _depends_on(reaches, first, second) and not _depends_on(reaches, second, first):
                    return struct(path = path, own = False, owners = [first, second])
    return None

def _package_relative(label, path):
    """`path` relative to the package of `label`, or `path` when it lies outside it."""
    package = label.split("//", 1)[-1].split(":", 1)[0]
    if package and path.startswith(package + "/"):
        return path[len(package) + 1:]
    return path

def duplicated_source_message(found, program):
    """What a user reads when one source belongs to two targets: which, and what to change.

    Args:
      found: The struct from `duplicated_source_owners`.
      program: The label of the executable, as a string.

    Returns:
      The message.
    """
    libraries = " and ".join(found.owners)
    if found.own:
        rel = _package_relative(found.owners[0], found.path)
        return (
            "source %s is listed by two targets, %s and %s: one source belongs to one target. " +
            "Remove it from the library's `srcs` (for example `glob([\"lib/**/*.dart\"], exclude = [\"%s\"])`), " +
            "or give %s only `main` and leave the rest of `lib/` to the library"
        ) % (found.path, program, libraries, rel, program)
    return (
        "source %s is listed by two libraries, %s, and neither depends on the other: one source belongs " +
        "to one target. Remove it from the `srcs` of one of them, or make one depend on the other"
    ) % (found.path, libraries)

def _depends_on(reaches, label, target):
    """Whether `label` depends on `target`, directly or through other libraries.

    Args:
      reaches: The `label` -> {dep_label: True} edges of the closure.
      label: The depending label.
      target: The label it may depend on.

    Returns:
      True when `target` is reached from `label` by at least one edge.
    """
    visited = {label: True}
    frontier = [label]
    for _ in range(len(reaches) + 1):
        if not frontier:
            break
        following = []
        for current in frontier:
            for dep in reaches.get(current, {}):
                if dep == target:
                    return True
                if dep not in visited:
                    visited[dep] = True
                    following.append(dep)
        frontier = following
    return False

def package_of_source(short_path, packages):
    """The `package_name` of the deepest `DartPackageInfo` whose `lib/` contains `short_path`, or None.

    Args:
      short_path: The source file's `File.short_path`.
      packages: The `DartPackageInfo` records to search; the one with the deepest matching `lib/` wins.

    Returns:
      The matching `package_name` string, or None.
    """
    best_name = None
    best_len = -1
    for pkg in packages:
        prefix = package_lib_prefix(pkg.lib_root)
        if short_path.startswith(prefix) and len(prefix) > best_len:
            best_name = pkg.package_name
            best_len = len(prefix)
    return best_name

def package_prefix_index(packages):
    """Indexes packages by the `lib/` prefix their files lie under.

    `package_of_indexed_source` answers with this index what `package_of_source`
    answers by scanning every package, so a closure of files costs one lookup
    per directory level of each file instead of one comparison per package.

    Args:
      packages: The `DartPackageInfo` records, in the order `package_of_source`
        would scan them.

    Returns:
      A dict from `lib/` prefix (e.g. `pkg/a/lib/`) to `package_name`. When two
      records share a prefix the first one wins, as in `package_of_source`.
    """
    index = {}
    for pkg in packages:
        prefix = package_lib_prefix(pkg.lib_root)
        if prefix not in index:
            index[prefix] = pkg.package_name
    return index

def package_of_indexed_source(short_path, index):
    """`package_of_source` over a `package_prefix_index`.

    Every `lib/` prefix ends in `/`, so a prefix that `short_path` starts with
    is one of the path's own directory prefixes. Checking each of them, the
    deepest that is indexed wins, exactly as the deepest matching package wins
    in `package_of_source`.

    Args:
      short_path: The source file's `File.short_path`.
      index: The dict from `package_prefix_index`.

    Returns:
      The matching `package_name` string, or None.
    """
    best = None
    prefix = ""
    parts = short_path.split("/")
    for part in parts[:-1]:
        prefix += part + "/"
        name = index.get(prefix)
        if name != None:
            best = name
    return best

def _cyclic_label_index(owned, packages):
    """Indexes owned sources by label and package. Returns (pkg_of_label, labels_of_pkg, paths_of_label)."""
    pkg_of_label = {}
    labels_of_pkg = {}
    paths_of_label = {}
    index = package_prefix_index(packages)
    for label, path in owned:
        paths_of_label.setdefault(label, []).append(path)
        pkg = package_of_indexed_source(path, index)
        if pkg != None:
            pkg_of_label[label] = pkg
            labels_of_pkg.setdefault(pkg, {})[label] = True
    return pkg_of_label, labels_of_pkg, paths_of_label

def _dependents(edges, seeds):
    """Every label that depends on one of `seeds` through at least one edge.

    One walk up the reversed edges from all seeds at once, so the cost is
    linear in the edges rather than one `_depends_on` search per label and
    seed. A seed is in the result only when another seed, or a cycle, leads
    back to it, as `_depends_on` would report.

    Args:
      edges: The `(label, dep_label)` edge list.
      seeds: The labels to find the dependents of.

    Returns:
      A dict whose keys are the dependent labels.
    """
    parents = {}
    for label, dep in edges:
        parents.setdefault(dep, []).append(label)
    found = {}
    frontier = list(seeds)

    # Each round finds at least one new label, and there are at most as many
    # labels as edges, so the walk always ends before the bound.
    for _ in range(len(edges) + 1):
        if not frontier:
            break
        following = []
        for current in frontier:
            for parent in parents.get(current, []):
                if parent not in found:
                    found[parent] = True
                    following.append(parent)
        frontier = following
    return found

def _cyclic_split_pkgs(own_package, dep_packages, labels_of_pkg, pkg_of_label, edges, is_executable):
    """Returns the set of split packages seeding the cyclic-paths computation."""
    split_pkgs = {
        pkg: True
        for pkg, labels in labels_of_pkg.items()
        if len(labels) > 1
    }
    if not is_executable and bool(own_package) and any([p.package_name == own_package for p in dep_packages]):
        split_pkgs[own_package] = True
    if is_executable and bool(own_package) and own_package not in split_pkgs:
        own_pkg_labels = [label for label, pkg in pkg_of_label.items() if pkg == own_package]
        others = [label for label, pkg in pkg_of_label.items() if pkg != own_package]
        if own_pkg_labels and others:
            dependents = _dependents(_edge_list(edges), own_pkg_labels)
            for label in others:
                if label in dependents:
                    split_pkgs[own_package] = True
                    break
    return split_pkgs

def _cyclic_active_labels(paths_of_label, pkg_of_label, edges, split_pkgs):
    """Returns the labels in split packages plus everything depending on them."""
    seed_labels = {label: True for label, pkg in pkg_of_label.items() if pkg in split_pkgs}
    dependents = _dependents(_edge_list(edges), seed_labels.keys())
    return {
        label: True
        for label in paths_of_label
        if label in seed_labels or label in dependents
    }

def _cyclic_source_paths(own_package, dep_packages, owned, edges, packages, is_executable = False):
    """The `short_path`s of sources in split or cyclic packages and targets depending on them.

    `edges` is a list, or a depset or function (see `_edge_list`) that is
    flattened only when a package is split.
    """
    pkg_of_label, labels_of_pkg, paths_of_label = _cyclic_label_index(owned, packages)
    split_pkgs = _cyclic_split_pkgs(own_package, dep_packages, labels_of_pkg, pkg_of_label, edges, is_executable)
    if not split_pkgs:
        return {}
    active_labels = _cyclic_active_labels(paths_of_label, pkg_of_label, edges, split_pkgs)
    return {
        path: True
        for label in active_labels
        for path in paths_of_label.get(label, [])
    }

def has_cross_pkg_cycle(
        own_package,
        dep_packages,
        owned = [],
        edges = [],
        packages = [],
        non_standalone = False,
        is_executable = False):
    """Whether a library or executable participates in a cross-target package split or cycle.

    A Dart package split across multiple `dart_library` targets (such as a cycle
    between `package:a` and `package:b` broken into `a_base <- b <- a_top`, or two
    sibling libraries sharing `package_name = "a"`), or a library tagged
    `no-dart-analyze` because its sources are not standalone, can cause a file in
    one target to import a `package:` URI owned by another target that is not in its
    own module closure. The module compiler leaves those files out at module compile time
    so the entry module compiles them from source together with the rest of the
    closure. When this returns True, the participating sources are carried in
    `DartKernelInfo.cross_pkg_srcs` so the entry module action declares them as
    inputs.

    Args:
      own_package: The target's own `package_name` (empty when it contributes no
        package).
      dep_packages: The `DartPackageInfo` records of the target's dependencies.
      owned: Optional `(label, short_path)` pairs of library sources in the closure.
      edges: Optional `(label, dep_label)` dependency edges in the closure.
      packages: Optional deduplicated `DartPackageInfo` records (including the
        target's own record). Defaults to `dep_packages`.
      non_standalone: True when the target carries the `no-dart-analyze` tag.
      is_executable: True when evaluating an executable rather than a library.

    Returns:
      True when the closure has a cross-target package split or cycle (or is tagged
      `no-dart-analyze`).
    """
    if non_standalone:
        return True
    if not is_executable and bool(own_package) and any([p.package_name == own_package for p in dep_packages]):
        return True
    if not owned and len({p.package_name: True for p in dep_packages}) < len(dep_packages):
        return True
    pkgs = packages if packages else dep_packages
    return len(_cyclic_source_paths(own_package, dep_packages, owned, edges, pkgs, is_executable = is_executable)) > 0

def _has_no_analyze_tag(ctx):
    for holder in [getattr(ctx, "rule", None), ctx]:
        if holder != None and hasattr(holder, "attr") and hasattr(holder.attr, "tags"):
            if "no-dart-analyze" in holder.attr.tags:
                return True
    return False

def find_kernel_module_tools(dart_sdk_info):
    """Locates the files a module compile runs from, in an SDK.

    Args:
      dart_sdk_info: The `DartSdkInfo` of the exec tools toolchain.

    Returns:
      `struct(dart, dartvm, runtime_files, dartaotruntime, module_compiler,
      platform_dill, version)`, or None when the SDK has no module compiler:
      its version has no pinned source closure (see
      `module_compiler_versions.bzl`), or it lacks `dartaotruntime` or the
      platform kernel.
    """
    module_compiler = getattr(dart_sdk_info, "module_compiler", None)
    if module_compiler == None:
        return None

    # `dart_toolchain` finds the files once and carries them; a `DartSdkInfo`
    # built elsewhere may not, and then this searches.
    named = getattr(dart_sdk_info, "kernel_module_files", None)
    if named == None:
        sdk_root = sdk_path_from_dart(dart_sdk_info.dart)
        found = {}
        for f in dart_sdk_info.compile_files.to_list():
            if f.path in (sdk_root + "/bin/dartvm", sdk_root + "/bin/dartvm.exe"):
                found["dartvm"] = f
            elif f.path in (sdk_root + "/bin/dartaotruntime", sdk_root + "/bin/dartaotruntime.exe"):
                found["dartaotruntime"] = f
            elif f.path == sdk_root + "/lib/_internal/vm_platform_strong.dill":
                found["platform_dill"] = f
        named = struct(
            dartvm = found.get("dartvm"),
            dartaotruntime = found.get("dartaotruntime"),
            platform_dill = found.get("platform_dill"),
        )
    if named.dartaotruntime == None or named.platform_dill == None:
        return None
    return struct(
        dart = dart_sdk_info.dart,
        dartvm = named.dartvm,
        runtime_files = dart_sdk_info.runtime_files,
        dartaotruntime = named.dartaotruntime,
        module_compiler = module_compiler,
        platform_dill = named.platform_dill,
        version = dart_sdk_info.version,
    )

def kernel_tools_for(ctx):
    """The exec SDK's kernel tools for a rule, or None when modular compile cannot run.

    Modules are built on the exec platform. A kernel is platform-independent, and
    the exec SDK is the one that runs on the machine doing the build.

    Args:
      ctx: A rule context that declares `EXEC_TOOLS_TOOLCHAIN`, optionally.

    Returns:
      The struct from `find_kernel_module_tools`, or None.
    """
    toolchain = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
    if toolchain == None:
        return None
    return find_kernel_module_tools(toolchain.dart_sdk_info)

def no_module_compiler_error(label, dart_sdk_info):
    """The analysis error for an executable whose SDK has no module compiler.

    Args:
      label: The executable's label.
      dart_sdk_info: The `DartSdkInfo` of the exec tools toolchain.

    Returns:
      The message.
    """
    return ("%s compiles as kernel modules, but the module compiler cannot be built for Dart SDK %s: " +
            "its version has no pinned sources in `MODULE_COMPILER_SOURCES` " +
            "(@rules_dart//dart/private:module_compiler_versions.bzl), or its toolchain names no " +
            "`module_compiler_sources`. Use an SDK version that table lists.") % (
        label,
        dart_sdk_info.version,
    )

def dep_kernels_or_none(deps):
    """The `DartKernelInfo` of each dependency, or None if any lacks one.

    Args:
      deps: The `deps` attribute's targets.

    Returns:
      A list of `DartKernelInfo`, or None.
    """
    out = []
    for dep in deps:
        if DartKernelInfo not in dep:
            return None
        out.append(dep[DartKernelInfo])
    return out

def no_kernel_module(reason = None):
    """The `DartKernelInfo` of a library that compiles no module and is not modular.

    Args:
      reason: Why, naming the library: what a kernel executable that reaches
        it reports when it fails.

    Returns:
      A `DartKernelInfo` whose `modular` is False.
    """
    return DartKernelInfo(
        not_modular = reason,
        kmod = None,
        koutline = None,
        transitive_kmods = depset(order = "postorder"),
        transitive_koutlines = depset(order = "postorder"),
        modular = False,
        closure_excluded = depset(),
        cross_pkg_srcs = depset(),
        owned = depset(),
        edges = depset(),
        base_dill = None,
        base_keys = None,
        base_kmods = depset(),
        unseeded_base_kmods = depset(),
    )

def _kmod_declare_outputs(ctx, output, packages, scheme, unused_inputs):
    """Declares and writes the module's package config. Returns (package_config, excluded, unused_inputs_list).

    `packages` is either the deduplicated record list (an executable's entry or
    a test fixture, written inline as before) or an `(own_records, transitive)`
    pair (a library module, whose worker writes the file from request
    arguments, so analysis never flattens the closure or formats the JSON in
    Starlark and no action of its own runs).
    """
    package_config = ctx.actions.declare_file(output.basename + ".package_config.json", sibling = output)
    if type(packages) != "tuple":
        ctx.actions.write(output = package_config, content = kernel_package_config(packages, scheme = scheme))
    excluded = ctx.actions.declare_file(output.basename + ".vm_excluded.txt", sibling = output)
    if unused_inputs:
        # Written by the module compiler alongside the module. Declared here, where
        # the one registering action is, so the declaration and the action
        # that generates the file can never part ways.
        unused_inputs_list = ctx.actions.declare_file(output.basename + ".unused_inputs", sibling = output)
    else:
        unused_inputs_list = None
    return package_config, excluded, unused_inputs_list

def _kmod_args(ctx, args, request):
    """Adds one module compile's request to `args`.

    Args:
      ctx: The rule context, for `ctx.bin_dir`.
      args: The params-file args object to add to.
      request: The module-compile struct (see `kernel_module_action`).
    """
    args.add("--target", request.target)
    args.add("--dart-sdk-summary", request.platform)
    args.add("--packages-file", request.package_config)
    if request.package_records != None:
        add_package_records(args, request.package_records)
    args.add("--multi-root", ".")
    args.add("--multi-root", ctx.bin_dir.path)
    args.add("--multi-root-scheme", request.scheme)
    if request.target == "vm":
        args.add_all([
            "-Ddart.vm.product=" + ("true" if request.product else "false"),
            "-Ddart.vm.asan=false",
            "-Ddart.vm.msan=false",
            "-Ddart.vm.tsan=false",
        ])

    # The defines reach the front end as a map, so a value keeps its commas.
    if request.define_file != None:
        args.add("--define-file", request.define_file)
    args.add_all(request.defines, format_each = "-D%s")
    args.add_all(request.extra_frontend_flags)

    # A module directory is one argument, not its files: `expand_directories` is off.
    args.add_all(request.dep_kmods, before_each = "--input-kmod", expand_directories = False)
    add_module_source_args(args, request.sources, request.unused_inputs_list != None)
    args.add("--output", request.output.path)
    if request.koutline != None:
        args.add("--output-outline", request.koutline.path)
    args.add("--excluded-output", request.excluded)
    if request.unused_inputs_list != None:
        args.add("--unused-inputs-list", request.unused_inputs_list)
    if not request.droppable:
        args.add("--no-drop")
    if request.native_assets != None:
        args.add("--native-assets", request.native_assets)
    if request.extra_inputs:
        args.add_all(request.extra_inputs, before_each = "--input-source")
    if request.check_imports:
        args.add("--check-imports")
        if request.target_label:
            args.add("--target-label", request.target_label)
        args.add_all(request.own_packages, before_each = "--own-package")
        args.add_all(request.direct_packages, before_each = "--direct-package")
        args.add_all(request.refused_libraries, before_each = "--refused-library")

def kernel_module_action(ctx, tools, inputs, outputs, options, compile):
    """Compiles one module with the SDK's module compiler.

    The module compiler is a Bazel persistent worker: it keeps the platform and
    the dependency outlines loaded between requests, each by the digest Bazel
    sent, and reads only the files the request declares. The request goes in a
    params file, which keeps long dependency lists off the command line; the
    startup arguments name only the tool, so every module of one SDK shares a
    worker.

    Args:
      ctx: The rule context.
      tools: The struct from `find_kernel_module_tools`.
      inputs: The struct from `kernel_module_inputs()`: the module's sources,
        packages, dependency modules, and closure inputs.
      outputs: The struct from `kernel_module_outputs()`: the module and
        outline directories to produce, and whether to write unused inputs.
      options: The struct from `kernel_module_options()`: the defines and
        whether the module may leave libraries out.
      compile: The struct from `kernel_compile_settings()`: the frontend
        target, platform, scheme, and extra flags.

    Returns:
      The `.vm_excluded.txt` sidecar File, which lists each source that the module
      leaves out for the target, and why.
    """
    settings = compile
    platform = settings.platform_dill if settings.platform_dill != None else tools.platform_dill
    package_config, excluded, unused_inputs_list = _kmod_declare_outputs(
        ctx,
        outputs.output,
        inputs.packages,
        settings.scheme,
        outputs.unused_inputs,
    )
    package_records = inputs.packages if type(inputs.packages) == "tuple" else None

    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    _kmod_args(ctx, args, struct(
        platform = platform,
        package_config = package_config,
        package_records = package_records,
        target = settings.target,
        product = settings.product,
        defines = options.defines,
        define_file = options.define_file,
        extra_frontend_flags = settings.extra_frontend_flags,
        scheme = settings.scheme,
        sources = inputs.sources,
        dep_kmods = inputs.dep_kmods,
        output = outputs.output,
        koutline = outputs.koutline,
        excluded = excluded,
        unused_inputs_list = unused_inputs_list,
        droppable = options.droppable,
        native_assets = options.native_assets,
        extra_inputs = inputs.extra_inputs,
        check_imports = options.check_imports,
        target_label = options.target_label,
        own_packages = options.own_packages,
        direct_packages = options.direct_packages,
        refused_libraries = getattr(options, "refused_libraries", ()),
    ))

    direct_inputs = [platform] + [s.file for s in inputs.sources]
    if options.define_file != None:
        direct_inputs.append(options.define_file)
    if options.native_assets != None:
        direct_inputs.append(options.native_assets)
    if package_records == None:
        # An inline-written config is an input; a worker-written one is an output.
        direct_inputs.append(package_config)
    exec_tc = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN] if EXEC_TOOLS_TOOLCHAIN in ctx.toolchains else None
    ctx.actions.run(
        executable = tools.dartaotruntime,
        # The startup arguments name the SDK's compiler, so every module of one
        # SDK shares a worker. Bazel sends each request's arguments through the
        # params file.
        arguments = [tools.module_compiler.path, args],
        inputs = depset(
            direct = direct_inputs,
            transitive = [inputs.dep_kmods] + ([inputs.extra_inputs] if inputs.extra_inputs else []),
        ),
        tools = [tools.dartaotruntime, tools.module_compiler],
        outputs = [outputs.output, excluded] + [f for f in [
            unused_inputs_list,
            outputs.koutline,
            package_config if package_records != None else None,
        ] if f],
        unused_inputs_list = unused_inputs_list,
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel module %s" % outputs.output.short_path,
        env = writable_home_env(tools.dartaotruntime, outputs.output),
        # Not multiplexed: the front end compiles one module at a time, so Bazel
        # runs as many worker processes as `--worker_max_instances` allows, each
        # with its own loaded platform and outlines.
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
        # `tools` come from the exec tools toolchain (`kernel_tools_for`). A rule
        # that resolves none hands over tools of its own, from no toolchain.
        toolchain = EXEC_TOOLS_TOOLCHAIN if exec_tc != None else None,
    )
    return excluded

def kernel_link_action(
        ctx,
        dep_kmods,
        entry = None,
        output = None,
        seed_modules = [],
        base_keys = None,
        write_keys = None,
        platform_dill = None):
    """Links an executable's or base module's kernel from reachable module kernels.

    `kernel_link` reads each module's `index.json`, and writes the kernels reachable
    from the entry's imports (or `seed_modules`), each after the kernels it imports,
    then the entry's own. The link tool reads only these directories, so it needs no
    SDK as an input unless `platform_dill` is provided.

    Args:
      ctx: The rule context, carrying the `_kernel_link` executable.
      dep_kmods: Postorder depset of the dependency module directories.
      entry: The entry module's directory, which holds its kernel and index, or
        None when linking a shared base `.dill` from `seed_modules`.
      output: The linked kernel File to produce.
      seed_modules: List of module directories to seed reachability from when
        linking a shared base `.dill`.
      base_keys: Optional `.keys` File listing `<kmod>:<dill>` SCCs already present
        in a shared base `.dill` (to skip emitting into `output`).
      write_keys: Optional `.keys` File to write the emitted `<kmod>:<dill>` keys to.
      platform_dill: Optional platform `.dill` File to prepend as the first
        sub-component in `output`.
    """

    # The module list can run long, and a Windows command line has a length limit,
    # so the arguments go in a params file. The tool expands it.
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    if write_keys != None:
        args.add("--write-keys", write_keys)
    if base_keys != None:
        args.add("--base-keys", base_keys)
    for seed in seed_modules:
        args.add("--seed-module", seed.path)
    if platform_dill != None:
        args.add("--platform", platform_dill)
    args.add(output)
    if entry != None:
        args.add(entry.path)
    args.add_all(dep_kmods, expand_directories = False)

    direct_inputs = []
    if entry != None:
        direct_inputs.append(entry)
    direct_inputs.extend(seed_modules)
    if base_keys != None:
        direct_inputs.append(base_keys)
    if platform_dill != None:
        direct_inputs.append(platform_dill)

    outputs = [output] + ([write_keys] if write_keys != None else [])

    exec_tc = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN] if EXEC_TOOLS_TOOLCHAIN in ctx.toolchains else None
    exec_sdk = exec_tc.dart_sdk_info if exec_tc != None else None
    link_tools = [platform_dill] if platform_dill != None else []
    if exec_sdk != None:
        launch = aot_tool_launch(ctx, "_kernel_link", exec_sdk, exec_sdk.compile_files)
        direct_inputs.append(ctx.executable._kernel_link)
        link_tools.extend(launch.inputs)
        executable = launch.executable
        arguments = launch.prefix + [args]
        transitive_inputs = [dep_kmods, exec_sdk.runtime_files]
        link_tool_depsets = [exec_sdk.runtime_files]
    else:
        link_tools.append(ctx.executable._kernel_link)
        executable = ctx.executable._kernel_link
        arguments = [args]
        transitive_inputs = [dep_kmods]
        link_tool_depsets = []

    ctx.actions.run(
        executable = executable,
        arguments = arguments,
        inputs = depset(direct = direct_inputs, transitive = transitive_inputs),
        tools = depset(direct = link_tools, transitive = link_tool_depsets),
        outputs = outputs,
        mnemonic = "DartKernelLink",
        progress_message = "Linking Dart kernel %s" % ctx.label,
        env = writable_home_env(exec_sdk.dart if exec_sdk != None else executable, output),
        # Singleplex on purpose: `kernel_link` serves one request at a time and keeps its
        # manifest and `.dill` caches unsynchronized, so it cannot answer concurrent requests.
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
        # Without the exec SDK the executable is the implicit `_kernel_link`.
        toolchain = EXEC_TOOLS_TOOLCHAIN if exec_sdk != None else None,
    )

def entry_sources(files, scheme = STABLE_SCHEME):
    """Pairs each entry file with the URI it is compiled under.

    Args:
      files: The entry module's files, its entry point first.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).

    Returns:
      A list of `struct(uri, file)`.
    """
    return [struct(uri = entry_source_uri(f.short_path, scheme = scheme), file = f) for f in files]

global_dart_defines = _global_dart_defines

def _inconsistent_package(records):
    """The package name a closure's records give two roots, or the root packages there are two of.

    Args:
      records: `DartPackageInfo` records, duplicates kept.

    Returns:
      A message fragment, or None when the records are consistent.
    """
    root_of = {}
    roots = []
    for pkg in records:
        seen = root_of.get(pkg.package_name)
        if seen == None:
            root_of[pkg.package_name] = pkg.lib_root
        elif seen != pkg.lib_root:
            return "package `%s` has two roots in its closure (`%s` and `%s`): a package config names one" % (
                pkg.package_name,
                seen or ".",
                pkg.lib_root or ".",
            )
        if not pkg.lib_root and pkg.package_name not in roots:
            roots.append(pkg.package_name)
    if len(roots) > 1:
        return "packages %s all sit at the workspace root: a package config holds one root package" % ", ".join(["`%s`" % r for r in roots])
    return None

def _not_modular_reasons(ctx, tools, target_sdk, closure, own_files, own_record, kernels):
    """Why an executable's closure cannot compile and link as modules: a list of messages, empty when it can.

    Args:
      ctx: The executable's rule context.
      tools: The struct from `find_kernel_module_tools`.
      target_sdk: The `DartSdkInfo` that runs the linked kernel.
      closure: The clean closure of `executable_package`, or None.
      own_files: The executable's own `.dart` files.
      own_record: The executable's own `DartPackageInfo`, or None.
      kernels: The `DartKernelInfo` of each dependency, or None when one has none.

    Returns:
      `(reasons, scan)`: the messages, and the flattened closure scan (or None).
    """
    reasons = []
    if tools.version != target_sdk.version:
        reasons.append(
            "the exec SDK (%s) and the target SDK (%s) differ: the module compiler of one writes kernels the VM of the other refuses; register one Dart SDK version for both" %
            (tools.version, target_sdk.version),
        )
    if kernels == None:
        missing = [str(dep.label) for dep in ctx.attr.deps if DartKernelInfo not in dep]
        reasons.append("%s provide no kernel module (`DartKernelInfo`)" % ", ".join(missing))
    else:
        for k in kernels:
            if not k.modular:
                reasons.append(getattr(k, "not_modular", None) or "a dependency's closure compiles no module")
                break
    if closure == None:
        records = depset(transitive = [dep[DartInfo].transitive_packages for dep in ctx.attr.deps]).to_list()
        if own_record != None:
            records = [own_record] + records
        inconsistent = _inconsistent_package(records)
        if inconsistent != None:
            reasons.append(inconsistent)
    own_paths = [f.short_path for f in own_files]
    scan = None
    if closure == None or _clean_own_in_lib(own_paths, closure.keys):
        scan = _closure_scan(kernels or [])
        duplicate = duplicated_source_owners(own_paths, scan.owned, scan.edges)
        if duplicate != None:
            reasons.append(duplicated_source_message(duplicate, str(ctx.label)))
    return reasons, scan

def modular_executable_tools(
        ctx,
        own_files,
        own_record,
        kernel_mode,
        resolved_assets = [],
        compile_flags = [],
        target_sdk = None,
        closure = None,
        own_defines = [],
        aot_link = False):
    """The tools an executable compiles its entry module with, or None when it compiles from sources.

    A kernel executable (`dart_test`, `dart_binary(compile_mode = "kernel")`)
    has one path: it compiles its entry module against the outlines of its
    closure and links the modules. A shape that path cannot take fails the
    build here, naming the target and every reason; nothing compiles the
    program another way. The caller compiles with `modular_executable_kernel`.

    Args:
      ctx: The executable's rule context, carrying `MODULAR_KERNEL_ATTRS` and
        `deps`.
      own_files: The executable's own `.dart` files, its entry point first.
      own_record: The executable's own `DartPackageInfo`, or None.
      kernel_mode: Whether the executable links modules at all. False returns
        None: the program compiles from sources (an AOT binary).
      resolved_assets: The code assets resolved for the executable. A kernel
        executable embeds their mapping in its entry module
        (`modular_executable_kernel(native_assets = ...)`).
      compile_flags: The `dart_compile_flags` that no module compile takes.
        Each fails a kernel executable, naming the flag.
      target_sdk: Optional `DartSdkInfo` that will execute the output kernel;
        defaults to `ctx.toolchains["//dart:toolchain_type"].dart_sdk_info`.
      closure: Optional `executable_package`'s `closure`: the closure's
        records as a depset and the index of their owners, set only when the
        closure is clean (see `clean_closure`). Its records are then one per
        name with one root each, so they are consistent without a walk, and
        `modular_executable_kernel` takes `packages = None`.
      own_defines: Defines of the executable that its `deps` edge does NOT
        carry as configuration. No module took them, so any fails the build.
        The built-in rules pass none: their `deps` edge sets
        `executable_defines_transition`, and they hand their `defines` to
        `modular_executable_kernel` instead. A custom rule does the same.
      aot_link: Whether this is an `exe` or `aot-snapshot` binary that opted
        into linking its modules (`link_modules`). That is a release path: a
        shape it cannot link (code assets, `dart_compile_flags`, any reason
        above) takes the program's sources instead, and this returns None.

    Returns:
      The struct from `find_kernel_module_tools`, or None.
    """
    if not kernel_mode:
        return None
    exec_tc = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
    tools = kernel_tools_for(ctx)
    if tools == None:
        if aot_link:
            return None
        if exec_tc != None:
            fail(no_module_compiler_error(ctx.label, exec_tc.dart_sdk_info))
        fail(("%s compiles as kernel modules, which the module compiler of the exec tools toolchain " +
              "(`@rules_dart//dart:exec_tools_toolchain_type`) builds, but the build registers none. " +
              "Register the Dart toolchains (`dart.toolchain()` in MODULE.bazel).") % ctx.label)
    if target_sdk == None:
        target_sdk = ctx.toolchains[_TOOLCHAIN_TYPE].dart_sdk_info

    kernels = dep_kernels_or_none(ctx.attr.deps)
    reasons, scan = _not_modular_reasons(ctx, tools, target_sdk, closure, own_files, own_record, kernels)
    for flag in compile_flags:
        reasons.append("`dart_compile_flags` entry `%s` cannot be given to a kernel module compile; only `-D` defines can, as `defines`" % flag)
    if own_defines:
        reasons.append("its `defines` (%s) reach no module: give its `deps` edge `executable_defines_transition` and pass them to `modular_executable_kernel`" % ", ".join(own_defines))
    if aot_link:
        if reasons or resolved_assets:
            return None
    elif reasons:
        fail("%s compiles as kernel modules, and cannot:\n%s" % (
            ctx.label,
            "\n".join(["  - " + r for r in reasons]),
        ))

    # The executable's entry compile reads the same closure: hand the one
    # flattened copy over with the tools, so `modular_executable_kernel` does
    # not flatten it again.
    return struct(closure_scan = scan, clean_closure = closure, **_struct_fields(tools))

def _struct_fields(value):
    """The fields of a struct as a dict, for rebuilding it with one more field."""
    return {
        name: getattr(value, name)
        for name in dir(value)
        if name not in ("to_json", "to_proto", "closure_scan", "clean_closure")
    }

def _clean_own_in_lib(own_paths, keys):
    """Whether one of an executable's own files lies in a clean closure package's `lib/`.

    In a clean closure every root has one owner and no root sits inside
    another package's `lib/`. A library that compiles a module lists only
    files under its own package's `lib/` (anything else makes it opaque, and
    its closure not modular), so two libraries listing one file would own one
    root, which a clean closure rules out. What `duplicated_source` can still
    find is an own file that a library lists too, and that file lies in a
    closure package's `lib/`. This answers that from the owner index, with no
    walk; when it says True, the precise scan runs.

    Args:
      own_paths: The `short_path` of each of the executable's own sources.
      keys: The `owner_keys` of the clean closure.

    Returns:
      True when some own file lies under a closure package's `lib/`.
    """
    for path in own_paths:
        for root in lib_roots_of(path):
            if root_key(root) in keys:
                return True
    return False

def _clean_entry_needs_scan(sources, keys):
    """Whether a clean closure's entry still needs the cross-package scan.

    `_cyclic_source_paths` finds nothing to add for a clean closure when the
    entry has one source that lies in no closure package's `lib/`: every
    package then has one owner, each owner's sources map to its own package,
    and the executable names no package of its own. Any other entry takes the
    scan, which gives the precise answer.

    Args:
      sources: The entry's `struct(uri, file)` list.
      keys: The `owner_keys` of the clean closure.

    Returns:
      True when the scan has to run.
    """
    if len(sources) != 1:
        return True
    return _clean_own_in_lib([sources[0].file.short_path], keys)

def _closure_scan(dep_kernels):
    """The closure ownership an executable checks, flattened once.

    `owned` is flattened here: the duplicate-source check and the
    cross-package scan both read every source of the closure, and no flag
    the libraries carry answers either. The edges are flattened on first use
    and kept, since only a source with two owners or a split package reads
    them.

    Args:
      dep_kernels: The `DartKernelInfo` of each direct dependency.

    Returns:
      `struct(kernels, owned, edges)`: `kernels` is `dep_kernels`, `owned` the
      `(label, short_path)` list, and `edges` a function returning the
      `(label, dep_label)` list.
    """
    memo = {}
    edges_depset = depset(transitive = [k.edges for k in dep_kernels])

    def edges():
        if "edges" not in memo:
            memo["edges"] = edges_depset.to_list()
        return memo["edges"]

    return struct(
        kernels = dep_kernels,
        owned = depset(transitive = [k.owned for k in dep_kernels]).to_list(),
        edges = edges,
    )

def _exec_entry_inputs(ctx, dep_kernels, packages, sources, closure = None, clean = None):
    """Collects the entry module's closures and cross-package sources. Returns (dep_closure, dep_outline_closure, cross_pkg_srcs)."""
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_kernels],
    )
    if clean != None and not _clean_entry_needs_scan(sources, clean.keys):
        return dep_closure, dep_outline_closure, depset(transitive = [k.cross_pkg_srcs for k in dep_kernels])
    if packages == None:
        # lint-allow: depset-flatten terminal executable entry whose cross-package scan needs every record
        packages = clean.records.to_list()
    if closure == None or closure.kernels != dep_kernels:
        closure = _closure_scan(dep_kernels)
    exec_owned = closure.owned
    exec_edges = closure.edges
    own_has_lib = bool(packages and any([package_of_source(s.file.short_path, packages[:1]) != None for s in sources]))
    own_pkg = packages[0].package_name if (packages and (len(sources) > 1 or own_has_lib)) else ""
    cyclic_paths = _cyclic_source_paths(
        own_pkg,
        packages,
        exec_owned,
        exec_edges,
        packages,
        is_executable = not own_has_lib,
    )
    extra_cross_pkg = []
    if cyclic_paths and hasattr(ctx.attr, "deps"):
        extra_cross_pkg = [
            f
            for f in collect_transitive_srcs(ctx.attr.deps).to_list()
            if f.short_path in cyclic_paths
        ]
    cross_pkg_srcs = depset(
        extra_cross_pkg,
        transitive = [k.cross_pkg_srcs for k in dep_kernels],
    )
    return dep_closure, dep_outline_closure, cross_pkg_srcs

def modular_executable_kernel(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        output,
        compile,
        link,
        own_defines = [],
        native_assets = None):
    """Compiles an executable's entry module, then links it to `output`.

    The entry compiles from source whatever it reaches that no dependency module
    holds, so it takes the closure's sources as inputs: an excluded file is among
    them, and the entry compiles it from source.

    Args:
      ctx: The rule context.
      tools: The struct from `find_kernel_module_tools`.
      sources: The entry module's `struct(uri, file)` list, its entry point first.
      packages: The executable's `DartPackageInfo` records, its own first; or
        None when `modular_executable_tools` was given a clean `closure`,
        whose record depset then stands in for them.
      dep_kernels: The `DartKernelInfo` of each direct dependency.
      output: The linked kernel File the executable runs.
      compile: The struct from `kernel_compile_settings()`: the frontend
        target, platform, scheme, and extra flags.
      link: The struct from `kernel_link_options()`: `use_base_dill` links
        `output` as a delta against any shared `base_dill`/`base_keys` in
        `dep_kernels` and returns `base_dill`; `platform_dill` is prepended to
        `output`, so it is a whole program a front end can load with `--from-dill`.
      own_defines: The executable's own `defines`, which its `deps` edge made
        the environment of every dependency module
        (`executable_defines_transition`). The entry compiles with the same
        canonical list, then the `//dart:extra_dart_defines` flag, exactly as
        the modules did.
      native_assets: The code-asset mapping (`native_assets.yaml`) the entry
        embeds, or None. The VM resolves each `@Native` asset of the linked
        program through it, as through a whole program's `--native-assets`.

    Returns:
      The shared `base_dill` File if `link.use_base_dill` is True and a dependency
      provides one, or None.
    """
    validate_dart_defines(own_defines, "the `defines` attribute of %s" % ctx.label)
    clean = getattr(tools, "clean_closure", None) if packages == None else None
    if packages == None and clean == None:
        fail("modular_executable_kernel: `packages` is None, but the tools carry no clean closure.")
    dep_closure, dep_outline_closure, cross_pkg_srcs = _exec_entry_inputs(
        ctx,
        dep_kernels,
        packages,
        sources,
        getattr(tools, "closure_scan", None),
        clean,
    )
    if clean != None:
        # The records are one per name already, in the order the merged list
        # would have, so the worker gets the same `--record` arguments from
        # the depset that it would from the list. A clean closure with no
        # record has an empty index.
        entry_packages = ([], clean.records) if clean.keys else []
    else:
        entry_packages = (packages, depset()) if packages else packages
    entry = ctx.actions.declare_directory(ctx.label.name + ".entry.kmod")
    kernel_module_action(
        ctx,
        tools,
        kernel_module_inputs(
            sources = sources,
            # The worker writes the entry's package config from the records,
            # as it does a library's, so analysis formats no closure-sized
            # JSON. The bytes are those `kernel_package_config` writes. With
            # no records the worker writes nothing, so that config stays inline.
            packages = entry_packages,
            dep_kmods = dep_outline_closure,
            extra_inputs = cross_pkg_srcs,
        ),
        kernel_module_outputs(
            output = entry,
            # This entry compiles in exactly one action registered by the
            # executable's own rule, so the list file stays single-owner.
            unused_inputs = True,
        ),
        kernel_module_options(
            defines = canonical_dart_defines(own_defines) + global_dart_defines(ctx),
            droppable = False,
            native_assets = native_assets,
        ),
        compile,
    )
    base_dill = None
    base_keys = None
    base_kmods = depset()
    if link.use_base_dill:
        base_dill, base_keys, base_kmods = exec_base_dill(dep_kernels)
    link_dep_closure = exec_link_closure(dep_closure, base_dill, base_keys, base_kmods)
    kernel_link_action(ctx, link_dep_closure, entry, output, base_keys = base_keys, platform_dill = link.platform_dill)
    return base_dill

_TEST_API_BASE_PACKAGES = {
    "async": True,
    "boolean_selector": True,
    "collection": True,
    "coverage": True,
    "file": True,
    "glob": True,
    "matcher": True,
    "meta": True,
    "package_config": True,
    "path": True,
    "pool": True,
    "source_maps": True,
    "source_span": True,
    "stack_trace": True,
    "stream_channel": True,
    "string_scanner": True,
    "term_glyph": True,
    "test": True,
    "test_api": True,
    "vm_service": True,
    "yaml": True,
}

def _kmod_pkg_name(kmod):
    name = kmod.basename
    return name[:-len(".kmod")] if name.endswith(".kmod") else name

def _lib_kernel_gate(ctx, opaque, rule_deps):
    """Returns (tools, deps, dep_kernels, env), or a reason string when no module is built.

    `env` is `struct(defines, define_file)`: the environment of the executable
    whose closure this is (the `executable_dart_defines` settings), then the
    `//dart:extra_dart_defines` flag. An exec SDK with no module compiler fails
    here, as it fails a kernel executable: the library would compile no module.
    """
    exe_env = executable_dart_defines(ctx)
    env = struct(
        defines = exe_env.defines + global_dart_defines(ctx),
        define_file = exe_env.flagfile,
    )
    if opaque:
        return "%s compiles no module: %s" % (ctx.label, opaque if type(opaque) == "string" else "its sources are not known at analysis")
    tools = kernel_tools_for(ctx)
    if tools == None:
        exec_tc = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
        if exec_tc != None:
            fail(no_module_compiler_error(ctx.label, exec_tc.dart_sdk_info))
        return "%s compiles no module: the build registers no exec tools toolchain (`@rules_dart//dart:exec_tools_toolchain_type`)" % ctx.label
    deps = rule_deps if rule_deps != None else ctx.attr.deps
    dep_kernels = dep_kernels_or_none(deps)
    if dep_kernels == None:
        missing = [str(dep.label) for dep in deps if DartKernelInfo not in dep]
        return "%s compiles no module: its dependencies %s provide none (`DartKernelInfo`)" % (ctx.label, ", ".join(missing))
    return tools, deps, dep_kernels, env

def _lib_kernel_records(deps, dep_kernels, own_record, own_records):
    """Returns (records, raw, own_records), or why the closure is not modular (a string)."""
    raw = depset(transitive = [dep[DartInfo].transitive_packages for dep in deps if DartInfo in dep]).to_list()
    if own_records == None:
        own_records = [own_record] if own_record != None else []
    records = own_records + raw
    inconsistent = _inconsistent_package(records)
    if inconsistent != None:
        return inconsistent
    return records, raw, own_records

def _lib_kernel_has_cycle(single_package_name, raw, owned_list, edges_list, pkgs, non_standalone):
    """Whether the library's packages form a cross-package cycle."""

    # One name for the cross-package check: a merged library owns several,
    # and its members compile in this very module, so no member can be split
    # across targets. A single-package library passes its own name as before.
    return has_cross_pkg_cycle(
        single_package_name,
        raw,
        owned = owned_list,
        edges = edges_list,
        packages = pkgs,
        non_standalone = non_standalone,
    )

def _lib_kernel_cyclic_srcs(deps, dep_kernels, own_srcs, single_package_name, raw, owned_list, edges_list, pkgs):
    """Returns (cross_pkg_srcs, dep_cross_pkg_srcs) for the cyclic case."""
    cyclic_paths = _cyclic_source_paths(
        single_package_name,
        raw,
        owned_list,
        edges_list,
        pkgs,
    )
    dep_cyclic_srcs = [
        f
        for f in collect_transitive_srcs(deps).to_list()
        if f.short_path in cyclic_paths
    ]
    return (
        depset(
            own_srcs + dep_cyclic_srcs,
            transitive = [k.cross_pkg_srcs for k in dep_kernels],
        ),
        depset(
            dep_cyclic_srcs,
            transitive = [k.cross_pkg_srcs for k in dep_kernels],
        ),
    )

def _lib_kernel_sources(package_name, lib_root, own_srcs, own_records, pkgs):
    """Returns the module's `struct(uri, file)` sources, named per owning member."""
    if len(own_records) == 1:
        return [library_module_source(package_name, lib_root, f) for f in own_srcs]

    # A merged library's sources span its members' roots: each file is
    # named by the member package whose `lib/` holds it.
    return [
        struct(uri = _owned_source_uri(f.short_path, pkgs), file = f)
        for f in own_srcs
    ]

def _lib_kernel_seed_base(ctx, dep_closure, kmod, package_name, own_records, target):
    """Links the shared test base dill. Returns a struct with `base_dill`, `base_keys`, `base_kmods`, and `unseeded_base_kmods`, or None."""
    if target == "vm" and hasattr(ctx.executable, "_kernel_link") and "test" in [package_name] + [r.package_name for r in own_records]:
        base_dill = ctx.actions.declare_file(ctx.label.name + ".base.dill")
        base_keys = ctx.actions.declare_file(ctx.label.name + ".base.keys")
        seeded_dep_kmods = [
            k
            for k in dep_closure.to_list()
            if _kmod_pkg_name(k) in _TEST_API_BASE_PACKAGES
        ]
        seed_kmods = [kmod] + seeded_dep_kmods
        unseeded_kmods = [
            k
            for k in dep_closure.to_list()
            if _kmod_pkg_name(k) not in _TEST_API_BASE_PACKAGES
        ]
        kernel_link_action(
            ctx,
            dep_closure,
            entry = None,
            output = base_dill,
            seed_modules = seed_kmods,
            write_keys = base_keys,
        )
        return struct(
            base_dill = base_dill,
            base_keys = base_keys,
            base_kmods = depset(seeded_dep_kmods),
            unseeded_base_kmods = depset(unseeded_kmods),
        )
    return None

def _lib_kernel_slow_state(ctx, library, options, deps, dep_kernels):
    """The precise module state for a library needing the ownership graph.

    A merged multi-package library and a library whose own package repeats
    across the direct edge take this path: only the flattened closure tells
    which sources a cross-package split excludes. Small and rare shapes pay
    the flattening; the common single-package chain never runs it.

    Args:
      ctx: The `dart_library` rule or aspect context.
      library: The struct from `library_kernel_sources()`.
      options: The struct from `library_kernel_options()`.
      deps: The direct dependency targets.
      dep_kernels: The `DartKernelInfo` of each direct dependency.

    Returns:
      The state struct `library_kernel_info` compiles from, or why the precise
      records do not stay modular (a string).
    """
    recs = _lib_kernel_records(deps, dep_kernels, library.own_record, library.own_records)
    if type(recs) == "string":
        return recs
    records, raw, own_records = recs
    pkgs = first_per_package(records)
    graph = lib_kernel_graph(ctx, deps, dep_kernels, library.own_srcs, records, pkgs)
    single = own_records[0].package_name if len(own_records) == 1 else ""
    has_cycle = _lib_kernel_has_cycle(
        single,
        raw,
        graph.owned_list,
        graph.edges_list,
        graph.pkgs,
        options.non_standalone,
    )
    if has_cycle and graph.need_graph:
        cross, dep_cross = _lib_kernel_cyclic_srcs(
            deps,
            dep_kernels,
            library.own_srcs,
            single,
            raw,
            graph.owned_list,
            graph.edges_list,
            graph.pkgs,
        )
    else:
        cross, dep_cross = lib_kernel_plain_srcs(
            dep_kernels,
            library.own_srcs,
            has_cycle or graph.has_upstream_cross_pkg,
        )
    return struct(
        graph = graph,
        cross_pkg_srcs = cross,
        dep_cross_pkg_srcs = dep_cross,
        module_packages = graph.pkgs,
    )

def library_kernel_info(ctx, library, compile, options):
    """The `DartKernelInfo` a `dart_library` provides.

    The module is declared only here. Nothing builds it until an executable links
    it, so a library reached only through AOT binaries compiles no module at all.

    Args:
      ctx: The `dart_library` rule or aspect context.
      library: The struct from `library_kernel_sources()`: the library's
        package identity, own sources, and own package records.
      compile: The struct from `kernel_compile_settings()`: the frontend
        target, platform, scheme, and extra flags.
      options: The struct from `library_kernel_options()`: opaqueness, the
        dependency targets, and the unused-inputs and standalone behavior.

    Returns:
      A `DartKernelInfo`.
    """
    gated = _lib_kernel_gate(ctx, options.opaque, options.rule_deps)
    if type(gated) == "string":
        return no_kernel_module(gated)
    tools, deps, dep_kernels, env = gated
    for k in dep_kernels:
        if not k.modular:
            return no_kernel_module(getattr(k, "not_modular", None))
    if not lib_owns_compatible(library.own_records, deps):
        return no_kernel_module(
            "%s compiles no module: one of its packages has another root, or it is a second root package, among its direct dependencies' packages: a package config names one root per package" % ctx.label,
        )

    if lib_kernel_needs_graph(library, options, deps):
        state = _lib_kernel_slow_state(ctx, library, options, deps, dep_kernels)
        if type(state) == "string":
            return no_kernel_module("%s compiles no module: %s" % (ctx.label, state))
    else:
        state = lib_kernel_fast_state(ctx, library, options, deps, dep_kernels)
    graph = state.graph
    cross_pkg_srcs = state.cross_pkg_srcs
    dep_cross_pkg_srcs = state.dep_cross_pkg_srcs
    own_records = library.own_records

    bases = lib_kernel_base(dep_kernels)
    if not library.own_srcs:
        return lib_kernel_facade(graph, bases, cross_pkg_srcs)

    kmod = ctx.actions.declare_directory(ctx.label.name + ".kmod")
    koutline = ctx.actions.declare_directory(ctx.label.name + ".koutline")
    sources = _lib_kernel_sources(library.package_name, library.lib_root, library.own_srcs, own_records, graph.pkgs)
    excluded = kernel_module_action(
        ctx,
        tools,
        kernel_module_inputs(
            sources = sources,
            packages = state.module_packages,
            dep_kmods = graph.dep_outline_closure,
            extra_inputs = dep_cross_pkg_srcs,
        ),
        kernel_module_outputs(
            output = kmod,
            koutline = koutline,
            unused_inputs = options.unused_inputs,
        ),
        kernel_module_options(
            defines = env.defines,
            define_file = env.define_file,
            droppable = True,
            check_imports = LAYERING_FEATURE not in ctx.disabled_features and not ctx.label.workspace_name,
            target_label = "//%s:%s" % (ctx.label.package, ctx.label.name),
            own_packages = own_packages(own_records, library.package_name),
            direct_packages = direct_packages(deps),
            refused_libraries = ctx.attr._refused_dart_libraries[BuildSettingInfo].value if hasattr(ctx.attr, "_refused_dart_libraries") else (),
        ),
        compile,
    )
    seeded = _lib_kernel_seed_base(ctx, graph.dep_closure, kmod, library.package_name, own_records, compile.target)
    if seeded != None:
        bases = seeded
    return DartKernelInfo(
        kmod = kmod,
        koutline = koutline,
        transitive_kmods = depset(order = "postorder", direct = [kmod], transitive = [graph.dep_closure]),
        transitive_koutlines = depset(order = "postorder", direct = [koutline], transitive = [graph.dep_outline_closure]),
        modular = True,
        closure_excluded = depset(direct = [excluded], transitive = [graph.upstream_excluded]),
        cross_pkg_srcs = cross_pkg_srcs,
        owned = graph.owned,
        edges = graph.edges,
        base_dill = bases.base_dill,
        base_keys = bases.base_keys,
        base_kmods = bases.base_kmods,
        unseeded_base_kmods = bases.unseeded_base_kmods,
    )

def _dart_kernel_module_aspect_impl(target, ctx):
    if DartKernelInfo in target:
        return []
    linked = ctx.attr.compile_mode == "kernel" or (ctx.attr.link_modules and ctx.attr.compile_mode in ("exe", "aot-snapshot"))
    if DartInfo not in target or not linked or not ctx.attr.modular_kernel:
        return [no_kernel_module()]
    library = getattr(ctx.rule.attr, "library", None)
    if library != None and DartKernelInfo in library:
        return [library[provider] for provider in (DartKernelInfo, DartKernelCycleInfo) if provider in library]

    inputs = library_module_inputs(ctx.rule.attr, ctx.rule.files, target[DartInfo])
    single = inputs.package_name if len(inputs.own_records) == 1 else ""
    non_standalone = _has_no_analyze_tag(ctx)
    info = library_kernel_info(
        ctx,
        library_kernel_sources(
            package_name = inputs.package_name,
            lib_root = inputs.lib_root,
            own_srcs = inputs.own_srcs,
            own_record = inputs.own_record,
            own_records = inputs.own_records,
        ),
        kernel_compile_settings(product = ctx.attr._vm_product[BuildSettingInfo].value),
        library_kernel_options(
            opaque = inputs.opaque_reason,
            rule_deps = inputs.rule_deps,
            non_standalone = non_standalone,
        ),
    )
    return [info, DartKernelCycleInfo(has_cross = lib_has_cross(single, inputs.rule_deps, non_standalone))]

dart_kernel_module_aspect = aspect(
    implementation = _dart_kernel_module_aspect_impl,
    attr_aspects = ["deps", "library"],
    attrs = KERNEL_MODULE_ATTRS | EXTRA_DART_DEFINES_ATTR | {
        "compile_mode": attr.string(
            doc = "The originating executable's `compile_mode` (`kernel` for `dart_test`). Defaults to `kernel`.",
            default = "kernel",
            values = ["exe", "aot-snapshot", "kernel", "jit-snapshot"],
        ),
        "modular_kernel": attr.bool(
            doc = "Whether the originating executable compiles modularly against dependency `.kmod` outputs. Defaults to `True`.",
            default = True,
        ),
        "link_modules": attr.bool(default = True, doc = "The `dart_binary`'s `link_modules`; `True` only because Bazel refuses a `False` default for a parameter the rule lacks."),
    },
    toolchains = MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles each `dart_library` in a modular executable's or test's closure to a `.kmod` directory.",
)
