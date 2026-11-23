"""File-by-file mirroring for `path:` dependency spokes.

`link_path_package` (in `flutter_pub_package.bzl`) brings a
workspace-local package into its spoke. Real directories mirror file by
file into real repository directories, so the generator's `ctx.file`
writes land in the spoke, never in the user's tree through a symlinked
directory. A source symlink is never replicated as a directory: a link
to a directory resolves to its target, which is confined to the
workspace's real root, checked for cycles, and mirrored the same way.
Every link at any depth, file or directory, goes through the same
refusals, so a nested link can never smuggle outside bytes into the
spoke, and every mirrored file and directory is watched, so adding or
removing an entry refetches the spoke.

Skip rule: directory names in `_PATH_SPOKE_SKIP_DIRS` (build output,
tool state, the example app, dot-directories) are skipped at the
package root (the shader-sibling walk) and at the top level of each
mirrored platform or shader directory tree — never inside `lib/` or
inside a declared asset directory, whose trees mirror whole the way
`flutter_tools` reads them. Names directly under `lib/` such as
`lib/build/a.dart`, and names directly under a declared asset
directory, link normally, as do deeper names everywhere (plugin Kotlin
under `android/src/main/kotlin/com/example/`, files under
`lib/src/build/` or `lib/src/example/`), and dot-files inside declared
asset directories are kept. User `BUILD`
files are watched but never linked, at any depth, so a nested BUILD
file can never cut the spoke's globs into a second Bazel package.

Case rule: every path comparison here folds case exactly when the fetch
host proves case-insensitive (see `detect_case_insensitive_host`). On a
case-sensitive host comparisons stay exact, so two distinct entries that
differ only by case are never merged; on a case-insensitive host a
case-only difference can neither hide an escape nor loop the walk.
"""

load(":flutter_pub_assets.bzl", "is_asset_variant_dir")
load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "scoped_tree_bound_error")

visibility(["//flutter/..."])

# Top-level names a path-spoke link walk never descends into: build output,
# pub's own tool state, the example app (whose `flutter pub get` leaves a
# `.plugin_symlinks` cycle back to the package root next to its own `build/`
# output), and dot-directories. The generator reads nothing under them, so
# linking or watching them only makes the fetch machine-dependent. Applies
# at the package root and at the top level of mirrored platform/shader
# trees only — never inside `lib/` or a declared asset directory (see the
# module docstring).
_PATH_SPOKE_SKIP_DIRS = ("build", ".dart_tool", "example")

# File names a path spoke never links: the spoke generates every BUILD file
# it needs, so the package's own stay untouched and are not used. Skipping
# them keeps a nested BUILD file from cutting the spoke's `lib/**` globs
# into a second Bazel package.
_PATH_SPOKE_SKIP_FILES = ("BUILD", "BUILD.bazel")

def fold_path_case(text, case_insensitive):
    """Fold `text` for path comparison on this fetch host.

    Args:
        text: The path string to fold.
        case_insensitive: True when the host proves case-insensitive
            (see `detect_case_insensitive_host`).

    Returns:
        The lowercased text when `case_insensitive`, else `text`
        unchanged, so case-sensitive hosts compare exactly.
    """
    return text.lower() if case_insensitive else text

def paths_match(first, second, case_insensitive):
    """Whether two paths name the same file under this host's case rule.

    Args:
        first: One path string.
        second: The other path string.
        case_insensitive: True when the host proves case-insensitive.

    Returns:
        True on an exact match, or on a case-only match when the host
        folds case. Never merges two case-distinct entries on a
        case-sensitive host.
    """
    if first == second:
        return True
    return case_insensitive and first.lower() == second.lower()

def detect_case_insensitive_host(ctx, segments):
    """Probe whether the fetch host resolves paths case-insensitively.

    Takes the deepest package path segment holding a cased letter and
    looks it up with its case flipped under its real parent, then checks
    that parent's `readdir()`: on a case-insensitive host (APFS, NTFS
    default) the flipped spelling resolves even though no entry holds
    that exact name — evidence a case-sensitive host cannot produce. A
    case-sensitive host holding both case variants either does not
    resolve the flipped spelling at all or lists it exactly, so the probe
    answers False and comparisons stay exact. Only the changed segment is
    tested, so a lowercase package under a mixed-case parent still proves
    a folding host. All path comparisons for the fetch then fold case
    exactly when this returns True.

    Args:
        ctx: The path-package spoke's repository context.
        segments: The workspace-relative package path segments, which
            exist (the caller checks first).

    Returns:
        True when the flipped spelling of the deepest cased segment
        resolves without an exactly-named entry, i.e. the host folds
        case; False when no segment holds a cased letter.
    """
    for i in range(len(segments) - 1, -1, -1):
        seg = segments[i]
        if seg.lower() != seg:
            flipped_seg = seg.lower()
        elif seg.upper() != seg:
            flipped_seg = seg.upper()
        else:
            continue
        if not ctx.workspace_root.get_child(*(segments[:i] + [flipped_seg])).exists:
            return False
        if i > 0:
            parent = ctx.workspace_root.get_child(*segments[:i])
        else:
            parent = ctx.workspace_root
        for child in parent.readdir():
            if child.basename == flipped_seg:
                return False
        return True
    return False

def is_path_spoke_skipped_dir(name, case_insensitive = False):
    """Whether a path-spoke link walk skips this top-level entry.

    Anything under `build/`, `.dart_tool/`, `example/`, or a dot-directory
    is build output or tool state the generator never reads. Applies at the
    package root and at the top of mirrored platform/shader trees only —
    never inside `lib/` or a declared asset directory; deeper names link
    normally.

    Args:
        name: A single directory basename (no slashes).
        case_insensitive: True when the host proves case-insensitive, in
            which case a case-only variant (e.g. `Build/`) skips too.

    Returns:
        True when the entry is skipped at a mirrored tree's top level.
    """
    if name in _PATH_SPOKE_SKIP_DIRS or name.startswith("."):
        return True
    return case_insensitive and name.lower() in _PATH_SPOKE_SKIP_DIRS

def path_spoke_is_ancestor_cycle(package_realpath, target_realpath, case_insensitive = False):
    """Whether a link target is the package itself or one of its ancestors.

    Pure testable core of the ancestor-link refusal: a source symlink
    resolving here would cycle any fetch-time walk (the `.plugin_symlinks`
    shape `flutter pub get` leaves behind).

    Args:
        package_realpath: The linked package root's resolved path.
        target_realpath: The link's resolved path.
        case_insensitive: True when the host proves case-insensitive, in
            which case a case-only spelling still counts as the same path.

    Returns:
        True when the target is the package or an ancestor of it.
    """
    package = fold_path_case(package_realpath, case_insensitive)
    target = fold_path_case(target_realpath, case_insensitive)
    return (
        target == package or
        target == "/" or
        package.startswith(target + "/")
    )

def ancestor_link_refusal(package_name, link_rel, link_real):
    """The fetch refusal for a link escaping to the package or an ancestor.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and the link.

    Args:
        package_name: The path-dependency package whose tree is being mirrored.
        link_rel: The package-relative path of the offending symlink.
        link_real: The resolved real path the symlink points to.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub repo rule: path dependency \"" + package_name + "\" " +
        "links \"" + link_rel + "\" which resolves to the package itself " +
        "or one of its ancestors (" + link_real + "); linking it would " +
        "cycle fetch-time walks. Point the path entry at the package " +
        "directory itself."
    )

def path_spoke_resolves_outside(workspace_realpath, target_realpath, case_insensitive = False):
    """Whether a resolved path lies outside the main workspace's real root.

    Pure testable core of the workspace-confinement refusal: every source
    symlink the spoke replicates, and every directory component of the
    package path itself, must resolve inside the workspace. A link such
    as `assets -> /host/dir` would otherwise bundle host bytes, and a
    package below a link out of the workspace (`third_party -> /host`)
    would be accepted — while the rule claims workspace-relative-only,
    fail-closed fetching.

    Args:
        workspace_realpath: The resolved main workspace root.
        target_realpath: The resolved path to check.
        case_insensitive: True when the host proves case-insensitive, in
            which case a case-only spelling still counts as inside.

    Returns:
        True when the target is neither the workspace root nor under it.
    """
    workspace = fold_path_case(workspace_realpath, case_insensitive)
    target = fold_path_case(target_realpath, case_insensitive)
    return (
        target != workspace and
        not target.startswith(workspace + "/")
    )

def outside_workspace_refusal(package_name, link_rel, link_real):
    """The fetch refusal for a node resolving outside the workspace.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package, the offending path, and
    its real path, so the fix (move the package or the link target inside
    the workspace) is evident.

    Args:
        package_name: The path-dependency package whose tree is being mirrored.
        link_rel: The package-relative path of the offending symlink.
        link_real: The resolved real path the symlink points to.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub repo rule: path dependency \"" + package_name + "\" " +
        "links \"" + link_rel + "\" which resolves outside the workspace " +
        "(" + link_real + "); linking it would bundle host bytes into a " +
        "hermetic fetch. Keep the package and everything it links inside " +
        "the workspace."
    )

def link_target_is_cycle(seen_keys, target_realpath, case_insensitive):
    """Whether mirroring `target_realpath` would re-enter a directory above it.

    Pure testable core of the symlink-cycle refusal: the walk carries the
    folded real paths of the directories on its current descent stack, and
    a link resolving to any of them would loop the mirror forever.

    Args:
        seen_keys: The folded real paths on the current descent stack.
        target_realpath: The link's resolved path.
        case_insensitive: True when the host proves case-insensitive.

    Returns:
        True when the target is already on the stack.
    """
    return fold_path_case(target_realpath, case_insensitive) in seen_keys

def cycle_refusal(package_name, link_rel, link_real):
    """The fetch refusal for a symlink cycle inside a path package.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and the link, and says it
    is a cycle.

    Args:
        package_name: The path-dependency package whose tree is being mirrored.
        link_rel: The package-relative path of the offending symlink.
        link_real: The resolved real path the symlink points to.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub repo rule: path dependency \"" + package_name + "\" " +
        "links \"" + link_rel + "\" which resolves to (" + link_real + ") " +
        "a directory already mirrored above it; following it would cycle " +
        "fetch-time walks. Remove the symlink cycle so the package tree " +
        "is finite."
    )

def make_link_scope(package_name, package_realpath, workspace_realpath, case_insensitive, linked, dest_prefix = ""):
    """Bundle the values every path-spoke link step reads.

    Args:
        package_name: The pub package linked, for refusals.
        package_realpath: The resolved package directory, for cycle checks.
        workspace_realpath: The resolved workspace root, for confinement.
        case_insensitive: True when the host proves case-insensitive.
        linked: Dict of already-linked spoke paths, updated in place.
        dest_prefix: Optional repository subdirectory prefix (e.g. `<member>`).

    Returns:
        A struct carrying the link-scope values together.
    """
    return struct(
        package_name = package_name,
        package_realpath = package_realpath,
        workspace_realpath = workspace_realpath,
        case_insensitive = case_insensitive,
        linked = linked,
        dest_prefix = dest_prefix,
    )

def _scope_dest_prefix(scope):
    """Returns `scope.dest_prefix` when present, or `""`."""
    if hasattr(scope, "dest_prefix") and scope.dest_prefix:
        return scope.dest_prefix
    return ""

def _spoke_entry_parts(package_name, entry_path):
    """Split a declared package entry into segments, failing closed.

    Absolute paths, entries escaping above the package root through `..`,
    and empty entries fail naming the package and the entry; `.` segments
    and duplicate slashes normalize away.
    """
    if entry_path == "" or entry_path.startswith("/"):
        fail("flutter.pub repo rule: path dependency \"" + package_name +
             "\" declares entry \"" + entry_path +
             "\" which is not inside the package.")
    parts = []
    for part in entry_path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                fail("flutter.pub repo rule: path dependency \"" +
                     package_name + "\" declares entry \"" + entry_path +
                     "\" which escapes the package.")
            parts.pop()
            continue
        parts.append(part)
    if not parts:
        fail("flutter.pub repo rule: path dependency \"" + package_name +
             "\" declares entry \"" + entry_path +
             "\" which names no file or directory.")
    return parts

def _link_new_symlink(ctx, node, repo_rel, linked, dest_prefix = ""):
    """Symlink one file unless an earlier entry already linked it.

    Overlapping declarations (a shader inside a declared asset dir, a file
    inside its own declared dir) reach the same spoke path twice; the
    second link would fail with "File exists". The first link already
    watches the source, so skipping repeats loses nothing. Directories
    never reach here: they mirror file by file, and a directory passed in
    fails the fetch rather than becoming one directory symlink (whose
    writes would land in the user's tree).
    """
    target = (dest_prefix + "/" + repo_rel) if dest_prefix else repo_rel
    if target in linked:
        return
    if node.is_dir:
        fail("flutter.pub repo rule: refusing to symlink directory \"" +
             target + "\"; directories mirror file by file so generated " +
             "files land in the spoke, never in the user's source tree.")
    ctx.symlink(node, target)
    ctx.watch(node)
    linked[target] = True

def _workspace_target_node(ctx, scope, target_realpath, link_rel):
    """Resolve a confined link target back to a workspace-side node.

    The target is known inside the workspace (the caller refused anything
    outside first); stripping the workspace prefix re-enters through
    `ctx.workspace_root`, so the mirror watches workspace-side nodes
    whose entries Bazel tracks.

    Args:
        ctx: The path-package spoke's repository context.
        scope: The fetch's link scope.
        target_realpath: The link's resolved path, inside the workspace.
        link_rel: The spoke-relative link, for the fail-closed refusal.

    Returns:
        The workspace-side directory node for the target.
    """
    folded_target = fold_path_case(target_realpath, scope.case_insensitive)
    folded_root = fold_path_case(scope.workspace_realpath, scope.case_insensitive)
    if not folded_target.startswith(folded_root + "/"):
        fail(outside_workspace_refusal(scope.package_name, link_rel, target_realpath))
    return ctx.workspace_root.get_child(*target_realpath[len(scope.workspace_realpath) + 1:].split("/"))

def _mirror_link_child(ctx, child, child_rel, child_real, scope, seen, tree_root, stack):
    """Mirror one symlinked child: replicate files, mirror directories.

    Refuses package-ancestor cycles and targets outside the workspace
    naming the package and the link. A link to a directory resolves to
    its target and joins the walk (confined, cycle-checked, watched entry
    by entry), so adding or removing an entry under it refetches the
    spoke; anything else replicates as one watched file symlink without
    descending, so the walk always terminates. User BUILD files are
    watched but never linked.

    Args:
        ctx: The path-package spoke's repository context.
        child: The workspace-side symlink node.
        child_rel: The spoke-relative path the child mirrors to.
        child_real: The link's resolved path.
        scope: The fetch's link scope.
        seen: The folded real paths on the current descent stack.
        tree_root: The mirrored tree's root: a `struct(root, apply_skip)`
            holding the spoke-relative root of the mirrored tree the
            child belongs to and whether that tree consults the skip
            list. A directory target starts its own tree here when the
            link is a declared entry, and deeper links inherit it so
            only the target's immediate children consult the skip list,
            and only when the tree applies skips (`lib/` and declared
            asset directory trees never do).
        stack: The walk stack, extended in place for directory targets.

    Returns:
        "" normally, or the cycle refusal naming the link; the caller
        fails the fetch with it.
    """
    if path_spoke_is_ancestor_cycle(scope.package_realpath, child_real, scope.case_insensitive):
        fail(ancestor_link_refusal(scope.package_name, child_rel, child_real))
    if path_spoke_resolves_outside(scope.workspace_realpath, child_real, scope.case_insensitive):
        fail(outside_workspace_refusal(scope.package_name, child_rel, child_real))
    if not child.is_dir:
        if child.basename in _PATH_SPOKE_SKIP_FILES:
            ctx.watch(child)
            return ""
        _link_new_symlink(ctx, child, child_rel, scope.linked, _scope_dest_prefix(scope))
        return ""
    if link_target_is_cycle(seen, child_real, scope.case_insensitive):
        return cycle_refusal(scope.package_name, child_rel, child_real)
    target = _workspace_target_node(ctx, scope, child_real, child_rel)
    ctx.watch(child)
    ctx.watch(target)
    stack.append((target, child_rel, seen + (fold_path_case(child_real, scope.case_insensitive),), tree_root))
    return ""

def _tree_skips_child(tree_root, parent_rel, name, case_insensitive):
    """Whether this mirrored tree skips directory `name` under `parent_rel`.

    Only a skipping tree's own top level consults the skip list: `lib/`
    and declared asset directory trees (whose root carries
    `apply_skip = False`) mirror whole, and deeper names link normally
    everywhere. A plain string root (from older callers such as
    `link_scoped_tree_bounded`) applies skips, preserving the old rule.

    Args:
        tree_root: The mirrored tree's `struct(root, apply_skip)`, or a
            plain spoke-relative root string, which applies skips.
        parent_rel: The spoke-relative path of the directory holding
            `name`.
        name: A single directory basename (no slashes).
        case_insensitive: True when the host proves case-insensitive,
            in which case a case-only skip variant skips too.

    Returns:
        True when the walk skips this directory here.
    """
    root_rel = tree_root.root if type(tree_root) == "struct" else tree_root
    if parent_rel != root_rel:
        return False
    if type(tree_root) == "struct" and not tree_root.apply_skip:
        return False
    return is_path_spoke_skipped_dir(name, case_insensitive)

def mirror_tree_bounded(ctx, stack, scope, bound):
    """Mirror one source directory into the spoke, reporting problems.

    Pure traversal core of `_link_scoped_tree` (the `ctx.symlink` /
    `ctx.watch` calls are the only effects): unit tests drive it with a
    small bound and fake directory listings. Real directories become real
    repository directories holding one file symlink per file; source
    symlinks replicate (files) or resolve and join the walk
    (directories); skipped top-level subtrees stay unlinked and unwatched
    so machine-local output cannot affect the fetch (only trees that
    apply skips consult the list — `lib/` and declared asset directory
    trees mirror whole); user BUILD files are
    watched but not linked. The explicit stack over a bounded loop keeps
    one pathological package from hanging the fetch.

    Each stack frame carries its mirrored tree's root as a
    `struct(root, apply_skip)`: a directory link that is a declared
    entry starts its own tree at the link, so its immediate children
    consult the skip list exactly like a real directory's do when the
    tree applies skips; links met deeper inherit the root, so deeper
    names link normally. A plain string root (from older callers such as
    `link_scoped_tree_bounded`) applies skips, preserving the old rule.

    Args:
        ctx: The path-package spoke's repository context.
        stack: The walk stack of `(node, repo_rel, seen, tree_root)`
            tuples, updated in place; `seen` holds the folded real paths
            on that entry's descent stack for cycle checks, and
            `tree_root` is the mirrored tree's `struct(root, apply_skip)`
            (or a plain spoke-relative root string, which applies
            skips). The walk root itself is already watched
            by the caller; every directory popped here is watched as it
            is visited.
        scope: The fetch's link scope.
        bound: Maximum directory pops; tests drive this small.

    Returns:
        A `struct(leftover, error)`: `leftover` is True when directories
        are left unvisited at the bound, and `error` is "" or the cycle
        refusal naming the link. The caller fails the fetch on either.
    """
    for _ in range(bound):
        if not stack:
            break
        parent, parent_rel, seen, tree_root = stack.pop()
        for child in parent.readdir():
            name = child.basename
            child_rel = parent_rel + "/" + name
            child_real = str(child.realpath)
            if child.is_dir and _tree_skips_child(tree_root, parent_rel, name, scope.case_insensitive):
                continue
            if not paths_match(child_real, scope.package_realpath + "/" + child_rel, scope.case_insensitive):
                error = _mirror_link_child(ctx, child, child_rel, child_real, scope, seen, tree_root, stack)
                if error:
                    return struct(leftover = False, error = error)
                continue
            if child.is_dir:
                ctx.watch(child)
                stack.append(
                    (child, child_rel, seen + (fold_path_case(child_real, scope.case_insensitive),), tree_root),
                )
                continue
            if name in _PATH_SPOKE_SKIP_FILES:
                ctx.watch(child)
                continue
            _link_new_symlink(ctx, child, child_rel, scope.linked, _scope_dest_prefix(scope))
    if stack:
        return struct(leftover = True, error = "")
    return struct(leftover = False, error = "")

def _link_scoped_tree(ctx, node, repo_rel, scope, bound = PUB_WALK_BOUND, apply_skip = True):
    """Mirror one real source directory into the spoke file by file.

    Real directories become real repository directories holding one symlink
    per file, so the generator's `ctx.file` writes (the root and generated
    BUILD files) can never land in the user tree through a symlinked
    directory. Symlinks replicate without descending for files, and
    resolve, confine, cycle-check, and mirror for directories; skipped
    top-level subtrees (`build/`, `.dart_tool/`, `example/`,
    dot-directories) stay unlinked and unwatched so machine-local output
    cannot affect the fetch, except in `lib/` and declared asset directory
    trees (`apply_skip = False`), which mirror whole the way
    `flutter_tools` reads them; user BUILD files are watched but not linked.
    The walk shares the pub spoke bound (`PUB_WALK_BOUND`): reaching it
    with directories left over, or entering a symlink cycle, fails the
    fetch instead of fetching part of the tree.

    Args:
        ctx: The path-package spoke's repository context.
        node: The workspace-side source directory node.
        repo_rel: The spoke-relative path the directory mirrors to.
        scope: The fetch's link scope.
        bound: Maximum directory pops.
        apply_skip: False for `lib/` and declared asset directory trees,
            which link skip names directly under them normally; True for
            every other mirrored tree.
    """
    seed = (fold_path_case(str(node.realpath), scope.case_insensitive),)
    root = struct(root = repo_rel, apply_skip = apply_skip)
    result = mirror_tree_bounded(ctx, [(node, repo_rel, seed, root)], scope, bound)
    if result.error:
        fail(result.error)
    if result.leftover:
        fail(scoped_tree_bound_error(scope.package_name, bound))

def _mirror_single_link(ctx, node, repo_rel, node_real, scope, seen, apply_skip = True):
    """Replicate one source symlink outside any running walk.

    Files replicate as one watched symlink; directory links resolve to
    their target and mirror entry by entry through a fresh walk. Refusals
    (package-ancestor cycles, outside-workspace targets, symlink cycles,
    the walk bound) fail the fetch naming the package and the link.

    Args:
        ctx: The path-package spoke's repository context.
        node: The workspace-side symlink node.
        repo_rel: The spoke-relative path the link mirrors to.
        node_real: The link's resolved path.
        scope: The fetch's link scope.
        seen: The folded real paths on the current descent stack.
        apply_skip: False for a declared `lib/` or asset-directory link,
            whose drained walk links skip names directly under it
            normally; True for every other link.
    """
    stack = []
    root = struct(root = repo_rel, apply_skip = apply_skip)
    error = _mirror_link_child(ctx, node, repo_rel, node_real, scope, seen, root, stack)
    if error:
        fail(error)
    if not stack:
        return

    # The drained walk roots at the link target: its own mirrored tree, so
    # its immediate children consult the skip list when the tree applies
    # skips, while deeper names link normally — the same rule as every
    # other mirrored tree.
    drained = mirror_tree_bounded(ctx, stack, scope, PUB_WALK_BOUND)
    if drained.error:
        fail(drained.error)
    if drained.leftover:
        fail(scoped_tree_bound_error(scope.package_name, PUB_WALK_BOUND))

def _link_top_level_shader_includes(ctx, src, scope):
    """Link top-level include siblings for a top-level declared shader.

    A declared `ripple.frag` at the package root resolves `#include`s
    against the root, so the spoke links the root's `.glsl`/`.frag`/`.vert`
    files beside it — flat, never descending, skipping build output, tool
    state, and user BUILD files like every other link.
    """
    for child in src.readdir():
        name = child.basename
        if is_path_spoke_skipped_dir(name, scope.case_insensitive):
            continue
        if child.is_dir:
            continue
        if name in _PATH_SPOKE_SKIP_FILES:
            ctx.watch(child)
            continue
        if name.rpartition(".")[2] not in ("glsl", "frag", "vert"):
            continue
        if not paths_match(str(child.realpath), scope.package_realpath + "/" + name, scope.case_insensitive):
            _mirror_single_link(ctx, child, name, str(child.realpath), scope, ())
            continue
        _link_new_symlink(ctx, child, name, scope.linked, _scope_dest_prefix(scope))

def _watch_scoped_entry(ctx, src, entry_path, scope):
    """Watch a declared entry and resolve it to its link triple.

    The declared path is watched before testing whether it exists, so
    creating it later refetches the spoke instead of leaving its files
    silently missing. Returns None when the entry is missing (a
    declared-but-absent path is not an error); otherwise returns
    (node, repo_rel, node_real), the workspace-side node, its
    package-relative repo path, and its canonical real path.

    Args:
        ctx: The path-package spoke's repository context.
        src: The workspace-side package directory node.
        entry_path: The package-relative declared path to resolve.
        scope: The fetch's link scope.
    """
    parts = _spoke_entry_parts(scope.package_name, entry_path)
    node = src.get_child(*parts)
    ctx.watch(node)
    if not node.exists:
        return None
    repo_rel = "/".join(parts)
    return (node, repo_rel, str(node.realpath))

def _link_scoped_dir_entry(ctx, src, entry_path, scope, apply_skip = True):
    """Link one declared directory entry (asset, shader, or platform dir).

    Missing entries stay unlinked (a declared-but-absent directory is not
    an error); real directories mirror file by file; anything else
    resolves, confines, cycle-checks, and mirrors (a directory link) or
    replicates as one file symlink, refusing package-ancestor cycles and
    targets outside the workspace.

    Args:
        ctx: The path-package spoke's repository context.
        src: The workspace-side package directory node.
        entry_path: The package-relative declared path to link.
        scope: The fetch's link scope.
        apply_skip: False for `lib/` and declared asset directories,
            which mirror whole; True for platform and shader directories.
    """
    resolved = _watch_scoped_entry(ctx, src, entry_path, scope)
    if resolved == None:
        return
    node, repo_rel, node_real = resolved
    if not paths_match(node_real, scope.package_realpath + "/" + repo_rel, scope.case_insensitive):
        _mirror_single_link(
            ctx,
            node,
            repo_rel,
            node_real,
            scope,
            (fold_path_case(scope.package_realpath, scope.case_insensitive),),
            apply_skip,
        )
        return
    if node.is_dir:
        _link_scoped_tree(ctx, node, repo_rel, scope, PUB_WALK_BOUND, apply_skip)
        return
    _link_new_symlink(ctx, node, repo_rel, scope.linked, _scope_dest_prefix(scope))

def link_scoped_file_entry(ctx, src, entry_path, scope, apply_skip = True):
    """Link one declared file entry (pubspec, hook, asset, font, shader).

    The declared path is watched before testing whether it exists, so
    creating it later refetches the spoke. Missing entries otherwise stay
    unlinked; a directory at the entry mirrors file by file; a user BUILD
    file is watched but not linked; anything else becomes a single file
    symlink, refusing package-ancestor cycles and targets outside the
    workspace.

    Args:
        ctx: The path-package spoke's repository context.
        src: The workspace-side package directory node.
        entry_path: The package-relative declared path to link.
        scope: The fetch's link scope.
        apply_skip: False when the entry is `lib/` or a declared asset
            directory, which mirrors whole; True otherwise.
    """
    resolved = _watch_scoped_entry(ctx, src, entry_path, scope)
    if resolved == None:
        return
    node, repo_rel, node_real = resolved
    if not paths_match(node_real, scope.package_realpath + "/" + repo_rel, scope.case_insensitive):
        _mirror_single_link(
            ctx,
            node,
            repo_rel,
            node_real,
            scope,
            (fold_path_case(scope.package_realpath, scope.case_insensitive),),
            apply_skip,
        )
        return
    if node.is_dir:
        _link_scoped_tree(ctx, node, repo_rel, scope, PUB_WALK_BOUND, apply_skip)
        return
    if node.basename in _PATH_SPOKE_SKIP_FILES:
        ctx.watch(node)
        return
    _link_new_symlink(ctx, node, repo_rel, scope.linked, _scope_dest_prefix(scope))

def _link_asset_variant_files(ctx, src, entry_path, scope, variant_cache):
    """Link the resolution variants of one declared file entry.

    A file entry bundles its main file plus same-named files in sibling
    `<N>x` directories; path spokes link selectively, so each variant is
    linked here or the spoke would reference an unlinked file. Missing
    variants stay unlinked — a main file without variants is the common
    case, and a missing main is reported later by the spoke generator.
    The variant directory is watched before testing whether it exists, so
    adding variants later refetches the spoke. `variant_cache` maps each
    parent directory to its already-read variant subdirectory names, so K
    file entries under one directory read it once.

    Args:
        ctx: The path-package spoke's repository context.
        src: The workspace-side package directory node.
        entry_path: The package-relative declared file path.
        scope: The fetch's link scope.
        variant_cache: Dict from parent directory path to its variant
            subdirectory names, updated in place.
    """
    parts = _spoke_entry_parts(scope.package_name, entry_path)
    base = parts[-1]
    parent_key = "/".join(parts[:-1])
    if parent_key not in variant_cache:
        dir_node = src.get_child(*parts[:-1]) if parts[:-1] else src
        ctx.watch(dir_node)
        variants = []
        if dir_node.exists:
            for child in dir_node.readdir():
                if child.is_dir and is_asset_variant_dir(child.basename):
                    variants.append(child.basename)
        variant_cache[parent_key] = variants
    for vdir in variant_cache[parent_key]:
        if parent_key == "":
            variant = vdir + "/" + base
        else:
            variant = parent_key + "/" + vdir + "/" + base
        link_scoped_file_entry(ctx, src, variant, scope)

def link_spoke_contents(ctx, src, asset_block, platform_dirs, scope):
    """Link everything the spoke generator reads or exposes — nothing else.

    The pubspec leads: `lib/`, hook scripts, declared assets, fonts, and
    shaders (plus each shader's own directory, or the root's include
    siblings for a top-level shader), and the plugin's platform
    directories. (`link_path_package` links the pubspec itself first, so it
    can parse it for this plan.) Everything else in the package —
    `example/`, `build/`, `.dart_tool/`, dot-directories, undeclared files
    — stays out of the spoke and unwatched, so machine-local state cannot
    affect the fetch. `lib/` and each declared asset directory mirror
    whole instead — `build/`, `example/`, or dot names directly under
    them link normally, the way `flutter_tools` reads them — while
    platform and shader directory trees still skip those names at their
    own top level. Overlapping declarations (a shader inside a declared
    asset dir, a file inside its own declared dir) link each spoke path
    once: `linked` records every created symlink.

    Args:
        ctx: The path-package spoke's repository context.
        src: The workspace-side package directory node.
        asset_block: The parsed `flutter:` assets/fonts/shaders block.
        platform_dirs: The plugin platform directories to mirror.
        scope: The fetch's link scope.
    """
    for entry in ["hook/build.dart", "hook/link.dart"]:
        link_scoped_file_entry(ctx, src, entry, scope)
    link_scoped_file_entry(ctx, src, "lib", scope, False)
    variant_cache = {}
    for asset in asset_block.assets:
        if asset.path.endswith("/"):
            _link_scoped_dir_entry(ctx, src, asset.path[:-1], scope, False)
        else:
            link_scoped_file_entry(ctx, src, asset.path, scope)
            _link_asset_variant_files(ctx, src, asset.path, scope, variant_cache)
    for family in asset_block.fonts:
        for font in family.fonts:
            link_scoped_file_entry(ctx, src, font.asset, scope)
    for shader in asset_block.shaders:
        link_scoped_file_entry(ctx, src, shader.path, scope)
        shader_dir = shader.path.rpartition("/")[0]
        if shader_dir:
            _link_scoped_dir_entry(ctx, src, shader_dir, scope)
        else:
            _link_top_level_shader_includes(ctx, src, scope)
    for platform_dir in platform_dirs:
        _link_scoped_dir_entry(ctx, src, platform_dir, scope)
