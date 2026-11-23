"""Guards for `flutter.pub` hosted spokes that unpack third-party archives.

Every `flutter_pub_package` spoke downloads a `pub.dev` tarball and unpacks
it with `ctx.extract`. A tarball can smuggle entries the build must never
trust: a hard-link entry whose target climbs out of the package becomes a
real hard link to a build-host file (a regular file with the host file's
inode, so no later realpath check can tell it apart), a climbing or absolute
symlink materialises as-is, and an entry whose own path climbs out lands
outside the spoke. All three reach `DartInfo.transitive_srcs`, and inside a
declared asset directory they reach `FlutterInfo.pub_assets`, so host bytes
can ship in an app — while the sha256 pins the archive bytes rather than the
spoke's content, so editing the host file changes the build with no lock or
source change.

`fetch_hosted_archive` below closes that hole by running rules_dart's public
guards from `@rules_dart//dart/pub:pub_scan.bzl`: `run_pub_archive_scan`
over the downloaded (and trimmed) archive before `ctx.extract`, and
`check_package_symlinks` over the extracted tree before anything reads it.
Both live in rules_dart and are reused here, never copied: a refusal fails
the spoke's fetch with rules_dart's own diagnostic naming the package and
the entry, and the one scanner snapshot rules_dart already builds serves
every spoke, so each hosted fetch costs exactly one scanner process with no
extra planning pass and no second compile.

No recorded state can weaken the scan: the spoke always scans the bytes it
just downloaded, and the lockfile carries no scan verdict — only the archive
sha256, which the download verifies first. A hand-edited lockfile entry is
reused without re-running the extension, but the spoke re-runs its scan on
every fetch regardless.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "trim_gzip_trailing_nulls")
load("@rules_dart//dart/pub:pub_scan.bzl", "check_package_symlinks", "run_pub_archive_scan")
load("//flutter/private:artifact_urls.bzl", "require_sha256")
load("//flutter/private:download.bzl", "pinned_download")

visibility(["//flutter/..."])

def scan_hosted_archive(ctx, archive_path, package_name):
    """Runs rules_dart's header scan over one downloaded archive.

    Refuses every hard-link entry whatever its target, every symlink entry
    whose target is absolute or climbs out of the package root, and every
    entry whose own path is absolute or climbs out of the root. A refusal
    fails the fetch with rules_dart's diagnostic naming the package and the
    entry — `fail` aborts the caller, so a refused archive is never
    extracted.

    Args:
        ctx: The spoke's repository context.
        archive_path: The archive file: a repo-relative path string, a
            `Path`, or a `Label`, resolved through `ctx.path` by the scan.
        package_name: The pub package the archive was fetched for.

    Returns:
        `""` when the archive is clean. A refusal never returns: it fails
        the fetch first. Callers still treat a non-empty return as the
        refusal diagnostic and fail, so an injected scan in tests stops the
        fetch the same way.
    """
    run_pub_archive_scan(ctx, archive_path, package_name)
    return ""

def walk_hosted_package(ctx, package_name):
    """Runs rules_dart's symlink walk over one extracted spoke tree.

    Fails the fetch when a link dangles or resolves outside the package
    root, and materialises in-package links as regular files so later reads
    cannot observe them. Runs after extraction and before anything reads the
    tree, as the second layer behind the header scan: headers can lie about
    what the extractor writes, and only the extracted tree shows what
    actually landed.

    Args:
        ctx: The spoke's repository context.
        package_name: The pub package the tree was extracted for.
    """
    check_package_symlinks(ctx, package_name)

def fetch_hosted_archive(ctx, scan_fn, walk_fn):
    """Downloads, scans, extracts and walks one hosted package archive.

    Verifies sha256 on download, strips trailing NUL padding past the RFC
    1952 gzip trailer, scans the trimmed bytes before trusting them to the
    extractor, then walks the extracted tree before anything reads it. The
    scan and the walk are injected so unit tests can pin the order with the
    existing mock context; the spoke passes `scan_hosted_archive` and
    `walk_hosted_package`.

    Args:
        ctx: The spoke's repository context.
        scan_fn: Callable `(ctx, archive_path, package_name)` returning `""`
            when the archive is clean, or the refusal diagnostic (the real
            scan fails the fetch instead of returning one).
        walk_fn: Callable `(ctx, package_name)` walking the extracted tree.

    Returns:
        `""` when the spoke may proceed to generate from the tree, or the
        refusal diagnostic when the scan refused the archive: the archive
        was not extracted and the tree was not walked.
    """
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = ctx.attr.base_url,
        name = ctx.attr.package_name,
        version = ctx.attr.version,
    )
    pinned_download(
        ctx,
        url = url,
        output = "_archive.tar.gz",
        sha256 = require_sha256(ctx.attr.sha256, url),
    )
    raw_archive = ctx.read("_archive.tar.gz", watch = "no")
    trimmed_archive = trim_gzip_trailing_nulls(raw_archive)
    if trimmed_archive != raw_archive:
        ctx.delete("_archive.tar.gz")
        ctx.file("_archive.tar.gz", trimmed_archive, executable = False)
    refusal = scan_fn(ctx, "_archive.tar.gz", ctx.attr.package_name)
    if refusal:
        return refusal
    ctx.extract("_archive.tar.gz")
    ctx.delete("_archive.tar.gz")
    walk_fn(ctx, ctx.attr.package_name)
    return ""
