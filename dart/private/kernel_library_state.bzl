"""Analysis-time state of a `dart_library` module.

A module names the packages it compiles against and decides, without building
anything, whether its closure stays modular. The common path holds no list of
the transitive package closure and formats no JSON: the records reach the
config action through `ctx.actions.args().add_all(map_each = ...)`, expanded at
execution, and the closure checks read only the direct dependencies' own
records and flags, so their work stays in the direct edge. Only a merged or
split library falls back to the precise ownership graph in `dart_kernel.bzl`.

The base dill a module links against and the provider a façade library returns
live here too, so `dart_kernel.bzl` keeps only the action builders.
"""

load("//dart:providers.bzl", "DartInfo", "DartKernelInfo")
load("//dart/private:common.bzl", "owned_package_records")
load("//dart/private:dart_info.bzl", "package_lib_prefix")

DartKernelCycleInfo = provider(
    doc = """Whether a library's closure carries cross-package sources.

A dependent reads this instead of flattening the dependency's
`cross_pkg_srcs` depset to test it for emptiness, which would walk the whole
transitive closure once per target. The flag travels beside `DartKernelInfo`
and is set wherever that provider is produced for a modular library.
""",
    fields = {
        "has_cross": "bool: True when the closure holds cross-package sources.",
    },
)

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
    own_records = owned_package_records(dart_info)
    own_record = None
    if len(own_records) == 1 and package_name:
        only = own_records[0]
        if only.package_name == package_name and only.lib_root == lib_root:
            own_record = only
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
    if not has_srcs_attr and own_srcs != [] and len(rule_deps) == 0:
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

def _package_record_flag(pkg):
    """The `--record` argument naming one package record for the config tool.

    `ctx.actions.args().add_all` applies this to each record of the transitive
    depset at execution time, so analysis never flattens the closure into a
    Starlark list. Fields keep their order and empty stays empty; the tool
    splits on the same separator.

    Args:
      pkg: A `DartPackageInfo` record.

    Returns:
      The `name|lib_root|language_version` string.
    """
    return "%s|%s|%s" % (pkg.package_name, pkg.lib_root, getattr(pkg, "language_version", ""))

_EXEC_TOOLS_TOOLCHAIN = Label("//dart:exec_tools_toolchain_type")

def write_package_config_with_tool(ctx, dartaotruntime, output, packages, scheme):
    """Writes a module's package config through the config tool. Returns None.

    The records reach the tool as action arguments over the transitive depset,
    expanded at execution, so per-target analysis holds no list and formats no
    JSON string no matter how large the closure grows. The bytes match
    `kernel_package_config` for the same records. The tool is an AOT snapshot
    run by `dartaotruntime`, like the module compiler.

    Args:
      ctx: The rule context, carrying the `_package_config` executable.
      dartaotruntime: The SDK runtime executing the snapshot.
      output: The `package_config.json` File to produce.
      packages: A `(own_records, transitive)` pair: the library's own record
        list first, then its transitive record depset. The tool keeps the
        first of each package name, so the own records win exactly as in
        `first_per_package` over the flattened closure.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).
    """
    tool = None
    if hasattr(ctx.executable, "_package_config"):
        tool = ctx.executable._package_config
    if tool == None:
        fail("kernel module %s needs the `_package_config` tool to write its package config." % ctx.label)
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--scheme", scheme)
    args.add("--output", output.path)
    own_records, transitive = packages
    args.add_all(own_records, map_each = _package_record_flag, before_each = "--record")
    args.add_all(transitive, map_each = _package_record_flag, before_each = "--record")
    ctx.actions.run(
        executable = dartaotruntime,
        arguments = [tool.path, args],
        inputs = depset(direct = [tool]),
        outputs = [output],
        mnemonic = "DartPackageConfig",
        progress_message = "Writing package config %s" % output.short_path,
        # The runtime comes from the exec tools toolchain when the rule resolves one.
        toolchain = _EXEC_TOOLS_TOOLCHAIN if ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN] != None else None,
    )

def _direct_owned_records(deps):
    """The own package records of each direct dependency, in order.

    Each entry is the dependency's `owned_packages` list, which is already
    materialized and tiny (zero or one record for every ordinary library, one
    per member for a merged one). Reading it touches no transitive depset, so
    the work stays in the direct dependencies no matter how large the closure
    grows. A producer predating the field falls back to its matched record.

    Args:
      deps: The direct dependency targets.

    Returns:
      A list with one `owned_packages` list per dependency.
    """
    return [owned_package_records(dep[DartInfo]) for dep in deps if DartInfo in dep]

def lib_owns_compatible(own_records, deps):
    """Whether new records join the direct dependencies without conflict.

    A closure holds one `rootUri` per package name and at most one root
    package. Two records for one name with different roots (or two root
    packages under different names) cannot share a config, and the closure
    then compiles whole-program. Checking the new records against each direct
    dependency's own records and those against each other is constant work in
    the direct dependencies; deeper conflicts surface through the
    dependencies' own `modular` flags, which already summarize their closures.

    Args:
      own_records: This library's own `DartPackageInfo` records.
      deps: The direct dependency targets.

    Returns:
      True when nothing among the new and direct records conflicts.
    """
    pool = list(own_records)
    for owns in _direct_owned_records(deps):
        pool.extend(owns)
    seen = {}
    roots = {}
    for rec in pool:
        prev = seen.get(rec.package_name)
        if prev != None and prev != rec.lib_root:
            return False
        seen[rec.package_name] = rec.lib_root
        if not rec.lib_root:
            roots[rec.package_name] = True
    return len(roots) <= 1

def _lib_own_cycle(own_package_name, deps, non_standalone):
    """Whether this library itself opens a cross-package split or cycle.

    A package split across targets (the same name on this library and on a
    direct dependency, or twice among them) and the `no-dart-analyze` tag both
    put sources of one package on several modules, which the entry compiles
    from source together. The check reads only the direct dependencies' own
    records, so it stays constant in the closure.

    Args:
      own_package_name: This library's own `package_name` ("" when none).
      deps: The direct dependency targets.
      non_standalone: True when the target carries the `no-dart-analyze` tag.

    Returns:
      True when this library's own package repeats across the direct edge.
    """
    if non_standalone:
        return True
    direct = _direct_owned_records(deps)
    if own_package_name and any([rec.package_name == own_package_name for owns in direct for rec in owns]):
        return True
    names = []
    if own_package_name:
        names.append(own_package_name)
    for owns in direct:
        for rec in owns:
            names.append(rec.package_name)
    return len(names) != len({name: True for name in names})

def _target_has_cross(dep):
    """Whether a direct dependency's closure holds cross-package sources.

    Reads the dependency's `DartKernelCycleInfo` flag instead of flattening
    its `cross_pkg_srcs` depset, which would walk the whole transitive closure.

    Args:
      dep: A direct dependency target.

    Returns:
      True when the dependency reports cross-package sources.
    """
    if DartKernelCycleInfo in dep:
        return dep[DartKernelCycleInfo].has_cross
    return False

def lib_has_cross(own_package_name, deps, non_standalone):
    """Whether the closure through a library holds cross-package sources.

    Either the library opens a split or cycle itself, or a direct dependency
    already carries sources past one. Both facts come from the direct edge
    alone, so the check is constant in the closure. The flag travels beside
    `DartKernelInfo` as `DartKernelCycleInfo`, so dependents never flatten
    the dependency's `cross_pkg_srcs` depset to test it for emptiness.

    Args:
      own_package_name: This library's own `package_name` ("" when none).
      deps: The direct dependency targets.
      non_standalone: True when the target carries the `no-dart-analyze` tag.

    Returns:
      True when cross-package sources ride this library's closure.
    """
    if _lib_own_cycle(own_package_name, deps, non_standalone):
        return True
    return any([_target_has_cross(dep) for dep in deps])

def _lib_direct_duplicates(own_records, deps):
    """Whether a package name repeats among the new and direct records.

    A repeated name means the closure holds the package twice and the module
    path needs the ownership graph to place the split sources. The check reads
    only the direct dependencies' own records, so it stays constant in the
    closure.

    Args:
      own_records: This library's own `DartPackageInfo` records.
      deps: The direct dependency targets.

    Returns:
      True when one package name appears twice or more.
    """
    count = len(own_records)
    seen = {rec.package_name: True for rec in own_records}
    for owns in _direct_owned_records(deps):
        for rec in owns:
            count += 1
            seen[rec.package_name] = True
    return len(seen) < count

def lib_kernel_closures(ctx, deps, dep_kernels, own_srcs):
    """The closure depsets a library module links against.

    Each depset extends the direct dependencies' own with this library's
    contribution, which only references the depsets and never flattens them,
    so the work stays in the direct dependencies no matter how large the
    closure grows. Both the precise and the fast module paths share these.

    Args:
      ctx: The `dart_library` rule or aspect context, for `ctx.label`.
      deps: The direct dependency targets.
      dep_kernels: The `DartKernelInfo` of each direct dependency.
      own_srcs: The library's own `.dart` files.

    Returns:
      A struct with `dep_closure`, `dep_outline_closure`,
      `upstream_excluded`, `owned`, and `edges`.
    """
    return struct(
        dep_closure = depset(
            order = "postorder",
            transitive = [k.transitive_kmods for k in dep_kernels],
        ),
        dep_outline_closure = depset(
            order = "postorder",
            transitive = [k.transitive_koutlines for k in dep_kernels],
        ),
        upstream_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels]),
        owned = depset(
            [(str(ctx.label), f.short_path) for f in own_srcs],
            transitive = [k.owned for k in dep_kernels],
        ),
        edges = depset(
            [(str(ctx.label), str(dep.label)) for dep in deps],
            transitive = [k.edges for k in dep_kernels],
        ),
    )

def _lib_kernel_graph_fast(ctx, deps, dep_kernels, own_srcs, has_upstream):
    """The module closures for a library needing no ownership graph.

    A library whose package names are all distinct takes this path: no name
    repeats, so no ownership graph can change the cycle check, and the module
    compiles against the transitive record depset the config tool dedupes.
    Nothing here flattens a closure-sized depset.

    Args:
      ctx: The `dart_library` rule or aspect context, for `ctx.label`.
      deps: The direct dependency targets.
      dep_kernels: The `DartKernelInfo` of each direct dependency.
      own_srcs: The library's own `.dart` files.
      has_upstream: Whether a direct dependency carries cross-package sources.

    Returns:
      The struct `_lib_kernel_graph` returns, with no packages flattened:
      `pkgs` and the lists stay empty and `need_graph` stays False.
    """
    closures = lib_kernel_closures(ctx, deps, dep_kernels, own_srcs)
    return struct(
        dep_closure = closures.dep_closure,
        dep_outline_closure = closures.dep_outline_closure,
        upstream_excluded = closures.upstream_excluded,
        owned = closures.owned,
        edges = closures.edges,
        pkgs = [],
        owned_list = [],
        edges_list = [],
        need_graph = False,
        has_upstream_cross_pkg = has_upstream,
    )

def lib_kernel_plain_srcs(dep_kernels, own_srcs, include_own):
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

def lib_kernel_needs_graph(library, options, deps):
    """Whether a library's module needs the precise ownership graph.

    A merged multi-package library maps each source through the graph, and a
    library whose own package repeats across the direct edge needs it to place
    the split sources. Every other library compiles from the transitive
    record depset the config tool dedupes.

    Args:
      library: The struct from `library_kernel_sources()`.
      options: The struct from `library_kernel_options()`.
      deps: The direct dependency targets.

    Returns:
      True when the precise (flattening) module path must run.
    """
    if len(library.own_records) > 1 and library.own_srcs:
        return True
    single = library.own_records[0].package_name if len(library.own_records) == 1 else ""
    return _lib_own_cycle(single, deps, options.non_standalone) and _lib_direct_duplicates(library.own_records, deps)

def lib_kernel_fast_state(ctx, library, options, deps, dep_kernels):
    """The module state for a library needing no ownership graph.

    Package names are distinct across the direct edge, so no graph can change
    the cycle check, and the module compiles against the transitive record
    depset the config tool dedupes. Nothing here flattens a closure-sized
    depset or formats a JSON string.

    Args:
      ctx: The `dart_library` rule or aspect context.
      library: The struct from `library_kernel_sources()`.
      options: The struct from `library_kernel_options()`.
      deps: The direct dependency targets.
      dep_kernels: The `DartKernelInfo` of each direct dependency.

    Returns:
      The state struct `library_kernel_info` compiles from.
    """
    single = library.own_records[0].package_name if len(library.own_records) == 1 else ""
    has_cross = lib_has_cross(single, deps, options.non_standalone)
    has_upstream = any([_target_has_cross(dep) for dep in deps])
    graph = _lib_kernel_graph_fast(ctx, deps, dep_kernels, library.own_srcs, has_upstream)
    cross, dep_cross = lib_kernel_plain_srcs(dep_kernels, library.own_srcs, has_cross)
    packages = (
        library.own_records,
        depset(transitive = [dep[DartInfo].transitive_packages for dep in deps if DartInfo in dep]),
    )
    return struct(
        graph = graph,
        cross_pkg_srcs = cross,
        dep_cross_pkg_srcs = dep_cross,
        module_packages = packages,
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

def lib_kernel_base(dep_kernels):
    """Finds the shared base dill and its unseeded modules.

    Args:
      dep_kernels: The `DartKernelInfo` of each direct dependency.

    Returns:
      A struct with `base_dill`, `base_keys`, `base_kmods`, and
      `unseeded_base_kmods`.
    """
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

def lib_kernel_facade(graph, bases, cross_pkg_srcs):
    """The `DartKernelInfo` for a façade library with nothing to compile.

    Args:
      graph: The struct from `_lib_kernel_graph`.
      bases: The struct from `lib_kernel_base`.
      cross_pkg_srcs: The depset of cross-package sources.

    Returns:
      The `DartKernelInfo` a façade library provides.
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
