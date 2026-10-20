"""Single validation entry point for pinned pub sources, and single place that runs host git.

Every repository rule and helper in `//dart/pub` that fetches a package —
hosted tarballs and git checkouts alike, including each member of a merged
cycle and the `pub` extension's own cycle-planning downloads — validates its
coordinates through `pinned_source_error` before it fetches, every git
checkout is verified afterwards with `verify_git_checkout`, every clone goes
through `git_clone`, and every other host `git` invocation goes through
`git_fetch`, `git_checkout` or `git_archive` below, so a new git call that
bypasses the helper fails the `pinned_sources_guard_test` enumeration.

A git source is pinned only by its full 40-hex commit SHA; anything else
(a branch, a tag, `HEAD`, a short SHA, a SHA with a revision suffix, ...)
fails the build instead of tracking a moving ref. A hosted source is pinned
by its non-blank sha256 checksum. There is deliberately one function for
both, so a new fetch call site cannot pick the wrong check.

Host git configuration and the archived bytes: cloning ignores the host's
template directory — `GIT_TEMPLATE_DIR` in the environment, or
`init.templateDir` from any readable config file — by passing `--template=`
pointing at an empty directory this helper creates (a command-line flag beats
every config file) and by pointing `GIT_TEMPLATE_DIR` at the same directory,
so a host template's `info/attributes` (with `export-subst` or `eol`) cannot
change the extracted bytes and its `hooks/` are never installed. The clone's
repository-local `.git/info/attributes` is truncated right after cloning (git
has no switch for that file), and every git invocation points
`core.hooksPath` at the empty directory on the command line (`-c` beats both
files and environment), so no host hook runs at any step. The materialization
step (`git_archive`) additionally neutralizes every host-side git
configuration — system, global, XDG and HOME config files,
`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_*` / `GIT_CONFIG_VALUE_*` and
`GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` — by
pinning the conversion knobs on the command line (`-c` beats both files and
environment) and by pointing the file selectors at an empty file this helper
writes. Fetching (`git_clone`, `git_fetch`, `git_checkout`) deliberately keeps
the host's transport configuration (credential helpers,
`url.<base>.insteadOf` rewrites, proxies, SSH settings): the commit id
already verifies what was fetched, and private repositories need it.

The package's own committed `.gitattributes` are honoured: `export-subst`,
`export-ignore` and `eol` attributes from the archived tree are a pure
function of the pinned commit, so they expand identically on every host and
OS, including Windows. Only host-side configuration is neutralized.
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

def _git_empty_dir(ctx):
    """Ensures the shared empty directory for git template and hook isolation.

    The directory holds one inert placeholder file: `ctx.file` creates parent
    directories but cannot create an empty one, and module-extension contexts
    have no `ctx.delete` to remove the placeholder afterwards. The placeholder
    is inert for both uses: as a template it copies to `.git/keep`, outside
    `hooks/` and `info/`, and as a hooks directory git only looks up exact
    hook names, never `keep`.

    Args:
        ctx: A repository or module-extension context.

    Returns:
        The empty directory's path string.
    """
    ctx.file("_git_empty/keep", "", executable = False)
    return str(ctx.path("_git_empty"))

def git_fetch(ctx, args):
    """Runs host `git` for one fetching step (checkout, fetch, rev-parse).

    The host's transport configuration is deliberately inherited — credential
    helpers, `url.<base>.insteadOf` rewrites, proxies and SSH settings keep
    working, which private repositories need. Only host-controlled code and
    byte inputs are neutralized: `core.hooksPath` is pointed at the shared
    empty directory on the command line (`-c` beats config files and
    environment on every git version, so an environment-injected hooks path
    loses too) and `GIT_TEMPLATE_DIR` is pointed at the same directory.
    Cloning additionally needs `--template=` and the attributes truncation,
    so it uses `git_clone`, not this function.

    Args:
        ctx: A repository or module-extension context.
        args: The `git` arguments, without the binary name
            (for example `["-C", clone_dir, "checkout", "--quiet", ref]`).

    Returns:
        The `ctx.execute` result, so the caller reports failures in its own
        words (checkout and fetch failures name different things).
    """
    empty_dir = _git_empty_dir(ctx)
    return ctx.execute(
        ["git", "-c", "core.hooksPath=" + empty_dir] + args,
        environment = {"GIT_TEMPLATE_DIR": empty_dir},
    )

def git_clone(ctx, url, clone_dir):
    """Clones `url` without checkout, ignoring host templates, hooks and attributes.

    `git clone` populates the new repository's `.git/info/attributes` and
    `.git/hooks/` from the host's template directory (`GIT_TEMPLATE_DIR`, or
    `init.templateDir` from any readable config file): a template
    `info/attributes` with `export-subst` changes the archived bytes of the
    pinned commit, and a template `post-checkout` hook runs host code at
    checkout time. The clone therefore passes `--template=` pointing at the
    shared empty directory (a command-line flag beats `init.templateDir` from
    every config file), points `GIT_TEMPLATE_DIR` at the same directory, pins
    `core.hooksPath` at it so no host hook runs, and truncates the clone's
    repository-local `.git/info/attributes` (git has no switch for that file;
    the package's own committed `.gitattributes` are untouched and keep the
    documented behaviour). Transport configuration is inherited, like
    `git_fetch`.

    Args:
        ctx: A repository or module-extension context.
        url: The git remote URL (or local bundle path) to clone.
        clone_dir: The repository-relative clone directory (for example
            `"_git_clone"`): relative so the attributes file can be
            neutralized with `ctx.file` on every context, including module
            extensions, which have no `ctx.delete`.

    Returns:
        The `ctx.execute` result, so the caller reports clone failures in its
        own words. The attributes file is neutralized only on success.
    """
    empty_dir = _git_empty_dir(ctx)
    res = ctx.execute(
        [
            "git",
            "-c",
            "core.hooksPath=" + empty_dir,
            "clone",
            "--no-checkout",
            "--template=" + empty_dir,
            url,
            str(ctx.path(clone_dir)),
        ],
        environment = {"GIT_TEMPLATE_DIR": empty_dir},
    )
    if res.return_code != 0:
        return res
    ctx.file(clone_dir + "/info/attributes", "", executable = False)
    return res

def git_checkout(ctx, clone_dir, resolved_ref, what):
    """Checks out the pinned commit, fetching it first when the clone lacks it.

    A `--no-checkout` clone of a bundle or a shallow mirror may not contain
    the pinned commit yet; the fetch-then-retry keeps such remotes working.
    Transport uses the host configuration, like `git_fetch`.

    Args:
        ctx: A repository or module-extension context.
        clone_dir: The clone directory (or its string path).
        resolved_ref: The pinned full 40-hex commit SHA.
        what: Human-readable label of the fetching rule, for diagnostics.

    Returns:
        The successful checkout's `ctx.execute` result.
    """
    res = git_fetch(ctx, ["-C", str(clone_dir), "checkout", "--quiet", resolved_ref])
    if res.return_code != 0:
        git_fetch(ctx, ["-C", str(clone_dir), "fetch", "origin", resolved_ref])
        res = git_fetch(ctx, ["-C", str(clone_dir), "checkout", "--quiet", resolved_ref])
        if res.return_code != 0:
            fail("%s: git checkout failed at %s: %s" % (what, resolved_ref, res.stderr))
    return res

def git_archive(ctx, clone_dir, output, spec, what):
    """Archives the pinned commit to `output` independently of host git configuration.

    `git archive` applies working-tree conversions to the bytes it writes, and
    the conversion knobs can come from the host rather than the repository:
    `core.autocrlf` / `core.eol` rewrite line endings (Git for Windows ships
    `core.autocrlf=true`, so Windows and Linux already differ without this),
    and a host `core.attributesFile` adds attributes such as `export-subst`
    or `eol=crlf` for the archived paths. Only the commit id is verified
    afterwards, so without isolation the same pinned commit builds different
    bytes on different hosts.

    The archived bytes therefore depend only on the pinned commit and the
    package's own committed content: the command pins `core.autocrlf=false`,
    `core.eol=lf` and `tar.umask=002` (git's default), points
    `core.attributesFile` at an empty file written for the call, points
    `core.hooksPath` at the shared empty directory (archive runs no hooks,
    but the pin keeps every git invocation uniformly hook-free), points
    `GIT_TEMPLATE_DIR` at the same directory, and scrubs the environment
    selectors (`GIT_CONFIG_COUNT`, `GIT_CONFIG_PARAMETERS`,
    `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`) at the same empty file.
    Command-line `-c` pins take precedence over both config files and
    environment on every git version, so the scrubbing is defence in depth.
    The clone's repository-local `.git/info/attributes` was already truncated
    by `git_clone`, so only the committed `.gitattributes` still apply — their
    expansion is a pure function of the pinned commit, identical on every
    host and OS.

    Args:
        ctx: A repository or module-extension context.
        clone_dir: The clone directory (or its string path).
        output: Where to write the tar archive (or its string path).
        spec: The archive spec: the pinned commit, or `<commit>:<path>` for a
            package living in a subdirectory of its repository.
        what: Human-readable label of the fetching rule, for diagnostics.

    Returns:
        The successful archive's `ctx.execute` result.
    """

    # The empty file doubles as the `core.attributesFile` replacement and as
    # the `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` replacement. It is left
    # behind on purpose: module-extension contexts have no `ctx.delete`, and
    # an empty underscore-prefixed file is inert (no BUILD glob reaches the
    # repository root, and the planning scratch is Bazel-managed).
    ctx.file("_git_empty_config", "", executable = False)
    empty = str(ctx.path("_git_empty_config"))
    empty_dir = _git_empty_dir(ctx)
    res = ctx.execute(
        [
            "git",
            "-c",
            "core.autocrlf=false",
            "-c",
            "core.eol=lf",
            "-c",
            "core.attributesfile=" + empty,
            "-c",
            "core.hooksPath=" + empty_dir,
            "-c",
            "tar.umask=002",
            "-C",
            str(clone_dir),
            "archive",
            "--format=tar",
            "-o",
            str(output),
            spec,
        ],
        environment = {
            "GIT_CONFIG_COUNT": "",
            "GIT_CONFIG_PARAMETERS": "",
            "GIT_CONFIG_GLOBAL": empty,
            "GIT_CONFIG_SYSTEM": empty,
            "GIT_TEMPLATE_DIR": empty_dir,
        },
    )
    if res.return_code != 0:
        fail("%s: git archive failed at %s: %s" % (what, spec, res.stderr))
    return res

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
    res = git_fetch(ctx, ["-C", str(clone_dir), "rev-parse", "HEAD^{commit}"])
    if res.return_code != 0:
        fail("%s: could not verify the checked-out commit: %s" % (what, res.stderr))
    actual = res.stdout.strip()
    if actual != want:
        fail("%s: checked-out commit %r does not match the pinned resolved-ref %r." % (what, actual, resolved_ref))
