"""Repository emission for the pub module extension.

Creates the spoke, merged and hub repositories that `extensions.bzl`
resolves. The cycle planning stays in the extension; this module only turns
its result into repository rules.
"""

load("//dart/ext:registry.bzl", "curated_code_assets")
load("//dart/pub:pub_lock_hub.bzl", "pub_lock_hub")
load("//dart/pub:pub_lock_package.bzl", "pub_lock_git_package", "pub_lock_package", "pub_lock_package_sha256_error")
load("//dart/pub/private:pub_repository.bzl", "pub_package")
load("//dart/pub/private:scc.bzl", "rewrite_vanished_spoke")

SPOKE_PREFIX = "dart_pub"

def pub_emit_explicit(explicit, vanished_spokes):
    """Creates the explicit `pub.package()` repositories."""
    for name, pkg in explicit.items():
        pub_package(
            name = name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            deps = [rewrite_vanished_spoke(dep, vanished_spokes) for dep in pkg.deps],
        )

def pub_emit_aliased(aliases, vanished_spokes):
    """Creates one alias repository per lock-pinned `pub.package()` name.

    A dependency may import the package by its `pub.package()` name even
    when a root lock pin resolves it, so the name must exist as a
    repository. The lock spoke stays the single materialization: the alias
    names its spoke, or the merged repository holding the whole cycle when
    the spoke merged away.

    Args:
      aliases: The alias names mapped to their pinned records.
      vanished_spokes: The spoke labels that merged into a repository.
    """
    for name in sorted(aliases.keys()):
        spoke = SPOKE_PREFIX + "__" + name
        scc_targets = {}
        if spoke in vanished_spokes:
            repo = vanished_spokes[spoke]
            scc_targets = {name: "@{repo}//:{member}".format(repo = repo, member = name)}
        pub_lock_hub(
            name = name,
            hub_name = SPOKE_PREFIX,
            spoke_prefix = SPOKE_PREFIX,
            packages = [name],
            explicit_packages = [],
            scc_targets = scc_targets,
        )

def pub_emit_shared_spokes(
        resolved,
        shared_sccs,
        all_package_names,
        explicit_package_names,
        ignore_hooks,
        shared_scc_targets):
    """Creates shared hosted spoke repos. Cycle members get no spoke of their own: the merged repository holds the whole cycle.

    Args:
      resolved: The resolved hosted packages by name.
      shared_sccs: The shared scope's cycle plan.
      all_package_names: Every package name the hub aliases.
      explicit_package_names: The names `pub.package()` declares explicitly.
      ignore_hooks: The package names whose hooks are ignored.
      shared_scc_targets: The merged labels shared cycles point at.
    """
    for name, pkg in resolved.items():
        if name in shared_sccs.members:
            continue
        err = pub_lock_package_sha256_error(name, pkg.version, pkg.sha256)
        if err:
            fail(err)
        pub_lock_package(
            name = SPOKE_PREFIX + "__" + name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            base_url = pkg.url,
            hub_name = SPOKE_PREFIX,
            lock_packages = all_package_names,
            # A spoke whose pubspec depends on an explicit package depends on
            # that package's repo, which is what every hub aliases it to.
            explicit_packages = explicit_package_names,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
            scc_targets = shared_scc_targets,
            planned_deps = shared_sccs.package_deps.get(name, []),
            plan_covers_package = name in shared_sccs.package_deps,
        )

def pub_emit_shared_git(
        resolved_git,
        shared_sccs,
        all_package_names,
        explicit_package_names,
        ignore_hooks,
        shared_scc_targets):
    """Creates shared git spoke repos.

    Args:
      resolved_git: The resolved git packages by name.
      shared_sccs: The shared scope's cycle plan.
      all_package_names: Every package name the hub aliases.
      explicit_package_names: The names `pub.package()` declares explicitly.
      ignore_hooks: The package names whose hooks are ignored.
      shared_scc_targets: The merged labels shared cycles point at.
    """
    for name, pkg in resolved_git.items():
        if name in shared_sccs.members:
            continue
        pub_lock_git_package(
            name = SPOKE_PREFIX + "__" + name,
            package_name = name,
            version = pkg.version,
            url = pkg.url,
            resolved_ref = pkg.resolved_ref,
            path = pkg.path,
            hub_name = SPOKE_PREFIX,
            lock_packages = all_package_names,
            explicit_packages = explicit_package_names,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
            scc_targets = shared_scc_targets,
            planned_deps = shared_sccs.package_deps.get(name, []),
            plan_covers_package = name in shared_sccs.package_deps,
        )

def pub_emit_isolated_spokes(
        hub_name,
        hosted,
        hub_sccs,
        package_names,
        hub_explicit,
        hub_scc_targets,
        ignore_hooks):
    """Creates one isolated hub's hosted spoke repos.

    Args:
      hub_name: The isolated hub's name.
      hosted: The hub's hosted packages by name.
      hub_sccs: The hub's cycle plan.
      package_names: Every package name the hub holds.
      hub_explicit: The names `pub.package()` declares explicitly.
      hub_scc_targets: The merged labels the hub's cycles point at.
      ignore_hooks: The package names whose hooks are ignored.
    """
    for pkg_name, pkg in hosted.items():
        if pkg_name in hub_sccs.members:
            continue
        err = pub_lock_package_sha256_error(pkg_name, pkg.version, pkg.sha256)
        if err:
            fail(err)
        pub_lock_package(
            name = hub_name + "__" + pkg_name,
            package_name = pkg_name,
            version = pkg.version,
            sha256 = pkg.sha256,
            base_url = pkg.url,
            hub_name = hub_name,
            lock_packages = package_names,
            explicit_packages = hub_explicit,
            code_assets = curated_code_assets(pkg_name, pkg.version),
            ignore_hook = pkg_name in ignore_hooks,
            scc_targets = hub_scc_targets,
            planned_deps = hub_sccs.package_deps.get(pkg_name, []),
            plan_covers_package = pkg_name in hub_sccs.package_deps,
        )

def pub_emit_isolated_git(
        hub_name,
        git_pkgs,
        hub_sccs,
        package_names,
        hub_explicit,
        hub_scc_targets,
        ignore_hooks):
    """Creates one isolated hub's git spoke repos.

    Args:
      hub_name: The isolated hub's name.
      git_pkgs: The hub's git packages by name.
      hub_sccs: The hub's cycle plan.
      package_names: Every package name the hub holds.
      hub_explicit: The names `pub.package()` declares explicitly.
      hub_scc_targets: The merged labels the hub's cycles point at.
      ignore_hooks: The package names whose hooks are ignored.
    """
    for pkg_name, pkg in git_pkgs.items():
        if pkg_name in hub_sccs.members:
            continue
        pub_lock_git_package(
            name = hub_name + "__" + pkg_name,
            package_name = pkg_name,
            version = pkg.version,
            url = pkg.url,
            resolved_ref = pkg.resolved_ref,
            path = pkg.path,
            hub_name = hub_name,
            lock_packages = package_names,
            explicit_packages = hub_explicit,
            code_assets = curated_code_assets(pkg_name, pkg.version),
            ignore_hook = pkg_name in ignore_hooks,
            scc_targets = hub_scc_targets,
            planned_deps = hub_sccs.package_deps.get(pkg_name, []),
            plan_covers_package = pkg_name in hub_sccs.package_deps,
        )

def pub_emit_hubs(hub_packages, isolated_hub_names, isolated_sccs, shared_sccs, explicit):
    """Creates the per-from_lock hub repos.

    Args:
      hub_packages: Each hub's package names.
      isolated_hub_names: The hubs that resolve their own versions.
      isolated_sccs: Each isolated hub's cycle plan.
      shared_sccs: The shared scope's cycle plan.
      explicit: The names `pub.package()` declares explicitly.
    """
    for hub_name, packages in hub_packages.items():
        package_names = sorted(packages)
        isolated = hub_name in isolated_hub_names
        if isolated:
            spoke_prefix = hub_name
            hub_explicit = []
            hub_scc_targets = {
                member: "@{repo}//:{member}".format(repo = repo, member = member)
                for member, repo in isolated_sccs[hub_name].members.items()
                if member in packages
            }
        else:
            spoke_prefix = SPOKE_PREFIX
            hub_explicit = [n for n in package_names if n in explicit]
            hub_scc_targets = {
                member: "@{repo}//:{member}".format(repo = repo, member = member)
                for member, repo in shared_sccs.members.items()
                if member in packages
            }
        pub_lock_hub(
            name = hub_name,
            hub_name = hub_name,
            spoke_prefix = spoke_prefix,
            packages = package_names,
            explicit_packages = hub_explicit,
            scc_targets = hub_scc_targets,
        )
