"""SCC planning and multi-package spoke creation for flutter.pub."""

load("@rules_dart//dart/ext:registry.bzl", "curated_code_assets")
load("//flutter/private:flutter_pub_overlays.bzl", "spoke_overlay_roots")
load(
    "//flutter/private:flutter_pub_scc.bzl",
    "collect_hosted_facts",
    "collect_path_deps",
    "plan_flutter_pub_sccs",
    "resolve_flutter_pub_schema",
)
load("//flutter/private:flutter_pub_scc_spoke.bzl", "flutter_pub_scc_package")
load("//flutter/private:pub_lock_sdks.bzl", "hosted_package_sha256")
load("//flutter/private:swiftpm_resolved.bzl", "pub_spoke_swiftpm_attrs")

visibility(["//flutter/..."])

_INTERNAL_HUB_NAMES = {
    "dev_tool_deps": True,
    "gen_l10n_deps": True,
}

_RULES_FLUTTER_REPO = Label("//:MODULE.bazel").repo_name

def _is_internal_hub(hub_name, pub_tag):
    """Checks whether a hub is an internal rules_flutter hub.

    Args:
        hub_name: The hub repository name string.
        pub_tag: The `flutter.pub` tag struct.

    Returns:
        True if the hub is an internal rules_flutter hub, False otherwise.
    """
    if hub_name not in _INTERNAL_HUB_NAMES:
        return False
    lock = getattr(pub_tag, "lock", None)
    if lock == None:
        return False
    return getattr(lock, "repo_name", None) == _RULES_FLUTTER_REPO

def plan_hub_sccs(module_ctx, hub_name, hosted, path_pkgs, all_package_names, pub_tag, facts_state):
    """Collects hosted/path pubspec deps (caching hosted in facts) and plans SCCs.

    Args:
        module_ctx: The module extension context.
        hub_name: The hub repository name.
        hosted: Dict of hosted package info from the lock.
        path_pkgs: Dict of path package info from the lock.
        all_package_names: List of all package names in the lock.
        pub_tag: The `flutter.pub` tag.
        facts_state: Struct with `facts` dict and `recorded` list.

    Returns:
        The SCC plan struct from `plan_flutter_pub_sccs`.
    """
    if _is_internal_hub(hub_name, pub_tag):
        return struct(
            hub_name = hub_name,
            all_package_names = all_package_names,
            singletons = sorted(all_package_names),
            merged = {},
            sccs = [],
            scc_targets = {},
            planned_deps = {},
        )
    package_deps = {}
    if len(hosted) + len(path_pkgs) >= 2 or bool(pub_tag.cycle_breaks):
        if hosted:
            schema = resolve_flutter_pub_schema(module_ctx)
            hosted_deps = collect_hosted_facts(
                module_ctx,
                hub_name,
                hosted,
                pub_tag.lock,
                schema,
                facts_state.facts,
            )
            facts_state.recorded.append(True)
            for pkg_name, deps in hosted_deps.items():
                package_deps[pkg_name] = deps
        if path_pkgs:
            path_deps = collect_path_deps(module_ctx, hub_name, path_pkgs, pub_tag.lock)
            for pkg_name, deps in path_deps.items():
                package_deps[pkg_name] = deps
    return plan_flutter_pub_sccs(
        all_package_names,
        hub_name,
        package_deps,
        pub_tag.cycle_breaks,
    )

def scc_member_spec(member, hosted, path_pkgs, planned_deps, pub_lock):
    """Builds the serialisable dict describing one SCC member for `flutter_pub_scc_package`.

    Args:
        member: The package name of the member.
        hosted: Dict of hosted packages.
        path_pkgs: Dict of path packages.
        planned_deps: Dict mapping package name to planned dependency list.
        pub_lock: The lockfile label.

    Returns:
        A dict describing the member.
    """
    if member in hosted:
        info = hosted[member]
        desc = info.get("description", {})
        base_url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev"
        version = info.get("version", "")
        return {
            "name": member,
            "source": "hosted",
            "version": version,
            "sha256": hosted_package_sha256(member, info, pub_lock),
            "url": base_url,
            "planned_deps": planned_deps.get(member, []),
            "code_assets": curated_code_assets(member, version),
        }
    path_info = path_pkgs[member]
    return {
        "name": member,
        "source": "path",
        "path": path_info.path,
        "version": path_info.version,
        "planned_deps": planned_deps.get(member, []),
        "code_assets": curated_code_assets(member, path_info.version),
    }

def create_scc_spokes(plan, hosted, path_pkgs, user_overlay_roots, pub_tag):
    """Creates one `flutter_pub_scc_package` repository per multi-package SCC.

    Args:
        plan: The SCC plan struct.
        hosted: Dict of hosted packages.
        path_pkgs: Dict of path packages.
        user_overlay_roots: Candidate overlay roots.
        pub_tag: The `flutter.pub` tag.
    """
    if not plan.merged:
        return
    overlay_roots = spoke_overlay_roots(user_overlay_roots)
    swiftpm_attrs = pub_spoke_swiftpm_attrs(pub_tag, include_ios_native_deps = True)
    for repo_name in sorted(plan.merged.keys()):
        members = plan.merged[repo_name]
        member_set = {m: True for m in members}
        member_specs = [
            scc_member_spec(m, hosted, path_pkgs, plan.planned_deps, pub_tag.lock)
            for m in members
        ]
        flutter_pub_scc_package(
            name = repo_name,
            repo_name = repo_name,
            hub_name = plan.hub_name,
            members_json = json.encode(member_specs),
            lock_packages = plan.all_package_names,
            scc_targets = plan.scc_targets,
            cycle_breaks = {m: pub_tag.cycle_breaks[m] for m in members if m in pub_tag.cycle_breaks},
            ios_plugin_defines = {m: pub_tag.ios_plugin_defines[m] for m in members if m in pub_tag.ios_plugin_defines},
            ios_plugin_deps = {
                m: str(pub_tag.ios_plugin_deps[m])
                for m in sorted(pub_tag.ios_plugin_deps)
                if m in member_set
            },
            overlay_roots = overlay_roots,
            ignore_hooks = sorted([m for m in pub_tag.ignore_hooks if m in member_set]),
            package_resolved = swiftpm_attrs.package_resolved,
            package_sha256 = swiftpm_attrs.package_sha256,
            ios_native_deps = swiftpm_attrs.ios_native_deps,
            podfile_lock = swiftpm_attrs.podfile_lock,
            pubspec_lock = pub_tag.lock,
        )
