"""Pure per-entry classification and diagnostics for the pub archive scan.

A pub archive is pinned by sha256, but that pins the archive bytes, not what
the extracted package ends up holding: `ctx.extract` turns a tar hard-link
entry into a real hard link, so an entry whose target climbs out of the
extraction directory makes a "package file" share bytes with a file elsewhere
on the build host. Editing that host file then changes the build with no lock
or source change. The post-extraction walk (`pub_symlink.bzl`) cannot see
hard links — a hard link is a regular file whose realpath is itself, and
Starlark has no stat (no inode or link count) to tell them apart — so the
decision has to come from the archive's own entry headers, before any
extracted content is trusted (before a BUILD file is written, a pubspec is
read, or a consumer can see the tree).

The scan itself runs in the AOT-compiled `dart_pub_scanner` executable (see
`//dart/pub:pub_scanner.bzl`), driven through the public
`//dart/pub:pub_scan.bzl` at every site that unpacks third-party pub content:
hosted spokes, git spokes, merged-cycle members (hosted and git),
`pub.package()` repositories, and the module extension's cycle-planning
scratch. This module holds what stays pure Starlark so unit tests cover every
refusal shape without downloading anything: `classify_archive_entry` applies
the per-entry policy (refusing every hard-link entry whatever its target,
every symlink entry whose target is absolute or climbs out of the package
root, and every entry whose own path is absolute or climbs out of the root),
`archive_entry_error` and `archive_path_error` build the fetch-failure
diagnostics, and `scan_error` builds the unscannable-archive diagnostic. The
scanner implements the same policy over the same tar shapes (ustar with
`prefix`, GNU `L`/`K`, pax `x`/`g` honouring `path=`, `linkpath=` and
`size=`, octal and base-256 sizes), failing closed on unknown entry kinds,
sparse entries, corrupt headers and truncated streams, with the strictest
path reading on every OS — so its verdicts and this classification never
disagree. The walk itself is kept behind the scan: dangling links, chain
escapes through in-package links, and materialising in-package links as
regular files all behave as before.
"""

load("//dart/pub/private:pub_symlink.bzl", "is_absolute_symlink_target", "symlink_escapes_package")

def scan_error(package_name, detail):
    """Builds the fetch-failure diagnostic for an unscannable archive.

    Policy refusals (hard links, escaping symlinks, escaping entry paths) go
    through `archive_entry_error` and `archive_path_error` instead; this is
    for archives the scanner cannot read exactly — corrupt, truncated, or
    using entry kinds it does not cover — which the build refuses rather than
    trusts.

    Args:
      package_name: The pub package the archive was fetched for.
      detail: What could not be read.

    Returns:
      The `fail()` message naming the package.
    """
    return 'pub package "%s": cannot scan its archive: %s' % (package_name, detail)

def archive_entry_error(package_name, path, kind, target):
    """Builds the fetch-failure diagnostic for a refused archive entry.

    Names the package, the entry path, the entry kind and the raw target, so
    the failure points at the offending archive entry. The symlink shape
    starts exactly like the post-extraction walk's diagnostic (which names
    the resolved target instead) so one grep matches either guard.

    Args:
      package_name: The pub package the entry was found in.
      path: The entry path relative to the package root, as stored.
      kind: `"hard-link"` or `"symlink"`.
      target: The entry's raw target, as stored.

    Returns:
      The `fail()` message naming the package, path, kind and target.
    """
    if kind == "hard-link":
        return (
            'pub package "%s": hard-link "%s" points at "%s": ' +
            "refusing an archive entry that extracts as a link sharing bytes " +
            "with another file, which the build cannot tell apart from a regular file"
        ) % (package_name, path, target)
    return (
        'pub package "%s": symlink "%s" escapes the package (points at "%s"): ' +
        "refusing to materialise a link that reads undeclared host files"
    ) % (package_name, path, target)

def archive_path_error(package_name, path):
    """Builds the fetch-failure diagnostic for a refused archive entry path.

    Names the package and the offending path, so the failure points at the
    archive entry that would extract outside the package root.

    Args:
      package_name: The pub package the entry was found in.
      path: The entry path as stored: absolute, or climbing out of the root.

    Returns:
      The `fail()` message naming the package and path.
    """
    return (
        'pub package "%s": entry "%s" escapes the package: ' +
        "refusing an archive entry whose path is absolute or climbs out of " +
        "the package root"
    ) % (package_name, path)

def archive_entry_path_escapes(name):
    """Returns True when a tar entry path escapes the package root. Pure.

    Absolute paths escape on every OS, and relative paths escape when their
    `..` segments climb above the root. Backslashes count as separators
    everywhere (the strictest reading), so verdicts are identical on Linux,
    macOS and Windows. Mirrors the scanner's path rule and
    `symlink_escapes_package` with an empty holding directory.

    Args:
      name: The entry path relative to the package root, as stored.

    Returns:
      True when the path leaves the package, False when it stays inside.
    """
    normalized = name.replace("\\", "/")
    if is_absolute_symlink_target(normalized):
        return True
    depth = 0
    for seg in normalized.split("/"):
        if seg == "" or seg == ".":
            continue
        elif seg == "..":
            if depth == 0:
                return True
            depth = depth - 1
        else:
            depth = depth + 1
    return False

def classify_archive_entry(name, typeflag, link_target):
    """Classifies one tar entry header as refused or benign. Pure.

    Refuses every entry whose own path is absolute or climbs out of the
    package root, every hard-link entry whatever its target, and every symlink
    entry whose target is absolute or climbs out of the package root (the
    walk's lexical rule, so the guards never disagree). Everything else —
    regular files, directories, long-name, long-link and pax records, inert
    device entries — is benign to this check.

    Args:
      name: The entry path relative to the package root, after long-name
        and pax `path=` resolution.
      typeflag: The entry kind character (`"1"` hard link, `"2"` symlink).
      link_target: The entry's raw target, after long-link and pax
        `linkpath=` resolution.

    Returns:
      A `struct(kind, path, target)` refusal, or None when benign.
    """
    if archive_entry_path_escapes(name):
        return struct(kind = "path", path = name, target = link_target)
    if typeflag == "1":
        return struct(kind = "hard-link", path = name, target = link_target)
    if typeflag == "2" and symlink_escapes_package(name, link_target):
        return struct(kind = "symlink", path = name, target = link_target)
    return None
