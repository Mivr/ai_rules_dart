"""Shared symlink guard for every repository that unpacks pub package content.

A published package archive (hosted tarball, `git archive` output, or a
merged-cycle member) can carry symlinks. A symlink whose target resolves
outside the package lets the build read host files no label references:
`srcs = glob(["lib/**/*.dart"])` names the link, and every consumer — the
kernel compile, the app-JIT snapshot, the analyzer staging — reads the
link's target instead. Editing that target changes build outputs without
any change to `deps()`, breaking hermeticity and letting a compromised
dependency exfiltrate host files at build time.

Every extraction site calls `check_package_symlinks` right after unpacking:
- a link that is dangling (including a link loop, which never resolves)
  fails the fetch with a diagnostic naming the package, the link, and the
  word "symlink";
- a link whose resolved target lies outside the package root fails the same
  way;
- links that resolve inside are materialised as regular files/directories
  so later reads cannot observe the link at all.

Before any of that, every fetch site runs the archive header scan
(`pub_scan.bzl`'s `run_pub_archive_scan`, executed by the AOT-compiled
`dart_pub_scanner`) over the archive file: it refuses every hard-link entry
whatever its target, every symlink entry whose target is absolute or climbs
out of the package root, and every entry whose own path is absolute or
climbs out of the root, using this module's lexical rule so the two guards
never disagree. The walk above stays
in place behind it — headers can lie about what the extractor writes, and
only the extracted tree shows what actually landed.

The guard uses Bazel's own repository APIs only (`path.readdir`,
`path.realpath`, `path.exists`/`is_dir`, `repository_ctx.read`/`file`/
`delete`): it never shells out to host tools and never consults `PATH`, so
a fetched package is byte-identical on Linux, macOS and Windows whatever
the host provides. In particular there is no `find`/`readlink`/`cp`/`rm`/
`mv` anywhere in this path, which Windows runners without GNU tools on
`PATH` (where `find` resolves to `FIND.EXE`) could not satisfy.

The lexical check (`symlink_escapes_package`) is pure so unit tests cover
it without downloading anything; so are `package_relpath`,
`realpath_escapes_root`, and the entry walk (`walk_symlink_entries`,
driven by an injectable listing function). The filesystem walk itself needs
a repository or module-extension context.

Module-extension scratch (the cycle-planning directories) is check-only:
`module_ctx` has no `delete`, and the scratch is transient — the spokes
re-fetch the same archives and materialise there. Repository rules do the
full check plus materialisation. The branch is on the context's
capabilities, never on the host or `PATH`, so results stay identical.

Materialisation notes: links are processed in sorted `rel` order and each
directory level in sorted entry order, so the resulting tree does not
depend on host directory order. File contents round-trip through
`ctx.read`/`ctx.file`. Empty directories leave no trace (Bazel has no
mkdir, and empty dirs carry no build inputs); executable bits are not
preserved (package sources run through the Dart toolchain, never directly).
"""

def is_absolute_symlink_target(target):
    """Returns True when a symlink target is absolute.

    POSIX absolute targets (`/etc/passwd`) and Windows drive or UNC targets
    (`C:/secret`, `\\\\host\\\\share`) can never stay inside the package.

    Args:
      target: The raw `readlink` target string.

    Returns:
      True for absolute targets, False otherwise.
    """
    if target.startswith("/"):
        return True
    if target.startswith("\\"):
        return True
    if len(target) >= 2 and target[1] == ":":
        return True
    return False

def symlink_escapes_package(link_relpath, target):
    """Returns True when a symlink escapes its package root.

    Pure lexical check over `/`-separated segments: absolute targets escape,
    and relative targets escape when their `..` segments climb above the
    directory holding the link. An empty target is broken and treated as
    escaping. Chain escapes (a safe-looking target that passes through an
    intermediate link pointing outside) are caught separately by the
    `realpath` comparison in `check_package_symlinks`.

    Args:
      link_relpath: The link path relative to the package root
        (e.g. `"lib/secret.dart"`).
      target: The raw `readlink` target string.

    Returns:
      True when the target leaves the package, False when it stays inside.
    """
    if target == "":
        return True
    normalized = target.replace("\\", "/")
    if is_absolute_symlink_target(normalized):
        return True
    parts = link_relpath.split("/")[:-1]
    stack = [p for p in parts if p != "" and p != "."]
    for seg in normalized.split("/"):
        if seg == "" or seg == ".":
            continue
        elif seg == "..":
            if not stack:
                return True
            stack.pop()
        else:
            stack.append(seg)
    return False

def pub_symlink_error(package_name, link_relpath, target):
    """Builds the fetch-failure diagnostic for an escaping symlink.

    Args:
      package_name: The pub package the link was found in.
      link_relpath: The link path relative to the package root.
      target: The link's raw target (or resolved path when raw is unknown).

    Returns:
      The `fail()` message naming the package and link.
    """
    return (
        'pub package "%s": symlink "%s" escapes the package (points at "%s"): ' +
        "refusing to materialise a link that reads undeclared host files"
    ) % (package_name, link_relpath, target)

def package_relpath(root_abs_str, link_abs_str):
    """Returns `link_abs_str` relative to `root_abs_str`, or None.

    Pure string prefix cut, so unit tests cover the boundary (a sibling
    like `/root2/x` is not under `/root`, and the root itself has no
    relative path).

    Args:
      root_abs_str: Canonical package-root path string.
      link_abs_str: Canonical absolute path string of a directory entry.

    Returns:
      The `rel` path, or None when the entry is not strictly under root.
    """
    prefix = root_abs_str + "/"
    if link_abs_str.startswith(prefix):
        return link_abs_str[len(prefix):]
    return None

def realpath_escapes_root(root_real_str, real_str):
    """Returns True when a resolved link target lies outside the root.

    Pure string comparison over canonical `realpath` spellings: the target
    itself counts as inside, and the trailing-slash guard keeps a sibling
    like `/root2` from matching root `/root`.

    Args:
      root_real_str: Canonical package-root path string.
      real_str: Canonical resolved-target path string.

    Returns:
      True when the target leaves the package, False when it stays inside.
    """
    if real_str == root_real_str:
        return False
    return not real_str.startswith(root_real_str + "/")

def _readdir_snapshot(ctx, dir_abs_str):
    """Snapshots one directory level into plain structs.

    Each entry records what the walk needs — the absolute path string,
    whether it resolves, whether it is a directory, and its canonical
    target — so the walk itself (`walk_symlink_entries`) stays pure over
    an injectable listing function and unit-testable without a context.

    Args:
      ctx: A repository_ctx or module_ctx.
      dir_abs_str: Absolute path string of the directory to list.

    Returns:
      List of structs with `abs`, `exists`, `is_dir` and `real` fields,
      sorted by `abs` for deterministic walks on every host.
    """
    out = []
    for entry in sorted(ctx.path(dir_abs_str).readdir(), key = lambda e: str(e)):
        entry_str = str(entry)
        if not entry.exists:
            out.append(struct(abs = entry_str, exists = False, is_dir = False, real = ""))
        else:
            out.append(struct(abs = entry_str, exists = True, is_dir = entry.is_dir, real = str(entry.realpath)))
    return out

def walk_symlink_entries(lister, dir_abs_str, root_abs_str, out):
    """Collects every symlink under `dir_abs_str` into `out`.

    A directory entry is a link when it does not resolve (dangling target
    or link loop) or when its canonical target differs from its own path;
    links to directories are recorded, never descended into, so loops
    through directory links terminate. Real directories recurse; regular
    files are skipped. An entry outside `root_abs_str` is ignored.

    Args:
      lister: Function from directory absolute-path string to that level's
        snapshot entries (see `_readdir_snapshot`).
      dir_abs_str: Absolute path string of the directory to walk.
      root_abs_str: Canonical package-root path string.
      out: List receiving `struct(abs, rel)` link entries.
    """

    # Iterative: Starlark forbids recursive calls (and has no `while`, so
    # the loop carries an absurdly high bound and fails closed past it —
    # a package with more directories than that is a zip bomb, not a
    # package, and the old `find` walk choked on those too).
    pending = [dir_abs_str]
    for _ in range(_MAX_TREE_STEPS):
        if not pending:
            break
        for entry in lister(pending.pop()):
            if (not entry.exists) or entry.real != entry.abs:
                rel = package_relpath(root_abs_str, entry.abs)
                if rel != None and rel != "":
                    out.append(struct(abs = entry.abs, rel = rel))
            elif entry.is_dir:
                pending.append(entry.abs)
    if pending:
        fail('pub package scan of "%s" exceeded %d directories: refusing to scan an unbounded tree' % (root_abs_str, _MAX_TREE_STEPS))

def _list_package_symlinks(ctx, root_real_str):
    """Lists every symlink under the package root, sorted by `rel`.

    Args:
      ctx: A repository_ctx or module_ctx.
      root_real_str: Canonical package-root path string.

    Returns:
      Sorted list of `struct(abs, rel)` link entries.
    """
    out = []
    walk_symlink_entries(lambda dir_abs_str: _readdir_snapshot(ctx, dir_abs_str), root_real_str, root_real_str, out)
    return sorted(out, key = lambda link: link.rel)

def _materialise_failure(link_abs_str, reason):
    """Builds the fetch-failure diagnostic for an uncopyable link."""
    return (
        'pub symlink "%s" could not be materialised as a regular file: %s'
    ) % (link_abs_str, reason)

# Upper bound on directories visited while walking or copying one package
# tree (Starlark has no `while`, so every loop is a bounded `for`).
# Exhausting it fails the fetch: a package that large is a zip bomb.
_MAX_TREE_STEPS = 1000000

def _copy_dir_tree(ctx, link, dest_repo_rel, src_obj, top_real_str):
    """Copies the directory `src_obj` to `dest_repo_rel` as regular files.

    Inner symlinks are followed and written out as the content they point
    at (inner directory links recurse the same way), so the copy holds no
    links. Each stack frame carries the canonical targets on its own
    ancestor path: revisiting one is a link cycle, which fails the fetch —
    the old `cp -RL` materialisation failed those too, by recursing until
    the host refused. Entries copy in sorted order, so the result is
    deterministic. Iterative: Starlark forbids recursive calls.

    Args:
      ctx: A repository_ctx (callers gate on `delete` first).
      link: The top-level `struct(abs, rel)` link being materialised, for
        diagnostics.
      dest_repo_rel: Repository-relative destination directory path.
      src_obj: Path object of the source directory (a resolved target).
      top_real_str: Canonical target of the top-level link, the first
        ancestor every copied directory descends from.
    """
    pending = [(src_obj, dest_repo_rel, [top_real_str])]
    for _ in range(_MAX_TREE_STEPS):
        if not pending:
            break
        current = pending.pop()
        current_obj = current[0]
        current_dest = current[1]
        ancestors = current[2]
        for entry in sorted(current_obj.readdir(), key = lambda e: str(e)):
            entry_str = str(entry)
            dest = current_dest + "/" + entry.basename
            if not entry.exists:
                fail(_materialise_failure(link.abs, 'could not read "%s"' % entry_str))
            entry_real = entry.realpath
            entry_real_str = str(entry_real)
            if entry.is_dir:
                if entry_real_str in ancestors:
                    fail(_materialise_failure(link.abs, 'link cycle at "%s"' % entry_str))
                pending.append((entry_real, dest, ancestors + [entry_real_str]))
            else:
                ctx.file(dest, ctx.read(entry_real), executable = False)
    if pending:
        fail(_materialise_failure(link.abs, "directory tree too large to materialise"))

def _materialise_link(ctx, root, link):
    """Replaces one validated in-package link with regular files.

    The link is deleted before its target is copied, so a link pointing at
    its own ancestor (whose target tree holds the link itself) still copies
    a finite tree. File contents round-trip through `ctx.read`/`ctx.file`.

    Args:
      ctx: A repository_ctx (callers gate on `delete` first).
      root: The package root passed to `check_package_symlinks`.
      link: The `struct(abs, rel)` link entry to materialise.
    """
    repo_rel = link.rel if root == "" else root + "/" + link.rel
    link_path = ctx.path(link.abs)
    if not link_path.exists:
        fail(_materialise_failure(link.abs, "link target vanished"))
    is_dir = link_path.is_dir
    real_obj = link_path.realpath
    ctx.delete(repo_rel)
    if is_dir:
        _copy_dir_tree(ctx, link, repo_rel, real_obj, str(real_obj))
    else:
        ctx.file(repo_rel, ctx.read(real_obj), executable = False)

def check_package_symlinks(ctx, package_name, root = ""):
    """Fails the fetch when `root` holds a symlink escaping the package.

    Runs after every archive unpack of third-party package content: hosted
    spokes, git spokes, merged-cycle members, `pub.package()` repos, and the
    module-extension cycle-planning scratch. Links that resolve outside the
    root (or dangle, which includes link loops) fail the fetch with a
    diagnostic naming the package and the link. Links that stay inside the
    package are materialised as regular files/directories so the build never
    observes a link at all — except on the module-extension scratch, where
    `module_ctx` offers no `delete` and the content is transient planning
    input the spokes re-fetch anyway; there the guard checks without
    materialising. Nothing here depends on host tools or `PATH`.

    Args:
      ctx: A repository_ctx or module_ctx.
      package_name: The pub package being fetched, for diagnostics.
      root: Package root relative to the context directory (`""` for the
        repository root, the member name for merged members, the scratch
        subdirectory for extension planning).
    """
    root_abs = ctx.path(root if root else ".")
    if not root_abs.exists or not root_abs.is_dir:
        return

    # Walk from the resolved root so every comparison below uses one
    # canonical spelling (macOS `/tmp` is `/private/tmp`, and Windows has
    # its own aliases): otherwise each file's `realpath` mismatches its
    # listed path and every file looks like a link.
    root_real_str = str(root_abs.realpath)
    links = _list_package_symlinks(ctx, root_real_str)
    if not links:
        return
    for link in links:
        link_path = ctx.path(link.abs)
        if not link_path.exists:
            fail(pub_symlink_error(package_name, link.rel, "(broken symlink)"))
        real_str = str(link_path.realpath)
        if realpath_escapes_root(root_real_str, real_str):
            fail(pub_symlink_error(package_name, link.rel, real_str))
    if not hasattr(ctx, "delete"):
        # Module-extension scratch: check-only, see the docstring above.
        return
    for link in links:
        _materialise_link(ctx, root, link)
