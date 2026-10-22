"""Fail-closed download helpers for every fetch in `//dart`.

Every repository rule and module extension under `//dart` that fetches bytes
— SDK archives, cross-compilation binaries and pub tarballs alike — goes
through `pinned_download` or `pinned_download_and_extract` instead of
calling `ctx.download` or `ctx.download_and_extract` directly. The helpers
are small and boring on purpose: they take the same keyword arguments, pass
them through unchanged, and return exactly what the context method returns.
Their only addition is the guarantee: a missing or malformed digest fails
the fetch before any bytes move, the digest is always handed to Bazel, and a
digest Bazel reports for the fetched bytes that differs from the pinned one
fails the fetch as well.

Callers keep their own per-site checks (which table entry lacks a digest,
which package and version the coordinates belong to); those messages stay
unchanged. The helpers are the backstop behind them: even a call site that
forgets every check cannot fetch unpinned bytes.
"""

_HEX_LOWER = "0123456789abcdef"

def _is_pinned_sha256(value):
    """Whether `value` is exactly 64 lowercase hex digits, with no trimming.

    Args:
        value: Candidate SHA-256 checksum string.

    Returns:
        True only for a string of exactly 64 `0-9a-f` characters.
    """
    if type(value) != "string":
        return False
    if len(value) != 64:
        return False
    for ch in value.elems():
        if ch not in _HEX_LOWER:
            return False
    return True

def _digest_error(caller, url, sha256):
    """The failure message for a fetch with no usable digest.

    Args:
        caller: `"pinned_download"` or `"pinned_download_and_extract"`.
        url: The fetch URL or URL list, named so the failure points at it.
        sha256: The rejected digest.

    Returns:
        The message the fetch fails with.
    """
    return (
        "%s: refusing to fetch \"%s\": " +
        "\"sha256\" must be exactly 64 lowercase hex digits, got \"%s\"."
    ) % (caller, url, sha256)

def _kwargs_error(caller, url):
    """The failure message for a digest smuggled past the `sha256` argument.

    Args:
        caller: `"pinned_download"` or `"pinned_download_and_extract"`.
        url: The fetch URL or URL list, named so the failure points at it.

    Returns:
        The message the fetch fails with.
    """
    return (
        "%s: refusing to fetch \"%s\": " +
        "pass the digest as the \"sha256\" argument, not as \"sha256\" or " +
        "\"integrity\" in the remaining keyword arguments."
    ) % (caller, url)

def _mismatch_error(caller, url, sha256, reported):
    """The failure message for bytes whose digest differs from the pinned one.

    Args:
        caller: `"pinned_download"` or `"pinned_download_and_extract"`.
        url: The fetch URL or URL list, named so the failure points at it.
        sha256: The pinned digest the fetch asked for.
        reported: The digest Bazel reported for the fetched bytes.

    Returns:
        The message the fetch fails with.
    """
    return (
        "%s: refusing to fetch \"%s\": " +
        "checksum mismatch: wanted \"%s\", the downloaded bytes have " +
        "sha256 \"%s\"."
    ) % (caller, url, sha256, reported)

def _checked_sha256(caller, ctx_url, sha256, kwargs):
    """Rejects keyword smuggling and unpinned digests before a fetch runs.

    Args:
        caller: `"pinned_download"` or `"pinned_download_and_extract"`.
        ctx_url: The `url` keyword argument (a string or a list of strings).
        sha256: The `sha256` argument the fetch asked for.
        kwargs: The remaining keyword arguments the fetch would pass through.

    Returns:
        The URL or URL list for the failure messages.
    """
    url = ctx_url if ctx_url != None else ""
    if "sha256" in kwargs or "integrity" in kwargs:
        fail(_kwargs_error(caller, url))
    if not _is_pinned_sha256(sha256):
        fail(_digest_error(caller, url, sha256))
    return url

def _checked_result(caller, url, sha256, result):
    """Fails the fetch when Bazel's reported digest differs from the pinned one.

    Bazel verifies the `sha256` it is handed, but the fetch must not depend
    on any one transport verifying: when the context reports a digest for
    the fetched bytes and it is not the pinned one, the bytes are refused.

    Args:
        caller: `"pinned_download"` or `"pinned_download_and_extract"`.
        url: The fetch URL or URL list, for the failure message.
        sha256: The pinned digest the fetch asked for.
        result: What the context method returned.

    Returns:
        The context method's result, unchanged.
    """
    if result != None and hasattr(result, "sha256"):
        reported = result.sha256
        if type(reported) == "string" and reported != "" and reported != sha256:
            fail(_mismatch_error(caller, url, sha256, reported))
    return result

def pinned_download(ctx, *, sha256, **kwargs):
    """Fetches a file only when `sha256` pins it, like `ctx.download`.

    Args:
        ctx: A repository context or module-extension context.
        sha256: Exactly 64 lowercase hex digits. Anything else — empty,
            short, uppercase, an SRI string, a conditional that evaluated
            to blank — fails the fetch with a message naming the URL.
        **kwargs: Passed to `ctx.download` unchanged (`url`, `output`,
            `executable`, ...). Must not carry `sha256` or `integrity`.

    Returns:
        What `ctx.download` returns.
    """
    url = _checked_sha256("pinned_download", kwargs.get("url", ""), sha256, kwargs)
    return _checked_result(
        "pinned_download",
        url,
        sha256,
        ctx.download(sha256 = sha256, **kwargs),
    )

def pinned_download_and_extract(ctx, *, sha256, **kwargs):
    """Fetches and extracts an archive only when `sha256` pins it.

    Args:
        ctx: A repository context or module-extension context.
        sha256: Exactly 64 lowercase hex digits. Anything else fails the
            fetch with a message naming the URL.
        **kwargs: Passed to `ctx.download_and_extract` unchanged (`url`,
            `stripPrefix`, `type`, ...). Must not carry `sha256` or
            `integrity`.

    Returns:
        What `ctx.download_and_extract` returns.
    """
    url = _checked_sha256(
        "pinned_download_and_extract",
        kwargs.get("url", ""),
        sha256,
        kwargs,
    )
    return _checked_result(
        "pinned_download_and_extract",
        url,
        sha256,
        ctx.download_and_extract(sha256 = sha256, **kwargs),
    )
