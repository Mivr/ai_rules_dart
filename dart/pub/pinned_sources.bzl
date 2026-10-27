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
   fresh BARE repository that is assembled without running `git init` at
   all — the helper writes the skeleton (`HEAD`, `config`, `objects/`,
   `refs/`) with `ctx.file`, checks the host git version (2.32 or newer is
   required, because older git ignores the config-file replacements below),
   resolves the fetch URL with `git ls-remote --get-url` (which applies the
   host's `url.<base>.insteadOf` rewrites without contacting the remote),
   then runs `git fetch` with the pinned SHA (the lock URL unchanged for a
   remote resolution, the resolved URL only for a local one), falling
   back to fetching all refs on servers that reject a bare SHA. Skipping
   `init` removes the host template surface by construction (no template
   is ever copied, so no template `info/attributes` or `hooks/` can reach
   the clone), and it removes the one command `GIT_WORK_TREE` breaks: git
   refuses `init` while that variable is set, even empty, while every
   other command ignores it on a bare repository with no worktree
   operation. There is no working tree, so no checkout ever runs: hooks,
   `core.fsmonitor` and working-tree attributes have nothing to act on.
   Hooks and fsmonitor are additionally pinned off on the command line
   (`-c` beats config files and environment on every git version), as is
   every fetch-time switch git consults during a bare fetch that could
   fail the pinned fetch or add work on one host and not another
   (`transfer`/`fetch.fsckObjects`, `gc.auto`, `maintenance.auto`,
   `fetch.writeCommitGraph`, `fetch.recurseSubmodules`,
   `submodule.recurse`, `fetch.prune`, `fetch.pruneTags` — see
   `_transport_config_args`). The wire protocol is pinned at version 2, so
   a host `protocol.version=0` cannot push the fetch onto the all-refs
   fallback (which would store host-dependent refs and tags). Every
   repository-resolution selector the
   host could otherwise redirect is
   pinned at the new bare repository instead: `--git-dir` (which beats
   `GIT_DIR`), `GIT_OBJECT_DIRECTORY` and `GIT_COMMON_DIR` (pointed at
   the new repository's own directories, which are pre-created so the
   pins always name existing paths), and `--no-replace-objects` plus
   `GIT_NO_REPLACE_OBJECTS=1` (which beat replace refs from any source).
   Every other documented non-transport `GIT_*` variable is unset with
   `None` (which `ctx.execute` removes from the child process — an empty
   string would stay set, and git treats a set-but-empty
   `GIT_QUARANTINE_PATH`, `GIT_WORK_TREE` or
   `GIT_INTERNAL_SUPER_PREFIX` as fatal): `GIT_DIR`, `GIT_WORK_TREE`,
   `GIT_INTERNAL_SUPER_PREFIX`, `GIT_EXEC_PATH`, `GIT_INDEX_FILE`,
   `GIT_NAMESPACE`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
   `GIT_QUARANTINE_PATH`, `GIT_REPLACE_REF_BASE`,
   `GIT_CEILING_DIRECTORIES`, `GIT_DISCOVERY_ACROSS_FILESYSTEM`,
   `GIT_PREFIX`, `GIT_TEMPLATE_DIR`, `GIT_GRAFT_FILE`, the
   `GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS` inline-config channel,
   and the editor, pager and tracing variables, plus every other
   `GIT_*` name in the host environment, closing undocumented and future
   variables. `GIT_INTERNAL_SUPER_PREFIX`
   likewise stays dropped (only git itself ever sets it). What is
   deliberately
   inherited is only transport: the host's config files (which may carry
   `insteadOf` rewrites) and the SSH, TLS, proxy and credential-helper
   variables allowlisted in `_TRANSPORT_PASSTHROUGH`. Whether a fetch is
   local is decided on the resolved URL, after the host's `insteadOf`
   rewriting: for a fetch that resolves to a local repository (`file://`,
   plain paths, bundles) even the config files are replaced — the global
   and system selectors point at the shared empty file, and the
   `GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS` inline-config channel is
   unset — so a host-global `uploadpack.packObjectsHook` (which runs on
   every local fetch, where `-c` pins cannot reach it) stays unread
   however the local repository was named; local fetches need no
   credentials, and only they fetch the resolved URL — a remote resolution
   keeps the lock URL on the fetch commands, so the inherited rewrites
   apply to it once, exactly as before. `GIT_ALLOW_PROTOCOL`
   is pinned to a fixed transport-only list so host state cannot widen
   the fetch to a command-executing helper. The `--` before the URL keeps
   a lock URL from being read as an option.
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
   is refused outright (the assembled skeleton never writes that file, so its
   presence means tampering). Verification reads the commit object id
   (`rev-parse --verify <sha>^{commit}` must print the pinned SHA), its type
   (`cat-file -t` must say `commit`), and the commit's tree id (`rev-parse
   <sha>^{tree}` must succeed), all under that empty environment; the archive is then
   streamed from the same bare repository under the same environment, so the
   tree written out is by construction the verified commit's tree — no host
   channel can make the two commands resolve the same SHA differently once
   replacements, alternates, templates, hooks, fsmonitor and every config
   source are pinned or removed. For a subdirectory package
   (`<commit>:<path>`) the archived spec is a synthetic commit of that
   tree with the pinned commit's committer date, so every entry carries
   the pinned time instead of the fetch's wall-clock time. The archive
   additionally pins the byte
   conversion knobs (`core.autocrlf=false`, `core.eol=lf`,
   `core.attributesFile` at the empty file, `tar.umask=002`), and the
   repository-local `info/attributes` holds the override below, written
   before the archive (and already at transport time).

The package's own `export-subst`, `export-ignore` and
`working-tree-encoding` attributes are turned off: before `git archive`,
the helper writes `* -export-subst -export-ignore -working-tree-encoding`
into the bare repository's `info/attributes`, which outranks the committed
`.gitattributes`. Placeholders stay literal and export-ignored files are
kept, exactly as `dart pub get` materializes the same package (it checks
out a work tree and applies neither). Other committed attributes (such as
`eol`) still apply, and remain a pure function of the pinned commit. Only
host-side configuration is neutralized.
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

# Repository-local attributes override, written into the bare repository's
# `info/attributes` (which outranks the committed `.gitattributes`) before
# any archive runs. `export-subst` placeholders would otherwise expand from
# host state that is not a function of the pinned commit (stored refs and
# tags, pack-vs-loose abbreviation length, the wall clock, host gpg/ssh
# programs), and `export-ignore` would drop files `dart pub get` keeps.
_GIT_ATTRIBUTES_OVERRIDE = "* -export-subst -export-ignore -working-tree-encoding\n"

def _is_local_url(url):
    """Whether a git URL is served from the local machine.

    The input is the resolved fetch URL (after the host's `insteadOf`
    rewriting): a remote lock URL that the host rewrites to a local path
    fetches locally, so it is classified here exactly like a lock URL that
    is local to begin with.

    Local transports (`file://`, plain paths, bundles) need no credentials,
    so their fetch environment replaces the host's global and system config
    files with the empty file — closing, among others, a host-global
    `uploadpack.packObjectsHook`, which runs on every local fetch and which
    `-c` pins cannot reach. An scp-like `host:path` remote has its colon
    before any slash and stays remote (a single-letter `C:\\...` drive
    prefix stays local); anything with a `://` scheme other than `file://`
    stays remote.

    Args:
        url: The git remote URL, local path or bundle path to classify.

    Returns:
        True for local URLs, False for remote ones.
    """
    if url.startswith("file://"):
        return True
    if "://" in url:
        return False
    colon = url.find(":")
    if colon == -1:
        return True
    if colon == 1:
        return True
    seps = [i for i in [url.find("/"), url.find("\\")] if i != -1]
    if not seps:
        return False
    return colon > min(seps)

# Minimum host git version. Git older than 2.32 ignores the
# `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` replacements (environment
# support for them landed in 2.32), silently reading the host's files
# instead — so every fetch checks `git version` before running any other
# git command and fails below this floor.
_GIT_MIN_MAJOR = 2
_GIT_MIN_MINOR = 32

def _is_digits(text):
    """Whether a string is a non-empty run of ASCII digits.

    Args:
        text: The string to check.

    Returns:
        True for `"0"`, `"32"`, `"45"`; False for `""`, `"2x"`, `" 2"`.
    """
    if not text:
        return False
    for char in text.elems():
        if char not in "0123456789":
            return False
    return True

def parse_git_version(output):
    """Parses `git version` output into a `[major, minor]` version pair.

    Accepts the shapes git prints, such as `"git version 2.39.5"`,
    `"git version 2.39.5 (Apple Git-154)"` and
    `"git version 2.45.1.windows.1"`: only the leading `major.minor`
    matters, and anything after the patch release is platform decoration.

    Args:
        output: The stdout string of `git version`.

    Returns:
        A two-element `[major, minor]` int list, or None when the output
        does not start with a `git version <digits>.<digits>` prefix.
    """
    text = output.strip()
    prefix = "git version "
    if not text.startswith(prefix):
        return None
    dotted = text[len(prefix):].split(" ")[0].split(".")
    if len(dotted) < 2:
        return None
    if not _is_digits(dotted[0]) or not _is_digits(dotted[1]):
        return None
    return [int(dotted[0]), int(dotted[1])]

def git_version_error(output, what):
    """Checks `git version` output against the minimum supported git.

    Args:
        output: The stdout string of `git version`.
        what: Human-readable label of the fetching rule, for diagnostics.

    Returns:
        None when the host git is supported; otherwise an error string
        naming the minimum supported version and the version found (or the
        unparsable output, which fails closed).
    """
    parsed = parse_git_version(output)
    if parsed == None:
        return "%s: could not determine the host git version (git %d.%d or newer is required), got %r." % (what, _GIT_MIN_MAJOR, _GIT_MIN_MINOR, output.strip())
    if parsed[0] < _GIT_MIN_MAJOR or (parsed[0] == _GIT_MIN_MAJOR and parsed[1] < _GIT_MIN_MINOR):
        return "%s: host git version %d.%d is below the minimum supported version %d.%d." % (what, parsed[0], parsed[1], _GIT_MIN_MAJOR, _GIT_MIN_MINOR)
    return None

def _require_git_version(ctx, env, what):
    """Fails unless the host git reports version 2.32 or newer.

    Runs before any other git command of the fetch: older git silently
    ignores the config-file replacements, so an unparsable version, a
    failing `git version`, and a version below the floor all fail the
    fetch loudly instead of fetching under host configuration.

    Args:
        ctx: A repository or module-extension context.
        env: The `environment` dict for the version check.
        what: Human-readable label of the fetching rule, for diagnostics.
    """
    res = ctx.execute(
        ["git", "--no-replace-objects", "version"],
        environment = env,
    )
    if res.return_code != 0:
        fail("%s: checking the host git version failed (git %d.%d or newer is required): %s" % (what, _GIT_MIN_MAJOR, _GIT_MIN_MINOR, res.stderr.strip()))
    err = git_version_error(res.stdout, what)
    if err:
        fail(err)

def _transport_config_args(empty_dir):
    """`-c` pins shared by every transport fetch command line (SHA and all-refs fallback).

    `-c` beats config files and the inline-config environment channel on
    every git version, including payloads a host file pulls in through
    `include`/`includeIf` chains conditioned on the skeleton path — so the
    fetch behaves like a default-configured host everywhere. Materialization
    stays unchanged: the SHA and tree verification there remain the
    integrity check. One line of reason per pin:

    Args:
        empty_dir: The shared empty directory's path string (hooks target).

    Returns:
        The `-c` flag pairs for one transport `git fetch` argv.
    """
    return [
        "-c",
        "core.hooksPath=" + empty_dir,  # Hooks have no checkout to run on a bare repository.
        "-c",
        "core.fsmonitor=false",  # No working tree exists for fsmonitor to watch.
        "-c",
        "core.untrackedCache=false",  # No working tree exists for the untracked cache.
        "-c",
        "transfer.fsckObjects=false",  # Receive-side fsck off (git default); the SHA is verified in materialization.
        "-c",
        "fetch.fsckObjects=false",  # Fetch-specific fsck off (git default); remote fetches match local ones.
        "-c",
        "gc.auto=0",  # No post-fetch auto-repack; host thresholds cannot add repack work.
        "-c",
        "maintenance.auto=false",  # No post-fetch background maintenance jobs.
        "-c",
        "fetch.writeCommitGraph=false",  # No post-fetch commit-graph files.
        "-c",
        "fetch.recurseSubmodules=false",  # Never recurse into submodules; host cannot add submodule fetches.
        "-c",
        "submodule.recurse=false",  # Companion recursion switch off; host cannot widen the fetch.
        "-c",
        "fetch.prune=false",  # Never prune refs; host cannot delete freshly fetched refs.
        "-c",
        "fetch.pruneTags=false",  # Never prune tags; host cannot delete freshly fetched tags.
        "-c",
        # Speak v2 even under a host protocol.version=0, which would otherwise refuse the bare-SHA fetch and push it
        # onto the all-refs fallback (landing host-dependent refs and tags).
        "protocol.version=2",
    ]

# Transport variables inherited from the host environment, copied verbatim
# only when the host sets them. The list is an allowlist: transport needs
# are met by copying these and nothing else, while every other `GIT_*`
# variable the host sets is unset in `_transport_env`. Each entry is
# transport only — SSH and TLS settings, HTTP knobs, proxy commands,
# credential helpers, and the inline-config channel carrying `url.<base>`
# `insteadOf` rewrites — which private repositories need; nothing here can
# redirect repository resolution or execute code during a bare fetch beyond
# what the inherited config files already allow, and the `-c` pins on every
# transport command line override any smuggled configuration.
_TRANSPORT_PASSTHROUGH = [
    "GIT_SSH",
    "GIT_SSH_COMMAND",
    "GIT_SSH_VARIANT",
    "GIT_SSL_CAINFO",
    "GIT_SSL_CAPATH",
    "GIT_SSL_CERT",
    "GIT_SSL_KEY",
    "GIT_SSL_CIPHER_LIST",
    "GIT_SSL_VERSION",
    "GIT_SSL_NO_VERIFY",
    "GIT_PROXY_COMMAND",
    "GIT_ASKPASS",
    "GIT_TERMINAL_PROMPT",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS",
]

# Prefix families copied verbatim like the entries above: every `http.*`
# knob, and the numbered inline-config slots (`GIT_CONFIG_KEY_<n>` /
# `GIT_CONFIG_VALUE_<n>`), which are meaningless without the count above.
_TRANSPORT_PASSTHROUGH_PREFIXES = [
    "GIT_HTTP_",
    "GIT_CONFIG_KEY_",
    "GIT_CONFIG_VALUE_",
]

# The inline-config channel slots. Carried verbatim for remote fetches (a
# host-provided `insteadOf` rewrite keeps working there), unset for fetches
# that resolve to a local repository (no local fetch needs host
# configuration, and the channel would otherwise reach the fetch even with
# the config files replaced).
_INLINE_CONFIG_VARS = [
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS",
]
_INLINE_CONFIG_PREFIXES = [
    "GIT_CONFIG_KEY_",
    "GIT_CONFIG_VALUE_",
]

def _is_inline_config_variable(var):
    """Whether a host `GIT_*` variable belongs to the inline-config channel.

    Args:
        var: The variable name.

    Returns:
        True for the count and parameters entries and the numbered key and
        value slots (`_INLINE_CONFIG_VARS`, `_INLINE_CONFIG_PREFIXES`).
    """
    if var in _INLINE_CONFIG_VARS:
        return True
    for prefix in _INLINE_CONFIG_PREFIXES:
        if var.startswith(prefix):
            return True
    return False

# Config-file selectors inherited verbatim by staying out of the environment
# dict: transport file configuration (which may carry `insteadOf` rewrites,
# credentials and proxies) needs the host's global and system files
# readable. They are exempt from the `_transport_env` sweep below.
_TRANSPORT_INHERITED = [
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_NOSYSTEM",
]

def _is_transport_variable(var):
    """Whether a host `GIT_*` variable belongs to the transport allowlist.

    Args:
        var: The variable name.

    Returns:
        True for the verbatim-copied entries and prefix families
        (`_TRANSPORT_PASSTHROUGH`, `_TRANSPORT_PASSTHROUGH_PREFIXES`) and
        the inherited selectors (`_TRANSPORT_INHERITED`).
    """
    if var in _TRANSPORT_PASSTHROUGH or var in _TRANSPORT_INHERITED:
        return True
    for prefix in _TRANSPORT_PASSTHROUGH_PREFIXES:
        if var.startswith(prefix):
            return True
    return False

def _transport_env(ctx, bare_abs, empty, local):
    """Environment for one transport command: host transport, pinned resolution.

    The host's transport configuration is deliberately inherited — config
    files (which may carry `url.<base>.insteadOf` rewrites) and the
    allowlisted SSH, TLS, HTTP, proxy, credential-helper and inline-config
    variables keep working, which private repositories need. Everything else
    the host could steer resolution or bytes with is unset: every documented
    non-transport `GIT_*` variable maps to `None` (which `ctx.execute`
    removes from the child process on Bazel 9.3 — an empty string would
    stay set, and git treats a set-but-empty `GIT_QUARANTINE_PATH`,
    `GIT_WORK_TREE` or `GIT_INTERNAL_SUPER_PREFIX` as fatal), and so does
    every other key in `ctx.os.environ` starting with `GIT_` that is not on
    the transport allowlist, closing undocumented and future variables. The
    object and common directories are pinned at the new bare repository
    (whose directories are pre-created so the pins always name existing
    paths), the protocol allowlist is pinned, and replacements are disabled
    twice (flag and variable). The inline-config channel passes through
    verbatim on purpose — a host-provided `insteadOf` rewrite keeps working
    — while the `-c` pins on every transport command line override it, so it
    cannot redirect repository resolution or re-enable hooks, fsmonitor,
    templates or replacements. For a fetch that resolves to a local
    repository the global and system config
    selectors point at the shared empty file instead of staying inherited:
    local fetches need no credentials, and a host-global
    `uploadpack.packObjectsHook` (which git runs on every local fetch
    without consulting `-c` pins) stays unread — and the inline-config
    channel is unset too, so the same hook cannot arrive through
    `GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS` either.

    Args:
        ctx: A repository or module-extension context (for `os.environ`).
        bare_abs: The bare repository's absolute path string.
        empty: The shared empty file's path string (local config replacement).
        local: Whether the resolved fetch URL is local (see `_is_local_url`).

    Returns:
        The `environment` dict for one transport `ctx.execute` call. It
        carries no empty-string value: unsets are `None`, pins are paths.
    """
    env = {
        "GIT_DIR": None,
        "GIT_WORK_TREE": None,
        "GIT_INTERNAL_SUPER_PREFIX": None,
        "GIT_EXEC_PATH": None,
        "GIT_OBJECT_DIRECTORY": bare_abs + "/objects",
        "GIT_COMMON_DIR": bare_abs,
        "GIT_INDEX_FILE": None,
        "GIT_INDEX_VERSION": None,
        "GIT_NAMESPACE": None,
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": None,
        "GIT_QUARANTINE_PATH": None,
        "GIT_REPLACE_REF_BASE": None,
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_CEILING_DIRECTORIES": None,
        "GIT_DISCOVERY_ACROSS_FILESYSTEM": None,
        "GIT_PREFIX": None,
        "GIT_SUPER_PREFIX": None,
        "GIT_TEMPLATE_DIR": None,
        "GIT_ALLOW_PROTOCOL": _GIT_ALLOW_PROTOCOL,
        "GIT_GRAFT_FILE": None,
        "GIT_AUTHOR_NAME": None,
        "GIT_AUTHOR_EMAIL": None,
        "GIT_AUTHOR_DATE": None,
        "GIT_COMMITTER_NAME": None,
        "GIT_COMMITTER_EMAIL": None,
        "GIT_COMMITTER_DATE": None,
        "GIT_REFLOG_ACTION": None,
        "GIT_FLUSH": None,
        "GIT_EDITOR": None,
        "GIT_PAGER": None,
        "GIT_EXTERNAL_DIFF": None,
        "GIT_DIFF_OPTS": None,
        "GIT_LITERAL_PATHSPECS": None,
        "GIT_TRACE": None,
        "GIT_TRACE_PACK_ACCESS": None,
        "GIT_TRACE_PACKET": None,
        "GIT_TRACE_PERFORMANCE": None,
        "GIT_TRACE_SETUP": None,
        "GIT_CURL_VERBOSE": None,
    }
    if local:
        env["GIT_CONFIG_GLOBAL"] = empty
        env["GIT_CONFIG_SYSTEM"] = empty
        env["GIT_CONFIG_COUNT"] = None
        env["GIT_CONFIG_PARAMETERS"] = None
    host = ctx.os.environ
    for var in host:
        if var in env:
            # Scrubbed (`None`), pinned, or already passed through below.
            # The local replacements above win over inheritance:
            # `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` stay pointed at the
            # empty file instead of the host's files, and the inline-config
            # channel stays unset instead of carrying host configuration.
            continue
        if var in _TRANSPORT_INHERITED:
            # Inherited verbatim: left out of the dict, which `ctx.execute`
            # merges over the host environment.
            continue
        if local and _is_inline_config_variable(var):
            env[var] = None
        elif _is_transport_variable(var):
            env[var] = host[var]
        elif var.startswith("GIT_"):
            env[var] = None
    for var in _TRANSPORT_PASSTHROUGH:
        if var in host and not (local and _is_inline_config_variable(var)):
            env[var] = host[var]
    return env

def _resolve_fetch_url(ctx, env, bare_abs, url, what):
    """Expands `url.<base>.insteadOf` rewrites to the URL git will fetch.

    `git ls-remote --get-url` applies the host's rewrites — from the config
    files and the inline-config channel carried in `env` — without
    contacting the remote, so the local/remote isolation decision sees the
    same URL the fetch would use. A host rewrite of a remote lock URL to a
    local repository is exactly what this is for: only a fetch that resolves
    to a local repository runs against the returned URL, because the isolated
    local environment no longer carries the rewrite that produced it. A
    remote resolution keeps the lock URL on the fetch commands below — the
    inheriting fetch environment still carries the host's rewrites, so git
    applies them to the lock URL once, as it always has.

    Args:
        ctx: A repository or module-extension context.
        env: The inheriting transport `environment` dict, so rewrites apply.
        bare_abs: The bare repository's absolute path string (pins repo
            discovery instead of walking up from the execution root).
        url: The lock URL to resolve.
        what: Human-readable label of the fetching rule, for diagnostics.

    Returns:
        The effective fetch URL string.
    """
    res = ctx.execute(
        ["git", "--no-replace-objects", "--git-dir=" + bare_abs, "ls-remote", "--get-url", "--", url],
        environment = env,
    )
    if res.return_code != 0:
        fail("%s: resolving the fetch URL %r failed: %s" % (what, url, res.stderr))
    effective = res.stdout.strip()
    if not effective:
        fail("%s: resolving the fetch URL %r produced an empty URL." % (what, url))
    return effective

def _materialize_env(ctx, empty, empty_dir, bare_abs):
    """Environment for one materialization command: nothing but PATH and a scratch HOME.

    `ctx.execute` inherits the host environment, so every selector is
    overridden explicitly: `HOME` and `XDG_CONFIG_HOME` point at the shared
    empty directory (neither `<dir>/.gitconfig` nor `<dir>/git/config`
    exists), system config is disabled, the global and system file selectors
    point at the shared empty file, replacements are disabled, the object
    and common directories are pinned at the bare repository, and every
    transport-executing variable (SSH, askpass, proxies) is unset —
    materialization never touches the network. `GIT_DIR` is unset and left
    to the argv flag: `--git-dir` beats it on every git version. So is
    `GIT_WORK_TREE`: every materialization command runs against a bare
    repository with no worktree operation, but git still validates the path
    when set — a nonexistent host work tree is fatal — so it is unset
    rather than inherited. Every other host `GIT_*` variable is unset too,
    closing undocumented and future variables. Unsets are `None` (which
    `ctx.execute` removes from the child process), never the empty string.
    What `ctx.execute` merges in untouched is only `PATH` (which locates
    the `git` binary) and non-`GIT_*` variables nothing here consults.

    Args:
        ctx: A repository or module-extension context (for `os.environ`).
        empty: The shared empty file's path string.
        empty_dir: The shared empty directory's path string.
        bare_abs: The bare repository's absolute path string.

    Returns:
        The `environment` dict for one materialization `ctx.execute` call.
        It carries no empty-string value: unsets are `None`, pins are
        paths.
    """
    env = {
        "HOME": empty_dir,
        "XDG_CONFIG_HOME": empty_dir,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": empty,
        "GIT_CONFIG_SYSTEM": empty,
        "GIT_CONFIG_COUNT": None,
        "GIT_CONFIG_PARAMETERS": None,
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_TEMPLATE_DIR": empty_dir,
        "GIT_OBJECT_DIRECTORY": bare_abs + "/objects",
        "GIT_COMMON_DIR": bare_abs,
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": None,
        "GIT_ALLOW_PROTOCOL": _GIT_ALLOW_PROTOCOL,
        "GIT_DIR": None,
        "GIT_WORK_TREE": None,
        "GIT_INDEX_FILE": None,
        "GIT_NAMESPACE": None,
        "GIT_REPLACE_REF_BASE": None,
        "GIT_CEILING_DIRECTORIES": None,
        "GIT_PREFIX": None,
        "GIT_DISCOVERY_ACROSS_FILESYSTEM": None,
        "GIT_SSH": None,
        "GIT_SSH_COMMAND": None,
        "GIT_ASKPASS": None,
        "GIT_PROXY_COMMAND": None,
        "GIT_EDITOR": None,
        "GIT_PAGER": None,
        "GIT_FLUSH": None,
        "GIT_TRACE": None,
        "GIT_TRACE_PACK_ACCESS": None,
        "GIT_TRACE_PACKET": None,
        "GIT_TRACE_PERFORMANCE": None,
        "GIT_TRACE_SETUP": None,
        "GIT_CURL_VERBOSE": None,
    }
    for var in ctx.os.environ:
        if var not in env and var.startswith("GIT_"):
            env[var] = None
    return env

def git_transport_fetch(ctx, url, bare_rel, resolved_ref, what):
    """Fetches the pinned commit into a fresh bare repository (phase 1: transport).

    The host git version is checked first (2.32 or newer is required), then
    the bare repository is assembled without running `git init`: the
    skeleton (`HEAD`, `config`, `objects/`, `refs/`) is written with
    `ctx.file`, the lock URL is resolved with `git ls-remote --get-url`
    (which applies the host's `url.<base>.insteadOf` rewrites without
    contacting the remote), and `git fetch` runs with the pinned SHA
    (falling back to fetching all refs on servers that reject a bare SHA,
    such as some corporate mirrors): the lock URL unchanged when the
    resolution is remote — the inheriting fetch environment still carries
    the host's rewrites, so git applies them to the lock URL once, as it
    always has — and the resolved URL only when the resolution is local,
    where the isolated environment no longer carries the rewrite that
    produced it. The `--` keeps a lock URL from being read as an option. Whether the fetch is local is decided on the
    resolved URL: a remote lock URL that the host rewrites to a local
    repository fetches with the same isolation as a lock URL that is local
    to begin with — no host config file is read, the inline-config channel
    is unset, and no host hook of any kind runs — while remote fetches keep
    inheriting the host's transport configuration. Skipping `init` removes
    the host template surface by construction — no template is ever copied,
    so no template `info/attributes` or `hooks/` can reach the clone — and
    every non-transport host `GIT_*` variable (including `GIT_WORK_TREE`,
    `GIT_QUARANTINE_PATH` and any undocumented or future `GIT_*` entry) is
    unset in the fetch environment rather than inherited. Nothing is ever
    checked out: with no working tree, host hooks, `core.fsmonitor` and
    working-tree attributes have nothing to act on, and the command-line
    pins (`core.hooksPath`, `core.fsmonitor=false`,
    `core.untrackedCache=false`, the `transfer`/`fetch.fsckObjects`,
    `gc.auto`, `maintenance.auto`, `fetch.writeCommitGraph`,
    `fetch.recurseSubmodules`, `submodule.recurse`, `fetch.prune`,
    `fetch.pruneTags` and `protocol.version=2` fetch-time switches,
    `--no-replace-objects`) keep
    them off even where host configuration is deliberately inherited for
    transport. The repository-local
    `info/attributes` holds `* -export-subst -export-ignore
    -working-tree-encoding` (nothing legitimate writes it; that file
    outranks the package's own committed `.gitattributes`, so placeholders
    stay literal and export-ignored files are kept, as with `dart pub
    get`).

    Args:
        ctx: A repository or module-extension context.
        url: The git remote URL (or local path, or bundle path) to fetch.
        bare_rel: The repository-relative bare directory (for example
            `"_git_bare"`): relative so the skeleton and the attributes
            override work with `ctx.file` on every context, including
            module extensions, which have no `ctx.delete`.
        resolved_ref: The pinned full 40-hex commit SHA.
        what: Human-readable label of the fetching rule, for diagnostics.
    """
    empty_dir = _git_empty_dir(ctx)
    empty = _git_empty_file(ctx)
    bare_abs = str(ctx.path(bare_rel))
    _require_git_version(ctx, _transport_env(ctx, bare_abs, empty, False), what)

    # Assemble the skeleton of a bare repository with `ctx.file` (which
    # creates parents but not empty directories, so `keep` files stand
    # in). The layout is the stable bare minimum every git version reads:
    # an unborn-HEAD symref, a minimal config marking the repository bare,
    # and the directories `is_git_directory` requires. A stray top-level
    # file in `objects/` is inert: git only reads the `info/`, `pack/`
    # entries and two-hex subdirectories there. `refs/.keep` is not a
    # valid ref name (components may not start with `.`), so ref
    # enumeration never sees it — and no phase command enumerates refs.
    ctx.file(bare_rel + "/objects/keep", "", executable = False)
    ctx.file(bare_rel + "/HEAD", "ref: refs/heads/main\n", executable = False)
    ctx.file(
        bare_rel + "/config",
        "[core]\n\trepositoryformatversion = 0\n\tbare = true\n",
        executable = False,
    )
    ctx.file(bare_rel + "/refs/.keep", "", executable = False)

    # The repository-local attributes file carries the export override (git
    # has no switch for it, and with no `init` nothing legitimate writes it).
    # `info/attributes` outranks the committed `.gitattributes`, so the
    # package's own `export-subst`/`export-ignore`/`working-tree-encoding`
    # entries stay inert and the archive matches `dart pub get`.
    ctx.file(bare_rel + "/info/attributes", _GIT_ATTRIBUTES_OVERRIDE, executable = False)

    resolve_env = _transport_env(ctx, bare_abs, empty, False)
    effective = _resolve_fetch_url(ctx, resolve_env, bare_abs, url, what)
    local = _is_local_url(effective)
    fetch_env = _transport_env(ctx, bare_abs, empty, local)

    # Only a fetch that resolved to a local repository uses the resolved
    # URL: the isolated local environment no longer carries the rewrite
    # that produced it. A remote resolution keeps the lock URL on both
    # fetch commands — the inheriting environment still carries the host's
    # `insteadOf` rewrites, so git applies them to the lock URL once, as
    # it always has. Fetching the resolved URL there would apply a chained
    # rewrite a second time (lock URL A resolving to B, then B rewritten
    # to C at fetch time) and land somewhere the lock URL never named.
    fetch_url = effective if local else url

    res = ctx.execute(
        ["git", "--no-replace-objects", "--git-dir=" + bare_abs] +
        _transport_config_args(empty_dir) + [
            "fetch",
            "--",
            fetch_url,
            resolved_ref,
        ],
        environment = fetch_env,
    )
    if res.return_code != 0:
        # Servers that reject fetching a bare SHA still serve the commit on
        # its refs: fetch everything and let the materialization phase verify
        # the pinned commit arrived.
        res = ctx.execute(
            ["git", "--no-replace-objects", "--git-dir=" + bare_abs] +
            _transport_config_args(empty_dir) + [
                "fetch",
                "--",
                fetch_url,
                "+refs/*:refs/origin/*",
            ],
            environment = fetch_env,
        )
    if res.return_code != 0:
        fail("%s: git fetch failed for %s at %s: %s" % (what, url, resolved_ref, res.stderr))

def _materialize_config_args(empty_dir):
    """The `-c` pins shared by every materialization command.

    `--no-replace-objects` stays spelled out at each `ctx.execute` call
    site (not here): the guard test requires the flag visible at every
    invocation so a new one without it fails.
    """
    return [
        "-c",
        "core.hooksPath=" + empty_dir,
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
    ]

def _refuse_alternates(ctx, bare_abs, empty, empty_dir, resolved_ref, what):
    """Fails when the bare repository carries an `objects/info/alternates` file."""
    res = ctx.execute(
        ["git", "--no-replace-objects", "--git-dir=" + bare_abs] +
        _materialize_config_args(empty_dir) + [
            "count-objects",
            "-v",
        ],
        environment = _materialize_env(ctx, empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: git count-objects failed at %s: %s" % (what, resolved_ref, res.stderr))
    for line in res.stdout.splitlines():
        if line.startswith("alternate:"):
            fail("%s: refusing git repository with alternates (%s)." % (what, line.strip()))

def _verify_commit_id(ctx, bare_abs, empty, empty_dir, resolved_ref, what):
    """Fails unless `rev-parse --verify <sha>^{commit}` prints the pinned SHA."""
    res = ctx.execute(
        ["git", "--no-replace-objects", "--git-dir=" + bare_abs] +
        _materialize_config_args(empty_dir) + [
            "rev-parse",
            "--verify",
            str(resolved_ref) + "^{commit}",
        ],
        environment = _materialize_env(ctx, empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: could not verify the fetched commit: %s" % (what, res.stderr))
    actual = res.stdout.strip()
    if actual != str(resolved_ref).strip():
        fail("%s: fetched commit %r does not match the pinned resolved-ref %r." % (what, actual, resolved_ref))

def _verify_commit_type(ctx, bare_abs, empty, empty_dir, resolved_ref, what):
    """Fails unless the pinned SHA names a commit object."""
    res = ctx.execute(
        ["git", "--no-replace-objects", "--git-dir=" + bare_abs] +
        _materialize_config_args(empty_dir) + [
            "cat-file",
            "-t",
            str(resolved_ref),
        ],
        environment = _materialize_env(ctx, empty, empty_dir, bare_abs),
    )
    if res.return_code != 0 or res.stdout.strip() != "commit":
        fail("%s: resolved-ref %r is not a commit object." % (what, resolved_ref))

def _verify_commit_tree(ctx, bare_abs, empty, empty_dir, resolved_ref, what):
    """Fails unless the pinned commit's tree id reads back."""
    res = ctx.execute(
        ["git", "--no-replace-objects", "--git-dir=" + bare_abs] +
        _materialize_config_args(empty_dir) + [
            "rev-parse",
            str(resolved_ref) + "^{tree}",
        ],
        environment = _materialize_env(ctx, empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: could not read the tree of %r: %s" % (what, resolved_ref, res.stderr))

# Identity pinned on the synthetic subdirectory-archive commit below. Fixed
# (never the host's identity) so the commit — and the archive streamed from
# it — depends only on the pinned tree and date.
_ARCHIVE_COMMIT_NAME = "rules-dart"
_ARCHIVE_COMMIT_EMAIL = "rules-dart@example.invalid"
_ARCHIVE_COMMIT_MESSAGE = "rules-dart subdirectory archive"

def _read_committer_date(ctx, bare_abs, empty, empty_dir, resolved_ref, what):
    """Reads the pinned commit's committer date in strict ISO format.

    Args:
        ctx: A repository or module-extension context.
        bare_abs: The bare repository's absolute path string.
        empty: The shared empty file's path string.
        empty_dir: The shared empty directory's path string.
        resolved_ref: The pinned full 40-hex commit SHA.
        what: Human-readable label of the fetching rule, for diagnostics.

    Returns:
        The committer date string (for example
        `"2020-05-06T07:08:09+02:00"`), re-parseable as a commit date.
    """
    res = ctx.execute(
        ["git", "--no-replace-objects", "--git-dir=" + bare_abs] +
        _materialize_config_args(empty_dir) + [
            "log",
            "-1",
            "--format=%cI",
            str(resolved_ref),
        ],
        environment = _materialize_env(ctx, empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: could not read the committer date of %r: %s" % (what, resolved_ref, res.stderr))
    date = res.stdout.strip()
    if not date:
        fail("%s: could not read the committer date of %r: empty output." % (what, resolved_ref))
    return date

def _read_spec_tree(ctx, bare_abs, empty, empty_dir, spec, what):
    """Reads the tree id of a `<commit>:<path>` subdirectory archive spec.

    Args:
        ctx: A repository or module-extension context.
        bare_abs: The bare repository's absolute path string.
        empty: The shared empty file's path string.
        empty_dir: The shared empty directory's path string.
        spec: The subdirectory archive spec (`<commit>:<path>`).
        what: Human-readable label of the fetching rule, for diagnostics.

    Returns:
        The subdirectory tree's object id string.
    """
    res = ctx.execute(
        ["git", "--no-replace-objects", "--git-dir=" + bare_abs] +
        _materialize_config_args(empty_dir) + [
            "rev-parse",
            spec,
        ],
        environment = _materialize_env(ctx, empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: could not read the tree of %r: %s" % (what, spec, res.stderr))
    tree = res.stdout.strip()
    if not tree:
        fail("%s: could not read the tree of %r: empty output." % (what, spec))
    return tree

def _commit_spec_tree(ctx, bare_abs, empty, empty_dir, tree, date, what):
    """Commits a subdirectory tree with the pinned commit's committer date.

    The synthetic commit has no parent, a fixed message and a fixed
    identity; only the pinned tree and the pinned date vary. Archiving this
    commit stamps every entry with the pinned committer time — the same
    mtimes a root package's archive carries — instead of the fetch's
    wall-clock time. `git archive` has no `--mtime` switch on the supported
    versions, hence the commit.

    Args:
        ctx: A repository or module-extension context.
        bare_abs: The bare repository's absolute path string.
        empty: The shared empty file's path string.
        empty_dir: The shared empty directory's path string.
        tree: The subdirectory tree's object id string.
        date: The pinned commit's committer date string.
        what: Human-readable label of the fetching rule, for diagnostics.

    Returns:
        The synthetic commit's object id string.
    """
    env = _materialize_env(ctx, empty, empty_dir, bare_abs)
    env.update({
        "GIT_AUTHOR_NAME": _ARCHIVE_COMMIT_NAME,
        "GIT_AUTHOR_EMAIL": _ARCHIVE_COMMIT_EMAIL,
        "GIT_AUTHOR_DATE": date,
        "GIT_COMMITTER_NAME": _ARCHIVE_COMMIT_NAME,
        "GIT_COMMITTER_EMAIL": _ARCHIVE_COMMIT_EMAIL,
        "GIT_COMMITTER_DATE": date,
    })
    res = ctx.execute(
        ["git", "--no-replace-objects", "--git-dir=" + bare_abs] +
        _materialize_config_args(empty_dir) + [
            "commit-tree",
            tree,
            "-m",
            _ARCHIVE_COMMIT_MESSAGE,
        ],
        environment = env,
    )
    if res.return_code != 0:
        fail("%s: could not commit the subdirectory tree %r: %s" % (what, tree, res.stderr))
    commit = res.stdout.strip()
    if not commit:
        fail("%s: could not commit the subdirectory tree %r: empty output." % (what, tree))
    return commit

def _archive_verified_tree(ctx, bare_abs, empty, empty_dir, output, spec, what):
    """Streams `git archive` of the verified spec under the scrubbed environment."""
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
        environment = _materialize_env(ctx, empty, empty_dir, bare_abs),
    )
    if res.return_code != 0:
        fail("%s: git archive failed at %s: %s" % (what, spec, res.stderr))

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
    SHA differently. For a subdirectory package (`<commit>:<path>`) the
    archived spec is a synthetic commit of that tree, written with the
    pinned commit's committer date under a fixed identity: every entry
    carries the pinned time, the same as a root package's archive, instead
    of the fetch's wall-clock time. The archive pins the byte conversion knobs
    (`core.autocrlf=false`, `core.eol=lf`, an empty `core.attributesFile`,
    `tar.umask=002`) so the bytes depend only on the pinned commit: the
    repository-local `info/attributes` override (rewritten below, so
    whatever it holds now is hostile by definition) keeps the package's own
    `export-subst`/`export-ignore`/`working-tree-encoding` entries inert.

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

    # Materialization-time override: the transport phase already wrote the
    # export override, and nothing legitimate rewrites it in between, so
    # whatever it holds now is hostile by definition.
    ctx.file(bare_rel + "/info/attributes", _GIT_ATTRIBUTES_OVERRIDE, executable = False)

    _refuse_alternates(ctx, bare_abs, empty, empty_dir, resolved_ref, what)
    _verify_commit_id(ctx, bare_abs, empty, empty_dir, resolved_ref, what)
    _verify_commit_type(ctx, bare_abs, empty, empty_dir, resolved_ref, what)
    _verify_commit_tree(ctx, bare_abs, empty, empty_dir, resolved_ref, what)
    if ":" in spec:
        # A subdirectory package's archive (`<commit>:<path>`) is of a tree,
        # whose entries `git archive` would stamp with the fetch's
        # wall-clock time. Archive a synthetic commit of that tree instead,
        # dated with the pinned commit's committer time: same paths, modes
        # and file bytes, with the same mtimes a root package's archive
        # carries.
        spec = _commit_spec_tree(
            ctx,
            bare_abs,
            empty,
            empty_dir,
            _read_spec_tree(ctx, bare_abs, empty, empty_dir, spec, what),
            _read_committer_date(ctx, bare_abs, empty, empty_dir, resolved_ref, what),
            what,
        )
    _archive_verified_tree(ctx, bare_abs, empty, empty_dir, output, spec, what)
