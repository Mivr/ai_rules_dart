"""The `swiftpm_package` repository rule: one fetched SwiftPM spoke.

Each SwiftPM pin in `Package.resolved` becomes a `<hub>__swiftpm-<identity>`
repo holding the pinned sources and a generated BUILD file. The fetch is
fail-closed throughout: an unpinned entry fails before any download (naming
the `swift_package_sha256` fix), the archive must hold one top-level
directory with the plain `Package.swift` manifest, and every source
refusal from the translator fails here. The archive's top-level directory
becomes the repository root, so the generated BUILD and a
`swift_package_build_files` override both see `Package.swift` and
`Sources/...` at the root whatever the revision. An override still
downloads the pinned archive but skips the translation, writing the
hand-written file as-is.
"""

load(":download.bzl", "pinned_download_and_extract")
load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "has_files_bound_error")
load(":swiftpm_clang.bzl", "swiftpm_clang_module_spec", "swiftpm_generated_modulemap_content")
load(":swiftpm_headers.bzl", "swiftpm_split_headers")
load(":swiftpm_manifest.bzl", "parse_swiftpm_package")
load(":swiftpm_paths.bzl", "swiftpm_join_path", "swiftpm_normalize_relative_path")
load(
    ":swiftpm_translate.bzl",
    "swiftpm_c99name",
    "swiftpm_reachable_targets",
    "translate_swiftpm_package",
)

visibility(["//flutter/..."])

# The archive extracts here first; its single top-level directory (named
# `<Repo>-<revision>` by GitHub) is then moved up to become the repo root.
_SWIFTPM_EXTRACT_DIR = ".swiftpm_extract"

_SWIFTPM_DEFAULT_DIRS = ["Sources", "Source", "src", "srcs"]

def _swiftpm_repo_fail(identity, detail):
    """The fetch failure for fetch-level (non-manifest) refusals.

    Args:
        identity: The SwiftPM package identity.
        detail: What was found and why it is unsupported.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return "SwiftPM package {identity}: {detail}.".format(identity = repr(identity), detail = detail)

def _swiftpm_check_entry(identity, target_name, entry, kind):
    """Normalize one path/sources/exclude entry and refuse only an escape.

    SwiftPM drops empty and `.` segments and a trailing `/`, so those
    spellings stay inside the target; only an absolute path or one whose
    `..` reaches above the target is refused.

    Args:
        identity: The SwiftPM package identity.
        target_name: The target holding the entry, for messages.
        entry: The manifest entry string.
        kind: The manifest key, for messages.

    Returns:
        `struct(ok, error, path)`: `path` is the normalized entry (`""`
        for the target directory itself), or `error` is the fetch failure.
    """
    normalized = swiftpm_normalize_relative_path(entry)
    if not normalized.ok:
        detail = "target {target} has an {kind} entry {entry} escaping the target directory".format(
            target = repr(target_name),
            kind = kind,
            entry = repr(entry),
        )
        return struct(ok = False, error = _swiftpm_repo_fail(identity, detail), path = "")
    return struct(ok = True, error = "", path = normalized.path)

def _swiftpm_package_root(ctx, identity):
    """Read the extracted archive's single top-level directory.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.

    Returns:
        `struct(ok, error, root)`: `root` is the directory's basename under
        the extraction directory.
    """
    children = ctx.path(_SWIFTPM_EXTRACT_DIR).readdir()
    dirs = [child.basename for child in children if child.is_dir]
    if len(children) != 1 or len(dirs) != 1:
        shown = sorted([child.basename for child in children])
        if len(shown) > 8:
            shown = shown[:8] + ["... ({count} entries)".format(count = len(children))]
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "expected the archive to hold one top-level directory (the package root), got {entries}".format(entries = shown)), root = "")
    return struct(ok = True, error = "", root = dirs[0])

def swiftpm_hoist_package_root(ctx, identity):
    """Move the archive's top-level directory contents to the repo root.

    The spoke's repository root becomes the package root, so the generated
    BUILD file and a `swift_package_build_files` override both see
    `Package.swift` and `Sources/...` whatever the pinned revision is.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.

    Returns:
        The fetch failure, or "".
    """
    root = _swiftpm_package_root(ctx, identity)
    if not root.ok:
        return root.error
    top = _SWIFTPM_EXTRACT_DIR + "/" + root.root
    for child in ctx.path(top).readdir():
        ctx.rename(top + "/" + child.basename, child.basename)
    ctx.delete(_SWIFTPM_EXTRACT_DIR)
    return ""

def _swiftpm_manifest_filename(ctx, identity):
    """Require the plain `Package.swift` manifest at the package root.

    A versioned `Package@swift-*.swift` sitting next to it fails the
    fetch naming it: the translator reads only the plain manifest, and
    silently ignoring a versioned sibling could build stale sources.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.

    Returns:
        `struct(ok, error, filename)`: the manifest basename.
    """
    if not ctx.path("Package.swift").exists:
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "no `Package.swift` manifest at the archive top level"), filename = "")
    versioned = [
        child.basename
        for child in ctx.path(".").readdir()
        if not child.is_dir and child.basename.startswith("Package@swift-") and child.basename.endswith(".swift")
    ]
    if versioned:
        msg = "versioned manifest(s) ({names}) sit next to `Package.swift`: only the plain manifest is translated, so remove them or point at a hand-written BUILD file with swift_package_build_files[{identity}]".format(
            names = sorted(versioned),
            identity = repr(identity),
        )
        return struct(ok = False, error = _swiftpm_repo_fail(identity, msg), filename = "")
    return struct(ok = True, error = "", filename = "Package.swift")

def _swiftpm_resolve_target_dir(ctx, identity, target):
    """Resolve one reached target's directory.

    An explicit `path:` is normalized first, so `.`, `./` and `""` name the
    package root, and it must then name an existing directory inside that
    root; an absent `path:` (None) instead takes the first existing
    `Sources/<name>`, `Source/<name>`, `src/<name>` or `srcs/<name>`.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        target: The target struct.

    Returns:
        `struct(ok, error, rel_dir)`: the repo-relative directory.
    """
    if target.path != None:
        checked = _swiftpm_check_entry(identity, target.name, target.path, "`path:`")
        if not checked.ok:
            return struct(ok = False, error = checked.error, rel_dir = "")
        rel_dir = checked.path
        node = ctx.path(rel_dir)
        if not node.exists or not node.is_dir:
            msg = "target {target} names a missing directory in `path:` ({dir})".format(
                target = repr(target.name),
                dir = repr(target.path),
            )
            return struct(ok = False, error = _swiftpm_repo_fail(identity, msg), rel_dir = "")
        return struct(ok = True, error = "", rel_dir = rel_dir)
    for base in _SWIFTPM_DEFAULT_DIRS:
        rel_dir = base + "/" + target.name
        node = ctx.path(rel_dir)
        if node.exists and node.is_dir:
            return struct(ok = True, error = "", rel_dir = rel_dir)
    dirs = [base + "/" + target.name for base in _SWIFTPM_DEFAULT_DIRS]
    msg = "target {target} has no `path:` and none of {dirs} exist".format(
        target = repr(target.name),
        dirs = dirs,
    )
    return struct(ok = False, error = _swiftpm_repo_fail(identity, msg), rel_dir = "")

# One table sorts every target file by its extension. The source and header
# spellings are the union the selector and `swiftpm_is_code_file` used to keep
# apart; the resource spellings are the types SwiftPM processes without a
# `resources:` declaration (`TargetSourcesBuilder`'s xcbuild rules and the
# localization directories it treats the same way).
_SWIFTPM_FILE_KINDS = {
    "C": "clang",
    "M": "clang",
    "S": "clang",
    "asm": "clang",
    "c": "clang",
    "c++": "clang",
    "cc": "clang",
    "cp": "clang",
    "cpp": "clang",
    "cxx": "clang",
    "m": "clang",
    "mm": "clang",
    "s": "clang",
    "h": "header",
    "hh": "header",
    "hpp": "header",
    "hxx": "header",
    "inc": "header",
    "lproj": "resource",
    "metal": "resource",
    "modulemap": "modulemap",
    "nib": "resource",
    "storyboard": "resource",
    "swift": "swift",
    "xcassets": "resource",
    "xcdatamodel": "resource",
    "xcdatamodeld": "resource",
    "xcmappingmodel": "resource",
    "xcprivacy": "resource",
    "xcstrings": "resource",
    "xib": "resource",
}

def _swiftpm_extension(basename):
    """The extension after a basename's last dot, or "" when it has none.

    Args:
        basename: The file or directory basename (no directory).

    Returns:
        The extension without its dot, or "".
    """
    dot = basename.rfind(".")
    return "" if dot < 0 else basename[dot + 1:]

def _swiftpm_file_kind(basename):
    """Sort one basename into Swift, C-family, header, module map, resource or skip.

    Args:
        basename: The file's basename (no directory).

    Returns:
        `"swift"`, `"clang"`, `"header"`, `"modulemap"`, `"resource"` or
        `"skip"`. A resource is a type SwiftPM processes without a
        `resources:` declaration, so the selector refuses it; any other
        file with no Bazel translation — READMEs, licenses, notes,
        images, DocC input — is skipped the way SwiftPM ignores
        unhandled files with a warning.
    """
    return _SWIFTPM_FILE_KINDS.get(_swiftpm_extension(basename), "skip")

def swiftpm_is_code_file(basename):
    """Whether a non-Swift filename is C-family code, a header or a module map.

    The target file selector translates these instead of skipping them
    the way it skips files with no Bazel translation (READMEs, licenses,
    notes, images, DocC input), which SwiftPM ignores with a warning. It
    shares `_SWIFTPM_FILE_KINDS` with `_swiftpm_file_kind`, so the public
    predicate and the selector cannot disagree about an extension.

    Args:
        basename: The file's basename (no directory).

    Returns:
        True for C-family sources and headers plus module maps.
    """
    return _swiftpm_file_kind(basename) in ["clang", "header", "modulemap"]

def _swiftpm_resource_path(rel):
    """The resource a target-relative path belongs to, or "".

    SwiftPM's built-in rules process asset catalogs, interface-builder
    files, Core Data models, Metal shaders, string catalogs, privacy
    manifests and everything under a `.lproj` directory as resources
    even when the manifest declares no `resources:`, which is why the
    selector refuses them instead of dropping bytes SwiftPM bundles.

    Args:
        rel: The path relative to the target directory.

    Returns:
        The leading file or directory segment that is the resource, or
        "" when the path holds no resource.
    """
    segments = rel.split("/")
    for index, segment in enumerate(segments):
        if _SWIFTPM_FILE_KINDS.get(_swiftpm_extension(segment), "") == "resource":
            return "/".join(segments[:index + 1])
    return ""

def _swiftpm_resource_error(identity, target_name, path):
    """The fetch failure for one implicitly processed resource.

    Args:
        identity: The SwiftPM package identity.
        target_name: The target holding the resource, for messages.
        path: The repo-relative resource path.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return _swiftpm_repo_fail(identity, "target {target} holds implicit resource {path}, which has no Bazel translation. Point at a hand-written BUILD file with swift_package_build_files[{identity}] = \"<label>\" to build it another way, or list the resource in the target's `exclude:`".format(
        target = repr(target_name),
        path = repr(path),
        identity = repr(identity),
    ))

def _swiftpm_find_resource_error(identity, target_name, rel_dir, excluded, files, dirs):
    """Find the first implicitly processed resource in a target tree.

    Args:
        identity: The SwiftPM package identity.
        target_name: The target holding the resource, for messages.
        rel_dir: The repo-relative target directory.
        excluded: The repo-relative excluded paths.
        files: Every file under the target directory (a dict set of
            repo-relative paths).
        dirs: Every directory under the target directory (a dict set of
            repo-relative paths).

    Returns:
        The fetch failure for the first resource, or "" when the target
        holds none.
    """
    for full in sorted(dirs.keys()) + sorted(files.keys()):
        if _swiftpm_is_under(full, excluded):
            continue
        rel = full[len(rel_dir) + 1:]
        if _swiftpm_under_docc(rel):
            continue
        resource = _swiftpm_resource_path(rel)
        if resource:
            return _swiftpm_resource_error(identity, target_name, swiftpm_join_path(rel_dir, resource))
    return ""

def _swiftpm_is_under(full, roots):
    """Whether a repo-relative path is one of `roots` or sits under one.

    Args:
        full: The repo-relative path.
        roots: The repo-relative root paths (a list).

    Returns:
        True on an exact or `/`-boundary prefix match.
    """
    for root in roots:
        if full == root or full.startswith(root + "/"):
            return True
    return False

def _swiftpm_under_docc(rel):
    """Whether a target-relative path sits inside a DocC catalog directory.

    SwiftPM ignores `<Name>.docc` catalogs by rule, so their contents are
    skipped like any other file with no translation.

    Args:
        rel: The path relative to the target directory.

    Returns:
        True when any leading directory segment ends in `.docc`.
    """
    segments = rel.split("/")
    for segment in segments[:len(segments) - 1]:
        if segment.endswith(".docc"):
            return True
    return False

def _swiftpm_keep_existing(identity, target_name, kind, entries, rel_dir, tree):
    """Drop entries naming nothing on disk, fail entries escaping the dir.

    Args:
        identity: The SwiftPM package identity.
        target_name: The target holding the entries, for messages.
        kind: "`exclude:`" or "`sources:`", for messages.
        entries: The manifest entry strings.
        rel_dir: The repo-relative target directory.
        tree: The `struct(files, dirs)` listing from
            `_swiftpm_list_target_tree`.

    Returns:
        `struct(ok, error, kept, all)`: `kept` holds the repo-relative
        paths that exist (or the target directory itself for an entry
        that normalizes away); `all` holds every normalized entry,
        whether or not it exists.
    """
    kept = []
    every = []
    for entry in entries:
        checked = _swiftpm_check_entry(identity, target_name, entry, kind)
        if not checked.ok:
            return struct(ok = False, error = checked.error, kept = [], all = [])
        full = swiftpm_join_path(rel_dir, checked.path)
        every.append(full)
        if checked.path == "" or full in tree.files or full in tree.dirs:
            kept.append(full)
    return struct(ok = True, error = "", kept = kept, all = every)

def _swiftpm_public_root(identity, target, rel_dir):
    """Resolve the repo-relative public-headers directory of one target.

    `include` unless the manifest sets `publicHeadersPath:`; an explicit
    `""` or `"."` is the target directory itself, which is not the same as
    leaving the argument out.

    Args:
        identity: The SwiftPM package identity.
        target: The target struct (`name`, `public_headers_path`).
        rel_dir: The repo-relative target directory.

    Returns:
        `struct(ok, error, root)`.
    """
    if target.public_headers_path == None:
        return struct(ok = True, error = "", root = swiftpm_join_path(rel_dir, "include"))
    checked = _swiftpm_check_entry(identity, target.name, target.public_headers_path, "`publicHeadersPath:`")
    root = swiftpm_join_path(rel_dir, checked.path) if checked.ok else ""
    return struct(ok = checked.ok, error = checked.error, root = root)

def _swiftpm_target_files_failure(error):
    """Return an error struct for `swiftpm_select_target_files`.

    Args:
        error: The failure error string.

    Returns:
        A failed `swiftpm_select_target_files` result struct.
    """
    return struct(
        ok = False,
        error = error,
        srcs = [],
        c_srcs = [],
        public_hdrs = [],
        private_hdrs = [],
        explicit_map = None,
        map_in_include = False,
    )

def swiftpm_select_target_files(identity, target, rel_dir, files, dirs):
    """Select one reached target's Swift and C-family files, purely.

    `exclude:` and `sources:` entries that escape the target directory fail
    the fetch; entries naming nothing on disk drop out, the way SwiftPM warns
    and builds with the files that exist. Every remaining file under the
    target directory contributes its `.swift` sources, its C-family sources
    and headers (split into public and private, with the explicit module
    map when the target ships one), except DocC catalog contents and other
    files with no Bazel translation, which are skipped. A resource SwiftPM
    processes without a `resources:` declaration — an asset catalog,
    interface-builder file, Core Data model, Metal shader, string catalog,
    privacy manifest or `.lproj` content — fails the fetch naming the
    resource, because the generated BUILD cannot bundle it; an `exclude:`
    entry that removes it removes the refusal, and `sources:` does not hide
    it because SwiftPM still processes resources outside the source list.

    Args:
        identity: The SwiftPM package identity.
        target: The target struct (`name`, `exclude`, `sources`,
            `public_headers_path`).
        rel_dir: The repo-relative target directory.
        files: Every file under the target directory (a dict set of
            repo-relative paths).
        dirs: Every directory under the target directory (a dict set of
            repo-relative paths).

    Returns:
        `struct(ok, error, srcs, c_srcs, public_hdrs, private_hdrs,
        explicit_map, map_in_include)`: the sorted repo-relative paths;
        `explicit_map` is None unless the target ships one.
    """
    tree = struct(files = files, dirs = dirs)
    excluded = _swiftpm_keep_existing(identity, target.name, "`exclude:`", target.exclude, rel_dir, tree)
    if not excluded.ok:
        return _swiftpm_target_files_failure(excluded.error)
    listed = None
    if target.sources != None:
        narrowed = _swiftpm_keep_existing(identity, target.name, "`sources:`", target.sources, rel_dir, tree)
        if not narrowed.ok:
            return _swiftpm_target_files_failure(narrowed.error)
        listed = narrowed.kept
    resource_excludes = excluded.all
    resource_error = _swiftpm_find_resource_error(identity, target.name, rel_dir, resource_excludes, files, dirs)
    if resource_error:
        return _swiftpm_target_files_failure(resource_error)
    public_root = _swiftpm_public_root(identity, target, rel_dir)
    if not public_root.ok:
        return _swiftpm_target_files_failure(public_root.error)
    srcs = []
    c_srcs = []
    headers = []
    unlisted_headers = []
    for full in files.keys():
        if _swiftpm_is_under(full, excluded.kept):
            continue
        rel = full[len(rel_dir) + 1:]
        if _swiftpm_under_docc(rel):
            continue
        kind = _swiftpm_file_kind(full[full.rfind("/") + 1:])
        if listed != None and not _swiftpm_is_under(full, listed):
            # `sources:` only drops the automatic compile rule, so a header
            # in the public-headers directory stays public.
            if kind == "header":
                unlisted_headers.append(full)
            continue
        if kind == "swift":
            srcs.append(full)
        elif kind == "clang":
            c_srcs.append(full)
        elif kind == "header":
            headers.append(full)
    if not srcs and not c_srcs:
        err = _swiftpm_repo_fail(identity, "target {target} reaches zero Swift files".format(target = repr(target.name)))
        return _swiftpm_target_files_failure(err)
    split = swiftpm_split_headers(
        public_root.root,
        rel_dir,
        struct(listed = headers, unlisted = unlisted_headers),
        files,
    )
    return struct(
        ok = True,
        error = "",
        srcs = sorted(srcs),
        c_srcs = sorted(c_srcs),
        public_hdrs = split.public_hdrs,
        private_hdrs = split.private_hdrs,
        explicit_map = split.explicit_map,
        map_in_include = split.map_in_include,
    )

def _swiftpm_list_target_tree(ctx, identity, rel_dir):
    """List every file and directory under one target directory, bounded.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        rel_dir: The repo-relative target directory.

    Returns:
        `struct(ok, error, files, dirs)`: dict sets of repo-relative paths.
    """
    files = {}
    dirs = {}
    stack = [rel_dir]
    for _ in range(PUB_WALK_BOUND):
        if not stack:
            break
        current = stack.pop()
        for child in ctx.path(current).readdir():
            full = swiftpm_join_path(current, child.basename)
            if child.is_dir:
                dirs[full] = True
                stack.append(full)
            else:
                files[full] = True
    if stack:
        err = has_files_bound_error(identity, rel_dir, PUB_WALK_BOUND)
        return struct(ok = False, error = err, files = {}, dirs = {})
    return struct(ok = True, error = "", files = files, dirs = dirs)

def _swiftpm_collect_sources(ctx, identity, target):
    """Resolve one reached target's directory and explicit file lists.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        target: The target struct.

    Returns:
        `struct(ok, error, files)`: `files` is `struct(dir, srcs, c_srcs,
        public_hdrs, private_hdrs, explicit_map, map_in_include)` with
        the repo-relative directory, Swift sources, C-family sources,
        headers and explicit module map.
    """
    resolved = _swiftpm_resolve_target_dir(ctx, identity, target)
    if not resolved.ok:
        return struct(ok = False, error = resolved.error, files = None)
    listed = _swiftpm_list_target_tree(ctx, identity, resolved.rel_dir)
    if not listed.ok:
        return struct(ok = False, error = listed.error, files = None)

    # SwiftPM never treats the package manifest as a source, and a target
    # whose `path:` is the package root (`.`) contains it.
    manifest = "Package.swift"
    files = {path: True for path in listed.files.keys() if path != manifest}
    selected = swiftpm_select_target_files(identity, target, resolved.rel_dir, files, listed.dirs)
    if not selected.ok:
        return struct(ok = False, error = selected.error, files = None)
    collected = struct(
        dir = resolved.rel_dir,
        srcs = selected.srcs,
        c_srcs = selected.c_srcs,
        public_hdrs = selected.public_hdrs,
        private_hdrs = selected.private_hdrs,
        explicit_map = selected.explicit_map,
        map_in_include = selected.map_in_include,
    )
    return struct(ok = True, error = "", files = collected)

def _swiftpm_write_generated_map(identity, target, files):
    """Write one C-family target's generated umbrella module map, if any.

    Targets shipping an explicit `module.modulemap`, or with no public
    headers at all (link-only), need no map. Anything else gets
    `<public>/module.modulemap` in its public-headers directory, which
    the translated `cc_library`/`objc_library` points at through
    `swift_interop_hint`.

    Args:
        identity: The SwiftPM package identity.
        target: The target struct.
        files: The collected files struct from `_swiftpm_collect_sources`.

    Returns:
        `struct(ok, error, path, content)`: `path` is "" when the target
        needs no generated map.
    """
    if not files.c_srcs or files.explicit_map != None:
        return struct(ok = True, error = "", path = "", content = "")
    c99 = swiftpm_c99name(target.name)
    spec = swiftpm_clang_module_spec(target, c99, files.dir, files.c_srcs, files.public_hdrs, None)
    if not spec.ok:
        return struct(ok = False, error = _swiftpm_repo_fail(identity, spec.detail), path = "", content = "")
    if spec.module_map == None:
        return struct(ok = True, error = "", path = "", content = "")
    content = swiftpm_generated_modulemap_content(
        c99,
        spec.umbrella_header,
        spec.include_dir,
        files.public_hdrs,
    )
    return struct(ok = True, error = "", path = spec.module_map, content = content)

def _swiftpm_package_impl(ctx):
    identity = ctx.attr.identity
    if ctx.attr.unpinned_error:
        fail(ctx.attr.unpinned_error)
    pinned_download_and_extract(
        ctx,
        url = ctx.attr.archive_url,
        sha256 = ctx.attr.sha256,
        output = _SWIFTPM_EXTRACT_DIR,
    )
    hoist_error = swiftpm_hoist_package_root(ctx, identity)
    if hoist_error:
        fail(hoist_error)
    if ctx.attr.build_file:
        ctx.file("BUILD.bazel", ctx.read(ctx.path(ctx.attr.build_file)))
        return ctx.repo_metadata(reproducible = True)
    manifest = _swiftpm_manifest_filename(ctx, identity)
    if not manifest.ok:
        fail(manifest.error)
    parsed = parse_swiftpm_package(identity, ctx.read(manifest.filename))
    if not parsed.ok:
        fail(parsed.error)
    reached = swiftpm_reachable_targets(identity, parsed.model, None, ctx.attr.hub_name)
    if not reached.ok:
        fail(reached.error)
    by_name = {target.name: target for target in parsed.model.targets}
    files_by_target = {}
    for name in reached.names:
        collected = _swiftpm_collect_sources(ctx, identity, by_name[name])
        if not collected.ok:
            fail(collected.error)
        files_by_target[name] = collected.files
        generated = _swiftpm_write_generated_map(identity, by_name[name], collected.files)
        if not generated.ok:
            fail(generated.error)
        if generated.path:
            ctx.file(generated.path, generated.content)
    translated = translate_swiftpm_package(identity, ctx.attr.hub_name, parsed.model, None, files_by_target)
    if not translated.ok:
        fail(translated.error)
    ctx.file("BUILD.bazel", translated.text)
    return ctx.repo_metadata(reproducible = True)

swiftpm_package = repository_rule(
    implementation = _swiftpm_package_impl,
    doc = "One fetched SwiftPM spoke: the pinned GitHub archive plus a BUILD file translated from its plain `Package.swift`, or the `swift_package_build_files` override.",
    attrs = {
        "archive_url": attr.string(doc = "The pinned archive URL to download (always downloaded, even with a build_file override)."),
        "build_file": attr.label(allow_single_file = True, doc = "Label of a hand-written BUILD file replacing the generated one; Bazel resolves it in the module that wrote the flutter.pub tag. None (the default) translates the manifest. Skips the translation only, not the download."),
        "hub_name": attr.string(mandatory = True, doc = "The flutter.pub hub name, for cross-package dep labels."),
        "identity": attr.string(mandatory = True, doc = "The SwiftPM package identity (the spoke suffix)."),
        "sha256": attr.string(doc = "The pinned SHA-256 of the archive (empty when unpinned, which fails before downloading)."),
        "unpinned_error": attr.string(default = "", doc = "The fetch failure for an unpinned entry; failing first keeps unpinned bytes out."),
    },
)
