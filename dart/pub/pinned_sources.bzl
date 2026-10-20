"""Single validation entry point for pinned pub sources.

Every repository rule and helper in `//dart/pub` that fetches a package —
hosted tarballs and git checkouts alike, including each member of a merged
cycle and the `pub` extension's own cycle-planning downloads — validates its
coordinates through `pinned_source_error` before it fetches, and every git
checkout is verified afterwards with `verify_git_checkout`.

A git source is pinned only by its full 40-hex commit SHA; anything else
(a branch, a tag, `HEAD`, a short SHA, a SHA with a revision suffix, ...)
fails the build instead of tracking a moving ref. A hosted source is pinned
by its non-blank sha256 checksum. There is deliberately one function for
both, so a new fetch call site cannot pick the wrong check.
"""

load("//dart/pub:yaml_parser.bzl", "is_valid_git_ref", "is_valid_sha256")

def pinned_source_error(source, package_name, version, sha256 = None, resolved_ref = None, rule = "pub package"):
    """Validates the pinned coordinates of one package source.

    Args:
        source: `"hosted"` or `"git"`.
        package_name: The pub package name, for diagnostics.
        version: The package version string, for diagnostics.
        sha256: Candidate SHA-256 checksum string (hosted sources).
        resolved_ref: Candidate resolved commit string (git sources).
        rule: Name of the calling rule, for diagnostics.

    Returns:
        An error string when the coordinates are unpinned or malformed —
        a blank or non-64-lowercase-hex sha256, or anything but a full
        40-lowercase-hex commit SHA — or None when valid.
    """
    if source == "hosted":
        trimmed = str(sha256).strip() if sha256 != None else ""
        if not trimmed:
            return '%s "%s" (%s) requires a non-empty sha256.' % (
                rule,
                package_name,
                version,
            )
        if not is_valid_sha256(trimmed):
            return '%s "%s" (%s) has invalid sha256 %r: expected 64 lowercase hex digits.' % (
                rule,
                package_name,
                version,
                sha256,
            )
        return None
    if source == "git":
        if not is_valid_git_ref(resolved_ref):
            return '%s "%s" (%s) requires a full 40-hex resolved-ref, got %r.' % (
                rule,
                package_name,
                version,
                resolved_ref,
            )
        return None
    return '%s "%s" (%s) has unknown source %r: expected "hosted" or "git".' % (
        rule,
        package_name,
        version,
        source,
    )

def verify_git_checkout(ctx, clone_dir, resolved_ref, what):
    """Fails unless the git checkout at `clone_dir` is the pinned commit.

    Validation before the fetch rejects every non-SHA spelling, but a ref
    that git resolves differently must still not slip through, so after
    checkout this resolves what git actually checked out and compares it to
    the requested commit.

    Args:
        ctx: A repository or module-extension context.
        clone_dir: The checkout directory (or its string path).
        resolved_ref: The pinned full 40-hex commit SHA that was validated
            before the fetch.
        what: Human-readable label of the fetching rule, for diagnostics.
    """
    want = str(resolved_ref).strip()
    res = ctx.execute(["git", "-C", str(clone_dir), "rev-parse", "HEAD^{commit}"])
    if res.return_code != 0:
        fail("%s: could not verify the checked-out commit: %s" % (what, res.stderr))
    actual = res.stdout.strip()
    if actual != want:
        fail("%s: checked-out commit %r does not match the pinned resolved-ref %r." % (what, actual, resolved_ref))
