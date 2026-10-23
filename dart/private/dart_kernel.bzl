"""Modular kernel compilation for `dart_library`, `dart_binary(compile_mode = "kernel")`, and `dart_test`.

Whole-program compilation puts every package in an executable's closure into that
executable's own kernel. With 30 tests, `package:test` is compiled 30 times, and a
one-line edit in a leaf library recompiles every test that reaches it.

Modular compilation is on by default (`//dart:modular_kernel = True`, and
`dart_binary.modular_kernel = True`) for every `dart_test` and
`dart_binary(compile_mode = "kernel")` (including `package:test`'s `test_runner`),
and splits the work along `dart_library` boundaries. Each library
compiles its own sources into a module: a `.kmod` directory of one kernel per
component of its sources (with embedded source text stripped), a `.koutline`
directory of deterministic outline kernels for downstream `--input-summary`
compiles, and an index that lists them. Any class that can be used as a mixin
(`mixin`, `mixin class`, and every class in a library whose language version is
below 3.0) keeps its member bodies and field initializers in `.koutline`. Both
binary strippers check the 32-bit kernel format version in the header (accepting
version 138, Dart 3.13.x) and log a diagnostic to `stderr` while falling back to
the unstripped `.dill` bytes on any other version. An executable compiles only
its entry module, and links the `.kmod` kernels it reaches through the indexes,
in dependency order, which the VM runs as one program. A kernel nothing reaches
is never linked.

A module's package config names every package by a multi-root URI,
`org-dartlang-root:///<path>`. The compiler resolves that against the source tree
and the output tree alike, so a package split between the two (a `dart_codegen`
part) is read where it lies and never copied.

A module compiles the sources its library declares that can compile for the VM.
`kernel_module` decides which those are from the import graph, before it compiles:
a source that imports a `dart:` library the VM lacks, or a file that is excluded,
is excluded, and so is every source that imports one. The excluded sources are
listed in the module's `.vm_excluded.txt` sidecar, which the modules above it read.
An executable whose entry module reaches an excluded file compiles that file from
source, so it fails exactly as a whole-program compile would when the VM cannot run
it.

Every decision that can send an executable back to whole-program compilation is a
pure function here, so each can be unit tested. The actions are built only when a
consumer needs them, so a library used only by AOT binaries never compiles its
module.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartCompileInfo", "DartInfo", _DartKernelInfo = "DartKernelInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR")
load(
    "//dart/private:common.bzl",
    "STABLE_SCHEME",
    "collect_transitive_srcs",
    "generate_stable_package_config",
    "has_comma_define",
    "kernel_sdk_mismatch_error",
    "own_package_record",
    "owned_package_records",
    "sdk_path_from_dart",
    "stable_path",
    "writable_home_env",
)
load("//dart/private:dart_info.bzl", "package_lib_prefix")
load(
    "//dart/private:kernel_params.bzl",
    "kernel_compile_settings",
    "kernel_module_inputs",
    "kernel_module_options",
    "kernel_module_outputs",
)

# The `org-dartlang-root` scheme `--multi-root` maps onto the exec root (`.`) and
# the output directory (`ctx.bin_dir`). Its URIs are the exec-root-relative paths
# a `File.short_path` already gives, so no path is copied or rewritten to make a
# generated file reachable.

_TOOLCHAIN_TYPE = Label("//dart:toolchain_type")
EXEC_TOOLS_TOOLCHAIN = Label("//dart:exec_tools_toolchain_type")

DartKernelInfo = _DartKernelInfo

def library_module_inputs(rule_attr, rule_files, dart_info):
    """The module inputs a `dart_library` target states, for the rule and the aspect.

    Both the `dart_library` rule (which compiles its own module) and the kernel
    module aspect (which falls back to compiling modules for targets whose rule
    does not) derive the same inputs from the same target. One function, so the
    two can never disagree about what the module holds — in particular about
    `opaque`, whose conditions are easy to restate slightly wrongly.

    Args:
      rule_attr: The target's attributes (`ctx.attr` in the rule,
        `ctx.rule.attr` in the aspect).
      rule_files: The target's files (`ctx.files` in the rule,
        `ctx.rule.files` in the aspect).
      dart_info: The target's `DartInfo`.

    Returns:
      A struct with `own_record`, `package_name`, `lib_root`, `own_srcs`,
      `opaque`, `rule_deps`, and `own_records`, as `library_kernel_info` takes
      them.
    """
    package_name = dart_info.package_name
    lib_root = dart_info.lib_root
    own_record = own_package_record(dart_info)
    own_records = owned_package_records(dart_info)
    srcs_dir = getattr(rule_attr, "srcs_dir", None)
    has_srcs_attr = hasattr(rule_attr, "srcs")
    own_srcs = list(getattr(rule_files, "srcs", []))
    rule_deps = getattr(rule_attr, "deps", [])
    if type(rule_deps) != "list":
        rule_deps = [rule_deps]

    # A merged multi-package library carries no `srcs` of its own: its files
    # arrive through `members`. They compile in this one module, like any
    # library's own sources.
    for member in getattr(rule_attr, "members", []):
        own_srcs.extend([
            f
            for f in member[DefaultInfo].files.to_list()
            if f.extension == "dart"
        ])

    opaque = bool(srcs_dir)
    if not has_srcs_attr and dart_info.transitive_srcs.to_list() != [] and len(rule_deps) == 0:
        opaque = True
    if own_srcs and not own_records:
        opaque = True
    else:
        for f in own_srcs:
            if not any([f.short_path.startswith(package_lib_prefix(record.lib_root)) for record in own_records]):
                opaque = True
                break

    return struct(
        own_record = own_record,
        package_name = package_name,
        lib_root = lib_root,
        own_srcs = own_srcs,
        opaque = opaque,
        rule_deps = rule_deps,
        own_records = own_records,
    )

def _kernel_module_for_mode(compile_mode, modular_kernel):
    if compile_mode == "kernel" and modular_kernel:
        return Label("//dart/private/tools:kernel_module")
    return None

def _kernel_link_for_mode(compile_mode, modular_kernel):
    if compile_mode == "kernel" and modular_kernel:
        return Label("//dart/private/tools:kernel_link")
    return None

# The build setting and the module compiler. `dart_library` takes these (its
# module), `dart_test` takes `MODULAR_KERNEL_ATTRS`, and `dart_binary` takes
# `BINARY_MODULAR_KERNEL_ATTRS` (which resolves the tools only for `kernel` mode,
# so an `exe` tool like `kernel_module` or `kernel_link` never depends on itself).
#
# `kernel_module` is a `dart_binary` with no pub dependencies, so it reaches no
# `dart_library` and no cycle is possible.
KERNEL_MODULE_ATTRS = {
    "_modular_kernel": attr.label(
        doc = "The `//dart:modular_kernel` build setting (`True` by default). When off, kernel-mode executables compile whole-program as before.",
        default = Label("//dart:modular_kernel"),
        providers = [BuildSettingInfo],
    ),
    "_kernel_module": attr.label(
        doc = "The tool that compiles one module with `kernel_worker`, excluding the sources that cannot compile for the VM. See `kernel_module.dart`.",
        default = Label("//dart/private/tools:kernel_module"),
        executable = True,
        cfg = "exec",
    ),
    "_kernel_link": attr.label(
        doc = "The tool that links an executable's kernel from the kernels its entry reaches. See `kernel_link.dart`.",
        default = Label("//dart/private/tools:kernel_link"),
        executable = True,
        cfg = "exec",
    ),
}

MODULAR_KERNEL_ATTRS = dict(KERNEL_MODULE_ATTRS)

BINARY_MODULAR_KERNEL_ATTRS = {
    "modular_kernel": attr.bool(
        default = True,
        doc = "Whether `compile_mode = \"kernel\"` compiles modularly against dependency `.kmod` outputs when eligible. Enabled (`True`) by default (including for `package:test`'s `test_runner`); set `modular_kernel = False` or `--@rules_dart//dart:modular_kernel=false` for whole-program compilation.",
    ),
    "_modular_kernel": KERNEL_MODULE_ATTRS["_modular_kernel"],
    "_kernel_module": attr.label(
        doc = "The tool that compiles one module with `kernel_worker`, when `compile_mode` is `kernel`.",
        default = _kernel_module_for_mode,
        executable = True,
        cfg = "exec",
    ),
    "_kernel_link": attr.label(
        doc = "The tool that links an executable's kernel from the kernels its entry reaches, when `compile_mode` is `kernel`.",
        default = _kernel_link_for_mode,
        executable = True,
        cfg = "exec",
    ),
}

# Optional, so a build that registers no exec tools toolchain keeps compiling
# whole-program rather than failing. See `kernel_tools_for`.
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

def duplicated_source(own_paths, owned, edges):
    """The source a modular executable cannot compile, or None.

    Each `dart_library` compiles the sources it lists into its module, and the
    executable links the modules it reaches. Within one dependency chain the planner
    in `kernel_module.dart` keeps one definition of a source: a library whose
    dependency module already defines the source does not compile it again. Two
    libraries that do not depend on each other each compile their own copy, and the
    executable would link two kernels that define one library. The frontend refuses
    that, and a whole-program compile merges the copies by file, so it never saw the
    problem. Such an executable falls back to whole-program compilation.

    The executable's own sources are compiled by its entry module, which does not
    dedupe against the libraries, so a source it shares with a library falls back too.

    Args:
      own_paths: The `short_path` of each of the executable's own sources.
      owned: The `(label, short_path)` of each source of each library in its closure.
      edges: The `(label, dep_label)` of each `dart_library` dependency in its closure.

    Returns:
      The `short_path` of the first source that cannot compile modularly, or None.
    """
    own = {}
    for path in own_paths:
        own[path] = True
    owners = {}
    for label, path in owned:
        if path in own:
            return path
        owners.setdefault(path, {})[label] = True
    reaches = {}
    for label, dep in edges:
        reaches.setdefault(label, {})[dep] = True
    for path in sorted(owners.keys()):
        labels = sorted(owners[path].keys())
        for i in range(len(labels)):
            for j in range(i + 1, len(labels)):
                first = labels[i]
                second = labels[j]
                if not _depends_on(reaches, first, second) and not _depends_on(reaches, second, first):
                    return path
    return None

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
      packages: `DartPackageInfo` records.

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

def _cyclic_label_index(owned, packages):
    """Indexes owned sources by label and package. Returns (pkg_of_label, labels_of_pkg, paths_of_label)."""
    pkg_of_label = {}
    labels_of_pkg = {}
    paths_of_label = {}
    for label, path in owned:
        paths_of_label.setdefault(label, []).append(path)
        pkg = package_of_source(path, packages)
        if pkg != None:
            pkg_of_label[label] = pkg
            labels_of_pkg.setdefault(pkg, {})[label] = True
    return pkg_of_label, labels_of_pkg, paths_of_label

def _cyclic_split_pkgs(own_package, dep_packages, labels_of_pkg, pkg_of_label, reaches, is_executable):
    """Returns the set of split packages seeding the cyclic-paths computation."""
    split_pkgs = {
        pkg: True
        for pkg, labels in labels_of_pkg.items()
        if len(labels) > 1
    }
    if not is_executable and bool(own_package) and any([p.package_name == own_package for p in dep_packages]):
        split_pkgs[own_package] = True
    if is_executable and bool(own_package):
        own_pkg_labels = [label for label, pkg in pkg_of_label.items() if pkg == own_package]
        for label, pkg in pkg_of_label.items():
            if pkg != own_package and any([_depends_on(reaches, label, m) for m in own_pkg_labels]):
                split_pkgs[own_package] = True
                break
    return split_pkgs

def _cyclic_active_labels(paths_of_label, pkg_of_label, reaches, split_pkgs):
    """Returns the labels in split packages plus everything depending on them."""
    seed_labels = [label for label, pkg in pkg_of_label.items() if pkg in split_pkgs]
    return {
        label: True
        for label in paths_of_label
        if label in seed_labels or any([_depends_on(reaches, label, s) for s in seed_labels])
    }

def _cyclic_source_paths(own_package, dep_packages, owned, edges, packages, is_executable = False):
    """The `short_path`s of sources in split or cyclic packages and targets depending on them."""
    pkg_of_label, labels_of_pkg, paths_of_label = _cyclic_label_index(owned, packages)
    reaches = {}
    for label, dep in edges:
        reaches.setdefault(label, {})[dep] = True
    split_pkgs = _cyclic_split_pkgs(own_package, dep_packages, labels_of_pkg, pkg_of_label, reaches, is_executable)
    if not split_pkgs:
        return {}
    active_labels = _cyclic_active_labels(paths_of_label, pkg_of_label, reaches, split_pkgs)
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
    own module closure. `kernel_module` excludes those files at module compile time
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

def modular_kernel_eligible(
        enabled,
        kernel_mode,
        dep_modular,
        packages_consistent,
        has_code_assets,
        has_own_defines,
        has_compile_flags,
        has_duplicate_source,
        same_sdk):
    """Whether one executable compiles modularly, given every fact that decides it.

    Each `False` is a reason the executable falls back to whole-program compilation,
    which is always correct, only slower.

    Args:
      enabled: The `//dart:modular_kernel` flag.
      kernel_mode: Whether the executable is a kernel (`dart_test` always is).
      dep_modular: Whether every dependency's closure is modular.
      packages_consistent: `kernel_packages_consistent` over the executable's closure.
      has_code_assets: Whether native code assets are embedded in the kernel. The
        embedding runs the front end over the whole program at once.
      has_own_defines: Whether the executable's own `defines` attribute is set.
        Modules compile with the `//dart:extra_dart_defines` flag, which is the same
        for the whole build, so the flag's `-D`s are shared by every module. Only a
        target's own `defines` cannot be shared, so only they fall back.
      has_compile_flags: Whether `dart_compile_flags` are set. They reach
        `dart compile`, which the modular path does not run.
      has_duplicate_source: Whether `duplicated_source` found a repeat.
      same_sdk: Whether the exec and target SDKs report the same version. A kernel
        compiled by one is loaded by the other, and the VM accepts only its own
        kernel format.

    Returns:
      True when the executable compiles modularly.
    """
    return (
        enabled and
        kernel_mode and
        dep_modular and
        packages_consistent and
        not has_code_assets and
        not has_own_defines and
        not has_compile_flags and
        not has_duplicate_source and
        same_sdk
    )

def find_kernel_module_tools(dart_sdk_info):
    """Locates the files a module compile and a link run from, in an SDK.

    The worker snapshot `kernel_worker_aot.dart.snapshot` is absent from older SDKs.
    Its absence is not an error: the library compiles no module and every consumer
    compiles whole-program, exactly as it did before modular compilation existed.

    Args:
      dart_sdk_info: The `DartSdkInfo` of the exec tools toolchain.

    Returns:
      `struct(dartaotruntime, kernel_worker, platform_dill, libraries_json,
      version, patched_kernel_worker)`, or None
      when the SDK lacks the worker snapshot. `patched_kernel_worker` is the
      toolchain's comma-splitting-disabled copy of the worker snapshot, or
      None when the toolchain declares none.
    """
    sdk_root = sdk_path_from_dart(dart_sdk_info.dart)
    dartvm_paths = [
        sdk_root + "/bin/dartvm",
        sdk_root + "/bin/dartvm.exe",
    ]
    wanted = {
        "dartaotruntime": [
            sdk_root + "/bin/dartaotruntime",
            sdk_root + "/bin/dartaotruntime.exe",
        ],
        "kernel_worker": [sdk_root + "/bin/snapshots/kernel_worker_aot.dart.snapshot"],
        "platform_dill": [sdk_root + "/lib/_internal/vm_platform_strong.dill"],
        "libraries_json": [sdk_root + "/lib/libraries.json"],
    }
    dartvm = None
    found = {}
    for f in dart_sdk_info.compile_files.to_list():
        if f.path in dartvm_paths:
            dartvm = f
        for key, paths in wanted.items():
            if f.path in paths:
                found[key] = f
    if len(found) != len(wanted):
        return None
    return struct(
        dart = dart_sdk_info.dart,
        dartvm = dartvm,
        runtime_files = dart_sdk_info.runtime_files,
        dartaotruntime = found["dartaotruntime"],
        kernel_worker = found["kernel_worker"],
        platform_dill = found["platform_dill"],
        libraries_json = found["libraries_json"],
        version = dart_sdk_info.version,
        patched_kernel_worker = getattr(dart_sdk_info, "patched_kernel_worker", None),
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

def no_kernel_module():
    """The `DartKernelInfo` of a library that compiles no module and is not modular.

    Returns:
      A `DartKernelInfo` whose `modular` is False.
    """
    return DartKernelInfo(
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
    """Declares and writes the module's package config. Returns (package_config, excluded, unused_inputs_list)."""
    package_config = ctx.actions.declare_file(output.basename + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = kernel_package_config(packages, scheme = scheme),
    )
    excluded = ctx.actions.declare_file(output.basename + ".vm_excluded.txt")
    if unused_inputs:
        # Written by `kernel_module` alongside the module. Declared here, where
        # the one registering action is, so the declaration and the action
        # that generates the file can never part ways.
        unused_inputs_list = ctx.actions.declare_file(output.basename + ".unused_inputs")
    else:
        unused_inputs_list = None
    return package_config, excluded, unused_inputs_list

def _kmod_common_args(ctx, args, request):
    """Adds the target/platform/define args shared by every module compile.

    Args:
      ctx: The rule context, for `ctx.bin_dir`.
      args: The args object to add to.
      request: A struct with `target`, `platform`, `package_config`, `libraries`,
        `libraries_platform`, `extra_libraries`, `defines`, `extra_frontend_flags`,
        and `scheme`.
    """
    args.add("--target", request.target)
    args.add("--dart-sdk-summary", request.platform)
    args.add("--packages-file", request.package_config)
    args.add("--libraries-json", request.libraries)
    if request.libraries_platform:
        args.add("--libraries-platform", request.libraries_platform)
    args.add_all(request.extra_libraries, before_each = "--extra-library")
    args.add("--multi-root", ".")
    args.add("--multi-root", ctx.bin_dir.path)
    args.add("--multi-root-scheme", request.scheme)
    if request.target == "vm":
        args.add_all([
            "-Ddart.vm.product=true",
            "-Ddart.vm.asan=false",
            "-Ddart.vm.msan=false",
            "-Ddart.vm.tsan=false",
        ])
    args.add_all(request.defines, format_each = "-D%s")
    args.add_all(request.extra_frontend_flags)

def _kmod_worker_snapshot(ctx, tools, defines):
    """Selects the worker snapshot for comma defines. Returns (worker_snapshot, patched_marker)."""

    # A comma-containing value only survives the frontend when the compile runs
    # the toolchain's patched worker snapshot: `kernel_worker` splits `-D`
    # values on commas. The patched snapshot is a distinct `--kernel-worker`
    # startup argument, so comma compiles get their own worker process and never
    # share one running the pristine snapshot. The marker is a startup argument
    # too (never params-file content): the worker parses it once, and it never
    # reaches a request's arguments, so `kernel_worker` never sees it. Without
    # comma defines the pristine snapshot runs, exactly as before.
    worker_snapshot = tools.kernel_worker
    patched_marker = []
    if has_comma_define(defines):
        worker_snapshot = getattr(tools, "patched_kernel_worker", None)
        if worker_snapshot == None:
            fail(("kernel_module_action: target %s passes comma-containing " +
                  "`-D` defines %s, but the exec SDK (Dart %s) declares no " +
                  "patched `kernel_worker` snapshot, so no compile of this " +
                  "module can keep the commas. Use an SDK whose snapshot " +
                  "`comma_patch.dart` knows how to patch.") %
                 (ctx.label, defines, getattr(tools, "version", "")))
        patched_marker = ["--comma-patched-snapshot"]
    return worker_snapshot, patched_marker

def _kmod_source_args(args, request):
    """Adds the per-module source, output, and exclusion args.

    Args:
      args: The args object to add to.
      request: A struct with `sources`, `dep_kmods`, `output`, `koutline`,
        `excluded`, `unused_inputs_list`, `droppable`, `closure_excluded`,
        `extra_inputs`, and `exclude_non_sources`.
    """

    # The VM target does not support `--summary-only`: it prints an error and
    # embeds the whole platform. Its absence keeps each kernel to its own libraries.
    args.add("--no-summary-only")

    # The worker keeps the platform and the dependency kernels loaded between
    # requests, and reuses a result when a request repeats. It reads a file only
    # through an input Bazel declared, and every request sends those inputs with
    # their digests, so it never reads a file it was not given.
    args.add("--reuse-compiler-result")
    args.add("--use-incremental-compiler")
    if request.exclude_non_sources:
        args.add("--exclude-non-sources")

    # A module directory is one argument, not its files: `expand_directories` is off.
    args.add_all(request.dep_kmods, before_each = "--input-kmod", expand_directories = False)
    for s in request.sources:
        args.add("--source", s.uri)
        args.add("--input-source", s.file)
        if request.unused_inputs_list != None:
            args.add("--own-source-file", s.file)
    args.add("--output", request.output.path)
    if request.koutline != None:
        args.add("--output-outline", request.koutline.path)

    # Read by `kernel_module` and not passed to `kernel_worker`.
    args.add("--excluded-output", request.excluded)
    if request.unused_inputs_list != None:
        args.add("--unused-inputs-list", request.unused_inputs_list)
    if not request.droppable:
        args.add("--no-drop")
    if request.closure_excluded:
        args.add_all(request.closure_excluded, before_each = "--closure-excluded")
    if request.extra_inputs:
        args.add_all(request.extra_inputs, before_each = "--input-source")

def _kmod_select_executable(ctx, tools, direct_inputs, action_tools):
    """Selects the module action's executable. Returns (executable, arguments-prefix, dart_exe)."""
    dart_exe = getattr(tools, "dart", None)
    dartvm = getattr(tools, "dartvm", None)
    tool_target = getattr(ctx.attr, "_kernel_module", None)
    tool_compile_mode = (
        tool_target[DartCompileInfo].compile_mode if tool_target != None and DartCompileInfo in tool_target else "kernel"
    )
    if tool_compile_mode == "aot-snapshot":
        # The tool is an AOT snapshot: `dart` refuses to run `.aot` files, so
        # `dartaotruntime` executes it directly. This also drops the `dart` and
        # `dartvm` inputs: the snapshot needs only the runtime. The
        # SDK-mismatch check below is kernel-only; an AOT snapshot built by a
        # foreign SDK fails loudly at execution time instead.
        direct_inputs.append(ctx.executable._kernel_module)
        return tools.dartaotruntime, ctx.executable._kernel_module.path, dart_exe
    if dart_exe != None:
        mismatch = kernel_sdk_mismatch_error(
            ctx.label,
            "_kernel_module",
            getattr(ctx.attr, "_kernel_module", None),
            getattr(tools, "version", ""),
        )
        if mismatch != None:
            fail(mismatch)
        direct_inputs.extend([ctx.executable._kernel_module, dart_exe])
        action_tools.append(dart_exe)
        if dartvm != None:
            direct_inputs.append(dartvm)
            action_tools.append(dartvm)
        return dart_exe, ctx.executable._kernel_module.path, dart_exe
    return ctx.executable._kernel_module, None, dart_exe

def _kmod_run_action(ctx, executable, arguments, request, direct_inputs, action_tools, runtime_files):
    """Registers the module's `kernel_module` worker action.

    Args:
      ctx: The rule context, for `ctx.actions.run`.
      executable: The executable to run.
      arguments: The startup arguments plus the params-file args.
      request: A struct with `tools`, `dep_kmods`, `extra_inputs`,
        `closure_excluded`, `output`, `excluded`, `unused_inputs_list`, and
        `koutline`.
      direct_inputs: The action's direct input files.
      action_tools: The action's direct tool files.
      runtime_files: The SDK runtime files depset, or None.
    """
    tools = request.tools
    ctx.actions.run(
        executable = executable,
        # The startup arguments name the SDK's compiler, so every module of one SDK
        # shares one worker. Bazel keeps the process running as a worker, and sends
        # each request's arguments through the params file.
        arguments = arguments,
        inputs = depset(
            direct = direct_inputs,
            transitive = [request.dep_kmods] + [
                d
                for d in [request.extra_inputs, request.closure_excluded]
                if d
            ],
        ),
        tools = depset(
            direct = action_tools,
            transitive = [runtime_files] if runtime_files != None else [],
        ),
        outputs = [request.output, request.excluded] + ([request.unused_inputs_list] if request.unused_inputs_list != None else []) + ([request.koutline] if request.koutline != None else []),
        unused_inputs_list = request.unused_inputs_list,
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel module %s" % request.output.short_path,
        env = writable_home_env(getattr(tools, "dart", None) or tools.dartaotruntime, request.output),
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
    )

def kernel_module_action(ctx, tools, inputs, outputs, options, compile):
    """Compiles one module with `kernel_module`, which drives the persistent `kernel_worker`.

    `kernel_module` is a Bazel persistent worker: it keeps one `kernel_worker` child
    running, so each module compile reuses the loaded SDK, and a retry reuses the
    same child. Everything except the wrapper's startup flags goes in a params file,
    which keeps long dependency lists off the command line.

    Args:
      ctx: The rule context, carrying the `_kernel_module` executable.
      tools: The struct from `find_kernel_module_tools`.
      inputs: The struct from `kernel_module_inputs()`: the module's sources,
        packages, dependency modules, and closure inputs.
      outputs: The struct from `kernel_module_outputs()`: the module and
        outline directories to produce, and whether to write unused inputs.
      options: The struct from `kernel_module_options()`: the defines and the
        exclusion and dropping behavior.
      compile: The struct from `kernel_compile_settings()`: the frontend
        target, platform, libraries, scheme, and extra flags.

    Returns:
      The `.vm_excluded.txt` sidecar File, which lists each source that the module
      excludes for the target, and why.
    """
    settings = compile
    platform = settings.platform_dill if settings.platform_dill != None else tools.platform_dill
    libraries = settings.libraries_json if settings.libraries_json != None else tools.libraries_json
    package_config, excluded, unused_inputs_list = _kmod_declare_outputs(ctx, outputs.output, inputs.packages, settings.scheme, outputs.unused_inputs)

    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")

    # One object for the module-compile clump that the helpers below share.
    request = struct(
        tools = tools,
        platform = platform,
        libraries = libraries,
        package_config = package_config,
        target = settings.target,
        libraries_platform = settings.libraries_platform,
        extra_libraries = settings.extra_libraries,
        defines = options.defines,
        extra_frontend_flags = settings.extra_frontend_flags,
        scheme = settings.scheme,
        sources = inputs.sources,
        dep_kmods = inputs.dep_kmods,
        output = outputs.output,
        koutline = outputs.koutline,
        excluded = excluded,
        unused_inputs_list = unused_inputs_list,
        droppable = options.droppable,
        closure_excluded = inputs.closure_excluded,
        extra_inputs = inputs.extra_inputs,
        exclude_non_sources = options.exclude_non_sources,
    )

    _kmod_common_args(ctx, args, request)

    worker_snapshot, patched_marker = _kmod_worker_snapshot(ctx, tools, options.defines)

    _kmod_source_args(args, request)

    _kmod_register(ctx, request, args, worker_snapshot, patched_marker)
    return excluded

def _kmod_register(ctx, request, args, worker_snapshot, patched_marker):
    """Builds the module action's inputs, selects its executable, and registers it.

    Args:
      ctx: The rule context, carrying the `_kernel_module` executable.
      request: The module-compile struct (see `kernel_module_action`).
      args: The params-file args for the worker request.
      worker_snapshot: The worker snapshot File to run.
      patched_marker: The comma-patch startup marker list (possibly empty).
    """
    tools = request.tools
    runtime_files = getattr(tools, "runtime_files", None)
    direct_inputs = [
        request.package_config,
        tools.dartaotruntime,
        worker_snapshot,
        request.libraries,
        request.platform,
    ] + [s.file for s in request.sources]
    action_tools = [
        tools.dartaotruntime,
        worker_snapshot,
        request.platform,
        ctx.executable._kernel_module,
    ]
    executable, tool_path, _ = _kmod_select_executable(ctx, tools, direct_inputs, action_tools)
    if tool_path != None:
        arguments = [
            tool_path,
            "--kernel-worker",
            worker_snapshot.path,
            "--dartaotruntime",
            tools.dartaotruntime.path,
            args,
        ] + patched_marker
    else:
        arguments = [
            "--kernel-worker",
            worker_snapshot.path,
            "--dartaotruntime",
            tools.dartaotruntime.path,
            args,
        ] + patched_marker

    _kmod_run_action(ctx, executable, arguments, request, direct_inputs, action_tools, runtime_files)

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

    outputs = [output]
    if write_keys != None:
        outputs.append(write_keys)

    exec_tc = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN] if EXEC_TOOLS_TOOLCHAIN in ctx.toolchains else None
    exec_sdk = exec_tc.dart_sdk_info if exec_tc != None else None
    link_tools = [ctx.executable._kernel_link] + ([platform_dill] if platform_dill != None else [])
    if exec_sdk != None:
        mismatch = kernel_sdk_mismatch_error(
            ctx.label,
            "_kernel_link",
            getattr(ctx.attr, "_kernel_link", None),
            exec_sdk.version,
        )
        if mismatch != None:
            fail(mismatch)
        direct_inputs.append(ctx.executable._kernel_link)
        link_tools.append(exec_sdk.dart)
        executable = exec_sdk.dart
        arguments = [ctx.executable._kernel_link.path, args]
        transitive_inputs = [dep_kmods, exec_sdk.runtime_files]
        link_tool_depsets = [exec_sdk.runtime_files]
    else:
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
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
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

def global_dart_defines(ctx):
    """The `//dart:extra_dart_defines` flag's values, shared by every module of a build.

    Args:
      ctx: A rule context carrying `_extra_dart_defines` (`EXTRA_DART_DEFINES_ATTR`).

    Returns:
      The list of `KEY` or `KEY=VALUE` strings.
    """
    if not hasattr(ctx.attr, "_extra_dart_defines"):
        return []
    return ctx.attr._extra_dart_defines[BuildSettingInfo].value

def modular_executable_tools(
        ctx,
        own_files,
        own_record,
        kernel_mode,
        resolved_assets,
        own_defines,
        compile_flags,
        target_sdk = None):
    """Decides whether an executable compiles modularly, and with which tools.

    Reads the flag and gathers each fact `modular_kernel_eligible` takes. The
    caller then compiles modularly only when this returns tools.

    Args:
      ctx: The executable's rule context, carrying `MODULAR_KERNEL_ATTRS` and
        `deps`.
      own_files: The executable's own `.dart` files, its entry point first.
      own_record: The executable's own `DartPackageInfo`, or None.
      kernel_mode: Whether the executable is compiled as a kernel.
      resolved_assets: The code assets resolved for the executable.
      own_defines: The executable's own `defines` attribute. The
        `//dart:extra_dart_defines` flag is not among them: every module takes it.
      compile_flags: The executable's `dart_compile_flags`.
      target_sdk: Optional `DartSdkInfo` that will execute the output kernel;
        defaults to `ctx.toolchains["//dart:toolchain_type"].dart_sdk_info`.

    Returns:
      The struct from `find_kernel_module_tools`, or None.
    """
    enabled = ctx.attr._modular_kernel[BuildSettingInfo].value if hasattr(ctx.attr, "_modular_kernel") else True
    if not enabled or not kernel_mode:
        return None
    tools = kernel_tools_for(ctx)
    if tools == None:
        return None
    if target_sdk == None:
        target_sdk = ctx.toolchains[_TOOLCHAIN_TYPE].dart_sdk_info

    kernels = dep_kernels_or_none(ctx.attr.deps)
    dep_modular = kernels != None and all([k.modular for k in kernels])

    records = depset(transitive = [dep[DartInfo].transitive_packages for dep in ctx.attr.deps]).to_list()
    if own_record != None:
        records = [own_record] + records

    owned = depset(transitive = [k.owned for k in kernels or []]).to_list()
    edges = depset(transitive = [k.edges for k in kernels or []]).to_list()
    duplicate = duplicated_source([f.short_path for f in own_files], owned, edges)

    eligible = modular_kernel_eligible(
        enabled = enabled,
        kernel_mode = kernel_mode,
        dep_modular = dep_modular,
        packages_consistent = kernel_packages_consistent(records),
        has_code_assets = len(resolved_assets) > 0,
        has_own_defines = len(own_defines) > 0,
        has_compile_flags = len(compile_flags) > 0,
        has_duplicate_source = duplicate != None,
        same_sdk = tools.version == target_sdk.version,
    )
    return tools if eligible else None

def _exec_entry_inputs(ctx, dep_kernels, packages, sources):
    """Collects the entry module's closures and cross-package sources. Returns (dep_closure, dep_outline_closure, cross_pkg_srcs)."""
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_kernels],
    )
    exec_owned = depset(transitive = [k.owned for k in dep_kernels]).to_list()
    exec_edges = depset(transitive = [k.edges for k in dep_kernels]).to_list()
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

def _exec_base_dill(dep_kernels):
    """Finds the shared base dill among dependencies. Returns (base_dill, base_keys, base_kmods)."""
    base_dill = None
    base_keys = None
    base_kmods = depset()
    for k in dep_kernels:
        kd = getattr(k, "base_dill", None)
        kk = getattr(k, "base_keys", None)
        if kd != None and kk != None:
            if base_dill == None:
                base_dill = kd
                base_keys = kk
                base_kmods = getattr(k, "base_kmods", depset())
                break
    return base_dill, base_keys, base_kmods

def _exec_link_closure(dep_closure, base_dill, base_keys, base_kmods):
    """Returns the dependency closure pruned of base-dill modules, when seeded."""
    if base_dill == None or base_keys == None:
        return dep_closure
    pruned_paths = {f.path: True for f in base_kmods.to_list()}
    if not pruned_paths:
        return dep_closure
    return depset(
        [f for f in dep_closure.to_list() if f.path not in pruned_paths],
        order = "postorder",
    )

def modular_executable_kernel(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        output,
        target = "vm",
        platform_dill = None,
        libraries_json = None,
        libraries_platform = None,
        extra_libraries = [],
        scheme = STABLE_SCHEME,
        extra_frontend_flags = [],
        use_base_dill = False):
    """Compiles an executable's entry module, then links it to `output`.

    The entry compiles from source whatever it reaches that no dependency module
    holds, so it takes the closure's sources as inputs: an excluded file is among
    them, and the entry compiles it from source.

    Args:
      ctx: The rule context.
      tools: The struct from `find_kernel_module_tools`.
      sources: The entry module's `struct(uri, file)` list, its entry point first.
      packages: The executable's `DartPackageInfo` records, its own first.
      dep_kernels: The `DartKernelInfo` of each direct dependency.
      output: The linked kernel File the executable runs.
      target: The `kernel_worker --target` name (`"vm"` by default).
      platform_dill: Optional platform `.dill` File override.
      libraries_json: Optional `libraries.json` File override.
      libraries_platform: Optional platform key in `libraries.json`.
      extra_libraries: Extra bare `dart:` library names available on the target.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).
      extra_frontend_flags: Extra flags forwarded to `kernel_worker`.
      use_base_dill: When True, links `output` as a delta against any shared
        `base_dill`/`base_keys` provided in `dep_kernels` and returns `base_dill`.

    Returns:
      The shared `base_dill` File if `use_base_dill` is True and a dependency
      provides one, or None.
    """
    dep_closure, dep_outline_closure, cross_pkg_srcs = _exec_entry_inputs(ctx, dep_kernels, packages, sources)
    entry = ctx.actions.declare_directory(ctx.label.name + ".entry.kmod")
    kernel_module_action(
        ctx,
        tools,
        kernel_module_inputs(
            sources = sources,
            packages = packages,
            dep_kmods = dep_outline_closure,
            extra_inputs = cross_pkg_srcs,
            closure_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels]),
        ),
        kernel_module_outputs(
            output = entry,
            # This entry compiles in exactly one action registered by the
            # executable's own rule, so the list file stays single-owner.
            unused_inputs = True,
        ),
        kernel_module_options(
            defines = global_dart_defines(ctx),
            exclude_non_sources = True,
            droppable = False,
        ),
        kernel_compile_settings(
            target = target,
            platform_dill = platform_dill,
            libraries_json = libraries_json,
            libraries_platform = libraries_platform,
            extra_libraries = extra_libraries,
            scheme = scheme,
            extra_frontend_flags = extra_frontend_flags,
        ),
    )
    base_dill = None
    base_keys = None
    base_kmods = depset()
    if use_base_dill:
        base_dill, base_keys, base_kmods = _exec_base_dill(dep_kernels)
    link_dep_closure = _exec_link_closure(dep_closure, base_dill, base_keys, base_kmods)
    kernel_link_action(ctx, link_dep_closure, entry, output, base_keys = base_keys)
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
    """Returns (tools, deps, dep_kernels, defines), or None when no module is built."""
    enabled = ctx.attr._modular_kernel[BuildSettingInfo].value if hasattr(ctx.attr, "_modular_kernel") else True
    defines = global_dart_defines(ctx)
    if opaque or not enabled:
        return None
    tools = kernel_tools_for(ctx)
    if tools == None:
        return None
    deps = rule_deps if rule_deps != None else ctx.attr.deps
    dep_kernels = dep_kernels_or_none(deps)
    if dep_kernels == None:
        return None
    return tools, deps, dep_kernels, defines

def _lib_kernel_records(deps, dep_kernels, own_record, own_records):
    """Returns (records, raw, own_records), or None when the closure is not modular."""
    raw = depset(transitive = [dep[DartInfo].transitive_packages for dep in deps if DartInfo in dep]).to_list()
    if own_records == None:
        own_records = [own_record] if own_record != None else []
    records = own_records + raw
    modular = kernel_packages_consistent(records) and all([k.modular for k in dep_kernels])
    if not modular:
        return None
    return records, raw, own_records

def _lib_kernel_graph(ctx, deps, dep_kernels, own_srcs, records):
    """Collects closures, ownership, and edges. Returns a struct with `dep_closure`, `dep_outline_closure`, `upstream_excluded`, `owned`, `edges`, `pkgs`, `owned_list`, `edges_list`, `need_graph`, and `has_upstream_cross_pkg`."""
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_kernels],
    )
    upstream_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels])
    owned = depset(
        [(str(ctx.label), f.short_path) for f in own_srcs],
        transitive = [k.owned for k in dep_kernels],
    )
    edges = depset(
        [(str(ctx.label), str(dep.label)) for dep in deps],
        transitive = [k.edges for k in dep_kernels],
    )
    pkgs = first_per_package(records)
    has_upstream_cross_pkg = any([bool(k.cross_pkg_srcs.to_list()) for k in dep_kernels])
    need_graph = len(pkgs) < len(records)
    owned_list = owned.to_list() if need_graph else []
    edges_list = edges.to_list() if need_graph else []
    return struct(
        dep_closure = dep_closure,
        dep_outline_closure = dep_outline_closure,
        upstream_excluded = upstream_excluded,
        owned = owned,
        edges = edges,
        pkgs = pkgs,
        owned_list = owned_list,
        edges_list = edges_list,
        need_graph = need_graph,
        has_upstream_cross_pkg = has_upstream_cross_pkg,
    )

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

def _lib_kernel_plain_srcs(dep_kernels, own_srcs, include_own):
    """Returns (cross_pkg_srcs, dep_cross_pkg_srcs) when no cycle graph is needed.

    Args:
      dep_kernels: The `DartKernelInfo` of each direct dependency.
      own_srcs: The library's own `.dart` files.
      include_own: Whether the library's own sources join the cross-package set
        (a cycle that needs no graph, or cross-package sources upstream).
    """
    if include_own:
        return (
            depset(own_srcs, transitive = [k.cross_pkg_srcs for k in dep_kernels]),
            depset(transitive = [k.cross_pkg_srcs for k in dep_kernels]),
        )
    return (
        depset(transitive = [k.cross_pkg_srcs for k in dep_kernels]),
        None,
    )

def _lib_kernel_unseeded(base_dill, unseeded_candidates, kd, k):
    """Intersects the unseeded candidates with one dep's unseeded modules."""
    if kd != base_dill:
        return unseeded_candidates
    k_unseeded = getattr(k, "unseeded_base_kmods", depset()).to_list()
    if unseeded_candidates == None:
        return {f.path: f for f in k_unseeded}
    keep = {f.path: True for f in k_unseeded}
    pruned = {}
    for p, f in unseeded_candidates.items():
        if p in keep:
            pruned[p] = f
    return pruned

def _lib_kernel_non_base_paths(dep_kernels):
    """Returns the kmod paths of deps that provide no base dill."""
    paths = {}
    for k in dep_kernels:
        if getattr(k, "base_dill", None) != None:
            continue
        for f in k.transitive_kmods.to_list():
            paths[f.path] = True
    return paths

def _lib_kernel_base(dep_kernels):
    """Finds the shared base dill and its unseeded modules. Returns a struct with `base_dill`, `base_keys`, `base_kmods`, and `unseeded_base_kmods`."""
    base_dill = None
    base_keys = None
    base_kmods = depset()
    unseeded_candidates = None
    for k in dep_kernels:
        kd = getattr(k, "base_dill", None)
        kk = getattr(k, "base_keys", None)
        if kd != None and kk != None:
            if base_dill == None:
                base_dill = kd
                base_keys = kk
                base_kmods = getattr(k, "base_kmods", depset())
            unseeded_candidates = _lib_kernel_unseeded(base_dill, unseeded_candidates, kd, k)
    if base_dill != None and unseeded_candidates != None:
        non_base_kmod_paths = _lib_kernel_non_base_paths(dep_kernels)
        if non_base_kmod_paths:
            unseeded_candidates = {
                p: f
                for p, f in unseeded_candidates.items()
                if p not in non_base_kmod_paths
            }
    return struct(
        base_dill = base_dill,
        base_keys = base_keys,
        base_kmods = base_kmods,
        unseeded_base_kmods = depset(unseeded_candidates.values() if unseeded_candidates != None else []),
    )

def _lib_kernel_facade(graph, bases, cross_pkg_srcs):
    """The `DartKernelInfo` for a façade library with nothing to compile.

    Args:
      graph: The struct from `_lib_kernel_graph`.
      bases: The struct from `_lib_kernel_base`.
      cross_pkg_srcs: The depset of cross-package sources.
    """

    # A façade: nothing to compile, but its dependencies' modules still link.
    return DartKernelInfo(
        kmod = None,
        koutline = None,
        transitive_kmods = graph.dep_closure,
        transitive_koutlines = graph.dep_outline_closure,
        modular = True,
        closure_excluded = graph.upstream_excluded,
        cross_pkg_srcs = cross_pkg_srcs,
        owned = graph.owned,
        edges = graph.edges,
        base_dill = bases.base_dill,
        base_keys = bases.base_keys,
        base_kmods = bases.base_kmods,
        unseeded_base_kmods = bases.unseeded_base_kmods,
    )

def _lib_kernel_sources(package_name, lib_root, own_srcs, own_records, pkgs):
    """Returns the module's `struct(uri, file)` sources, named per owning member."""
    if len(own_records) == 1:
        return [
            struct(uri = library_source_uri(package_name, lib_root, f.short_path), file = f)
            for f in own_srcs
        ]

    # A merged library's sources span its members' roots: each file is
    # named by the member package whose `lib/` holds it.
    return [
        struct(uri = _owned_source_uri(f.short_path, pkgs), file = f)
        for f in own_srcs
    ]

def _lib_kernel_seed_base(ctx, dep_closure, kmod, package_name, own_records, target):
    """Links the shared test base dill. Returns a struct with `base_dill`, `base_keys`, `base_kmods`, and `unseeded_base_kmods`, or None."""
    if (package_name == "test" or "test" in [record.package_name for record in own_records]) and target == "vm" and hasattr(ctx.executable, "_kernel_link"):
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

def library_kernel_info(
        ctx,
        own_record,
        package_name,
        lib_root,
        own_srcs,
        opaque,
        target = "vm",
        platform_dill = None,
        libraries_json = None,
        libraries_platform = None,
        extra_libraries = [],
        scheme = STABLE_SCHEME,
        extra_frontend_flags = [],
        rule_deps = None,
        own_records = None,
        unused_inputs = False,
        non_standalone = False):
    """The `DartKernelInfo` a `dart_library` provides.

    The module is declared only here. Nothing builds it until an executable links
    it, so a library reached only through AOT binaries compiles no module at all.

    Args:
      ctx: The `dart_library` rule or aspect context.
      own_record: The library's own `DartPackageInfo`, or None.
      package_name: The package the library declares.
      lib_root: The package's `lib_root`.
      own_srcs: The library's own `.dart` files.
      opaque: True when the sources arrive as one directory (`srcs_dir`), whose
        files are not known here.
      target: The `kernel_worker --target` name (`"vm"` by default).
      platform_dill: Optional platform `.dill` File override.
      libraries_json: Optional `libraries.json` File override.
      libraries_platform: Optional platform key in `libraries.json`.
      extra_libraries: Extra bare `dart:` library names available on the target.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).
      extra_frontend_flags: Extra flags forwarded to `kernel_worker`.
      unused_inputs: Whether `kernel_module_action` writes an unused-inputs
        list. True when the caller registers the action once (the
        `dart_library` rule compiles its own module); False in the aspect's
        fallback compile, where several evaluations register it.
      non_standalone: True when the target carries the `no-dart-analyze` tag.
        The aspect computes this from its host (`_has_no_analyze_tag`, which
        reads `ctx.rule` and runs only there); the rule passes nothing, which
        is exact in practice — the tag's in-repo carrier is a plumbing library
        no kernel host depends on, and a rule cannot read its own tags anyway.
      rule_deps: Optional list of dependency targets (defaults to `ctx.attr.deps`).
      own_records: The library's own `DartPackageInfo` records, one per owned
        package. Defaults to `[own_record]` (or empty when it is None), which
        is what every one-package library passes; a merged multi-package
        library passes one record per member, and its module compiles all of
        their sources together, against a package config naming every member.

    Returns:
      A `DartKernelInfo`.
    """
    gated = _lib_kernel_gate(ctx, opaque, rule_deps)
    if gated == None:
        return no_kernel_module()
    tools, deps, dep_kernels, defines = gated

    recs = _lib_kernel_records(deps, dep_kernels, own_record, own_records)
    if recs == None:
        return no_kernel_module()
    records, raw, own_records = recs

    graph = _lib_kernel_graph(ctx, deps, dep_kernels, own_srcs, records)

    single_package_name = own_records[0].package_name if len(own_records) == 1 else ""
    has_cycle = _lib_kernel_has_cycle(single_package_name, raw, graph.owned_list, graph.edges_list, graph.pkgs, non_standalone)
    if has_cycle and graph.need_graph:
        cross_pkg_srcs, dep_cross_pkg_srcs = _lib_kernel_cyclic_srcs(deps, dep_kernels, own_srcs, single_package_name, raw, graph.owned_list, graph.edges_list, graph.pkgs)
    else:
        cross_pkg_srcs, dep_cross_pkg_srcs = _lib_kernel_plain_srcs(dep_kernels, own_srcs, has_cycle or graph.has_upstream_cross_pkg)

    bases = _lib_kernel_base(dep_kernels)
    if not own_srcs:
        return _lib_kernel_facade(graph, bases, cross_pkg_srcs)

    kmod = ctx.actions.declare_directory(ctx.label.name + ".kmod")
    koutline = ctx.actions.declare_directory(ctx.label.name + ".koutline")
    sources = _lib_kernel_sources(package_name, lib_root, own_srcs, own_records, graph.pkgs)
    excluded = kernel_module_action(
        ctx,
        tools,
        kernel_module_inputs(
            sources = sources,
            packages = graph.pkgs,
            dep_kmods = graph.dep_outline_closure,
            extra_inputs = dep_cross_pkg_srcs,
            closure_excluded = graph.upstream_excluded,
        ),
        kernel_module_outputs(
            output = kmod,
            koutline = koutline,
            unused_inputs = unused_inputs,
        ),
        kernel_module_options(
            defines = defines,
            exclude_non_sources = True,
            droppable = True,
        ),
        kernel_compile_settings(
            target = target,
            platform_dill = platform_dill,
            libraries_json = libraries_json,
            libraries_platform = libraries_platform,
            extra_libraries = extra_libraries,
            scheme = scheme,
            extra_frontend_flags = extra_frontend_flags,
        ),
    )
    seeded = _lib_kernel_seed_base(ctx, graph.dep_closure, kmod, package_name, own_records, target)
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
    if DartInfo not in target or ctx.attr.compile_mode != "kernel" or not ctx.attr.modular_kernel:
        return [no_kernel_module()]
    library = getattr(ctx.rule.attr, "library", None)
    if library != None and DartKernelInfo in library:
        return [library[DartKernelInfo]]

    inputs = library_module_inputs(ctx.rule.attr, ctx.rule.files, target[DartInfo])
    return [
        library_kernel_info(
            ctx,
            inputs.own_record,
            inputs.package_name,
            inputs.lib_root,
            inputs.own_srcs,
            opaque = inputs.opaque,
            rule_deps = inputs.rule_deps,
            own_records = inputs.own_records,
            non_standalone = _has_no_analyze_tag(ctx),
        ),
    ]

dart_kernel_module_aspect = aspect(
    implementation = _dart_kernel_module_aspect_impl,
    attr_aspects = ["deps", "library"],
    attrs = KERNEL_MODULE_ATTRS | EXTRA_DART_DEFINES_ATTR | {
        "_modular_kernel": attr.label(
            doc = "The `//dart:modular_kernel` build setting, disabled when `--allow_analysis_failures` is active.",
            default = Label("//dart/private:aspect_modular_kernel"),
            providers = [BuildSettingInfo],
        ),
        "compile_mode": attr.string(
            doc = "The originating executable's `compile_mode` (`kernel` for `dart_test`).",
            default = "kernel",
            values = ["exe", "aot-snapshot", "kernel", "jit-snapshot"],
        ),
        "modular_kernel": attr.bool(
            doc = "Whether the originating executable compiles modularly against dependency `.kmod` outputs.",
            default = True,
        ),
    },
    toolchains = MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles each `dart_library` in a modular executable's or test's closure to a `.kmod` directory.",
)
