"""Module extension for declaring pub.dev package dependencies."""

load("//dart/pub:pub_lock_package.bzl", "pub_lock_package_sha256_error")
load("//dart/pub/private:build_content.bzl", "PACKAGE_FILES_ATTR_DOC")
load("//dart/pub/private:pin_checks.bzl", "lock_package_error")
load("//dart/pub/private:project.bzl", "register_dart_projects")
load("//dart/pub/private:pub_emit.bzl", "SPOKE_PREFIX", "instantiate_pub_repos", "pub_repo_specs", "pub_scopes")
load("//dart/pub/private:pub_hooks.bzl", "HOOK_TAG_ATTRS", "lock_hook_settings")
load("//dart/pub/private:pub_plan.bzl", "plan_pub_graph", "read_pub_plans")
load("//dart/pub/private:pub_root_pin.bzl", "best_entry", "decl_lock_sha_conflict", "git_path_conflict", "git_ref_conflict", "git_version_error", "hosted_sha_conflict", "hosted_version_error", "select_all_explicit")
load("//dart/pub/private:pub_scanner_sdk.bzl", "scanner_runtime_label")
load("//dart/pub/private:pub_scc_entries.bzl", _scc_member_entries = "scc_member_entries")
load("//dart/pub/private:pub_sources.bzl", "check_path_build_files", "local_entry_conflict", "path_package_dir", "path_package_label", "sdk_package_message", "unknown_source_error")
load("//dart/pub/private:pub_workspace.bzl", "check_workspaces")
load("//dart/pub/private:pubspec_data.bzl", "lock_packages")
load("//dart/pub/private:scc.bzl", _plan_scope_sccs = "plan_scope_sccs")
load("//dart/pub/private:yaml2json.bzl", "yaml_to_json")

visibility("public")

# Re-exported for //dart/tests, which exercises the entry shape and the
# cycle planning directly.
scc_member_entries = _scc_member_entries
plan_scope_sccs = _plan_scope_sccs

_package = tag_class(
    doc = "Declares one pub.dev package to download and materialize as a spoke repository, pinned by version and archive hash with its pub dependencies. A `package` tag from the root module wins over `package` tags for the same package from dependencies: a dependency's different version is dropped with a NOTE naming both versions. A root lock's git entry pins like a hosted one, and a root pin never hides a same-version sha256 conflict. With `workspace_members`, the lock is a pub workspace root's lock and its members are checked (see docs/pub.md, Workspaces).",
    attrs = {
        "name": attr.string(
            doc = "The pub.dev package name (also used as the repository name).",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive.",
            mandatory = True,
        ),
        "deps": attr.string_list(
            doc = "Repository names of pub packages this package depends on.",
            default = [],
        ),
        "package_files": attr.string_list(
            doc = "Applies to the package this tag declares. " + PACKAGE_FILES_ATTR_DOC,
            default = ["pubspec.yaml", "LICENSE*"],
        ),
    },
)

_from_lock = tag_class(
    doc = "Resolves a pubspec.lock file into one hub repository and its package spokes, joining the global version resolution unless isolated. A package pinned by a lock the root module reads keeps the resolved version when a dependency declares another version with `pub.package()`: the dependency's version is dropped with a NOTE naming the resolved version. A root lock's git entry pins like a hosted one, and a root pin never hides a same-version sha256 conflict.",
    attrs = {
        "name": attr.string(
            doc = "Repository name for the resolved packages. The name is global to the " +
                  "extension, not scoped to the declaring module: every `from_lock` that " +
                  "states it — in any module in the build — contributes to one hub holding " +
                  "the union of those locks, and each package is aliased once. That is what " +
                  "makes two modules that both call their hub the obvious thing work when a " +
                  "third depends on both. It also means a module can reach a package only " +
                  "another module's lock names, which resolves today and breaks the day that " +
                  "module leaves the build, so state in your own lock everything you import. " +
                  "Package versions are reconciled across the union — see " +
                  "`on_version_conflict`.",
            mandatory = True,
        ),
        "lock": attr.label(
            doc = "The pubspec.lock file to parse.",
            mandatory = True,
            allow_single_file = True,
        ),
        "on_version_conflict": attr.string(
            doc = "What to do when another lock file provides a higher version of a package. " +
                  "'error' (default) fails the build. 'upgrade' accepts the higher version. " +
                  "Ignored for isolated hubs, which never join version resolution.",
            default = "error",
            values = ["error", "upgrade"],
        ),
        "isolated": attr.bool(
            doc = "When True, this hub is isolated: its spokes are namespaced by the hub " +
                  "name (`<hub>__<pkg>`), it does not join the global registry or " +
                  "`on_version_conflict` resolution, and it pins the versions in its own " +
                  "lock. Use for standalone tools that need a different version of a " +
                  "package than the rest of the build. Defaults to False.",
            default = False,
        ),
        "workspace_members": attr.label_list(
            doc = "Labels of a pub workspace's member `pubspec.yaml` files; checked at fetch time (docs/pub.md, Workspaces). Empty checks nothing.",
            allow_files = True,
            default = [],
        ),
        "package_files": attr.string_list(
            doc = "Applies to every package this lock materializes, including merged cycle " +
                  "members. " + PACKAGE_FILES_ATTR_DOC,
            default = ["pubspec.yaml", "LICENSE*"],
        ),
        "plan": attr.label(
            doc = "A checked-in plan of this lock (`bazel run @rules_dart//dart/pub/plan -- " +
                  "write`): the dependency names and archive URL of every hosted package, as " +
                  "planning records them. A package the plan covers is planned with no " +
                  "request to its server and recorded in no lockfile; one it does not cover " +
                  "(a stale plan) is planned as without one. A module that ships a lock to " +
                  "its users ships its plan with it, so they never plan it. Unset by default.",
            allow_single_file = True,
            default = None,
        ),
    } | HOOK_TAG_ATTRS,
)

def touch_scanner_runtime_label(ctx):
    """Resolves the scanner runtime label so cold and warm lockfiles stay byte-identical.

    `run_pub_archive_scans` resolves `scanner_runtime_label(ctx.os)` through
    this module's repo mapping, which the lockfile records as a
    `REPO_MAPPING` input — but only on evaluations that actually scan. A warm
    evaluation whose facts hit for every package scans nothing, so without
    this touch its recorded inputs miss that line. Resolving the same label
    here, for every scope that holds hosted or git packages whether or not
    anything misses the facts, records the identical input on both paths.
    Label construction only: no `ctx.path` and no download, so a warm
    evaluation still fetches nothing. The scanner snapshot label needs no
    touch: it is a module-level `Label` in `pub_scan.bzl`, resolved at load
    on every evaluation already.

    Args:
      ctx: The module extension context.

    Returns:
      The scanner runtime label, so tests can pin that it names the same
      label the scan resolves.
    """
    return scanner_runtime_label(ctx.os)

def _resolve_state():
    """Returns the mutable resolution state for lock collection."""

    # registry[pkg_name] = {url, entries: [{version, sha256, hub_name, lock_label, on_version_conflict}]}
    # git_registry mirrors it for git-sourced packages, pinned by commit SHA.
    # hub_packages maps each hub to its package set (a set, not a list: a hub
    # name is shared by every `from_lock` stating it, so it holds their union).
    return {
        "registry": {},
        "git_registry": {},
        "hub_packages": {},
        "warnings": [],
        "isolated_hubs": {},
        "isolated_hub_packages": {},
        "isolated_git_packages": {},
        # Per hub: name to the label of a `path` package's target, and name to
        # the message of a hub target that fails when used (`sdk` packages).
        "path_packages": {},
        "unavailable": {},
    }

def _resolve_hub_scope(state, lock_tag):
    """Registers a lock tag's hub scope. Returns (hub_name, isolated, error)."""
    hub_name = lock_tag.name
    isolated = getattr(lock_tag, "isolated", False)
    if hub_name in state["isolated_hubs"] and state["isolated_hubs"][hub_name] != isolated:
        return hub_name, isolated, "Hub \"%s\" is declared both isolated and non-isolated." % hub_name
    state["isolated_hubs"][hub_name] = isolated
    state["hub_packages"].setdefault(hub_name, {})
    if isolated:
        state["isolated_hub_packages"].setdefault(hub_name, {})
    return hub_name, isolated, None

def _lock_entry_error(name, info, lock_tag):
    """Returns the lock-entry error string, or None when the entry is valid."""
    err = lock_package_error(name, info, lock_tag.lock)
    if not err:
        return None
    if info.get("source") == "hosted":
        sha_err = pub_lock_package_sha256_error(
            name,
            info.get("version", ""),
            info.get("description", {}).get("sha256", ""),
        )
        return "%s (%s)" % (err, sha_err)
    return err

def _register_git_package(state, name, info, lock_tag, hub_name, isolated):
    """Registers one git-sourced lock entry. Returns the error string, or None."""

    # Git packages are fetched at their resolved-ref commit, like
    # hosted packages, and exposed in the hub the same way.
    state["hub_packages"][hub_name][name] = True

    desc = info.get("description", {})
    url = desc.get("url", "")
    version = info.get("version", "")
    resolved_ref = desc.get("resolved-ref", "").strip()
    path = desc.get("path", ".")
    if path == None or str(path).strip() == "":
        path = "."
    package_files = getattr(lock_tag, "package_files", ["pubspec.yaml", "LICENSE*"])

    if not url:
        return 'pub package "%s" %s in %s has no url for its git source.' % (name, version, lock_tag.lock)

    if isolated:
        # Isolated hubs pin their own versions: the spoke is
        # namespaced by the hub and never joins the global
        # registry or `on_version_conflict` resolution.
        state["isolated_git_packages"].setdefault(hub_name, {})[name] = struct(
            version = version,
            url = url,
            resolved_ref = resolved_ref,
            path = path,
            package_files = package_files,
        )
        return None

    entry = struct(
        version = version,
        resolved_ref = resolved_ref,
        path = path,
        hub_name = hub_name,
        lock_label = str(lock_tag.lock),
        on_version_conflict = lock_tag.on_version_conflict,
        package_files = package_files,
    )

    git_registry = state["git_registry"]
    if name not in git_registry:
        git_registry[name] = struct(url = url, entries = [entry])
        return None
    existing = git_registry[name]
    if existing.url != url:
        return (
            "Package \"%s\" has conflicting git URLs:\n" % name +
            "  - %s (from \"%s\")\n" % (existing.url, existing.entries[0].hub_name) +
            "  - %s (from \"%s\")" % (url, hub_name)
        )
    git_registry[name] = struct(url = existing.url, entries = existing.entries + [entry])
    return None

def _register_hosted_package(state, explicit, name, info, lock_tag, hub_name, isolated):
    """Registers one hosted lock entry. Returns the error string, or None."""
    state["hub_packages"][hub_name][name] = True

    desc = info.get("description", {})
    url = desc.get("url", "https://pub.dev")
    version = info.get("version", "")
    sha256 = desc["sha256"].strip()
    package_files = getattr(lock_tag, "package_files", ["pubspec.yaml", "LICENSE*"])

    if isolated:
        state["isolated_hub_packages"][hub_name][name] = struct(
            version = version,
            sha256 = sha256,
            url = url,
            package_files = package_files,
        )
        return None

    if name in explicit:
        exp = explicit[name]
        if exp.version == version and exp.sha256 != sha256:
            return decl_lock_sha_conflict(name, version, exp.sha256, hub_name, str(lock_tag.lock), sha256)

    entry = struct(
        version = version,
        sha256 = sha256,
        hub_name = hub_name,
        lock_label = str(lock_tag.lock),
        on_version_conflict = lock_tag.on_version_conflict,
        package_files = package_files,
    )

    registry = state["registry"]
    if name not in registry:
        registry[name] = struct(url = url, entries = [entry])
        return None
    existing = registry[name]
    if existing.url != url:
        return (
            "Package \"%s\" has conflicting registry URLs:\n" % name +
            "  - %s (from \"%s\")\n" % (existing.url, existing.entries[0].hub_name) +
            "  - %s (from \"%s\")\n" % (url, hub_name)
        )
    registry[name] = struct(url = existing.url, entries = existing.entries + [entry])
    return None

def _register_path_package(state, name, info, lock_tag, hub_name):
    """Registers one `path` lock entry: the hub aliases the package's own target. Returns the error, or None."""
    resolved = path_package_dir(name, info, lock_tag.lock)
    if resolved.error:
        return resolved.error
    label = path_package_label(name, lock_tag.lock, resolved.dir)
    for other_hub, packages in state["path_packages"].items():
        other = packages.get(name)
        if other and other.label != label and not state["isolated_hubs"].get(hub_name) and not state["isolated_hubs"].get(other_hub):
            return local_entry_conflict(name, "a path package at %s" % label, "a path package at %s" % other.label, lock_tag.lock)
    state["hub_packages"][hub_name][name] = True
    state["path_packages"].setdefault(hub_name, {})[name] = struct(label = label, dir = resolved.dir, lock = lock_tag.lock)
    return None

def _register_lock_package(state, explicit, name, info, lock_tag, hub_name, isolated):
    """Registers one lock entry by source. Returns (error, error_shape)."""
    err = _lock_entry_error(name, info, lock_tag)
    if err:
        return err, "lock"
    source = info.get("source", "unknown")
    if source == "git":
        return _register_git_package(state, name, info, lock_tag, hub_name, isolated), "git"
    if source == "path":
        return _register_path_package(state, name, info, lock_tag, hub_name), "lock"
    if source == "sdk":
        state["hub_packages"][hub_name][name] = True
        state["unavailable"].setdefault(hub_name, {})[name] = sdk_package_message(name, info, lock_tag.lock)
        return None, "lock"
    if source != "hosted":
        return unknown_source_error(name, info, lock_tag.lock), "lock"
    return _register_hosted_package(state, explicit, name, info, lock_tag, hub_name, isolated), "lock"

def _resolve_lock_tag(state, explicit, lock_tag):
    """Collects one lock file's entries into the state. Returns (error, error_shape)."""
    hub_name, isolated, err = _resolve_hub_scope(state, lock_tag)
    if err:
        return err, "hub"

    for name, info in lock_tag.packages.items():
        err, shape = _register_lock_package(
            state,
            explicit,
            name,
            info,
            lock_tag,
            hub_name,
            isolated,
        )
        if err:
            return err, shape
    return None, ""

def _resolve_hosted_package(name, pkg, explicit, git_registry, warnings):
    """Resolves one hosted package. Returns (resolved_struct_or_None, skip_reason, error)."""
    err = hosted_sha_conflict(name, pkg.entries)
    if err:
        return None, "", err
    if name in explicit:
        return None, "explicit", None
    if name in git_registry:
        # A package listed as both hosted and git materialises once, from
        # its git checkout: generating both a hosted spoke and a git spoke
        # would name two repositories dart_pub__<name>, and a merged cycle
        # would otherwise fetch the hosted tarball and drop the git
        # checkout silently. A single pubspec.lock cannot list both (its
        # package names are unique), so this only fires across the union
        # of several locks.
        git_pkg = git_registry[name]
        lines = ["Package \"%s\" is listed as both a hosted package and a git package; using the git checkout and ignoring the hosted entries:" % name]
        for e in pkg.entries:
            lines.append("  - %s (hosted, from \"%s\", %s)" % (e.version, e.hub_name, e.lock_label))
        for e in git_pkg.entries:
            lines.append("  - %s (git, from \"%s\", %s)" % (e.version, e.hub_name, e.lock_label))
        warnings.append("\n".join(lines))
        return None, "git", None
    if len(pkg.entries) == 1:
        e = pkg.entries[0]
        return struct(version = e.version, sha256 = e.sha256, url = pkg.url, package_files = e.package_files), "", None
    best = best_entry(pkg.entries)
    for e in pkg.entries:
        if e.version != best.version and e.on_version_conflict == "error":
            return None, "", hosted_version_error(name, pkg.entries, best)
    return struct(
        version = best.version,
        sha256 = best.sha256,
        url = pkg.url,
        package_files = best.package_files,
    ), "", None

def _resolve_hosted(state, explicit):
    """Resolves every hosted package to one version. Returns (resolved, error)."""
    resolved = {}
    git_registry = state["git_registry"]
    for name, pkg in state["registry"].items():
        entry, _, err = _resolve_hosted_package(name, pkg, explicit, git_registry, state["warnings"])
        if err:
            return {}, err
        if entry != None:
            resolved[name] = entry
    return resolved, None

def _resolve_git_versions(state):
    """Resolves every git package to one version. Returns (resolved_git, error)."""
    resolved_git = {}
    for name, pkg in state["git_registry"].items():
        err = git_ref_conflict(name, pkg.entries)
        if err:
            return {}, err
        err = git_path_conflict(name, pkg.entries)
        if err:
            return {}, err
        if len(pkg.entries) == 1:
            e = pkg.entries[0]
            resolved_git[name] = struct(
                version = e.version,
                url = pkg.url,
                resolved_ref = e.resolved_ref,
                path = e.path,
                package_files = e.package_files,
            )
            continue
        best = best_entry(pkg.entries)
        for e in pkg.entries:
            if e.version != best.version and e.on_version_conflict == "error":
                return {}, git_version_error(name, pkg.entries)
        resolved_git[name] = struct(
            version = best.version,
            url = pkg.url,
            resolved_ref = best.resolved_ref,
            path = best.path,
            package_files = best.package_files,
        )
    return resolved_git, None

def _resolve_isolated_overlap(state):
    """Drops hosted entries shadowed by a git checkout in an isolated hub."""

    # A package listed as both hosted and git in one isolated hub
    # materialises once, from its git checkout, like the shared scope above.
    for hub_name, git_pkgs in state["isolated_git_packages"].items():
        hosted = state["isolated_hub_packages"].get(hub_name, {})
        for name in sorted(git_pkgs.keys()):
            if name in hosted:
                state["warnings"].append(
                    "\n".join([
                        "Package \"%s\" in isolated hub \"%s\" is listed as both a hosted package and a git package; using the git checkout and ignoring the hosted entry:" % (name, hub_name),
                        "  - %s (hosted)" % hosted[name].version,
                        "  - %s (git)" % git_pkgs[name].version,
                    ]),
                )
                hosted.pop(name)

def _resolve_error_sha(error):
    """The error struct for `pub.package()` pin errors."""
    return struct(
        error = error,
        explicit = {},
        resolved = {},
        resolved_git = {},
        hub_packages = {},
        aliases = {},
        notes = [],
        warnings = [],
    )

def _resolve_error_conflict(error):
    """The error struct for conflicting `pub.package()` declarations and lock-collection or hosted-resolution failures."""
    return struct(
        error = error,
        explicit = {},
        resolved = {},
        resolved_git = {},
        hub_packages = {},
        isolated_packages = {},
        aliases = {},
        notes = [],
        warnings = [],
    )

def _resolve_error_hub(error):
    """The error struct for isolated/non-isolated hub conflicts."""
    return struct(
        error = error,
        explicit = {},
        resolved = {},
        hub_packages = {},
        isolated_packages = {},
        aliases = {},
        notes = [],
        warnings = [],
    )

def _resolve_error_git(error):
    """The error struct for git-registration and git-resolution failures."""
    return struct(
        error = error,
        explicit = {},
        resolved = {},
        resolved_git = {},
        hub_packages = {},
        isolated_packages = {},
        isolated_git_packages = {},
        aliases = {},
        notes = [],
        warnings = [],
    )

def resolve_pub_packages(package_tags, lock_tags):
    """Validates and resolves `pub.package` and `pub.from_lock` declarations.

    Every `pub.package` and hosted `pub.from_lock` entry must carry a
    64-lowercase-hex-digit `sha256` after trimming, even when later superseded
    by version resolution or an explicit `pub.package()`. Conflicting `sha256`
    values for the same package version across lock files or between
    `pub.package()` and a lock file are rejected. A package listed as both a
    hosted package and a git package resolves to its git checkout: the hosted
    entries are ignored with a warning, so the package materialises exactly
    once however the dependency cycles fall.

    The root module wins over dependencies: its `pub.package()` pin, or the
    version its non-isolated `pub.from_lock` locks settle on, resolves when a
    non-root `pub.package()` declares another version, with an informational
    NOTE naming the resolved version. A root lock's git entry pins like a
    hosted one. A non-root declaration at the resolved version
    with a different sha256 is an integrity conflict and fails.

    Args:
        package_tags: List of structs with `(name, version, sha256, deps)`
            and optionally `(is_root, module)`. Tags without `is_root`
            count as root.
        lock_tags: List of structs with `(name, lock, packages, on_version_conflict, isolated)`
            and optionally `(is_root, module)`.

    Returns:
        `struct(error, explicit, resolved, resolved_git, hub_packages, isolated_packages, isolated_git_packages, aliases, notes, warnings)`
        where `error` is an error string when any declaration is unpinned,
        malformed, or conflicting, or `None` when resolution succeeds.
        `isolated_packages` maps each isolated hub name to
        `{pkg_name: struct(version, sha256, url)}` and `isolated_git_packages`
        maps each isolated hub name to
        `{pkg_name: struct(version, url, resolved_ref, path)}`. `aliases`
        maps package name to `(version, sha256, source)` for names a root
        lock pin resolves while declarations exist: the package-named
        repository is generated as an alias to the lock spoke. `notes` holds
        one NOTE per package whose root pin overrode a different version.
    """
    explicit, aliases, notes, err, err_shape = select_all_explicit(package_tags, lock_tags)
    if err:
        if err_shape == "sha":
            return _resolve_error_sha(err)
        return _resolve_error_conflict(err)

    state = _resolve_state()
    for lock_tag in lock_tags:
        err, err_shape = _resolve_lock_tag(state, explicit, lock_tag)
        if err:
            if err_shape == "hub":
                return _resolve_error_hub(err)
            if err_shape == "git":
                return _resolve_error_git(err)
            return _resolve_error_conflict(err)

    err = _path_source_conflict(state, explicit)
    if err:
        return _resolve_error_conflict(err)

    resolved, err = _resolve_hosted(state, explicit)
    if err:
        return _resolve_error_conflict(err)

    resolved_git, err = _resolve_git_versions(state)
    if err:
        return _resolve_error_git(err)

    _resolve_isolated_overlap(state)

    return struct(
        error = None,
        explicit = explicit,
        resolved = resolved,
        resolved_git = resolved_git,
        hub_packages = state["hub_packages"],
        isolated_packages = state["isolated_hub_packages"],
        isolated_git_packages = state["isolated_git_packages"],
        aliases = aliases,
        notes = notes,
        warnings = state["warnings"],
        path_packages = state["path_packages"],
        unavailable = state["unavailable"],
    )

def _path_source_conflict(state, explicit):
    """Returns the error for a name that is a path package in a shared hub and hosted, git or declared elsewhere."""
    for hub_name in sorted(state["path_packages"].keys()):
        if state["isolated_hubs"].get(hub_name):
            continue
        for name, pkg in sorted(state["path_packages"][hub_name].items()):
            here = "a path package at %s" % pkg.label
            if name in state["registry"]:
                return local_entry_conflict(name, here, "a hosted package", pkg.lock)
            if name in state["git_registry"]:
                return local_entry_conflict(name, here, "a git package", pkg.lock)
            if name in explicit:
                return local_entry_conflict(name, here, "declared with pub.package()", pkg.lock)
    return None

def _pub_collect_tags(ctx):
    """Collects package/lock tags across modules. Returns (package_tags, lock_tags, root_repos, plan_files)."""

    # Repos the root module names, mapped to whether every naming is a
    # `dev_dependency = True` usage: Bazel checks the root's `use_repo` calls
    # against that split, and fails a dev-only root that reports non-dev repos.
    root_repos = {}

    package_tags = []
    lock_fields = []
    plan_files = []
    for mod in ctx.modules:
        module_name = getattr(mod, "name", "")
        for pkg in mod.tags.package:
            package_tags.append(struct(
                name = pkg.name,
                version = pkg.version,
                sha256 = pkg.sha256,
                deps = pkg.deps,
                package_files = pkg.package_files,
                is_root = mod.is_root,
                module = module_name,
            ))
            if mod.is_root:
                root_repos[pkg.name] = root_repos.get(pkg.name, True) and ctx.is_dev_dependency(pkg)

        for lock_tag in mod.tags.from_lock:
            if mod.is_root:
                root_repos[lock_tag.name] = root_repos.get(lock_tag.name, True) and ctx.is_dev_dependency(lock_tag)
            ctx.watch(lock_tag.lock)
            if lock_tag.plan != None:
                plan_files.append(lock_tag.plan)
            lock_fields.append(dict(
                name = lock_tag.name,
                lock = lock_tag.lock,
                on_version_conflict = lock_tag.on_version_conflict,
                isolated = lock_tag.isolated,
                package_files = lock_tag.package_files,
                workspace_members = lock_tag.workspace_members,
                hook_data = lock_tag.hook_data,
                hook_network = lock_tag.hook_network,
                is_root = mod.is_root,
                module = module_name,
            ))

    # Every lock of every module in one `yaml2json` process.
    locks = yaml_to_json(ctx, [f["lock"] for f in lock_fields], [str(f["lock"]) for f in lock_fields])
    lock_tags = [
        struct(packages = lock_packages(locks[i], str(fields["lock"])), **fields)
        for i, fields in enumerate(lock_fields)
    ]
    check_workspaces(ctx, package_tags, lock_tags)
    return package_tags, lock_tags, root_repos, plan_files

def _pub_extension_metadata(ctx, root_repos, recorded):
    """Returns this evaluation's metadata: the root's direct deps plus the planning facts for the lockfile."""
    return ctx.extension_metadata(
        root_module_direct_deps = [name for name, dev in root_repos.items() if not dev],
        root_module_direct_dev_deps = [name for name, dev in root_repos.items() if dev],
        facts = recorded,
    )

def _pub_impl(ctx):
    package_tags, lock_tags, root_repos, plan_files = _pub_collect_tags(ctx)

    resolution = resolve_pub_packages(package_tags, lock_tags)
    if resolution.error:
        fail(resolution.error)

    for note in resolution.notes:
        # buildifier: disable=print
        print("NOTE: " + note)

    for warning in resolution.warnings:
        # buildifier: disable=print
        print(warning)

    # Every package's dependency names decide the dependency cycles to merge
    # and each repository's own dependency labels. They come from the
    # lockfile facts when recorded, else from a checked-in plan a module ships
    # with its lock, else from the server's listing JSON (no archive is
    # downloaded), else from the package's archive or git checkout; the
    # repositories check them against the real pubspecs.
    resolution = check_path_build_files(ctx, resolution)
    scopes = pub_scopes(resolution)
    if any([scope.hosted or scope.git for scope in scopes]):
        touch_scanner_runtime_label(ctx)
    recorded = {}
    scope_plans = plan_pub_graph(ctx, scopes, recorded, read_pub_plans(ctx, plan_files))
    instantiate_pub_repos(pub_repo_specs(resolution, scope_plans, lock_hook_settings(ctx, lock_tags, SPOKE_PREFIX)))

    # What each project of the root module's locks says about itself, for
    # the macros of `//dart:defs.bzl`. rules_dart imports it, and only a root
    # rules_dart names it.
    register_dart_projects(ctx, lock_tags)
    if Label("//:MODULE.bazel").repo_name == "":
        root_repos["dart_projects"] = False
    return _pub_extension_metadata(ctx, root_repos, recorded)

pub = module_extension(
    implementation = _pub_impl,
    tag_classes = {
        "package": _package,
        "from_lock": _from_lock,
    },
    doc = "Declares pub.dev package dependencies for download and use as dart_library targets. The root module wins over dependencies: its `pub.package()` pin, or the version its `from_lock` locks settle on, resolves when a dependency declares another version with `pub.package()`, with a NOTE naming the resolved version. A root lock's git entry pins like a hosted one.",
)
