"""Repository emission for the pub module extension.

Turns the extension's resolution and plan into one spec per repository —
which rule, which attributes — and then instantiates them. Building the
specs is pure, so a test can show what one lock change does to them.

A package repository's attributes are what that package needs: its name,
version, archive URL and hash (or git coordinates), the dependency names
planning used for it, and the labels of its own dependencies. Nothing about
the rest of the graph: a change to one lock entry changes the attributes of
that entry's repository only, plus the repositories whose own dependency
labels name it when it joins or leaves a merged cycle, and the hubs that
list it.
"""

load("//dart/pub:pub_lock_scc.bzl", "pub_lock_scc_package")
load("//dart/pub/private:build_content.bzl", "build_yaml_target")
load("//dart/pub/private:package_graph.bzl", "builder_packages", "package_graph_json")
load("//dart/pub/private:pub_hooks.bzl", "hook_repo_attrs")
load("//dart/pub/private:pub_lock_hub.bzl", "pub_lock_hub")
load("//dart/pub/private:pub_lock_package.bzl", "pub_lock_git_package", "pub_lock_package", "pub_lock_package_sha256_error")
load("//dart/pub/private:pub_repository.bzl", "pub_package")
load("//dart/pub/private:pub_scc_entries.bzl", "scc_member_entries")
load("//dart/pub/private:scc.bzl", "plan_scope_sccs", "rewrite_vanished_spoke")

visibility(["//dart/..."])

SPOKE_PREFIX = "dart_pub"

_RULES = {
    "pub_lock_git_package": pub_lock_git_package,
    "pub_lock_hub": pub_lock_hub,
    "pub_lock_package": pub_lock_package,
    "pub_lock_scc_package": pub_lock_scc_package,
    "pub_package": pub_package,
}

def pub_scopes(resolution):
    """Splits a resolution into its planning scopes.

    The shared scope holds every non-isolated lock's packages; each isolated
    hub is a scope of its own, its spokes prefixed by the hub's name.

    Args:
      resolution: The `resolve_pub_packages` result.

    Returns:
      List of `struct(prefix, hub_names, hosted, git, path, explicit_names,
      label_explicit)`, the shared scope first, then the isolated hubs in
      name order. `path` maps each `path` package of the scope's hubs to the
      label of its own target. `explicit_names` are the `pub.package()` names
      cycle planning sees; `label_explicit` are those a dependency label
      points at the explicit repository for.
    """
    explicit_names = sorted(resolution.explicit.keys())
    isolated = resolution.isolated_packages
    isolated_git = resolution.isolated_git_packages
    shared_hubs = sorted([
        hub
        for hub in resolution.hub_packages.keys()
        if hub not in isolated and hub not in isolated_git
    ])
    path_packages = getattr(resolution, "path_packages", {})
    shared_path = {}
    for hub in shared_hubs:
        for name, pkg in path_packages.get(hub, {}).items():
            shared_path.setdefault(name, pkg.label)
    scopes = [struct(
        prefix = SPOKE_PREFIX,
        hub_names = shared_hubs,
        hosted = resolution.resolved,
        git = resolution.resolved_git,
        path = shared_path,
        explicit_names = explicit_names,
        label_explicit = explicit_names,
    )]
    for hub in sorted(set(isolated.keys()) | set(isolated_git.keys())):
        hosted = isolated.get(hub, {})
        git = isolated_git.get(hub, {})
        scopes.append(struct(
            prefix = hub,
            hub_names = [hub],
            hosted = hosted,
            git = git,
            path = {name: pkg.label for name, pkg in path_packages.get(hub, {}).items()},
            explicit_names = explicit_names,
            label_explicit = [n for n in explicit_names if n not in hosted and n not in git],
        ))
    return scopes

def _merged_label(repo, member):
    return "@{repo}//:{member}".format(repo = repo, member = member)

def _scope_labels(scope, sccs):
    """Maps every package name a scope's repositories may depend on to its label."""

    # A path package (a `dependency_overrides` fork that a hosted package
    # depends on, say) is the module's own target.
    labels = dict(scope.path)
    for name in list(scope.hosted.keys()) + list(scope.git.keys()):
        labels[name] = "@{prefix}__{name}//:{name}".format(prefix = scope.prefix, name = name)
    for name in scope.label_explicit:
        labels[name] = "@{name}//:{name}".format(name = name)
    for member, repo in sccs.members.items():
        labels[member] = _merged_label(repo, member)
    return labels

def own_dep_labels(name, deps, labels):
    """The labels of one package's own dependencies.

    Args:
      name: The name of the package whose dependencies these are.
      deps: Its dependency names, as planned.
      labels: The scope's name-to-label map.

    Returns:
      The labels, in dependency-name order; names outside the scope (an SDK
      package, a dev-only name) and the package itself are dropped.
    """
    return [labels[d] for d in sorted(deps) if d in labels and d != name]

def _add(specs, name, rule, attrs):
    if name in specs:
        fail("pub: the repository \"%s\" would be generated twice (as %s and as %s); rename the hub or the `pub.package()` that collides." % (name, specs[name].rule, rule))
    specs[name] = struct(rule = rule, attrs = attrs)

def _scope_package_specs(specs, scope, plans, sccs, labels, hook_settings):
    """Adds one scope's spokes and merged repositories."""
    for name in sorted(scope.hosted.keys()):
        if name in sccs.members:
            continue
        pkg = scope.hosted[name]
        err = pub_lock_package_sha256_error(name, pkg.version, pkg.sha256)
        if err:
            fail(err)
        _add(specs, scope.prefix + "__" + name, "pub_lock_package", dict(
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            url = plans[name]["archive_url"],
            planned_deps = plans[name]["deps"],
            deps = own_dep_labels(name, plans[name]["deps"], labels),
            package_files = pkg.package_files,
            **hook_repo_attrs(hook_settings.get(name))
        ))
    for name in sorted(scope.git.keys()):
        if name in sccs.members:
            continue
        pkg = scope.git[name]
        _add(specs, scope.prefix + "__" + name, "pub_lock_git_package", dict(
            package_name = name,
            version = pkg.version,
            url = pkg.url,
            resolved_ref = pkg.resolved_ref,
            path = pkg.path,
            planned_deps = plans[name]["deps"],
            deps = own_dep_labels(name, plans[name]["deps"], labels),
            package_files = pkg.package_files,
            **hook_repo_attrs(hook_settings.get(name))
        ))
    for repo in sorted(sccs.merged.keys()):
        members = sccs.merged[repo]
        _add(specs, repo, "pub_lock_scc_package", dict(
            repo_name = repo,
            members_json = json.encode(scc_member_entries(members, scope.hosted, scope.git, plans, labels)),
        ))

def _hub_graph_attrs(names, scope, plans, sccs, explicit):
    """The package graph and `build_runner` attributes of one hub.

    Args:
      names: The hub's package names.
      scope: The planning scope the hub's packages come from.
      plans: That scope's plans, by package name.
      sccs: That scope's merged cycles.
      explicit: Names the hub aliases to `pub.package()` repositories.

    Returns:
      Dict of `pub_lock_hub` attributes.
    """
    versions = {}
    deps = {}
    labels = {}
    for name in names:
        pkg = scope.hosted.get(name) or scope.git.get(name)
        if pkg == None:
            continue
        versions[name] = pkg.version
        deps[name] = plans[name]["deps"] if name in plans else []
        if name in sccs.members:
            labels[name] = "@%s//%s:%s" % (sccs.members[name], name, build_yaml_target(name))
        elif name in explicit:
            labels[name] = "@%s//:%s" % (name, build_yaml_target(name))
        else:
            labels[name] = "@%s__%s//:%s" % (scope.prefix, name, build_yaml_target(name))
    return dict(
        package_graph = package_graph_json(versions, deps),
        build_runner_version = versions.get("build_runner", ""),
        builder_packages = builder_packages(sorted(versions.keys()), deps, labels),
    )

def _hub_specs(specs, resolution, scopes, scope_sccs, scope_plans):
    """Adds one hub per `from_lock` name."""
    by_prefix = {scope.prefix: (scope, sccs, plans) for scope, sccs, plans in zip(scopes, scope_sccs, scope_plans)}
    for hub_name in sorted(resolution.hub_packages.keys()):
        packages = resolution.hub_packages[hub_name]
        names = sorted(packages)
        isolated = hub_name in resolution.isolated_packages or hub_name in resolution.isolated_git_packages
        prefix = hub_name if isolated else SPOKE_PREFIX
        scope, sccs, plans = by_prefix[prefix]
        explicit = [] if isolated else [n for n in names if n in resolution.explicit]
        unavailable = getattr(resolution, "unavailable", {}).get(hub_name, {})
        _add(specs, hub_name, "pub_lock_hub", dict(
            hub_name = hub_name,
            spoke_prefix = prefix,
            packages = names,
            explicit_packages = explicit,
            local_targets = {
                name: pkg.label
                for name, pkg in getattr(resolution, "path_packages", {}).get(hub_name, {}).items()
                if name not in unavailable
            },
            unavailable = unavailable,
            scc_targets = {
                member: _merged_label(repo, member)
                for member, repo in sccs.members.items()
                if member in packages
            },
            **_hub_graph_attrs(names, scope, plans, sccs, explicit)
        ))

def pub_repo_specs(resolution, scope_plans, hook_settings):
    """Builds every repository the extension generates, as specs.

    Args:
      resolution: The `resolve_pub_packages` result.
      scope_plans: Per scope of `pub_scopes(resolution)`, in order, a dict of
        package name to its plan (`deps`, `sdk`, and `archive_url` for a
        hosted package).
      hook_settings: The `lock_hook_settings` result: per scope prefix and
        package name, what its build hook gets from the workspace.

    Returns:
      Dict of repository name to `struct(rule, attrs)`.
    """
    scopes = pub_scopes(resolution)
    explicit = resolution.explicit
    explicit_deps = {name: pkg.deps for name, pkg in explicit.items()}

    # Dependency cycles become one merged repository each. Merged-away
    # spokes vanish, so an explicit `pub.package()` naming one must name its
    # merged repository instead.
    scope_sccs = []
    vanished = {}
    for scope, plans in zip(scopes, scope_plans):
        names = sorted(set(scope.hosted.keys()) | set(scope.git.keys())) + scope.explicit_names
        sccs = plan_scope_sccs(
            names,
            explicit_deps,
            scope.hub_names,
            scope.prefix,
            {name: plans[name]["deps"] for name in plans.keys()},
        )
        for member, repo in sccs.members.items():
            vanished[scope.prefix + "__" + member] = repo
        scope_sccs.append(sccs)

    specs = {}
    for name in sorted(explicit.keys()):
        pkg = explicit[name]
        _add(specs, name, "pub_package", dict(
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            deps = [rewrite_vanished_spoke(dep, vanished) for dep in pkg.deps],
            package_files = pkg.package_files,
        ))

    # A dependency may import a lock-pinned package by its `pub.package()`
    # name, so that name exists as a repository aliasing the lock spoke (or
    # the merged repository holding it).
    for name in sorted(resolution.aliases.keys()):
        spoke = SPOKE_PREFIX + "__" + name
        _add(specs, name, "pub_lock_hub", dict(
            hub_name = SPOKE_PREFIX,
            spoke_prefix = SPOKE_PREFIX,
            packages = [name],
            explicit_packages = [],
            scc_targets = {name: _merged_label(vanished[spoke], name)} if spoke in vanished else {},
        ))

    for scope, plans, sccs in zip(scopes, scope_plans, scope_sccs):
        _scope_package_specs(specs, scope, plans, sccs, _scope_labels(scope, sccs), hook_settings.get(scope.prefix, {}))
    _hub_specs(specs, resolution, scopes, scope_sccs, scope_plans)
    return specs

def instantiate_pub_repos(specs):
    """Generates the repositories `pub_repo_specs` describes.

    Args:
      specs: Dict of repository name to `struct(rule, attrs)`.
    """
    for name in sorted(specs.keys()):
        spec = specs[name]
        _RULES[spec.rule](name = name, **spec.attrs)
