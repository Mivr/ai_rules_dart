"""Public/private header split for one SwiftPM C-family target.

SwiftPM treats every header under the public-headers directory as public.
`sources:` only drops the automatic compile rule for files it does not list,
so a header there stays public even when `sources:` does not name it.
"""

load(":swiftpm_paths.bzl", "swiftpm_join_path")

visibility(["//flutter/..."])

def swiftpm_split_headers(public_root, rel_dir, headers, files):
    """Split headers into public and private, and find the explicit map.

    The explicit module map is chosen in SwiftPM's order: `module.modulemap`
    at the target root wins; otherwise the public-headers directory. Only the
    headers under the public-headers directory are public; every other
    header is private: it still compiles, but Swift importers do not see it.

    Args:
        public_root: The repo-relative public-headers directory (the target
            directory for an explicit `publicHeadersPath: ""` or `"."`).
        rel_dir: The repo-relative target directory.
        headers: `struct(listed, unlisted)`: the repo-relative headers
            `sources:` keeps (all of them when unset), and those it does not
            list; only the unlisted ones under `public_root` count.
        files: Every file under the target directory (a dict set of
            repo-relative paths).

    Returns:
        `struct(ok, error, public_hdrs, private_hdrs, explicit_map,
        map_in_include)`: `explicit_map` is the repo-relative explicit
        map or None; `map_in_include` when it lives under the
        public-headers directory rather than the target root.
    """
    prefix = public_root + "/" if public_root else ""
    public_hdrs = sorted([header for header in headers.listed + headers.unlisted if header.startswith(prefix)])
    private_hdrs = sorted([header for header in headers.listed if not header.startswith(prefix)])
    root_map = swiftpm_join_path(rel_dir, "module.modulemap")
    public_map = swiftpm_join_path(public_root, "module.modulemap")
    explicit_map = None
    map_in_include = False
    if root_map in files:
        explicit_map = root_map
    elif public_map in files:
        explicit_map = public_map
        map_in_include = True
    return struct(
        ok = True,
        error = "",
        public_hdrs = public_hdrs,
        private_hdrs = private_hdrs,
        explicit_map = explicit_map,
        map_in_include = map_in_include,
    )
