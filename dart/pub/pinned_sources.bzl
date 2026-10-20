"""Single validation entry point for pinned pub sources, and single place that runs host git.

Every repository rule and helper in `//dart/pub` that fetches a package —
hosted tarballs and git checkouts alike, including each member of a merged
cycle and the `pub` extension's own cycle-planning downloads — validates its
coordinates through `pinned_source_error` before it fetches, and every git
package is fetched through exactly the two phases below, so a new git call
that bypasses the helpers fails the `pinned_sources_guard_test` enumeration.

A git source is pinned only by its full 40-hex commit SHA; anything else
(a branch, a tag, `HEAD`, a short SHA, a SHA with a revision suffix, ...)
fails the build instead of tracking a moving ref. A hosted source is pinned
by its non-blank sha256 checksum. There is deliberately one function for
both, so a new fetch call site cannot pick the wrong check.

## The two phases

Fetching a pinned commit is split in two so that host git state can neither
change the extracted bytes nor run host code, while transport configuration
(credentials, `url.<base>.insteadOf` rewrites, proxies, SSH) keeps working:

1. Transport (`git_transport_fetch`): the pinned commit is fetched into a
   fresh BARE repository — `git init --bare` plus `git fetch <url> <sha>`,
   falling back to fetching all refs on servers that reject a bare SHA.
   There is no working tree, so no checkout ever runs: hooks, `core.fsmonitor`
   and working-tree attributes have nothing to act on. Hooks and fsmonitor
   are additionally pinned off on the command line (`-c` beats config files
   and environment on every git version). Every repository-resolution
   selector the host could otherwise redirect is pinned at the new bare
   repository instead: `--git-dir` (which beats `GIT_DIR`), `--template=`
   plus `GIT_TEMPLATE_DIR` (which beat `init.templateDir` from any config
   file), `GIT_OBJECT_DIRECTORY` and `GIT_COMMON_DIR` (pointed at the new
   repository's own directories, which are pre-created so the pins always
   name existing paths), and `--no-replace-objects` (which beats replace
   refs from any source). The remaining non-transport selectors
   (`GIT_INDEX_FILE`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_NAMESPACE`,
   `GIT_REPLACE_REF_BASE`, `GIT_CEILING_DIRECTORIES`, ...) are scrubbed from
   the environment. What is deliberately inherited is only transport: the
   host's config files and `GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS`
   (which may carry `insteadOf` rewrites), SSH and credential-helper
   variables, and proxies. `GIT_ALLOW_PROTOCOL` is pinned to a fixed
   transport-only list so host state cannot widen the fetch to a
   command-executing helper. One host variable cannot be neutralized: git
   refuses to run `init` at all when `GIT_WORK_TREE` is set, and an empty
   value is equally fatal, so a host that exports `GIT_WORK_TREE` fails the
   fetch loudly instead of fetching wrongly; it is never set during builds,
   and every later command ignores it (a bare repository has no work tree).
2. Materialization (`git_materialize`): every later git command — the
   `count-objects` alternates refusal, the `rev-parse`/`cat-file`
   verification, the tree read, the `archive` — runs against that bare
   repository with an explicit `--git-dir`, `--no-replace-objects`, the same
   hook/fsmonitor pins, and an environment scrubbed to `PATH` plus a scratch
   `HOME`: no `GIT_*` at all (every selector is either pinned at the bare
   repository or pointed at an empty file or directory), `XDG_CONFIG_HOME`
   pointed at the empty directory, `GIT_CONFIG_NOSYSTEM=1`, the global and
   system selectors pointed at an empty file this helper writes, and
   `GIT_NO_REPLACE_OBJECTS=1`. A repository with `objects/info/alternates`
   is refused outright (a fresh `init` never writes that file, so its
   presence means tampering). Verification reads the commit object id
   (`rev-parse --verify <sha>^{commit}` must print the pinned SHA), its type
   (`cat-file -t` must say `commit`), and its tree (`rev-parse
   <sha>^{tree}`), all under that empty environment; the archive is then
   streamed from the same bare repository under the same environment, so the
   tree written out is by construction the verified commit's tree — no host
   channel can make the two commands resolve the same SHA differently once
   replacements, alternates, templates, hooks, fsmonitor and every config
   source are pinned or removed. The archive additionally pins the byte
   conversion knobs (`core.autocrlf=false`, `core.eol=lf`,
   `core.attributesFile` at the empty file, `tar.umask=002`), and the
   repository-local `info/attributes` is truncated both after `init` and
   before the archive.

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
    hook names, never `keep`. It also serves as the scratch `HOME` and
    `XDG_CONFIG_HOME` for materialization: neither `<dir>/.gitconfig` nor
    `<dir>/git/config` exists, so no host file is read.

    Args:
        ctx: A repository or module-extension context.

    Returns:
        The empty directory's path string.
    """
    ctx.file("_git_empty/keep", "", executable = False)
    return str(ctx.path("_git_empty"))

def _git_empty_file(ctx):
    """Ensures the shared empty file replacing host-side git config selectors.

    The file doubles as the `core.attributesFile` replacement and as the
    `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` replacement. It is left behind
    on purpose: module-extension contexts have no `ctx.delete`, and an empty
    underscore-prefixed file is inert (no BUILD glob reaches the repository
    root, and the planning scratch is Bazel-managed).

    Args:
        ctx: A repository or module-extension context.

    Returns:
        The empty file's path string.
    """
    ctx.file("_git_empty_config", "", executable = False)
    return str(ctx.path("_git_empty_config"))

# Protocols the transport phase may speak. Pinned (rather than inherited)
# so host state cannot widen a fetch to a command-executing helper: the
# list covers every URL shape pub git sources use (https, http and git
# remotes, ssh in both syntaxes, file URLs and plain local paths).
_GIT_ALLOW_PROTOCOL = "https:http:git:ssh:file"

def _transport_env(empty_dir, bare_abs):
    """Environment for one transport command: host transport, pinned resolution.

    The host's transport configuration is deliberately inherited — config
    files and `GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS` (which may carry
    `url.<base>.insteadOf` rewrites), credential helpers, proxies and SSH
    settings keep working, which private repositories need. Only
    host-controlled resolution and byte inputs are neutralized: the template
    directory, the object and common directories (pinned at the new bare
    repository, whose directories are pre-created so the pins always name
    existing paths — git refuses empty values there), the protocol
    allowlist, and every remaining non-transport selector scrubbed to an
    empty value (which git reads as unset). `GIT_DIR` is left to the argv
    flags: `--git-dir` beats it on the fetch, and the `init` target
    directory wins over it. `GIT_WORK_TREE` cannot be neutralized — git
    refuses `init` while it is set — and is documented on
    `git_transport_fetch`.

    Args:
        empty_dir: The shared empty directory's path string.
        bare_abs: The bare repository's absolute path string.

    Returns:
        The `environment` dict for one transport `ctx.execute` call.
    """
    return {
        "GIT_TEMPLATE_DIR": empty_dir,
        "GIT_OBJECT_DIRECTORY": bare_abs + "/objects",
        "GIT_COMMON_DIR": bare_abs,
        "GIT_ALLOW_PROTOCOL": _GIT_ALLOW_PROTOCOL,
        "GIT_INDEX_FILE": "",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": "",
        "GIT_NAMESPACE": "",
        "GIT_REPLACE_REF_BASE": "",
        "GIT_CEILING_DIRECTORIES": "",
        "GIT_PREFIX": "",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM": "",
        "GIT_FLUSH": "",
    }

def _materialize_env(empty, empty_dir, bare_abs):
    """Environment for one materialization command: nothing but PATH and a scratch HOME.

    `ctx.execute` inherits the host environment, so every selector is
    overridden explicitly: `HOME` and `XDG_CONFIG_HOME` point at the shared
    empty directory (neither `<dir>/.gitconfig` nor `<dir>/git/config`
    exists), system config is disabled, the global and system file selectors
    point at the shared empty file, the inline-config selectors are emptied,
    replacements are disabled, the object and common directories are pinned
    at the bare repository, and every transport-executing variable (SSH,
    askpass, proxies) is emptied — materialization never touches the
    network. `GIT_DIR` is left to the argv flag: `--git-dir` beats it on
    every git version, and an empty value is fatal. `GIT_WORK_TREE` is
    likewise inherited but inert: every materialization command runs against
    a bare repository with no worktree operation. What `ctx.execute` merges
    in untouched is only `PATH` (which locates the `git` binary) and
    transport-adjacent variables nothing here consults.

    Args:
        empty: The shared empty file's path string.
        empty_dir: The shared empty directory's path string.
        bare_abs: The bare repository's absolute path string.

    Returns:
        The `environment` dict for one materialization `ctx.execute` call.
    """
    return {
        "HOME": empty_dir,
        "XDG_CONFIG_HOME": empty_dir,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": empty,
        "GIT_CONFIG_SYSTEM": empty,
        "GIT_CONFIG_COUNT": "",
        "GIT_CONFIG_PARAMETERS": "",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_TEMPLATE_DIR": empty_dir,
        "GIT_OBJECT_DIRECTORY": bare_abs + "/objects",
        "GIT_COMMON_DIR": bare_abs,
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": "",
        "GIT_ALLOW_PROTOCOL": _GIT_ALLOW_PROTOCOL,
        "GIT_INDEX_FILE": "",
        "GIT_NAMESPACE": "",
        "GIT_REPLACE_REF_BASE": "",
        "GIT_CEILING_DIRECTORIES": "",
        "GIT_PREFIX": "",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM": "",
        "GIT_SSH": "",
        "GIT_SSH_COMMAND": "",
        "GIT_ASKPASS": "",
        "GIT_PROXY_COMMAND": "",
        "GIT_EDITOR": "",
        "GIT_PAGER": "",
        "GIT_FLUSH": "",
        "GIT_TRACE": "",
        "GIT_TRACE_PACK_ACCESS": "",
        "GIT_TRACE_PACKET": "",
        "GIT_TRACE_PERFORMANCE": "",
        "GIT_TRACE_SETUP": "",
        "GIT_CURL_VERBOSE": "",
    }

def git_transport_fetch(ctx, url, bare_rel, resolved_ref, what):
    """Fetches the pinned commit into a fresh bare repository (phase 1: transport).

    `git init --bare` (with `--template=` at the shared empty directory, so
    no host template's `info/attributes` or `hooks/` ever reach the clone)
    plus `git fetch <url> <sha>` (falling back to fetching all refs on
    servers that reject a bare SHA, such as some corporate mirrors). Nothing
    is ever checked out: with no working tree, host hooks, `core.fsmonitor`
    and working-tree attributes have nothing to act on, and the command-line
    pins (`core.hooksPath`, `core.fsmonitor=false`,
    `core.untrackedCache=false`, `--no-replace-objects`) keep them off even
    where host configuration is deliberately inherited for transport. The
    bare repository's directories are pre-created (via a `keep` file, since
    `ctx.file` cannot create an empty directory) so the object and common
    directory pins always name existing paths, and the repository-local
    `info/attributes` is truncated right after `init` (git has no switch for
    that file; the package's own committed `.gitattributes` are untouched
    and keep the documented behaviour).

    A host that exports `GIT_WORK_TREE` fails this function loudly at
    `init`: git refuses to initialize while it is set, and no scrubbed value
    satisfies it. That variable is never set during builds, and every later
    command ignores it.

    Args:
        ctx: A repository or module-extension context.
        url: The git remote URL (or local path, or bundle path) to fetch.
        bare_rel: The repository-relative bare directory (for example
            `"_git_bare"`): relative so the pre-creation and the attributes
            truncation work with `ctx.file` on every context, including
            module extensions, which have no `ctx.delete`.
        resolved_ref: The pinned full 40-hex commit SHA.
        what: Human-readable label of the fetching rule, for diagnostics.
    """
    empty_dir = _git_empty_dir(ctx)
    bare_abs = str(ctx.path(bare_rel))

    # Pre-create the bare repository's directories: the object and common
    # directory pins below must name existing paths (git rejects empty
    # values there), and `ctx.file` creates parents but not empty
    # directories, so a `keep` file stands in. A stray top-level file in
    # `objects/` is inert: git only reads the `info/`, `pack/` entries and
    # two-hex subdirectories there.
    ctx.file(bare_rel + "/objects/keep", "", executable = False)

    res = ctx.execute(
        ["git", "--no-replace-objects"] + [
            "-c",
            "core.hooksPath=" + empty_dir,
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "init",
            "--bare",
            "--template=" + empty_dir,
            bare_abs,
        ],
        environment = _transport_env(empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: git init failed for %s: %s" % (what, url, res.stderr))

    # The clone's repository-local attributes file is truncated (git has no
    # switch for it): with the empty template it is already absent, but a
    # hostile `init.templateDir` file entry is beaten by the `--template=`
    # flag only for copied content, so the truncation closes the file
    # itself. Committed `.gitattributes` are untouched.
    ctx.file(bare_rel + "/info/attributes", "", executable = False)

    res = ctx.execute(
        ["git", "--no-replace-objects"] + [
            "--git-dir=" + bare_abs,
            "-c",
            "core.hooksPath=" + empty_dir,
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "fetch",
            url,
            resolved_ref,
        ],
        environment = _transport_env(empty_dir, bare_abs),
    )
    if res.return_code != 0:
        # Servers that reject fetching a bare SHA still serve the commit on
        # its refs: fetch everything and let the materialization phase verify
        # the pinned commit arrived.
        res = ctx.execute(
            ["git", "--no-replace-objects"] + [
                "--git-dir=" + bare_abs,
                "-c",
                "core.hooksPath=" + empty_dir,
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.untrackedCache=false",
                "fetch",
                url,
                "+refs/*:refs/origin/*",
            ],
            environment = _transport_env(empty_dir, bare_abs),
        )
    if res.return_code != 0:
        fail("%s: git fetch failed for %s at %s: %s" % (what, url, resolved_ref, res.stderr))

def git_materialize(ctx, bare_rel, resolved_ref, output, spec, what):
    """Verifies the pinned commit and archives it, isolated from the host (phase 2).

    Every git command here runs against the phase-1 bare repository with an
    explicit `--git-dir`, `--no-replace-objects`, the hook/fsmonitor pins,
    and the scrubbed `_materialize_env` environment (PATH plus a scratch
    HOME; no host config file, variable, template, hook, fsmonitor,
    replacement ref or alternate object store is consulted). The sequence
    refuses a repository with `objects/info/alternates` (a fresh `init`
    never writes that file), verifies the commit object id (`rev-parse
    --verify <sha>^{commit}` must print the pinned SHA) and its type
    (`cat-file -t` must say `commit`), reads the commit's tree (`rev-parse
    <sha>^{tree}`), and only then streams `git archive` of the pinned spec
    from the same repository under the same environment: the tree written
    out is by construction the verified commit's tree, because no remaining
    host channel can make the verification and the archive resolve the same
    SHA differently. The archive pins the byte conversion knobs
    (`core.autocrlf=false`, `core.eol=lf`, an empty `core.attributesFile`,
    `tar.umask=002`) so the bytes depend only on the pinned commit and its
    own committed `.gitattributes`.

    Args:
        ctx: A repository or module-extension context.
        bare_rel: The repository-relative bare directory created by
            `git_transport_fetch`.
        resolved_ref: The pinned full 40-hex commit SHA.
        output: Where to write the tar archive (or its string path).
        spec: The archive spec: the pinned commit, or `<commit>:<path>` for a
            package living in a subdirectory of its repository.
        what: Human-readable label of the fetching rule, for diagnostics.
    """
    empty_dir = _git_empty_dir(ctx)
    empty = _git_empty_file(ctx)
    bare_abs = str(ctx.path(bare_rel))

    # Materialization-time truncation: the transport phase already truncated
    # this file, and nothing legitimate rewrites it in between, so whatever
    # it holds now is hostile by definition.
    ctx.file(bare_rel + "/info/attributes", "", executable = False)

    res = ctx.execute(
        ["git", "--no-replace-objects"] + [
            "--git-dir=" + bare_abs,
            "-c",
            "core.hooksPath=" + empty_dir,
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "count-objects",
            "-v",
        ],
        environment = _materialize_env(empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: git count-objects failed at %s: %s" % (what, resolved_ref, res.stderr))
    for line in res.stdout.splitlines():
        if line.startswith("alternate:"):
            fail("%s: refusing git repository with alternates (%s)." % (what, line.strip()))

    res = ctx.execute(
        ["git", "--no-replace-objects"] + [
            "--git-dir=" + bare_abs,
            "-c",
            "core.hooksPath=" + empty_dir,
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "rev-parse",
            "--verify",
            str(resolved_ref) + "^{commit}",
        ],
        environment = _materialize_env(empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: could not verify the fetched commit: %s" % (what, res.stderr))
    actual = res.stdout.strip()
    if actual != str(resolved_ref).strip():
        fail("%s: fetched commit %r does not match the pinned resolved-ref %r." % (what, actual, resolved_ref))

    res = ctx.execute(
        ["git", "--no-replace-objects"] + [
            "--git-dir=" + bare_abs,
            "-c",
            "core.hooksPath=" + empty_dir,
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "cat-file",
            "-t",
            str(resolved_ref),
        ],
        environment = _materialize_env(empty, empty_dir, bare_abs),
    )
    if res.return_code != 0 or res.stdout.strip() != "commit":
        fail("%s: resolved-ref %r is not a commit object." % (what, resolved_ref))

    res = ctx.execute(
        ["git", "--no-replace-objects"] + [
            "--git-dir=" + bare_abs,
            "-c",
            "core.hooksPath=" + empty_dir,
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "rev-parse",
            str(resolved_ref) + "^{tree}",
        ],
        environment = _materialize_env(empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: could not read the tree of %r: %s" % (what, resolved_ref, res.stderr))

    res = ctx.execute(
        ["git", "--no-replace-objects"] + [
            "--git-dir=" + bare_abs,
            "-c",
            "core.autocrlf=false",
            "-c",
            "core.eol=lf",
            "-c",
            "core.attributesfile=" + empty,
            "-c",
            "core.hooksPath=" + empty_dir,
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "-c",
            "tar.umask=002",
            "archive",
            "--format=tar",
            "-o",
            str(output),
            spec,
        ],
        environment = _materialize_env(empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: git archive failed at %s: %s" % (what, spec, res.stderr))
