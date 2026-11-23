"""Variant-aware expansion of pub package `flutter.assets` entries.

flutter_tools parity for `flutter.pub` spokes (`flutter_pub_package.bzl`):

- A file entry bundles its main file plus every resolution variant living
  in a sibling `<N>x` / `<N.M>x` directory (`_AssetDirectoryCache.variantsFor`
  in `packages/flutter_tools/lib/src/asset.dart`), each inheriting the
  entry's `platforms` / `flavors`. A variant-only entry (main absent) is
  accepted; an entry with neither a main file nor a variant fails the fetch.
- A trailing-slash directory entry bundles the directory's own files plus
  each one's variants. Files in deeper subdirectories are not bundled
  (`listSync()` without recursion in `_parseAssetsFromFolder`).
- Every walk is bounded and fails loudly at the bound instead of silently
  dropping files.

The pure core (`list_files_recursive`, `expand_pub_asset_entries`) works
over caller-provided `readdir` / `list_dir` callables so unit tests drive it
with fakes; the spoke passes context-backed adapters and `fail()`s the
fetch on the returned error, which already names the package and the entry
or directory.

Every entry is normalized through `asset_uri.bzl` (string entries read
like `Uri.parse`, map-form entries like `Uri(pathSegments:
path.split('/'))` in flutter_tools 3.47.7): the file is resolved
from the decoded path while the emitted `key` carries the percent-encoded
bundle key. A spelling flutter_tools would not bundle (a query, an
escaping `..`, an invalid escape, ...) refuses here, naming the package,
its pubspec.yaml and the entry.
"""

load(":asset_uri.bzl", "encode_asset_key", "spoke_asset_uri_error")
load(":asset_variant.bzl", _is_asset_variant_dir = "is_asset_variant_dir")
load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND")

visibility(["//flutter/..."])

# Bound for every asset directory walk. Starlark has no `while`, so every
# walk is a bounded `for`; reaching the bound fails loudly (see
# `walk_bound_error`) instead of silently dropping files. This is the
# shared pub spoke walk bound (`PUB_WALK_BOUND` in `flutter_pub_walk.bzl`),
# kept under its old name so existing loads keep working.
PUB_ASSET_LIST_BOUND = PUB_WALK_BOUND

# The variant-directory rule lives in `asset_variant.bzl`; re-exported so
# existing loads of `is_asset_variant_dir` keep working.
is_asset_variant_dir = _is_asset_variant_dir

def walk_bound_error(package_name, directory, bound):
    """The fetch failure for an asset walk that reaches its bound.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and the directory.

    Args:
        package_name: The pub package walked.
        directory: The package-relative directory walked.
        bound: The walk bound reached.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    shown = directory if directory else "."
    return (
        "flutter.pub spoke for \"{pkg}\": asset directory \"{dir}\" holds " +
        "more than {bound} directories; refusing it rather than bundling " +
        "part of the tree."
    ).format(pkg = package_name, dir = shown, bound = bound)

def missing_asset_error(package_name, entry_path):
    """The fetch failure for an asset entry with no main file and no variant.

    Mirrors flutter_tools' `No file or variants found for ...` refusal.
    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and the entry.

    Args:
        package_name: The pub package the entry comes from.
        entry_path: The entry's `path`, as declared in pubspec.yaml.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": no file or variants found for " +
        "asset \"{entry}\"."
    ).format(pkg = package_name, entry = entry_path)

def overlapping_bundle_key_error(package_name, raw_key, other_key):
    """The fetch failure for two entries bundling one file under two keys.

    rules_flutter's `pkg_assets` carries one bundle key per file, so when two
    entries of one package give one file two different keys — only an empty
    segment can do that (`a/b.png` beside `a//b.png`; `a/b.png` beside
    `a//2.0x/b.png`, whose file is the first entry's variant) — the spoke
    fetch fails instead of bundling under a key flutter_tools would not use.
    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and the empty-segment entry,
    and says the spelling is not supported, like every other entry refusal.

    Args:
        package_name: The pub package the entries come from.
        raw_key: The empty-segment entry's raw bundle key (its declared
            spelling, e.g. `a//b.png`).
        other_key: The other bundle key claimed for the same file.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return spoke_asset_uri_error(
        package_name,
        raw_key,
        "it bundles the same file as {other} under a different key".format(
            other = repr(other_key),
        ),
    )

def asset_entry_problem_error(package_name, problem):
    """The fetch failure for one malformed asset entry condition.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and `pubspec.yaml`, then the
    entry and the key.

    Args:
        package_name: The pub package the entry comes from.
        problem: A `struct(path, key, detail)` from the asset entry parser;
            `detail` already words the complaint flutter_tools style, and
            `path` names the entry (`fonts[0]`, `assets[2]`, ...).

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": pubspec.yaml: " +
        "asset \"{entry}\": {detail}"
    ).format(
        pkg = package_name,
        entry = problem.path,
        detail = problem.detail,
    )

def check_asset_entry_problems(package_name, asset_errors):
    """Fail the spoke fetch on the first malformed asset entry, if any.

    A `platforms` / `flavors` value that is not a list of strings, or an
    entry carrying `transformers`, loads today but contradicts
    flutter_tools; refusing it is a breaking change. Each failure names the
    package and `pubspec.yaml`, then the entry and the key.

    Args:
        package_name: The pub package the entries come from.
        asset_errors: The `asset_errors` of `parse_flutter_assets_block`.

    Returns:
        None; fails the fetch on the first problem.
    """
    for problem in asset_errors:
        fail(asset_entry_problem_error(package_name, problem))

def list_files_recursive(readdir, rel_dir, package_name, bound = PUB_ASSET_LIST_BOUND):
    """Walk `rel_dir` and return every file under it, bounded and loud.

    Args:
        readdir: Callable taking a package-relative directory path and
            returning its immediate children as a list of
            `struct(name, is_dir)`. A missing directory returns [].
        rel_dir: Package-relative directory to walk ("" for the package root).
        package_name: The pub package walked, for the bound failure.
        bound: Maximum directory pops; reaching it with work left returns
            `error` instead of silently truncating. Tests drive this small.

    Returns:
        `struct(files, error)`: `files` holds the package-relative path of
        every file under `rel_dir` ([] on error); `error` is "" or the fetch
        failure naming the package and the directory.
    """
    files = []
    stack = [rel_dir]
    for _ in range(bound):
        if not stack:
            break
        current = stack.pop()
        for child in readdir(current):
            child_rel = child.name if current == "" else current + "/" + child.name
            if child.is_dir:
                stack.append(child_rel)
            else:
                files.append(child_rel)
    if stack:
        return struct(files = [], error = walk_bound_error(package_name, rel_dir, bound))
    return struct(files = files, error = "")

def _split_asset_path(path):
    """Split a package-relative path into `(directory, basename)`.

    Args:
        path: A package-relative file path.

    Returns:
        The `(directory, basename)` tuple; directory is "" for top-level files.
    """
    parent, _, base = path.rpartition("/")
    return (parent, base)

def _conditioned_entry(entry, path):
    """One expanded file inheriting its declaring entry's conditions.

    `path` is the decoded file path (what the label names); `key` is its
    percent-encoded bundle key (see `asset_uri.bzl`). A file entry's own
    path keeps the intake key exactly (already normalized, so a
    `packages`-first main file keeps its normalized key); walked files
    encode their listed path, which is filesystem truth and never decodes.

    Args:
        entry: The normalized entry (`struct(path, key, flavors,
            platforms)`); `path` is decoded, `key` encoded.
        path: The decoded file path to emit.
    """
    if path == entry.path:
        key = entry.key
    else:
        key = encode_asset_key(path)
    return struct(path = path, key = key, flavors = entry.flavors, platforms = entry.platforms)

def _memoized_reader(reader):
    """Wrap a directory `reader` so each distinct directory is read once.

    The pub asset expansion and the spoke lister both resolve many entries
    against few directories; without memoization K file entries under one
    directory would read it K times. The cache lives for one fetch.

    Args:
        reader: Callable taking a directory path and returning its listing.

    Returns:
        A callable with the same shape that reads each directory once.
    """
    cache = {}

    def cached(rel_dir):
        """The cached read of `rel_dir`."""
        if rel_dir not in cache:
            cache[rel_dir] = reader(rel_dir)
        return cache[rel_dir]

    return cached

def _index_listed_files(directory, files):
    """Index one directory listing for linear asset resolution.

    Partitions `files` into the directory's own files (a sorted list plus
    an exact-membership dict) and, per basename, the files living directly
    inside its immediate resolution-variant subdirectories
    (`is_asset_variant_dir`). Files deeper in the tree, or under a
    non-variant subdirectory, land in neither — mirroring `variantsFor`,
    which only consults the directory itself and its immediate variant
    subdirectories. Every entry below then resolves through dict lookups.

    Args:
        directory: The listed directory path ("" for the package root).
        files: Every file path the listing returned for it.

    Returns:
        A struct `(own, own_set, variants)`: `own` the sorted own files,
        `own_set` the same paths as a membership dict, `variants` a dict
        from basename to that basename's sorted variant paths.
    """
    own = []
    own_set = {}
    variants = {}
    for f in files:
        parent, _, base = f.rpartition("/")
        if parent == directory:
            own.append(f)
            own_set[f] = True
        else:
            grandparent, _, vdir = parent.rpartition("/")
            if grandparent == directory and is_asset_variant_dir(vdir):
                variants.setdefault(base, []).append(f)
    return struct(
        own = sorted(own),
        own_set = own_set,
        variants = {base: sorted(paths) for base, paths in variants.items()},
    )

def _overlapping_bundle_key(expanded):
    """The first file two entries bundle under different keys, if any.

    `pkg_assets` maps each file to one bundle key, so one file claimed under
    two keys cannot bundle: only an empty-segment entry can claim a second
    key for a file (`a//b.png` for `a/b.png`; `a//2.0x/b.png` for the
    `a/2.0x/b.png` variant another entry finds). A lone entry never triggers
    this: its raw key and its collapsed files each name their own path.

    Args:
        expanded: Per-file entries in declaration order, each a
            `struct(path, key, flavors, platforms)` with the decoded file and
            the encoded bundle key.

    Returns:
        `struct(raw, other)` naming the empty-segment key and the other key
        for the same file, or None when every file carries one key.
    """
    seen = {}
    for entry in expanded:
        if entry.path not in seen:
            seen[entry.path] = entry.key
        elif seen[entry.path] != entry.key:
            first = seen[entry.path]
            if "" in entry.key.split("/"):
                return struct(raw = entry.key, other = first)
            return struct(raw = first, other = entry.key)
    return None

def _asset_scope(list_dir, package_name):
    """Bundle one expansion's memoized listing reader and index cache.

    Args:
        list_dir: Callable taking a directory path (no trailing slash, ""
            for the package root) and returning `struct(files, error)`.
        package_name: The pub package the entries come from, for failures.

    Returns:
        A struct `(list_dir, index, package_name)`: the memoized reader,
        the per-directory index cache (built once per directory), and the
        package name.
    """
    return struct(
        list_dir = _memoized_reader(list_dir),
        index = {},
        package_name = package_name,
    )

def _scope_index(scope, rel_dir):
    """The listing index for `rel_dir`, read and built once per expansion.

    Args:
        scope: An `_asset_scope` struct, updated in place.
        rel_dir: The directory path to index.

    Returns:
        A struct `(error, listing)`: `error` is "" or the listing failure,
        and `listing` is the `_index_listed_files` result (None on error).
    """
    if rel_dir not in scope.index:
        listed = scope.list_dir(rel_dir)
        if listed.error:
            scope.index[rel_dir] = struct(error = listed.error, listing = None)
        else:
            scope.index[rel_dir] = struct(
                error = "",
                listing = _index_listed_files(rel_dir, listed.files),
            )
    return scope.index[rel_dir]

def _expand_directory_entry(entry, scope, expanded):
    """Bundle a trailing-slash entry's own files plus each one's variants.

    Args:
        entry: The normalized entry (`struct(path, key, flavors,
            platforms)`); `path` is decoded with its trailing `/`.
        scope: An `_asset_scope` struct; the entry's directory is read
            and indexed once per expansion.
        expanded: The output list to append `struct(path, key, flavors,
            platforms)` entries to.

    Returns:
        "" or the fetch failure (a walk bound, already naming the package
        and the directory).
    """
    indexed = _scope_index(scope, entry.path.rstrip("/"))
    if indexed.error:
        return indexed.error
    for main in indexed.listing.own:
        expanded.append(_conditioned_entry(entry, main))
        for variant in indexed.listing.variants.get(_split_asset_path(main)[1], []):
            expanded.append(_conditioned_entry(entry, variant))
    return ""

def _expand_file_entry(entry, scope, expanded):
    """Bundle a file entry's main file (when present) plus its variants.

    Args:
        entry: The normalized entry (`struct(path, key, flavors,
            platforms)`); `path` names the decoded file.
        scope: An `_asset_scope` struct, as in `_expand_directory_entry`.
        expanded: The output list to append to.

    Returns:
        "" or the fetch failure: a walk bound, or `missing_asset_error`
        when neither the main file nor any variant exists.
    """
    parent, base = _split_asset_path(entry.path)
    indexed = _scope_index(scope, parent)
    if indexed.error:
        return indexed.error
    found_main = entry.path in indexed.listing.own_set
    variants = indexed.listing.variants.get(base, [])
    if not found_main and not variants:
        return missing_asset_error(scope.package_name, entry.path)
    if found_main:
        expanded.append(_conditioned_entry(entry, entry.path))
    for variant in variants:
        expanded.append(_conditioned_entry(entry, variant))
    return ""

def expand_pub_asset_entries(normalized_assets, list_dir, package_name = ""):
    """Expand normalized `flutter.assets` entries to one struct per bundled file.

    Pure core of the spoke's asset expansion: file entries resolve to their
    main file plus resolution variants (variant-only entries are accepted),
    directory entries to their own files plus each one's variants. Every
    emitted file inherits its declaring entry's `platforms` / `flavors`.
    Each distinct directory is read and indexed once no matter how many
    entries name it, so directory and file entries both resolve in time
    linear in the number of files.

    The entries arrive already normalized (see `normalize_spoke_assets`):
    `path` names the decoded file, `key` its encoded bundle key, and a
    trailing `/` still marks a directory entry. Nothing here decodes again,
    so no entry text is decoded twice between the pubspec and the spoke
    dicts; walked files encode their listed path, which is filesystem truth.

    Args:
        normalized_assets: List of `struct(path, key, flavors, platforms)`
            from `normalize_spoke_assets` (decoded paths, encoded keys).
        list_dir: Callable taking a directory path (no trailing slash, ""
            for the package root) and returning `struct(files, error)` with
            every file under it. Tests pass a fake; the spoke passes a
            context-backed lister (see `ctx_package_lister`).
        package_name: The pub package the entries come from, for failures.

    Returns:
        `struct(expanded, error)`: `expanded` holds one
        `struct(path, key, flavors, platforms)` per bundled file (in
        declaration order, mains before their variants; `path` names the
        decoded file, `key` its encoded bundle key); `error` is "" or the
        fetch failure naming the package and the entry or directory, or the
        empty-segment entry when two entries give one file two bundle keys
        (see `overlapping_bundle_key_error`). The caller `fail()`s on it.
    """
    scope = _asset_scope(list_dir, package_name)
    expanded = []
    for entry in normalized_assets:
        if entry.path.endswith("/"):
            error = _expand_directory_entry(entry, scope, expanded)
        else:
            error = _expand_file_entry(entry, scope, expanded)
        if error:
            return struct(expanded = [], error = error)
    overlap = _overlapping_bundle_key(expanded)
    if overlap != None:
        return struct(
            expanded = [],
            error = overlapping_bundle_key_error(package_name, overlap.raw, overlap.other),
        )
    return struct(expanded = expanded, error = "")

def _ctx_readdir(ctx, directory):
    """The immediate children of a spoke directory as `struct(name, is_dir)`."""
    base = ctx.path(directory if directory else ".")
    if not base.exists:
        return []
    return [struct(name = child.basename, is_dir = child.is_dir) for child in base.readdir()]

def _shallow_asset_files(readdir, rel_dir, package_name, bound = PUB_ASSET_LIST_BOUND):
    """List one asset directory the way flutter_tools reads it, bounded and loud.

    Reads the directory's own entries plus the entries directly inside its
    immediate resolution-variant subdirectories (`is_asset_variant_dir`) —
    the two listings `_AssetDirectoryCache.variantsFor` in
    `packages/flutter_tools/lib/src/asset.dart` consults — and nothing
    deeper. Needs one read for the directory itself plus one per variant
    subdirectory; needing more than `bound` returns `error` instead of
    silently truncating, the same `walk_bound_error` failure the recursive
    walk reports.

    Args:
        readdir: Callable taking a package-relative directory path and
            returning its immediate children as a list of
            `struct(name, is_dir)`. A missing directory returns [].
        rel_dir: Package-relative directory to list ("" for the package root).
        package_name: The pub package listed, for the bound failure.
        bound: Maximum directory reads; needing more returns `error`
            instead of silently truncating. Tests drive this small.

    Returns:
        `struct(files, error)`: `files` holds the package-relative paths of
        the directory's own files plus the files directly inside its
        variant subdirectories ([] on error); `error` is "" or the fetch
        failure naming the package and the directory.
    """
    own = []
    variant_dirs = []
    for child in readdir(rel_dir):
        if child.is_dir:
            if is_asset_variant_dir(child.name):
                variant_dirs.append(child.name)
        elif rel_dir == "":
            own.append(child.name)
        else:
            own.append(rel_dir + "/" + child.name)
    if 1 + len(variant_dirs) > bound:
        return struct(files = [], error = walk_bound_error(package_name, rel_dir, bound))
    files = list(own)
    for vdir in variant_dirs:
        vrel = vdir if rel_dir == "" else rel_dir + "/" + vdir
        for child in readdir(vrel):
            if not child.is_dir:
                files.append(vrel + "/" + child.name)
    return struct(files = files, error = "")

def _asset_lister(readdir, package_name, bound = PUB_ASSET_LIST_BOUND):
    """A memoized shallow `list_dir` over `readdir`, for tests and the spoke.

    Each distinct directory is read once through `_shallow_asset_files`;
    file entries sharing a parent reuse its listing. This keeps its own
    closure rather than reusing `_memoized_reader`: the lister always flows
    into `expand_pub_asset_entries`, which memoizes again, and Bazel refuses
    to re-enter one closure factory's function object.

    Args:
        readdir: Callable taking a package-relative directory path and
            returning its immediate children as a list of
            `struct(name, is_dir)`.
        package_name: The pub package listed, for the bound failure.
        bound: Maximum directory reads per listed directory.

    Returns:
        A `list_dir` callable as `expand_pub_asset_entries` takes it.
    """
    cache = {}

    def list_dir(rel_dir):
        """The cached shallow listing of `rel_dir`."""
        if rel_dir not in cache:
            cache[rel_dir] = _shallow_asset_files(readdir, rel_dir, package_name, bound)
        return cache[rel_dir]

    return list_dir

def ctx_package_lister(ctx, package_name, bound = PUB_ASSET_LIST_BOUND):
    """The spoke's `list_dir` for `expand_pub_asset_entries`, memoized.

    Reads through `_shallow_asset_files` with the fetch's bound: the
    directory's own files plus its immediate variant subdirectories' files,
    the same two listings flutter_tools reads, never deeper trees. A read
    that needs more than the bound fails the fetch naming the package and
    the directory rather than bundling part of the tree. One read per
    distinct directory: file entries sharing a parent reuse it.

    Args:
        ctx: The spoke's repository context.
        package_name: The pub package walked, for the bound failure.
        bound: Maximum directory reads per listed directory.

    Returns:
        A `list_dir` callable as `expand_pub_asset_entries` takes it.
    """
    return _asset_lister(
        lambda directory: _ctx_readdir(ctx, directory),
        package_name,
        bound,
    )

def pub_shader_condition_entries(expanded, normalized_shaders, parsed_shaders):
    """The asset entries plus the per-file condition entries for a spoke's `pkg_shaders`.

    A shader entry carries the same `platforms` / `flavors` conditions as an
    asset entry, keyed the same way (`":" + path`), because the spoke passes
    both channels through one pair of attrs, `pkg_asset_platforms` and
    `pkg_asset_flavors`. The caller merges these entries together with the
    asset entries exactly as asset entries are merged
    (`build_pkg_asset_conditions`), flavor-conflict refusal included; this
    function returns the asset entries followed by the shader entries so that
    call takes one list.

    When a `flutter.assets` entry (such as a directory walk) already covers a
    file that `flutter.shaders` also lists, both `pkg_assets` and `pkg_shaders`
    on the generated spoke still receive the file so rule analysis fails in
    `check_asset_shader_conflict`, naming both entries; skipping the duplicate
    condition key here keeps condition merging from failing first on flavor
    disagreement.

    Normalization keeps one entry per parsed entry in order, so the two
    shader lists pair by index.

    Args:
        expanded: Per-file asset entries from `expand_pub_asset_entries`.
        normalized_shaders: `struct(path, key)` entries from
            `normalize_spoke_shaders`.
        parsed_shaders: The parsed `struct(path, is_map, flavors, platforms)`
            entries they came from, in the same order.

    Returns:
        `expanded` followed by a `struct(path, flavors, platforms)` per shader
        whose path is not already in `expanded`.
    """
    asset_paths = {entry.path: True for entry in expanded}
    return expanded + [
        struct(
            path = entry.path,
            flavors = parsed_shaders[index].flavors,
            platforms = parsed_shaders[index].platforms,
        )
        for index, entry in enumerate(normalized_shaders)
        if entry.path not in asset_paths
    ]
