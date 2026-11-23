"""Cycle-breaking helpers for `flutter.pub` spokes.

A pub lock may hold two packages that depend on each other, such as `dio`
and `dio_web_adapter`. Pub resolves that lock because a conditional import
picks one side per platform, but one Bazel repository per package turns the
pair into a repository cycle. `flutter.pub(cycle_breaks = ...)` names the
spoke-to-spoke edges to leave out; these helpers hold the two checks that
keep the escape hatch honest.

The extension validates lock membership before it creates any spoke; a spoke
validates that each break names an edge its own pubspec declares. Both
helpers are pure so unit tests drive them with plain strings and lists.
"""

visibility(["//flutter/..."])

def cycle_breaks_lock_error(cycle_breaks, lock_packages, sdk_packages = ()):
    """Refuses a `cycle_breaks` key or value that names no lock package.

    Args:
        cycle_breaks: The `flutter.pub` tag's package -> dependency names
            dictionary.
        lock_packages: The package names the lock resolves.
        sdk_packages: The locked Flutter SDK package names; a key naming one
            is refused, while a dependency value may still name one.

    Returns:
        An error string naming `flutter.pub(cycle_breaks = ...)`, the key and
        the entry, or the empty string when every name is in the lock.
    """
    available = {name: True for name in lock_packages}
    sdk = {name: True for name in sdk_packages}
    for package in sorted(cycle_breaks.keys()):
        if package not in available:
            return (
                "flutter.pub(cycle_breaks = ...): key \"{package}\" is not " +
                "a package in the lock. Name a locked package, or remove " +
                "the entry."
            ).format(package = package)
        if package in sdk:
            return (
                "flutter.pub(cycle_breaks = ...): key \"{package}\" is a " +
                "Flutter SDK package; Flutter SDK packages are not " +
                "configurable through cycle_breaks. Remove the entry."
            ).format(package = package)
        for dependency in cycle_breaks[package]:
            if dependency not in available:
                return (
                    "flutter.pub(cycle_breaks = ...): \"{package}\" names " +
                    "\"{dependency}\", which is not a package in the lock. " +
                    "Name a locked package, or remove the entry."
                ).format(package = package, dependency = dependency)
    return ""

def apply_cycle_breaks(package_name, declared_dependencies, broken_dependencies):
    """Drops the named dependencies from one package's spoke edges.

    Args:
        package_name: The package whose pubspec declared the dependencies.
        declared_dependencies: The package's pubspec dependency names.
        broken_dependencies: The `cycle_breaks` value for this package: the
            dependency names whose spoke-to-spoke edge is left out.

    Returns:
        `struct(dependencies, error)`: the declared dependencies minus the
        named ones, or an empty list and an error string naming the package,
        the entry and `flutter.pub(cycle_breaks = ...)` when a break names an
        edge the pubspec does not declare.
    """
    declared = {dependency: True for dependency in declared_dependencies}
    broken = {}
    for dependency in broken_dependencies:
        if dependency not in declared:
            return struct(
                dependencies = [],
                error = (
                    "flutter.pub(cycle_breaks = ...): \"{package}\" lists " +
                    "\"{dependency}\", which its pubspec.yaml does not " +
                    "declare. Remove the entry or name a declared " +
                    "dependency."
                ).format(package = package_name, dependency = dependency),
            )
        broken[dependency] = True
    return struct(
        dependencies = sorted([
            dependency
            for dependency in declared_dependencies
            if dependency not in broken
        ]),
        error = "",
    )

def spoke_dep_labels(ctx, bazel_deps, asset_block, scc_targets = None):
    """Sibling-spoke labels for the package's own pubspec dependencies.

    If the pubspec declares `uses-material-design: true`, the spoke depends
    on `@rules_flutter//flutter:material_icons` so the bundled font travels
    through the deps graph automatically — same channel any other pub
    package's font flows through. Cross-package mismatch (app says false,
    pub dep says true) becomes structurally impossible.

    Args:
        ctx: The spoke's repository context.
        bazel_deps: The dependency names left after the cycle breaks.
        asset_block: The parsed `flutter` asset block.
        scc_targets: Optional dict mapping package name to merged SCC target
            label (`@<scc_repo>//:<pkg>`). Defaults to `ctx.attr.scc_targets`.

    Returns:
        The sibling-spoke labels for `bazel_deps`, plus the material-icons
        label when the pubspec asks for material design.
    """
    resolved_scc = scc_targets
    if resolved_scc == None:
        resolved_scc = ctx.attr.scc_targets if hasattr(ctx.attr, "scc_targets") else {}
    dep_labels = [
        resolved_scc[dep] if dep in resolved_scc else "@{hub}__{dep}//:{dep}".format(hub = ctx.attr.hub_name, dep = dep)
        for dep in bazel_deps
    ]
    if asset_block and hasattr(asset_block, "uses_material_design") and asset_block.uses_material_design:
        dep_labels = dep_labels + ["@rules_flutter//flutter:material_icons"]
    return dep_labels
