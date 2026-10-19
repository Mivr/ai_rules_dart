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

- a link whose raw target is absolute, or whose `..` segments climb above
  the package root, fails the fetch with a diagnostic naming the package,
  the link, and the word "symlink";
- a link whose chain resolves outside the root (through an intermediate
  link that stays inside) fails the same way;
- links that stay inside are materialised as regular files/directories so
  later reads cannot observe the link at all.

The lexical check (`symlink_escapes_package`) is pure so unit tests cover
it without downloading anything; the filesystem walk needs a repository or
module-extension context.
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

def _package_relpath(root_abs_str, link_abs_str):
    prefix = root_abs_str + "/"
    if link_abs_str.startswith(prefix):
        return link_abs_str[len(prefix):]
    return None

def _list_symlinks_find(ctx, root_abs_str):
    find = ctx.which("find")
    if find == None:
        return None
    res = ctx.execute([find, root_abs_str, "-type", "l", "-print"])
    if res.return_code != 0:
        fail("symlink check: find failed under %s: %s" % (root_abs_str, res.stderr))
    links = []
    for line in res.stdout.split("\n"):
        if line == "":
            continue
        rel = _package_relpath(root_abs_str, line)
        if rel == None or rel == "":
            continue
        links.append(struct(abs = line, rel = rel))
    return sorted(links, key = lambda l: l.rel)

def _list_symlinks_readdir(ctx, dir_obj, root_abs_str, out):
    for entry in dir_obj.readdir():
        entry_str = str(entry)
        if not entry.exists:
            rel = _package_relpath(root_abs_str, entry_str)
            if rel != None and rel != "":
                out.append(struct(abs = entry_str, rel = rel))
            continue
        if str(entry.realpath) != entry_str:
            rel = _package_relpath(root_abs_str, entry_str)
            if rel != None and rel != "":
                out.append(struct(abs = entry_str, rel = rel))
            continue
        if entry.is_dir:
            _list_symlinks_readdir(ctx, entry, root_abs_str, out)

def _list_package_symlinks(ctx, root_abs):
    root_abs_str = str(root_abs)
    via_find = _list_symlinks_find(ctx, root_abs_str)
    if via_find != None:
        return via_find
    out = []
    _list_symlinks_readdir(ctx, root_abs, root_abs_str, out)
    return sorted(out, key = lambda l: l.rel)

def _read_link_target(ctx, link_abs):
    readlink = ctx.which("readlink")
    if readlink == None:
        return None
    res = ctx.execute([readlink, link_abs])
    if res.return_code != 0:
        return None
    raw = res.stdout
    if raw.endswith("\n"):
        raw = raw[:len(raw) - 1]
    return raw

def _realpath_outside_root(ctx, link_abs, root_real_str):
    real_str = str(ctx.path(link_abs).realpath)
    if real_str == root_real_str:
        return False
    return not real_str.startswith(root_real_str + "/")

def _materialise_link(ctx, link_abs):
    cp = ctx.which("cp")
    rm = ctx.which("rm")
    mv = ctx.which("mv")
    if cp == None or rm == None or mv == None:
        return
    tmp_abs = link_abs + ".__pub_symlink_tmp"
    ctx.execute([rm, "-rf", tmp_abs])
    res = ctx.execute([cp, "-RL", link_abs, tmp_abs])
    if res.return_code != 0:
        fail(
            'pub symlink "%s" could not be materialised as a regular file: %s' %
            (link_abs, res.stderr),
        )
    res = ctx.execute([rm, link_abs])
    if res.return_code != 0:
        fail(
            'pub symlink "%s" could not be materialised as a regular file: %s' %
            (link_abs, res.stderr),
        )
    res = ctx.execute([mv, tmp_abs, link_abs])
    if res.return_code != 0:
        fail(
            'pub symlink "%s" could not be materialised as a regular file: %s' %
            (link_abs, res.stderr),
        )

def check_package_symlinks(ctx, package_name, root = ""):
    """Fails the fetch when `root` holds a symlink escaping the package.

    Runs after every archive unpack of third-party package content: hosted
    spokes, git spokes, merged-cycle members, `pub.package()` repos, and the
    module-extension cycle-planning scratch. Links that stay inside the
    package are materialised as regular files/directories so the build never
    observes a link at all.

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
    root_real_str = str(root_abs.realpath)
    links = _list_package_symlinks(ctx, root_abs)
    if not links:
        return
    for link in links:
        raw = _read_link_target(ctx, link.abs)
        if raw == None:
            raw = ""
        if raw != "" and symlink_escapes_package(link.rel, raw):
            fail(pub_symlink_error(package_name, link.rel, raw))
        if not ctx.path(link.abs).exists:
            fail(pub_symlink_error(package_name, link.rel, raw if raw != "" else "(broken symlink)"))
        if _realpath_outside_root(ctx, link.abs, root_real_str):
            fail(pub_symlink_error(package_name, link.rel, raw if raw != "" else "(unresolved)"))
    for link in links:
        _materialise_link(ctx, link.abs)
