"""Per-hub plugin overlay root selection (root-wins).

A hub declared by module M resolves its spokes' `BUILD.bazel.tpl`
overlays against the root module's `flutter.plugin_overlays(roots = ...)`
first, then M's own roots (when M is not the root), then the bundled
`@rules_flutter//ext` root. A module's overlays never reach a hub another
non-root module declared, and never the root's hubs. Order inside one
module stays tag order.

Why root-wins: the extension used to hand every module's roots to every
hub, so any module in the dependency graph could replace the BUILD file
of any pub package in the root's hubs (one it does not override itself),
and the root could not tell. The Flutter version choice is already
root-wins; overlays were the remaining gap. A hub consults its root
list in order and the first root holding a template for the package wins,
so listing the root's roots first is what makes the root's overlay win.
"""

visibility(["//flutter/..."])

def hub_overlay_roots(root_roots, owner_roots, owner_is_root):
    """Overlay roots for one hub, with the root module's roots first.

    Pure selection core: the extension collects each module's roots in tag
    order and calls this per hub, so unit tests can pin the per-hub list
    for a root hub, a dependency's hub, and both modules overlaying the
    same package.

    Args:
        root_roots: Overlay roots declared by the root module, in tag order.
        owner_roots: Overlay roots declared by the hub's own module, in tag
            order.
        owner_is_root: Whether the hub's module is the root module.

    Returns:
        The root module's roots first, then the owner's own roots when the
        owner is not the root. The caller appends the bundled
        `@rules_flutter//ext` root last.
    """
    if owner_is_root:
        return list(root_roots)
    return list(root_roots) + list(owner_roots)

_BUNDLED_OVERLAY_ROOT = "@rules_flutter//ext:BUILD.bazel"

def spoke_overlay_roots(user_overlay_roots):
    """The full overlay root list a spoke resolves, bundled root included.

    Args:
        user_overlay_roots: Roots from `flutter.plugin_overlays`, in order.

    Returns:
        The user roots followed by the bundled `@rules_flutter//ext` root.
    """
    return user_overlay_roots + [_BUNDLED_OVERLAY_ROOT]

def _overlay_root_label(overlay_label):
    """Resolve an overlay root to a label `module_ctx.path` can read.

    Args:
        overlay_label: A `Label` from a tag, or the bundled root string.

    Returns:
        A `Label` naming the overlay root's anchor file.
    """
    if type(overlay_label) == "string":
        if overlay_label != _BUNDLED_OVERLAY_ROOT:
            fail("flutter.pub: unexpected overlay root string " + repr(overlay_label))
        return Label("//ext:BUILD.bazel")
    return overlay_label

def _overlay_version_candidates(version):
    """Directory candidates inside an overlay root for a package version.

    Args:
        version: The locked package version string.

    Returns:
        `<major>.<minor>.<patch>`, `<major>.<minor>`, `<major>` and the bare
        package directory, in that order.
    """
    parts = version.split(".")
    candidates = []
    if len(parts) >= 3:
        candidates.append("{}.{}.{}".format(parts[0], parts[1], parts[2]))
    if len(parts) >= 2:
        candidates.append("{}.{}".format(parts[0], parts[1]))
    if len(parts) >= 1 and parts[0]:
        candidates.append(parts[0])
    candidates.append("")
    return candidates

def _overlay_template_path(module_ctx, overlay_label, package_name, version, relpath):
    """The first overlay template path for one package and version, or None.

    Args:
        module_ctx: The module extension context.
        overlay_label: One overlay root label.
        package_name: The pub package the overlay belongs to.
        version: The locked package version string.
        relpath: The template path inside the package, e.g. `BUILD.bazel.tpl`.

    Returns:
        The template's `Path`, or None when no candidate exists.
    """
    anchor = module_ctx.path(_overlay_root_label(overlay_label))
    pkg_dir = anchor.dirname.get_child(package_name)
    for candidate in _overlay_version_candidates(version):
        tpl = pkg_dir.get_child(candidate) if candidate else pkg_dir
        for part in relpath.split("/"):
            tpl = tpl.get_child(part)
        if tpl.exists:
            return tpl
    return None

def overlay_replaces_spoke(module_ctx, overlay_roots, package_name, version):
    """Whether an overlay supplies the package's top-level BUILD template.

    Args:
        module_ctx: The module extension context.
        overlay_roots: Candidate overlay root labels, in precedence order.
        package_name: The pub package the overlay belongs to.
        version: The locked package version string.

    Returns:
        True when an overlay template exists for this package and version.
    """
    for root in overlay_roots:
        if _overlay_template_path(module_ctx, root, package_name, version, "BUILD.bazel.tpl") != None:
            return True
    return False
