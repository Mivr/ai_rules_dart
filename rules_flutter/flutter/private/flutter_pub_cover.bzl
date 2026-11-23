"""Covering-entry lookup for `flutter.assets` failure messages.

A trailing-slash directory declaration covers every file walked out of it,
so a failure about a walked file names the declaration the user wrote
rather than the file. The index below records each declaration's position
so the lookup replays the scan's first-match-in-declaration-order rule
through dict lookups instead of a linear scan per file.
"""

visibility(["//flutter/..."])

def covering_entry_lookup(parsed_assets):
    """Index asset declarations for linear covering-entry lookup.

    Records each declaration's position so `covering_entry` replays the
    scan's first-match-in-declaration-order rule through dict lookups:
    exact file entries by path, trailing-slash directory entries by
    directory path. Built once per fetch; every walked file below then
    resolves in time linear in its own depth.

    Args:
        parsed_assets: The `assets` of `parse_flutter_assets_block`.

    Returns:
        A struct `(exact, dirs)` of declaration-path-to-position dicts.
    """
    exact = {}
    dirs = {}
    for i, entry in enumerate(parsed_assets):
        if entry.path.endswith("/"):
            if entry.path not in dirs:
                dirs[entry.path] = i
        elif entry.path not in exact:
            exact[entry.path] = i
    return struct(exact = exact, dirs = dirs)

def covering_entry(lookup, path):
    """The `flutter.assets` declaration covering `path`, for failure messages.

    A direct entry covers itself; a trailing-slash directory declaration
    covers every file walked out of it. Falls back to the path itself when
    no declaration covers it (a font asset or a shader path). When several
    declarations cover `path`, the earliest in declaration order wins, the
    way the scan it replaces did.

    Args:
        lookup: A `covering_entry_lookup` index over the declarations.
        path: The walked or declared file path to cover.

    Returns:
        The covering declaration's path, or `path` itself.
    """
    hit = None
    hit_at = None
    if path in lookup.exact:
        hit = path
        hit_at = lookup.exact[path]
    ancestor = ""
    for part in path.split("/")[:-1]:
        ancestor = ancestor + part + "/"
        if ancestor in lookup.dirs and (hit_at == None or lookup.dirs[ancestor] < hit_at):
            hit = ancestor
            hit_at = lookup.dirs[ancestor]
    return hit if hit != None else path
