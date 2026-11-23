"""Cycle planning and lockfile facts for flutter.pub dependency graphs.

Loads cycle planner, lockfile facts cache, and verification helpers from
@rules_dart//dart/pub:pub_scc.bzl, collects facts, and plans strongly connected
components (SCCs) for flutter.pub.
"""

load("@rules_dart//dart/pub:extensions.bzl", "touch_scanner_runtime_label")
load("@rules_dart//dart/pub:pinned_sources.bzl", "pinned_source_error")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "trim_gzip_trailing_nulls")
load(
    "@rules_dart//dart/pub:pub_scan.bzl",
    "check_package_symlinks",
    "run_pub_archive_scans",
)
load(
    "@rules_dart//dart/pub:pub_scc.bzl",
    "PARSER_SOURCE_LABELS",
    "compute_sccs",
    "package_dep_graph",
    "parser_schema",
    "read_scope_pubspec",
    "record_scope_facts",
    "scc_repo_name",
    "split_scope_facts",
    _hosted_fact_key = "hosted_fact_key",
    _lookup_fact_deps = "lookup_fact_deps",
    _parser_texts_digest = "parser_texts_digest",
    _scc_member_deps_error = "scc_member_deps_error",
    _scc_members_connectivity_error = "scc_members_connectivity_error",
    _scc_planned_deps_error = "scc_planned_deps_error",
    _spoke_planned_deps_error = "spoke_planned_deps_error",
)
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_deps")
load("//flutter/private:download.bzl", "pinned_download")
load("//flutter/private:flutter_pub_cycle_breaks.bzl", "apply_cycle_breaks")
load(
    "//flutter/private:flutter_pub_mirror.bzl",
    "detect_case_insensitive_host",
    "path_spoke_resolves_outside",
)
load("//flutter/private:flutter_pub_path.bzl", "is_absolute_lock_path")
load("//flutter/private:pub_lock_sdks.bzl", "hosted_package_sha256")

visibility(["//flutter/..."])

parser_texts_digest = _parser_texts_digest
hosted_fact_key = _hosted_fact_key
lookup_fact_deps = _lookup_fact_deps
scc_planned_deps_error = _scc_planned_deps_error
scc_member_deps_error = _scc_member_deps_error
spoke_planned_deps_error = _spoke_planned_deps_error
scc_members_connectivity_error = _scc_members_connectivity_error

def resolve_flutter_pub_schema(module_ctx):
    """Builds the fact-key schema from pubspec parser source bytes.

    Args:
        module_ctx: The module extension context.

    Returns:
        The parser schema string for this evaluation.
    """
    texts = [module_ctx.read(label, watch = "no") for label in PARSER_SOURCE_LABELS]
    return parser_schema(texts)

def _download_and_scan_scratch(module_ctx, scope_dir, misses):
    """Downloads missing hosted package archives into scratch and scans them."""
    pending = []
    for name in sorted(misses.keys()):
        pkg = misses[name]
        err = pinned_source_error(
            "hosted",
            name,
            pkg.version,
            sha256 = pkg.sha256,
            rule = "flutter.pub",
        )
        if err:
            fail(err)
        url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
            base = pkg.url,
            name = name,
            version = pkg.version,
        )
        archive = "{dir}/{name}.tar.gz".format(dir = scope_dir, name = name)
        out = "{dir}/{name}".format(dir = scope_dir, name = name)
        pinned_download(module_ctx, url = url, output = archive, sha256 = pkg.sha256)
        raw = module_ctx.read(archive, watch = "no")
        trimmed = trim_gzip_trailing_nulls(raw)
        if trimmed != raw:
            if hasattr(module_ctx, "delete"):
                module_ctx.delete(archive)
            module_ctx.file(archive, trimmed, executable = False)
        pending.append(struct(archive = archive, name = name, out = out))

    if pending:
        run_pub_archive_scans(
            module_ctx,
            [struct(archive = p.archive, name = p.name) for p in pending],
        )

    miss_deps = {}
    for p in pending:
        module_ctx.extract(p.archive, output = p.out)
        check_package_symlinks(module_ctx, p.name, root = p.out)
        pubspec_content = read_scope_pubspec(module_ctx, p.name, p.out)
        miss_deps[p.name] = sorted(parse_pubspec_deps(pubspec_content))

    return miss_deps

def collect_hosted_facts(module_ctx, hub_name, hosted, pub_lock, schema, recorded_facts):
    """Collects pubspec dependencies for hosted packages, caching in facts.

    Args:
        module_ctx: The module extension context.
        hub_name: The name of the pub hub.
        hosted: Dict mapping package name to hosted package info dict.
        pub_lock: The `pubspec.lock` label.
        schema: The parser schema string.
        recorded_facts: Mutable dict to record facts into.

    Returns:
        Dict mapping package name to its sorted dependency list.
    """
    if not hosted:
        return {}
    if hasattr(module_ctx, "os"):
        touch_scanner_runtime_label(module_ctx)

    hosted_structs = {}
    for name, info in hosted.items():
        desc = info.get("description", {})
        base_url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev"
        sha256 = hosted_package_sha256(name, info, pub_lock)
        hosted_structs[name] = struct(
            version = info.get("version", ""),
            sha256 = sha256,
            url = base_url,
        )

    facts = module_ctx.facts if hasattr(module_ctx, "facts") else {}
    split = split_scope_facts(facts, hosted_structs, {}, schema)

    miss_deps = {}
    if split.hosted_miss:
        scope_dir = "_scc_scratch/" + hub_name
        module_ctx.file(scope_dir + "/.scc_scope", "flutter pub dependency-cycle scope scratch")
        miss_deps = _download_and_scan_scratch(module_ctx, scope_dir, split.hosted_miss)
        if hasattr(module_ctx, "delete"):
            module_ctx.delete(scope_dir)

    record_scope_facts(recorded_facts, split, miss_deps)

    deps = dict(split.deps)
    for name, d in miss_deps.items():
        deps[name] = d
    return deps

def normalize_realpath(raw):
    """Normalizes a realpath string to forward slashes without a trailing slash.

    Windows drive roots such as `D:/` or `D:\\` normalize to `D:` so joining
    `"/"` in confinement checks produces `D:/...` rather than `D://...`.

    Args:
        raw: A path object or path string.

    Returns:
        The normalized forward-slash path string.
    """
    norm = str(raw).replace("\\", "/")
    if len(norm) > 1 and norm.endswith("/"):
        norm = norm.rstrip("/")
    return norm

def _is_case_insensitive_workspace(ws_root, ws_realpath, segments, os_name):
    """Returns True when path confinement checks should fold case."""
    if "win" in os_name.lower():
        return True
    if len(ws_realpath) >= 2 and ws_realpath[1] == ":":
        drive = ws_realpath[0]
        if ("A" <= drive and drive <= "Z") or ("a" <= drive and drive <= "z"):
            return True
    if hasattr(ws_root, "readdir"):
        return detect_case_insensitive_host(struct(workspace_root = ws_root), segments)
    return False

def _prefix_escape_error(ws_root, ws_realpath, hub_name, name, segments, case_insensitive):
    """Returns a confinement error if any existing prefix of `segments` resolves outside `ws_realpath`."""
    prefix = []
    for seg in segments:
        prefix.append(seg)
        node = ws_root.get_child(*prefix)
        if not node.exists:
            break
        node_real = normalize_realpath(node.realpath)
        if path_spoke_resolves_outside(ws_realpath, node_real, case_insensitive):
            return 'flutter.pub hub "%s": path dependency "%s" resolves outside workspace (%s)' % (
                hub_name,
                name,
                str(node.realpath),
            )
    return None

def resolve_path_pubspec(ws_root, ws_realpath, hub_name, name, rel_path, os_name = ""):
    """Validates workspace confinement for `<rel_path>/pubspec.yaml` without failing.

    Accepts forward-slash or backslash relative paths while refusing POSIX,
    Windows drive-letter, and UNC absolute paths, `.`/`..` segments, missing or
    directory `pubspec.yaml` entries, and symlinks resolving outside the
    workspace root. Returns the `pubspec_file` `path` directly so callers pass
    it to `module_ctx.read(...)` without constructing a Bazel package `Label`
    (which fails on case-insensitive hosts when a directory such as `build/`
    collides in name with `BUILD`).

    Args:
        ws_root: The workspace root `path` object.
        ws_realpath: Normalized realpath string of `ws_root`.
        hub_name: The `flutter.pub` hub name.
        name: The pub package name.
        rel_path: The lock's workspace-relative path string.
        os_name: Host OS name from `module_ctx.os.name`, if available.

    Returns:
        `struct(segments, pubspec_file, error)` where `error` is `None` on
        success or a human-readable refusal message.
    """
    if is_absolute_lock_path(rel_path) or rel_path in ("", "."):
        err = 'flutter.pub hub "%s": path dependency "%s" has invalid path %r' % (
            hub_name,
            name,
            rel_path,
        )
        return struct(segments = [], pubspec_file = None, error = err)
    segments = rel_path.replace("\\", "/").split("/")
    if ".." in segments or "." in segments or "" in segments:
        err = 'flutter.pub hub "%s": path dependency "%s" escapes workspace (%r)' % (
            hub_name,
            name,
            rel_path,
        )
        return struct(segments = [], pubspec_file = None, error = err)
    norm_ws = normalize_realpath(ws_realpath)
    case_insensitive = _is_case_insensitive_workspace(ws_root, norm_ws, segments, os_name)
    prefix_err = _prefix_escape_error(ws_root, norm_ws, hub_name, name, segments, case_insensitive)
    if prefix_err:
        return struct(segments = [], pubspec_file = None, error = prefix_err)
    pkg_dir = ws_root.get_child(*segments)
    pubspec_file = pkg_dir.get_child("pubspec.yaml")
    if not pubspec_file.exists or (hasattr(pubspec_file, "is_dir") and pubspec_file.is_dir):
        err = 'flutter.pub hub "%s": path dependency "%s" has no readable pubspec.yaml' % (
            hub_name,
            name,
        )
        return struct(segments = [], pubspec_file = None, error = err)
    pubspec_real = normalize_realpath(pubspec_file.realpath)
    if path_spoke_resolves_outside(norm_ws, pubspec_real, case_insensitive):
        err = 'flutter.pub hub "%s": path dependency "%s" pubspec.yaml resolves outside workspace (%s)' % (
            hub_name,
            name,
            str(pubspec_file.realpath),
        )
        return struct(segments = [], pubspec_file = None, error = err)
    return struct(segments = segments, pubspec_file = pubspec_file, error = None)

def _resolve_workspace_root(module_ctx, lock_label):
    """Resolves the root module's workspace directory `path` from `lock_label`."""
    if lock_label == None:
        return module_ctx.path(Label("@@//:MODULE.bazel")).dirname
    root = module_ctx.path(lock_label).dirname
    lock_dir = lock_label.name.rpartition("/")[0]
    if lock_dir:
        for _ in lock_dir.split("/"):
            root = root.dirname
    if lock_label.package:
        for _ in lock_label.package.split("/"):
            root = root.dirname
    return root

def collect_path_deps(module_ctx, hub_name, path_pkgs, lock_label = None):
    """Collects pubspec dependencies for workspace path packages.

    Args:
        module_ctx: The module extension context.
        hub_name: The name of the pub hub.
        path_pkgs: Dict mapping package name to path package info struct.
        lock_label: Optional root-module `pubspec.lock` label anchoring the workspace root.

    Returns:
        Dict mapping package name to its sorted dependency list.
    """
    if not path_pkgs:
        return {}
    ws_root = _resolve_workspace_root(module_ctx, lock_label)
    ws_realpath = normalize_realpath(ws_root.realpath)
    os_name = module_ctx.os.name if hasattr(module_ctx, "os") else ""
    deps = {}

    for name in sorted(path_pkgs.keys()):
        info = path_pkgs[name]
        resolved = resolve_path_pubspec(
            ws_root,
            ws_realpath,
            hub_name,
            name,
            info.path,
            os_name = os_name,
        )
        if resolved.error:
            fail(resolved.error)
        content = module_ctx.read(resolved.pubspec_file)
        deps[name] = sorted(parse_pubspec_deps(content))

    return deps

def plan_flutter_pub_sccs(all_package_names, hub_name, package_deps, cycle_breaks):
    """Plans strongly connected components for a flutter.pub hub.

    Applies cycle_breaks before computing SCCs so explicitly broken edges
    do not merge packages. Single-package SCCs become individual spokes;
    multi-package SCCs emit a merged spoke repository.

    Args:
        all_package_names: List of all package names in the lock.
        hub_name: The name of the pub hub.
        package_deps: Dict mapping package name to its dependency list.
        cycle_breaks: Dict mapping package name to broken dependency list.

    Returns:
        A struct with `hub_name`, `all_package_names`, `singletons`, `merged`,
        `sccs`, `scc_targets`, and `planned_deps`.
    """
    filtered_deps = {}
    if package_deps or cycle_breaks:
        for pkg in all_package_names:
            if pkg not in package_deps and pkg not in cycle_breaks:
                continue
            raw = package_deps.get(pkg, [])
            applied = apply_cycle_breaks(pkg, raw, cycle_breaks.get(pkg, []))
            if applied.error:
                fail(applied.error)
            if pkg in package_deps:
                filtered_deps[pkg] = applied.dependencies

    graph = package_dep_graph(filtered_deps, {}, all_package_names, [hub_name], [hub_name])
    components = compute_sccs(graph)

    merged = {}
    scc_targets = {}
    scc_members = {}

    for comp in components:
        if len(comp) >= 2:
            repo = scc_repo_name(hub_name, comp)
            merged[repo] = comp
            for member in comp:
                scc_targets[member] = "@" + repo + "//:" + member
                scc_members[member] = True

    singletons = sorted([pkg for pkg in all_package_names if pkg not in scc_members])

    return struct(
        hub_name = hub_name,
        all_package_names = all_package_names,
        singletons = singletons,
        merged = merged,
        sccs = [comp for comp in components if len(comp) >= 2],
        scc_targets = scc_targets,
        planned_deps = filtered_deps,
    )
