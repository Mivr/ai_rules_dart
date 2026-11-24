"""SwiftPM relative path normalization.

SwiftPM resolves every manifest-relative path (`path:`, `sources:`,
`exclude:`, `publicHeadersPath:` and `.headerSearchPath`) against its base
directory after dropping empty and `.` segments and a trailing `/`. Only an
absolute path, or one whose `..` segments reach above that base, leaves the
target. This is the one normalization both the repo rule
(`swiftpm_package.bzl`) and the settings reader (`swiftpm_settings.bzl`)
use, so an entry and its escape check cannot disagree.
"""

visibility(["//flutter/..."])

def swiftpm_normalize_relative_path(path):
    """Normalize one SwiftPM relative path and report whether it escapes.

    Empty and `.` segments and a trailing `/` drop out; each `..` segment
    removes the segment before it. The base itself normalizes to `""`.

    Args:
        path: The manifest-relative path, as written.

    Returns:
        `struct(ok, error, path)`: `path` is the normalized path; `error`
        is `"absolute path"` or `"leaves its base"` when the path is not
        inside the base, else `""`.
    """
    if path.startswith("/"):
        return struct(ok = False, error = "absolute path", path = "")
    segments = []
    for segment in path.split("/"):
        if segment == "" or segment == ".":
            continue
        if segment == "..":
            if not segments:
                return struct(ok = False, error = "leaves its base", path = "")
            segments.pop()
            continue
        segments.append(segment)
    return struct(ok = True, error = "", path = "/".join(segments))

def swiftpm_join_path(base, relative):
    """Join a repo-relative base directory and a normalized relative path.

    The spoke's repository root is the package root, so a target whose
    directory is the package root has the base `""`; joining must not
    produce a leading `/` then, and a `""` relative path is the base.

    Args:
        base: The repo-relative base directory (`""` for the repo root).
        relative: The normalized path below it (`""` for the base itself).

    Returns:
        The repo-relative path.
    """
    if relative == "":
        return base
    if base == "":
        return relative
    return base + "/" + relative
