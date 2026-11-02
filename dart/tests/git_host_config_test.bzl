"""Unit tests for the two-phase host-git helpers in `//dart/pub`.

`git_transport_fetch` and `git_materialize` are the only way fetch call
sites may run host `git` (see `pinned_sources_guard_test.dart`). The
Starlark tests below drive them with a fake context that records every
`execute` call — the arguments and the environment — and every `file`
call, so the host-independence contract is pinned without needing a real
git binary:

- transport (`git_transport_fetch`) checks the host git version (2.32 or
  newer), assembles a bare repository skeleton without running
  `git init`, resolves `insteadOf` rewrites with `git ls-remote
  --get-url`, then fetches the pinned SHA (falling back
  to all refs) — remote resolutions keep the lock URL on both fetch
  commands so the inherited rewrites apply once, while only local
  resolutions fetch the resolved URL — all while inheriting only the allowlisted transport
  variables and unsetting every other `GIT_*` selector to `None` — one
  hostile-value test per variable below, plus sweep tests for
  undocumented `GIT_*` names and a regression test that no value is ever
  the empty string (git treats set-but-empty as set). The fetch pins
  `protocol.version=2`, separates the URL with `--`, and replaces the
  host's global and system config with the empty file for fetches that
  resolve to a local repository — unsetting the inline-config channel
  there too — with the local/remote decision made on the resolved URL;
- materialization (`git_materialize`) refuses alternates, verifies the
  commit id, its type and its tree, and archives the pinned spec, every
  command with an explicit `--git-dir`, `--no-replace-objects` and an
  environment scrubbed to `PATH` plus a scratch `HOME`.

Real-git coverage lives in `//e2e/pub_lock_git:git_probes.bzl`
(`git_hostile_fetch_probe`, `git_fsck_fetch_probe`, `git_export_subst_probe`):
repository rules that run the production helpers against a real git binary
under hostile host environments and require the hostile run's archive bytes
to equal a clean control's. They live beside the e2e workspace that
instantiates them, because a test source here is not loadable across
repositories. `check_hostile_markers.sh` re-verifies their markers at test
time.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:pinned_sources.bzl", "git_materialize", "git_transport_fetch", "git_version_error", "parse_git_version")
load(":small_suite.bzl", "small_unittest_suite")

visibility(["//dart/..."])

_SHA = "08a084d50090f0e6ca907fc627ae335c6ac4fd88"
_EMPTY_DIR = "/fake/_git_empty"
_EMPTY_FILE = "/fake/_git_empty_config"
_BARE = "/fake/_git_bare"
_URL = "https://example.com/r.git"

def _fake_ctx(record, results = [], os_environ = {}):
    """Builds a fake repository/module context recording its calls.

    Args:
      record: A list each call appends a struct to (`args`/`environment` for
        `execute`, `path`/`content` for `file`).
      results: `exec` result structs consumed in order, one per `execute`
        call; calls past the end succeed empty.
      os_environ: The fake host environment, visible as `ctx.os.environ`.

    Returns:
        A struct with the `execute`, `file`, `path` and `os` members the
        helpers use. `path` answers `/fake/<path>` so the helpers'
        `str(ctx.path(..))` calls behave.
    """
    pending = list(results)

    def _execute(args, environment = None):
        record.append(struct(args = args, environment = environment))
        if pending:
            return pending.pop(0)
        return struct(return_code = 0, stdout = "", stderr = "")

    def _file(path, content, executable = True):
        record.append(struct(path = path, content = content, executable = executable))

    def _path(path):
        return "/fake/" + path

    return struct(
        execute = _execute,
        file = _file,
        path = _path,
        os = struct(environ = os_environ),
    )

def _executes(record):
    return [call for call in record if hasattr(call, "args")]

def _files(record):
    return [call for call in record if hasattr(call, "content")]

# Fake `git version` and `git ls-remote --get-url` results consumed by every
# transport test before the fetch results: production `git_transport_fetch`
# checks the host git version, then resolves `insteadOf` rewrites, then
# fetches. The resolve echoes its input (no rewrite), so the fetch argv in
# the older tests below is unchanged.
_VERSION_RESULT = struct(return_code = 0, stdout = "git version 2.39.5\n", stderr = "")

def _resolve_result(url):
    return struct(return_code = 0, stdout = url + "\n", stderr = "")

def _transport_pins():
    return [
        "-c",
        "core.hooksPath=" + _EMPTY_DIR,
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
        "-c",
        "transfer.fsckObjects=false",
        "-c",
        "fetch.fsckObjects=false",
        "-c",
        "gc.auto=0",
        "-c",
        "maintenance.auto=false",
        "-c",
        "fetch.writeCommitGraph=false",
        "-c",
        "fetch.recurseSubmodules=false",
        "-c",
        "submodule.recurse=false",
        "-c",
        "fetch.prune=false",
        "-c",
        "fetch.pruneTags=false",
        "-c",
        "protocol.version=2",
    ]

# The repository-local attributes override the helpers write before any
# archive runs (see `_GIT_ATTRIBUTES_OVERRIDE` in `pinned_sources.bzl`).
_ATTRIBUTES_OVERRIDE = "* -export-subst -export-ignore -working-tree-encoding\n"

# Transport variables the helpers copy from the host environment. The
# passthrough test below sets every one to a sentinel and requires it
# back verbatim. This mirrors `_TRANSPORT_PASSTHROUGH` in
# `pinned_sources.bzl` (the prefix families `GIT_HTTP_*`,
# `GIT_CONFIG_KEY_*` and `GIT_CONFIG_VALUE_*`, and the inherited
# `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` / `GIT_CONFIG_NOSYSTEM`
# selectors, have their own tests below).
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

def _transport_env(extra = {}, local = False):
    env = {
        "GIT_DIR": None,
        "GIT_WORK_TREE": None,
        "GIT_INTERNAL_SUPER_PREFIX": None,
        "GIT_EXEC_PATH": None,
        "GIT_OBJECT_DIRECTORY": _BARE + "/objects",
        "GIT_COMMON_DIR": _BARE,
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
        "GIT_ALLOW_PROTOCOL": "https:http:git:ssh:file",
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
        env["GIT_CONFIG_GLOBAL"] = _EMPTY_FILE
        env["GIT_CONFIG_SYSTEM"] = _EMPTY_FILE
        env["GIT_CONFIG_COUNT"] = None
        env["GIT_CONFIG_PARAMETERS"] = None
    env.update(extra)
    return env

def _materialize_env():
    return {
        "HOME": _EMPTY_DIR,
        "XDG_CONFIG_HOME": _EMPTY_DIR,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": _EMPTY_FILE,
        "GIT_CONFIG_SYSTEM": _EMPTY_FILE,
        "GIT_CONFIG_COUNT": None,
        "GIT_CONFIG_PARAMETERS": None,
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_TEMPLATE_DIR": _EMPTY_DIR,
        "GIT_OBJECT_DIRECTORY": _BARE + "/objects",
        "GIT_COMMON_DIR": _BARE,
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": None,
        "GIT_ALLOW_PROTOCOL": "https:http:git:ssh:file",
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

def _materialize_pins():
    return [
        "--git-dir=" + _BARE,
        "-c",
        "core.hooksPath=" + _EMPTY_DIR,
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
    ]

def _transport_skeleton_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(record, [
            _VERSION_RESULT,
            _resolve_result(_URL),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    calls = _executes(record)

    # No `git init` runs: the bare repository is assembled with `ctx.file`,
    # so a stray `GIT_WORK_TREE` (which makes git refuse `init`) and host
    # templates (which only `init` copies) cannot reach the fetch. The
    # version gate runs before any other git command, the resolve expands
    # `insteadOf` rewrites without contacting the remote, and only then does
    # the SHA fetch run, with `--` keeping the URL from being read as an
    # option and `protocol.version=2` keeping a hostile host off the
    # all-refs fallback.
    asserts.equals(env, 3, len(calls))
    asserts.equals(
        env,
        ["git", "--no-replace-objects", "version"],
        calls[0].args,
    )
    asserts.equals(
        env,
        ["git", "--no-replace-objects", "--git-dir=" + _BARE, "ls-remote", "--get-url", "--", _URL],
        calls[1].args,
    )
    asserts.equals(
        env,
        ["git", "--no-replace-objects", "--git-dir=" + _BARE] + _transport_pins() + ["fetch", "--", _URL, _SHA],
        calls[2].args,
    )
    asserts.equals(env, _transport_env(), calls[2].environment)
    return unittest.end(env)

def _transport_precreates_dirs_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(record, [
            _VERSION_RESULT,
            _resolve_result(_URL),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    by_path = {call.path: call.content for call in _files(record)}
    asserts.equals(env, "", by_path["_git_bare/objects/keep"])
    asserts.equals(env, "ref: refs/heads/main\n", by_path["_git_bare/HEAD"])
    asserts.equals(
        env,
        "[core]\n\trepositoryformatversion = 0\n\tbare = true\n",
        by_path["_git_bare/config"],
    )
    asserts.equals(env, "", by_path["_git_bare/refs/.keep"])

    # The repository-local attributes carry the export override, not an
    # empty file: `info/attributes` outranks the committed `.gitattributes`,
    # so the package's own `export-subst`/`export-ignore` entries stay inert.
    asserts.equals(env, _ATTRIBUTES_OVERRIDE, by_path["_git_bare/info/attributes"])
    asserts.equals(env, "", by_path["_git_empty/keep"])
    asserts.equals(env, "", by_path["_git_empty_config"])
    return unittest.end(env)

def _transport_fetch_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(record, [
            _VERSION_RESULT,
            _resolve_result(_URL),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    calls = _executes(record)
    asserts.equals(
        env,
        ["git", "--no-replace-objects", "--git-dir=" + _BARE] + _transport_pins() + ["fetch", "--", _URL, _SHA],
        calls[2].args,
    )
    asserts.equals(env, _transport_env(), calls[2].environment)

    # Transport inherits the host's transport configuration: the global
    # and system file selectors stay readable, so `insteadOf` rewrites and
    # credential helpers keep working.
    asserts.false(env, "GIT_CONFIG_GLOBAL" in calls[2].environment)
    asserts.false(env, "GIT_CONFIG_SYSTEM" in calls[2].environment)
    asserts.false(env, "GIT_CONFIG_NOSYSTEM" in calls[2].environment)
    return unittest.end(env)

def _transport_local_config_test_impl(ctx):
    env = unittest.begin(ctx)
    for url in [
        "file:///srv/repos/r.git",
        "file:///C:/repos/r.git",
        "/srv/repos/r.git",
        "C:\\repos\\r.git",
        "relative/bundle",
        "../sibling/r.git",
    ]:
        record = []
        git_transport_fetch(
            _fake_ctx(
                record,
                [_VERSION_RESULT, _resolve_result(url), struct(return_code = 0, stdout = "", stderr = "")],
                os_environ = {
                    "GIT_CONFIG_GLOBAL": "/hostile/global.gitconfig",
                    "GIT_CONFIG_SYSTEM": "/hostile/system.gitconfig",
                    "GIT_CONFIG_COUNT": "1",
                    "GIT_CONFIG_KEY_0": "uploadpack.packObjectsHook",
                    "GIT_CONFIG_VALUE_0": "/hostile/hook.sh",
                    "GIT_CONFIG_PARAMETERS": "'uploadpack.packObjectsHook=/hostile/hook.sh'",
                },
            ),
            url,
            "_git_bare",
            _SHA,
            "test",
        )
        fetch_env = _executes(record)[2].environment

        # Local transports need no credentials: the host's global and system
        # files stay unread (a host-global `uploadpack.packObjectsHook`
        # would otherwise run on the fetch, where `-c` pins cannot reach
        # it), and so does the inline-config channel — the hook cannot
        # arrive through `GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS`
        # either. The fetch URL is still separated with `--`.
        asserts.equals(env, _EMPTY_FILE, fetch_env["GIT_CONFIG_GLOBAL"])
        asserts.equals(env, _EMPTY_FILE, fetch_env["GIT_CONFIG_SYSTEM"])
        asserts.equals(env, None, fetch_env["GIT_CONFIG_COUNT"])
        asserts.equals(env, None, fetch_env["GIT_CONFIG_PARAMETERS"])
        asserts.equals(env, None, fetch_env["GIT_CONFIG_KEY_0"])
        asserts.equals(env, None, fetch_env["GIT_CONFIG_VALUE_0"])
        asserts.equals(
            env,
            ["git", "--no-replace-objects", "--git-dir=" + _BARE] + _transport_pins() + ["fetch", "--", url, _SHA],
            _executes(record)[2].args,
        )
    for url in [
        "https://example.com/r.git",
        "ssh://git@example.com/r.git",
        "git@example.com:r.git",
        "host.xz:path/to/r.git",
    ]:
        record = []
        git_transport_fetch(
            _fake_ctx(
                record,
                [_VERSION_RESULT, _resolve_result(url), struct(return_code = 0, stdout = "", stderr = "")],
                os_environ = {
                    "GIT_CONFIG_GLOBAL": "/host/global.gitconfig",
                    "GIT_CONFIG_SYSTEM": "/host/system.gitconfig",
                },
            ),
            url,
            "_git_bare",
            _SHA,
            "test",
        )
        fetch_env = _executes(record)[2].environment

        # Remote transports keep the host's config files (credentials and
        # `insteadOf` rewrites); only local ones are replaced.
        asserts.false(env, "GIT_CONFIG_GLOBAL" in fetch_env)
        asserts.false(env, "GIT_CONFIG_SYSTEM" in fetch_env)
    return unittest.end(env)

def _transport_resolved_local_test_impl(ctx):
    env = unittest.begin(ctx)
    rewritten = "/srv/repos/local-r.git"
    record = []
    git_transport_fetch(
        _fake_ctx(
            record,
            [_VERSION_RESULT, _resolve_result(rewritten), struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = {
                "GIT_CONFIG_GLOBAL": "/hostile/global.gitconfig",
                "GIT_CONFIG_SYSTEM": "/hostile/system.gitconfig",
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "uploadpack.packObjectsHook",
                "GIT_CONFIG_VALUE_0": "/hostile/hook.sh",
            },
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    calls = _executes(record)
    asserts.equals(env, 3, len(calls))

    # The resolve runs under the inheriting transport environment, so the
    # host's rewrite channels reach it.
    asserts.equals(env, "1", calls[1].environment["GIT_CONFIG_COUNT"])
    asserts.equals(env, "uploadpack.packObjectsHook", calls[1].environment["GIT_CONFIG_KEY_0"])

    # The local/remote decision sees the resolved URL: the remote lock URL
    # rewrote to a local repository, so the fetch is isolated exactly like
    # a lock URL that is local to begin with — and it fetches the resolved
    # URL, because the isolated environment no longer carries the rewrite.
    fetch_env = calls[2].environment
    asserts.equals(env, _EMPTY_FILE, fetch_env["GIT_CONFIG_GLOBAL"])
    asserts.equals(env, _EMPTY_FILE, fetch_env["GIT_CONFIG_SYSTEM"])
    asserts.equals(env, None, fetch_env["GIT_CONFIG_COUNT"])
    asserts.equals(env, None, fetch_env["GIT_CONFIG_KEY_0"])
    asserts.equals(env, None, fetch_env["GIT_CONFIG_VALUE_0"])
    asserts.equals(
        env,
        ["git", "--no-replace-objects", "--git-dir=" + _BARE] + _transport_pins() + ["fetch", "--", rewritten, _SHA],
        calls[2].args,
    )
    return unittest.end(env)

# A remote resolution keeps the lock URL on both fetch commands, while a
# local resolution fetches the resolved URL on both: the inheriting remote
# environment still carries the host's `insteadOf` rewrites, so git
# applies them to the lock URL once, exactly as before the
# resolve-then-isolate change — fetching the resolved URL there would
# apply a chained rewrite a second time. Each case runs the SHA fetch and
# the all-refs fallback (the SHA fetch failing once).
def _transport_resolved_fetch_url_test_impl(ctx):
    env = unittest.begin(ctx)
    for rewritten, want_url, want_env in [
        ("https://mirror.example.com/r.git", _URL, _transport_env()),
        ("/srv/repos/local-r.git", "/srv/repos/local-r.git", _transport_env(local = True)),
    ]:
        for fetch_results in [
            [struct(return_code = 0, stdout = "", stderr = "")],
            [
                struct(return_code = 128, stdout = "", stderr = "couldn't find remote ref"),
                struct(return_code = 0, stdout = "", stderr = ""),
            ],
        ]:
            record = []
            git_transport_fetch(
                _fake_ctx(record, [_VERSION_RESULT, _resolve_result(rewritten)] + fetch_results),
                _URL,
                "_git_bare",
                _SHA,
                "test",
            )
            fetch = _executes(record)[-1]
            want_ref = _SHA if len(fetch_results) == 1 else "+refs/*:refs/origin/*"
            asserts.equals(
                env,
                ["git", "--no-replace-objects", "--git-dir=" + _BARE] + _transport_pins() + ["fetch", "--", want_url, want_ref],
                fetch.args,
            )
            asserts.equals(env, want_env, fetch.environment)
    return unittest.end(env)

def _version_accepted_test_impl(ctx):
    env = unittest.begin(ctx)
    for output in [
        "git version 2.32.0\n",
        "git version 2.39.5\n",
        "git version 2.39.5 (Apple Git-154)\n",
        "git version 2.45.1.windows.1\n",
        "git version 3.0.0\n",
    ]:
        asserts.equals(env, None, git_version_error(output, "test"))
    asserts.equals(env, [2, 39], parse_git_version("git version 2.39.5 (Apple Git-154)\n"))
    asserts.equals(env, [2, 45], parse_git_version("git version 2.45.1.windows.1\n"))
    return unittest.end(env)

def _version_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    for output, found in [
        ("git version 2.31.9\n", "2.31"),
        ("git version 2.7.4\n", "2.7"),
        ("git version 1.8.3\n", "1.8"),
    ]:
        err = git_version_error(output, "test")
        asserts.true(env, err != None)
        asserts.true(env, "2.32" in err)
        asserts.true(env, found in err)
    return unittest.end(env)

def _version_unparsable_test_impl(ctx):
    env = unittest.begin(ctx)
    for output in [
        "",
        "2.39.5\n",
        "git version two\n",
        "git version 2\n",
        "git version 2.x\n",
    ]:
        err = git_version_error(output, "test")
        asserts.equals(env, None, parse_git_version(output))
        asserts.true(env, err != None)
        asserts.true(env, "could not determine" in err)
        asserts.true(env, "2.32" in err)
    return unittest.end(env)

def _transport_fallback_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(record, [
            _VERSION_RESULT,
            _resolve_result(_URL),
            struct(return_code = 128, stdout = "", stderr = "couldn't find remote ref"),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    calls = _executes(record)
    asserts.equals(env, 4, len(calls))
    asserts.equals(
        env,
        ["git", "--no-replace-objects", "--git-dir=" + _BARE] + _transport_pins() + ["fetch", "--", _URL, "+refs/*:refs/origin/*"],
        calls[3].args,
    )
    asserts.equals(env, _transport_env(), calls[3].environment)
    return unittest.end(env)

# One hostile value per unset transport variable. Each generated test sets
# its variable in the fake host environment and requires the fetch
# environment to unset it to `None` — present in the dict (so `ctx.execute`
# removes it from the child process) and never the empty string (which git
# reads as set: a set-but-empty `GIT_QUARANTINE_PATH`, `GIT_WORK_TREE` or
# `GIT_INTERNAL_SUPER_PREFIX` is fatal). Per-variable unset tests: one
# `_clears_var_<name>_test` rule per unset transport variable, each named
# after the variable it covers.

def _clears_var_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(
            record,
            [_VERSION_RESULT, _resolve_result(_URL), struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = {ctx.attr.var: ctx.attr.hostile},
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[0].environment
    asserts.true(env, ctx.attr.var in fetch_env)
    asserts.equals(env, None, fetch_env[ctx.attr.var])
    return unittest.end(env)

# One test rule per scrubbed variable, each bound to a module-level
# name: `rule()` objects must be exported by the bzl file, so a
# comprehension-generated list is not a valid rule class.
_clears_var_git_dir_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_DIR"), "hostile": attr.string(default = "/hostile/dir")},
)
_clears_var_git_work_tree_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_WORK_TREE"), "hostile": attr.string(default = "/hostile/wt")},
)
_clears_var_git_internal_super_prefix_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_INTERNAL_SUPER_PREFIX"), "hostile": attr.string(default = "hostile/")},
)
_clears_var_git_exec_path_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_EXEC_PATH"), "hostile": attr.string(default = "/hostile/exec")},
)
_clears_var_git_index_file_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_INDEX_FILE"), "hostile": attr.string(default = "/hostile/index")},
)
_clears_var_git_index_version_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_INDEX_VERSION"), "hostile": attr.string(default = "4")},
)
_clears_var_git_namespace_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_NAMESPACE"), "hostile": attr.string(default = "hostile")},
)
_clears_var_git_alternate_object_directories_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_ALTERNATE_OBJECT_DIRECTORIES"), "hostile": attr.string(default = "/hostile/alt")},
)
_clears_var_git_quarantine_path_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_QUARANTINE_PATH"), "hostile": attr.string(default = "/hostile/quarantine")},
)
_clears_var_git_replace_ref_base_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_REPLACE_REF_BASE"), "hostile": attr.string(default = "refs/hostile")},
)
_clears_var_git_ceiling_directories_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_CEILING_DIRECTORIES"), "hostile": attr.string(default = "/")},
)
_clears_var_git_discovery_across_filesystem_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_DISCOVERY_ACROSS_FILESYSTEM"), "hostile": attr.string(default = "0")},
)
_clears_var_git_prefix_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_PREFIX"), "hostile": attr.string(default = "hostile")},
)
_clears_var_git_super_prefix_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_SUPER_PREFIX"), "hostile": attr.string(default = "hostile/")},
)
_clears_var_git_template_dir_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_TEMPLATE_DIR"), "hostile": attr.string(default = "/hostile/template")},
)
_clears_var_git_graft_file_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_GRAFT_FILE"), "hostile": attr.string(default = "/hostile/grafts")},
)
_clears_var_git_author_name_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_AUTHOR_NAME"), "hostile": attr.string(default = "hostile")},
)
_clears_var_git_author_email_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_AUTHOR_EMAIL"), "hostile": attr.string(default = "hostile@example.com")},
)
_clears_var_git_author_date_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_AUTHOR_DATE"), "hostile": attr.string(default = "@0 +0000")},
)
_clears_var_git_committer_name_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_COMMITTER_NAME"), "hostile": attr.string(default = "hostile")},
)
_clears_var_git_committer_email_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_COMMITTER_EMAIL"), "hostile": attr.string(default = "hostile@example.com")},
)
_clears_var_git_committer_date_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_COMMITTER_DATE"), "hostile": attr.string(default = "@0 +0000")},
)
_clears_var_git_reflog_action_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_REFLOG_ACTION"), "hostile": attr.string(default = "hostile")},
)
_clears_var_git_editor_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_EDITOR"), "hostile": attr.string(default = "/hostile/editor")},
)
_clears_var_git_pager_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_PAGER"), "hostile": attr.string(default = "/hostile/pager")},
)
_clears_var_git_external_diff_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_EXTERNAL_DIFF"), "hostile": attr.string(default = "/hostile/diff")},
)
_clears_var_git_diff_opts_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_DIFF_OPTS"), "hostile": attr.string(default = "-hostile")},
)
_clears_var_git_literal_pathspecs_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_LITERAL_PATHSPECS"), "hostile": attr.string(default = "1")},
)
_clears_var_git_flush_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_FLUSH"), "hostile": attr.string(default = "1")},
)
_clears_var_git_trace_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_TRACE"), "hostile": attr.string(default = "/hostile/trace")},
)
_clears_var_git_trace_pack_access_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_TRACE_PACK_ACCESS"), "hostile": attr.string(default = "/hostile/trace")},
)
_clears_var_git_trace_packet_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_TRACE_PACKET"), "hostile": attr.string(default = "/hostile/trace")},
)
_clears_var_git_trace_performance_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_TRACE_PERFORMANCE"), "hostile": attr.string(default = "/hostile/trace")},
)
_clears_var_git_trace_setup_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_TRACE_SETUP"), "hostile": attr.string(default = "/hostile/trace")},
)
_clears_var_git_curl_verbose_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_CURL_VERBOSE"), "hostile": attr.string(default = "1")},
)
_clears_var_tests = [
    _clears_var_git_dir_test,
    _clears_var_git_work_tree_test,
    _clears_var_git_internal_super_prefix_test,
    _clears_var_git_exec_path_test,
    _clears_var_git_index_file_test,
    _clears_var_git_index_version_test,
    _clears_var_git_namespace_test,
    _clears_var_git_alternate_object_directories_test,
    _clears_var_git_quarantine_path_test,
    _clears_var_git_replace_ref_base_test,
    _clears_var_git_ceiling_directories_test,
    _clears_var_git_discovery_across_filesystem_test,
    _clears_var_git_prefix_test,
    _clears_var_git_super_prefix_test,
    _clears_var_git_template_dir_test,
    _clears_var_git_graft_file_test,
    _clears_var_git_author_name_test,
    _clears_var_git_author_email_test,
    _clears_var_git_author_date_test,
    _clears_var_git_committer_name_test,
    _clears_var_git_committer_email_test,
    _clears_var_git_committer_date_test,
    _clears_var_git_reflog_action_test,
    _clears_var_git_editor_test,
    _clears_var_git_pager_test,
    _clears_var_git_external_diff_test,
    _clears_var_git_diff_opts_test,
    _clears_var_git_literal_pathspecs_test,
    _clears_var_git_flush_test,
    _clears_var_git_trace_test,
    _clears_var_git_trace_pack_access_test,
    _clears_var_git_trace_packet_test,
    _clears_var_git_trace_performance_test,
    _clears_var_git_trace_setup_test,
    _clears_var_git_curl_verbose_test,
]

def _transport_no_empty_values_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    host = {var: "/host/sentinel/" + var for var in _TRANSPORT_PASSTHROUGH}
    host.update({
        "GIT_DIR": "/hostile/dir",
        "GIT_WORK_TREE": "/hostile/wt",
        "GIT_INTERNAL_SUPER_PREFIX": "hostile/",
        "GIT_EXEC_PATH": "/hostile/exec",
        "GIT_QUARANTINE_PATH": "/hostile/quarantine",
        "GIT_FUTURE_TRANSPORT_XYZ": "hostile",
        "GIT_HTTP_PROXY": "http://host/proxy",
        "GIT_CONFIG_KEY_0": "url.https://host/r.git.insteadOf",
        "GIT_CONFIG_VALUE_0": "https://rewritten.example/r.git",
    })
    git_transport_fetch(
        _fake_ctx(
            record,
            [_VERSION_RESULT, _resolve_result(_URL), struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = host,
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[2].environment

    # No value is ever the empty string: git checks `getenv(...) != NULL`,
    # so a set-but-empty variable stays set — unsets must be `None`.
    for var in fetch_env:
        asserts.false(env, fetch_env[var] == "")
    return unittest.end(env)

def _transport_unknown_vars_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(
            record,
            [_VERSION_RESULT, _resolve_result(_URL), struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = {
                "GIT_FUTURE_TRANSPORT_XYZ": "hostile",
                "GIT_SOME_NEW_THING": "",
                "GIT_QUARANTINE_PATHOLOGY": "/hostile",
            },
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[0].environment

    # Undocumented `GIT_*` names — and any future git variable — are unset,
    # whether the host sets them empty or not: only the transport allowlist
    # survives the sweep.
    for var in ["GIT_FUTURE_TRANSPORT_XYZ", "GIT_SOME_NEW_THING", "GIT_QUARANTINE_PATHOLOGY"]:
        asserts.true(env, var in fetch_env)
        asserts.equals(env, None, fetch_env[var])
    return unittest.end(env)

def _transport_empty_hostile_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(
            record,
            [_VERSION_RESULT, _resolve_result(_URL), struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = {
                "GIT_QUARANTINE_PATH": "",
                "GIT_WORK_TREE": "",
                "GIT_DIR": "",
                "GIT_INTERNAL_SUPER_PREFIX": "",
                "GIT_EXEC_PATH": "",
                "GIT_SUPER_PREFIX": "",
            },
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[0].environment

    # Hostile empty values unset exactly like hostile non-empty ones: git
    # rejects a set-but-empty quarantine path, work tree and super prefix.
    for var in [
        "GIT_QUARANTINE_PATH",
        "GIT_WORK_TREE",
        "GIT_DIR",
        "GIT_INTERNAL_SUPER_PREFIX",
        "GIT_EXEC_PATH",
        "GIT_SUPER_PREFIX",
    ]:
        asserts.true(env, var in fetch_env)
        asserts.equals(env, None, fetch_env[var])
    return unittest.end(env)

def _transport_pins_dirs_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(
            record,
            [_VERSION_RESULT, _resolve_result(_URL), struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = {
                "GIT_OBJECT_DIRECTORY": "/hostile/objects",
                "GIT_COMMON_DIR": "/hostile/common",
                "GIT_NO_REPLACE_OBJECTS": "0",
            },
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[0].environment

    # The object and common directories cannot be scrubbed to empty (git
    # rejects empty values there), so they are pinned at the new bare
    # repository's own pre-created directories instead.
    asserts.equals(env, _BARE + "/objects", fetch_env["GIT_OBJECT_DIRECTORY"])
    asserts.equals(env, _BARE, fetch_env["GIT_COMMON_DIR"])

    # Replacements stay disabled even when the host opts back in: the flag
    # on every argv beats the variable, and the variable is pinned on.
    asserts.equals(env, "1", fetch_env["GIT_NO_REPLACE_OBJECTS"])
    return unittest.end(env)

def _transport_config_count_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(
            record,
            [_VERSION_RESULT, _resolve_result(_URL), struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = {
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "url.https://host/r.git.insteadOf",
                "GIT_CONFIG_VALUE_0": "https://rewritten.example/r.git",
                "GIT_CONFIG_PARAMETERS": "'unpackLimit=1'",
                "GIT_HTTP_PROXY": "http://host/proxy",
                "GIT_SSL_NO_VERIFY": "true",
            },
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[0].environment

    # The inline-config channel passes through verbatim, like the config
    # files: a host-provided `insteadOf` rewrite keeps working, and the
    # `-c` pins on the fetch command line override it where they overlap.
    asserts.equals(env, "1", fetch_env["GIT_CONFIG_COUNT"])
    asserts.equals(env, "url.https://host/r.git.insteadOf", fetch_env["GIT_CONFIG_KEY_0"])
    asserts.equals(env, "https://rewritten.example/r.git", fetch_env["GIT_CONFIG_VALUE_0"])
    asserts.equals(env, "'unpackLimit=1'", fetch_env["GIT_CONFIG_PARAMETERS"])

    # The `GIT_HTTP_*` family and `GIT_SSL_NO_VERIFY` pass through too.
    asserts.equals(env, "http://host/proxy", fetch_env["GIT_HTTP_PROXY"])
    asserts.equals(env, "true", fetch_env["GIT_SSL_NO_VERIFY"])
    return unittest.end(env)

def _transport_passthrough_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    host = {var: "/host/sentinel/" + var for var in _TRANSPORT_PASSTHROUGH}
    host["GIT_FOOBAR"] = "hostile"
    host["PATH"] = "/host/bin"
    git_transport_fetch(
        _fake_ctx(
            record,
            [_VERSION_RESULT, _resolve_result(_URL), struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = host,
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[0].environment

    # The allowlisted transport variables pass through verbatim. A
    # non-allowlisted `GIT_*` host variable is unset (`None`, never absent:
    # `ctx.execute` merges over the host environment, so absence would
    # inherit); a non-`GIT_` host variable is never named at all.
    for var in _TRANSPORT_PASSTHROUGH:
        asserts.equals(env, host[var], fetch_env[var])
    asserts.equals(env, None, fetch_env["GIT_FOOBAR"])
    asserts.false(env, "PATH" in fetch_env)
    return unittest.end(env)

def _materialize_sequence_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_materialize(
        _fake_ctx(record, [
            struct(return_code = 0, stdout = "count: 0\nsize: 0\n", stderr = ""),
            struct(return_code = 0, stdout = _SHA + "\n", stderr = ""),
            struct(return_code = 0, stdout = "commit\n", stderr = ""),
            struct(return_code = 0, stdout = "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr = ""),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        "_git_bare",
        _SHA,
        "/fake/_out.tar",
        _SHA,
        "test",
    )
    calls = _executes(record)
    asserts.equals(env, 5, len(calls))
    asserts.equals(
        env,
        ["git", "--no-replace-objects"] + _materialize_pins() + ["count-objects", "-v"],
        calls[0].args,
    )
    asserts.equals(
        env,
        ["git", "--no-replace-objects"] + _materialize_pins() + ["rev-parse", "--verify", _SHA + "^{commit}"],
        calls[1].args,
    )
    asserts.equals(
        env,
        ["git", "--no-replace-objects"] + _materialize_pins() + ["cat-file", "-t", _SHA],
        calls[2].args,
    )
    asserts.equals(
        env,
        ["git", "--no-replace-objects"] + _materialize_pins() + ["rev-parse", _SHA + "^{tree}"],
        calls[3].args,
    )
    asserts.equals(
        env,
        [
            "git",
            "--no-replace-objects",
            "--git-dir=" + _BARE,
            "-c",
            "core.autocrlf=false",
            "-c",
            "core.eol=lf",
            "-c",
            "core.attributesfile=" + _EMPTY_FILE,
            "-c",
            "core.hooksPath=" + _EMPTY_DIR,
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "-c",
            "tar.umask=002",
            "archive",
            "--format=tar",
            "-o",
            "/fake/_out.tar",
            _SHA,
        ],
        calls[4].args,
    )
    for call in calls:
        asserts.equals(env, _materialize_env(), call.environment)
    return unittest.end(env)

def _materialize_env_isolation_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_materialize(
        _fake_ctx(record, [
            struct(return_code = 0, stdout = "", stderr = ""),
            struct(return_code = 0, stdout = _SHA + "\n", stderr = ""),
            struct(return_code = 0, stdout = "commit\n", stderr = ""),
            struct(return_code = 0, stdout = "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr = ""),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        "_git_bare",
        _SHA,
        "/fake/_out.tar",
        _SHA,
        "test",
    )
    environment = _executes(record)[0].environment

    # The scratch HOME doubles as the XDG home: neither user nor XDG host
    # file exists under the empty directory.
    asserts.equals(env, _EMPTY_DIR, environment["HOME"])
    asserts.equals(env, _EMPTY_DIR, environment["XDG_CONFIG_HOME"])
    asserts.equals(env, "1", environment["GIT_CONFIG_NOSYSTEM"])
    asserts.equals(env, _EMPTY_FILE, environment["GIT_CONFIG_GLOBAL"])
    asserts.equals(env, _EMPTY_FILE, environment["GIT_CONFIG_SYSTEM"])
    asserts.equals(env, None, environment["GIT_CONFIG_COUNT"])
    asserts.equals(env, None, environment["GIT_CONFIG_PARAMETERS"])
    asserts.equals(env, "1", environment["GIT_NO_REPLACE_OBJECTS"])
    asserts.equals(env, None, environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"])
    asserts.equals(env, _BARE + "/objects", environment["GIT_OBJECT_DIRECTORY"])
    asserts.equals(env, _BARE, environment["GIT_COMMON_DIR"])

    # Transport-executing variables are unset: materialization never
    # touches the network.
    asserts.equals(env, None, environment["GIT_SSH_COMMAND"])
    asserts.equals(env, None, environment["GIT_ASKPASS"])

    # `GIT_DIR` is unset and left to the `--git-dir` flag, and
    # `GIT_WORK_TREE` is unset rather than inherited: git validates the
    # path when set, so a nonexistent host work tree is fatal even though
    # no materialization command touches a working tree.
    asserts.equals(env, None, environment["GIT_DIR"])
    asserts.equals(env, None, environment["GIT_WORK_TREE"])

    # No value is ever the empty string.
    for var in environment:
        asserts.false(env, environment[var] == "")
    return unittest.end(env)

def _materialize_hostile_vars_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_materialize(
        _fake_ctx(
            record,
            [
                struct(return_code = 0, stdout = "count: 0\nsize: 0\n", stderr = ""),
                struct(return_code = 0, stdout = _SHA + "\n", stderr = ""),
                struct(return_code = 0, stdout = "commit\n", stderr = ""),
                struct(return_code = 0, stdout = "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr = ""),
                struct(return_code = 0, stdout = "", stderr = ""),
            ],
            os_environ = {
                "GIT_WORK_TREE": "/nonexistent/wt",
                "GIT_DIR": "/hostile/dir",
                "GIT_QUARANTINE_PATH": "/hostile/quarantine",
                "GIT_EXEC_PATH": "/hostile/exec",
                "GIT_FUTURE_VAR": "hostile",
                "GIT_SSH_COMMAND": "ssh -o evil",
                "PATH": "/host/bin",
            },
        ),
        "_git_bare",
        _SHA,
        "/fake/_out.tar",
        _SHA,
        "test",
    )
    environment = _executes(record)[0].environment

    # Hostile `GIT_*` variables are unset, whether documented or unknown;
    # non-`GIT_*` host variables stay out of the dict.
    for var in [
        "GIT_WORK_TREE",
        "GIT_DIR",
        "GIT_QUARANTINE_PATH",
        "GIT_EXEC_PATH",
        "GIT_FUTURE_VAR",
        "GIT_SSH_COMMAND",
    ]:
        asserts.true(env, var in environment)
        asserts.equals(env, None, environment[var])
    asserts.false(env, "PATH" in environment)
    return unittest.end(env)

def _materialize_truncates_attributes_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_materialize(
        _fake_ctx(record, [
            struct(return_code = 0, stdout = "", stderr = ""),
            struct(return_code = 0, stdout = _SHA + "\n", stderr = ""),
            struct(return_code = 0, stdout = "commit\n", stderr = ""),
            struct(return_code = 0, stdout = "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr = ""),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        "_git_bare",
        _SHA,
        "/fake/_out.tar",
        _SHA,
        "test",
    )
    by_path = {call.path: call.content for call in _files(record)}
    asserts.equals(env, _ATTRIBUTES_OVERRIDE, by_path["_git_bare/info/attributes"])
    asserts.equals(env, "", by_path["_git_empty_config"])
    asserts.equals(env, "", by_path["_git_empty/keep"])
    return unittest.end(env)

def _materialize_subpath_spec_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    tree = "2e81171448eb9f2ee3821e3d447aa6b2fe3ddba1"
    syn = "63d2b5b571b0315e7e928f4be77cda908e9216cc"
    date = "2020-05-06T07:08:09+02:00"
    git_materialize(
        _fake_ctx(record, [
            struct(return_code = 0, stdout = "", stderr = ""),
            struct(return_code = 0, stdout = _SHA + "\n", stderr = ""),
            struct(return_code = 0, stdout = "commit\n", stderr = ""),
            struct(return_code = 0, stdout = "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n", stderr = ""),
            struct(return_code = 0, stdout = tree + "\n", stderr = ""),
            struct(return_code = 0, stdout = date + "\n", stderr = ""),
            struct(return_code = 0, stdout = syn + "\n", stderr = ""),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        "_git_bare",
        _SHA,
        "/fake/_out.tar",
        _SHA + ":pkgs/foo",
        "test",
    )
    calls = _executes(record)

    # A subdirectory spec archives a synthetic commit of the subdirectory
    # tree, dated with the pinned commit's committer time — never the
    # `<commit>:<path>` tree directly, whose entries `git archive` would
    # stamp with the fetch's wall-clock time.
    asserts.equals(env, 8, len(calls))
    asserts.equals(
        env,
        ["git", "--no-replace-objects"] + _materialize_pins() + ["rev-parse", _SHA + ":pkgs/foo"],
        calls[4].args,
    )
    asserts.equals(
        env,
        ["git", "--no-replace-objects"] + _materialize_pins() + ["log", "-1", "--format=%cI", _SHA],
        calls[5].args,
    )
    asserts.equals(
        env,
        ["git", "--no-replace-objects"] + _materialize_pins() + ["commit-tree", tree, "-m", "rules-dart subdirectory archive"],
        calls[6].args,
    )
    commit_env = dict(_materialize_env())
    commit_env.update({
        "GIT_AUTHOR_NAME": "rules-dart",
        "GIT_AUTHOR_EMAIL": "rules-dart@example.invalid",
        "GIT_AUTHOR_DATE": date,
        "GIT_COMMITTER_NAME": "rules-dart",
        "GIT_COMMITTER_EMAIL": "rules-dart@example.invalid",
        "GIT_COMMITTER_DATE": date,
    })
    asserts.equals(env, commit_env, calls[6].environment)
    asserts.equals(env, syn, calls[7].args[len(calls[7].args) - 1])
    return unittest.end(env)

_t0_test = unittest.make(_transport_skeleton_test_impl)
_t1_test = unittest.make(_transport_precreates_dirs_test_impl)
_t2_test = unittest.make(_transport_fetch_test_impl)
_t3_test = unittest.make(_transport_fallback_test_impl)
_t4_test = unittest.make(_materialize_sequence_test_impl)
_t5_test = unittest.make(_materialize_env_isolation_test_impl)
_t14_test = unittest.make(_materialize_hostile_vars_test_impl)
_t6_test = unittest.make(_materialize_truncates_attributes_test_impl)
_t7_test = unittest.make(_materialize_subpath_spec_test_impl)
_t8_test = unittest.make(_transport_pins_dirs_test_impl)
_t9_test = unittest.make(_transport_config_count_test_impl)
_t10_test = unittest.make(_transport_passthrough_test_impl)
_t11_test = unittest.make(_transport_no_empty_values_test_impl)
_t12_test = unittest.make(_transport_unknown_vars_test_impl)
_t13_test = unittest.make(_transport_empty_hostile_test_impl)
_t15_test = unittest.make(_transport_local_config_test_impl)
_t16_test = unittest.make(_transport_resolved_local_test_impl)
_t17_test = unittest.make(_version_accepted_test_impl)
_t18_test = unittest.make(_version_refused_test_impl)
_t19_test = unittest.make(_version_unparsable_test_impl)
_t20_test = unittest.make(_transport_resolved_fetch_url_test_impl)

def git_host_config_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
        _t13_test,
        _t14_test,
        _t15_test,
        _t16_test,
        _t17_test,
        _t18_test,
        _t19_test,
        _t20_test,
        *_clears_var_tests
    )
