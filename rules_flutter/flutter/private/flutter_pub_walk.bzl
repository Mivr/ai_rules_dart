"""Shared bounds for the `flutter pub` spoke directory walks.

Every spoke-side directory walk — asset listing (`flutter_pub_assets.bzl`
`list_files_recursive`), plugin source detection (`_has_files_under` in
`flutter_pub_package.bzl`), and path-package linking (`_link_scoped_tree`
there) — is a bounded Starlark `for` loop (Starlark has no `while`). All
three share `PUB_WALK_BOUND` and fail the fetch loudly at it, naming the
package, the directory, and the bound, instead of truncating or answering
from a half-walked tree. Starlark `range` is lazy and each walk is linear
in the directories it visits, so the high bound costs nothing until a walk
nears it.

The pure core (`has_files_under_walk`) works over a caller-provided
`readdir` callable so unit tests drive it with fakes; the spoke passes a
context-backed adapter and `fail()`s the fetch on the returned error. The
bound-error helpers return their message instead of failing so unit tests
can assert them; the caller `fail()`s with them.
"""

visibility(["//flutter/..."])

# Bound for every pub spoke directory walk: at most this many directory
# pops before the fetch fails loudly. 1000000 covers the 2-5M-line
# monorepos rules_flutter targets, where a large package legitimately
# holds far more than ten thousand asset or source folders; Starlark
# `range` is lazy, so the bound costs nothing until a walk nears it.
PUB_WALK_BOUND = 1000000

def _extension_of(name):
    """The file extension of `name`, or "" when it has none.

    Args:
        name: A single file basename (no slashes).

    Returns:
        The text after the last dot, or "".
    """
    return name.rsplit(".", 1)[-1] if "." in name else ""

def has_files_bound_error(package_name, directory, bound):
    """The fetch failure for a source scan that reaches its walk bound.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package, the directory, and the
    bound: reaching the bound with directories unvisited must never be
    reported as "no sources".

    Args:
        package_name: The pub package scanned.
        directory: The package-relative directory scanned.
        bound: The walk bound reached.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"" + package_name + "\": directory \"" +
        directory + "\" holds more than " + str(bound) + " directories; " +
        "refusing it rather than reporting no sources from part of the tree."
    )

def scoped_tree_bound_error(package_name, bound):
    """The fetch failure for a link walk that reaches its walk bound.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and the bound.

    Args:
        package_name: The path package linked.
        bound: The walk bound reached.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub repo rule: path dependency \"" + package_name +
        "\" holds more than " + str(bound) + " directories under its linked " +
        "entries. Refusing it rather than fetching part of the tree."
    )

def heredoc_blocks_bound_error(package_name, template, bound):
    """The fetch failure for an overlay rewrite that reaches its block bound.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package, the template, and the
    bound: a template with blocks left over must never emit part of itself.

    Args:
        package_name: The pub package the overlay belongs to.
        template: The overlay template path.
        bound: The block bound reached.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub overlay for \"" + package_name + "\" (" + template +
        "): template holds more than " + str(bound) + " heredoc genrule " +
        "blocks; refusing it rather than emitting part of the template."
    )

def has_files_under_walk(readdir, rel_dir, package_name, extensions = None, bound = PUB_WALK_BOUND):
    """Walk `rel_dir` for the first matching file, bounded and loud.

    Pure core of the plugin source scan: returns on the first file whose
    extension is in `extensions` (any file when `extensions` is None).
    Reaching `bound` with directories unvisited returns the bound failure
    instead of answering "no files" from a half-walked tree.

    Args:
        readdir: Callable taking a package-relative directory path and
            returning its immediate children as a list of
            `struct(name, is_dir)`. A missing directory returns [].
        rel_dir: Package-relative directory to scan.
        package_name: The pub package scanned, for the bound failure.
        extensions: File extensions to accept, or None for any file.
        bound: Maximum directory pops; reaching it with work left returns
            `error` instead of silently reporting no sources. Tests drive
            this small.

    Returns:
        `struct(found, error)`: `found` is True on the first matching file;
        `error` is "" or the fetch failure naming the package, the
        directory, and the bound.
    """
    stack = [rel_dir]
    for _ in range(bound):
        if not stack:
            break
        current = stack.pop()
        for child in readdir(current):
            if child.is_dir:
                if current == "":
                    stack.append(child.name)
                else:
                    stack.append(current + "/" + child.name)
            elif extensions == None:
                return struct(found = True, error = "")
            elif _extension_of(child.name) in extensions:
                return struct(found = True, error = "")
    if stack:
        return struct(found = False, error = has_files_bound_error(package_name, rel_dir, bound))
    return struct(found = False, error = "")
