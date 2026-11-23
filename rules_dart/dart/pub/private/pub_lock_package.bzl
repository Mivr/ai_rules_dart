"""Repository rule that downloads a single package from a pubspec.lock.

Each hosted package gets its own external repository (spoke), with the hub
repo providing aliases for backward-compatible `@hub//:pkg` labels.

Also re-exports `make_dart_library_build_content` as a public Starlark
helper. Other Bazel rule sets (notably rules_flutter's `flutter_pub_package`,
the `flutter pub get` analog) reuse this helper to emit the same
`dart_library` shape for non-plugin packages without duplicating the format.
"""

load("//dart/private:download.bzl", "pinned_download")
load("//dart/pub/private:build_content.bzl", _PACKAGE_FILES_ATTR_DOC = "PACKAGE_FILES_ATTR_DOC", _classify_pub_hooks = "classify_pub_hooks", _make_dart_library_build_content = "make_dart_library_build_content")
load("//dart/pub/private:language_version.bzl", _derive_language_version = "derive_language_version")
load("//dart/pub/private:pinned_sources.bzl", "git_materialize", "git_transport_fetch", "pinned_source_error")
load("//dart/pub/private:pub_scan.bzl", _run_pub_archive_scan = "run_pub_archive_scan")
load("//dart/pub/private:pub_scc_verify.bzl", "spoke_planned_deps_error")
load("//dart/pub/private:pub_symlink.bzl", _check_package_symlinks = "check_package_symlinks")
load("//dart/pub/private:pubspec_data.bzl", "pubspec_deps", "pubspec_environment_error", "pubspec_sdk_constraint")
load("//dart/pub/private:yq.bzl", "yaml_to_json")

visibility(["//dart/..."])

# Re-export for consumers outside //dart/pub (rules_flutter's
# `flutter_pub_package`). Loading the private bzl directly would trip
# buildifier's bzl-visibility check, so we expose it via this public file.
derive_language_version = _derive_language_version
make_dart_library_build_content = _make_dart_library_build_content

# Same re-export for the archive header scan: `run_pub_archive_scan` runs the
# AOT scanner over a fetched archive before extraction, failing a fetch whose
# tar headers already smuggle a hard link, an escaping symlink, or an
# escaping entry path.
run_pub_archive_scan = _run_pub_archive_scan

def pub_lock_package_sha256_error(package_name, version, sha256):
    """Validates `sha256` for a `pub_lock_package` target.

    Args:
        package_name: The pub.dev package name.
        version: The package version string.
        sha256: Candidate SHA-256 checksum string.

    Returns:
        An error string when `sha256` is empty or not 64 lowercase hex digits,
        or None when valid.
    """
    return pinned_source_error(
        "hosted",
        package_name,
        version,
        sha256 = sha256,
        rule = "pub_lock_package",
    )

def trim_gzip_trailing_nulls(data):
    """Strips trailing NUL padding after a `.tar.gz` gzip stream.

    Some pub.dev tarballs (e.g. `nested@1.0.0`) are padded with NUL bytes to a
    10 KiB tar record boundary past the 8-byte RFC 1952 gzip trailer (4-byte
    CRC32 + 4-byte little-endian uncompressed `ISIZE`). Bazel's
    `GzipCompressorInputStream` rejects trailing bytes after the trailer with
    `Garbage after a valid .gz stream`.

    Because the uncompressed stream is a `.tar` archive (a non-empty multiple
    of 512 bytes), `ISIZE % 512 == 0`, so `ISIZE[0] == 0` and at least one of
    `ISIZE[1..3]` is non-zero (for archives < 4 GiB), meaning an unpadded
    `.tar.gz` ends with at most two NUL bytes.

    Args:
        data: Raw archive bytes as an ISO-8859-1 Starlark string.

    Returns:
        The archive bytes with any trailing NUL padding past the gzip trailer
        removed.
    """
    if not data.endswith("\0\0\0\0"):
        return data
    stripped = data.rstrip("\0")
    if len(stripped) < 10:
        return data
    b2_zero = stripped[-2:-1] == "\0"
    b3_zero = stripped[-3:-2] == "\0"
    if b2_zero and not b3_zero:
        return stripped + "\0\0"
    if b3_zero and not b2_zero:
        if stripped[-4:-3] == "\0" and (hash(stripped[-2:-1]) + hash(stripped[-1:]) * 256) * 256 < len(stripped):
            return stripped
        return stripped + "\0"
    if b2_zero and b3_zero:
        b = hash(stripped[-1:])
        if b % 2 != 0 or b * 256 < len(stripped):
            return stripped + "\0"
        return stripped + "\0\0"
    return stripped

def _pub_lock_write_build(ctx, rule_name):
    """Reads the staged `pubspec.yaml` and writes the spoke `BUILD.bazel`.

    Shared by the hosted and git spokes: both lay out the package's files and
    then derive the same `dart_library` from its pubspec — its SDK
    constraint (as the Dart language version) and its hooks (recorded for
    the consuming binary to complain about, or for `dart_link_hook` to run).
    Its dependencies are the `deps` labels the extension computed from the
    planned names.

    Before writing anything it checks the unfiltered dependency names the
    fetched pubspec lists against the sorted names planning used (the
    spoke's `planned_deps` attribute, from the server's listing, a lockfile
    fact or the archive): planning metadata that drops a real edge would
    otherwise hide a dependency or a cycle, and one that gains a fake edge
    would pass silently. A mismatch fails the fetch naming the package, so
    the failure surfaces here and never as a missing dependency or a target
    cycle.

    Args:
      ctx: The repository rule context.
      rule_name: The spoke rule (`"pub_lock_package"` or
        `"pub_lock_git_package"`), for diagnostics.
    """
    language_version = ""
    real_deps = []
    if ctx.path("pubspec.yaml").exists:
        pubspec_label = ctx.attr.package_name + "/pubspec.yaml"
        pubspec = yaml_to_json(ctx, ["pubspec.yaml"], [pubspec_label])[0]
        sdk_err = pubspec_environment_error(pubspec, pubspec_label)
        if sdk_err:
            fail(sdk_err)
        real_deps = sorted(pubspec_deps(pubspec))
        language_version = _derive_language_version(pubspec_sdk_constraint(pubspec))

    err = spoke_planned_deps_error(rule_name, ctx.name, ctx.attr.package_name, ctx.attr.planned_deps, real_deps)
    if err:
        fail(err)

    # A package that builds native code declares a build hook. rules_dart
    # cannot run it, so unless a curated `dart_code_asset` replaces it — or the
    # user has declared it irrelevant — record it for the consuming binary to
    # complain about. Recording rather than failing here is deliberate: the
    # whole lock is materialised, including packages nothing depends on. A link
    # hook is recorded too, for `dart_link_hook` to run.
    hooks = _classify_pub_hooks(
        has_build_hook = ctx.path("hook/build.dart").exists,
        has_link_hook = ctx.path("hook/link.dart").exists,
        build_hook_handled = bool(ctx.attr.code_assets) or ctx.attr.ignore_hook,
    )

    build_content = make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = ctx.attr.deps,
        language_version = language_version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = hooks.unreplaced_hook,
        version = ctx.attr.version,
        link_hook = hooks.link_hook,
        package_files = ctx.attr.package_files,
    )

    ctx.file("BUILD.bazel", build_content)

def _pub_lock_package_impl(ctx):
    err = pub_lock_package_sha256_error(
        ctx.attr.package_name,
        ctx.attr.version,
        ctx.attr.sha256,
    )
    if err:
        fail(err)

    url = ctx.attr.url

    # pub.dev serves some tarballs padded with trailing NUL bytes past the
    # 8-byte RFC 1952 gzip trailer (observed as of 2026-04 on `nested@1.0.0`,
    # among others). Bazel's built-in `GzipCompressorInputStream` rejects
    # trailing bytes after the trailer with `Garbage after a valid .gz stream`.
    #
    # Download the archive (verifying its sha256), strip any trailing NUL
    # padding past the gzip trailer, and unpack with `ctx.extract`.
    pinned_download(
        ctx,
        url = url,
        output = "_archive.tar.gz",
        sha256 = ctx.attr.sha256.strip(),
    )
    raw_archive = ctx.read("_archive.tar.gz", watch = "no")
    trimmed_archive = trim_gzip_trailing_nulls(raw_archive)
    if trimmed_archive != raw_archive:
        ctx.delete("_archive.tar.gz")
        ctx.file("_archive.tar.gz", trimmed_archive, executable = False)

    # Run the AOT header scanner over the archive file before the extractor
    # trusts it: a hard-link entry, an absolute or package-escaping symlink
    # entry, or an absolute or climbing entry path fails the fetch here, not
    # after its links hit the filesystem.
    _run_pub_archive_scan(ctx, "_archive.tar.gz", ctx.attr.package_name)
    ctx.extract("_archive.tar.gz")
    ctx.delete("_archive.tar.gz")
    _check_package_symlinks(ctx, ctx.attr.package_name)

    _pub_lock_write_build(ctx, "pub_lock_package")
    return ctx.repo_metadata(reproducible = True)

pub_lock_package = repository_rule(
    implementation = _pub_lock_package_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub.dev package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive for integrity verification.",
            mandatory = True,
        ),
        "url": attr.string(
            doc = "The archive URL: the server's `archive_url` for the version, or " +
                  "`<base>/packages/<name>/versions/<version>.tar.gz` when it lists none.",
            mandatory = True,
        ),
        "planned_deps": attr.string_list(
            doc = "The sorted dependency names planning used for this package (its whole " +
                  "`dependencies:`, unfiltered). The fetch fails when the fetched pubspec " +
                  "lists other names.",
            default = [],
        ),
        "deps": attr.string_list(
            doc = "Labels of this package's own dependencies: a sibling spoke, the merged " +
                  "repository holding a dependency cycle, or a `pub.package()` repository.",
            default = [],
        ),
        "ignore_hook": attr.bool(
            doc = "Suppress the unreplaced-hook diagnostic for this package. Set by " +
                  "`pub.from_lock(ignore_hooks = [...])`; never a default.",
            default = False,
        ),
        "code_assets": attr.string_list(
            doc = "Labels of `dart_code_asset` targets replacing this package's " +
                  "`hook/build.dart` output. Resolved by the `pub` extension from " +
                  "rules_dart's curated registry; attached to the generated " +
                  "`dart_library` so they propagate to every consumer.",
            default = [],
        ),
        "package_files": attr.string_list(
            doc = "Applies to this hosted package. " + _PACKAGE_FILES_ATTR_DOC,
            default = ["pubspec.yaml", "LICENSE*"],
        ),
    },
    doc = "Downloads a single hosted package from a pubspec.lock and generates a BUILD file.",
)

def _pub_lock_git_package_impl(ctx):
    err = pinned_source_error(
        "git",
        ctx.attr.package_name,
        ctx.attr.version,
        resolved_ref = ctx.attr.resolved_ref,
        rule = "pub_lock_git_package",
    )
    if err:
        fail(err)

    path = ctx.attr.path.strip() if ctx.attr.path != None else "."
    if path == "":
        path = "."

    clone_rel = "_git_bare"
    git_transport_fetch(
        ctx,
        ctx.attr.url,
        clone_rel,
        ctx.attr.resolved_ref,
        'pub_lock_git_package "%s"' % ctx.attr.package_name,
    )

    archive_path = ctx.path("_git_archive.tar")
    spec = ctx.attr.resolved_ref if path == "." else ctx.attr.resolved_ref + ":" + path
    git_materialize(
        ctx,
        clone_rel,
        ctx.attr.resolved_ref,
        archive_path,
        spec,
        'pub_lock_git_package "%s"' % ctx.attr.package_name,
    )

    # `git archive` output is a plain tar: refuse hostile entries from its
    # headers before the extractor trusts them, the same check as hosted.
    _run_pub_archive_scan(ctx, archive_path, ctx.attr.package_name)
    ctx.extract(archive_path)
    ctx.delete(archive_path)
    ctx.delete(ctx.path(clone_rel))
    _check_package_symlinks(ctx, ctx.attr.package_name)

    _pub_lock_write_build(ctx, "pub_lock_git_package")
    return ctx.repo_metadata(reproducible = True)

pub_lock_git_package = repository_rule(
    implementation = _pub_lock_git_package_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version.",
            mandatory = True,
        ),
        "url": attr.string(
            doc = "Git remote URL.",
            mandatory = True,
        ),
        "resolved_ref": attr.string(
            doc = "Full 40-hex commit SHA to fetch.",
            mandatory = True,
        ),
        "path": attr.string(
            doc = "Subdirectory inside the git repo holding the package; '.' means repo root.",
            default = ".",
        ),
        "planned_deps": attr.string_list(
            doc = "The sorted dependency names planning used for this package (its whole " +
                  "`dependencies:`, unfiltered). The fetch fails when the fetched pubspec " +
                  "lists other names.",
            default = [],
        ),
        "deps": attr.string_list(
            doc = "Labels of this package's own dependencies: a sibling spoke, the merged " +
                  "repository holding a dependency cycle, or a `pub.package()` repository.",
            default = [],
        ),
        "ignore_hook": attr.bool(
            doc = "Suppress the unreplaced-hook diagnostic for this package.",
            default = False,
        ),
        "code_assets": attr.string_list(
            doc = "Labels of `dart_code_asset` targets replacing this package's `hook/build.dart`.",
            default = [],
        ),
        "package_files": attr.string_list(
            doc = "Applies to this git-sourced package. " + _PACKAGE_FILES_ATTR_DOC,
            default = ["pubspec.yaml", "LICENSE*"],
        ),
    },
    doc = "Fetches a single git-sourced package from a pubspec.lock and generates a BUILD file.",
)
