"""Unit tests for the two-phase host-git helpers in `//dart/pub`.

`git_transport_fetch` and `git_materialize` are the only way fetch call
sites may run host `git` (see `pinned_sources_guard_test.dart`). The
Starlark tests below drive them with a fake context that records every
`execute` call — the arguments and the environment — and every `file`
call, so the host-independence contract is pinned without needing a real
git binary:

- transport (`git_transport_fetch`) assembles a bare repository skeleton
  without running `git init`, then fetches the pinned SHA (falling back
  to all refs), all while inheriting only the allowlisted transport
  variables and unsetting every other `GIT_*` selector to `None` — one
  hostile-value test per variable below, plus sweep tests for
  undocumented `GIT_*` names and a regression test that no value is ever
  the empty string (git treats set-but-empty as set);
- materialization (`git_materialize`) refuses alternates, verifies the
  commit id, its type and its tree, and archives the pinned spec, every
  command with an explicit `--git-dir`, `--no-replace-objects` and an
  environment scrubbed to `PATH` plus a scratch `HOME`.

Real-git coverage lives in `git_hostile_fetch_probe` at the bottom of
this file: it runs the production helpers against a real git binary under
a hostile host environment (hook, quarantine, worktree, unknown `GIT_*`,
all-refs fallback, `insteadOf` rewrites) and compares the bytes with a
clean control fetch. It is instantiated by `//e2e/pub_lock_git`'s
`hostile_probe_ext.bzl`, whose markers `check_hostile_markers.sh`
re-verifies at test time.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:pinned_sources.bzl", "git_materialize", "git_transport_fetch")
load(":small_suite.bzl", "small_unittest_suite")

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

def _transport_pins():
    return [
        "-c",
        "core.hooksPath=" + _EMPTY_DIR,
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
    ]

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

def _transport_env(extra = {}):
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
    # first and only `execute` calls are the SHA fetch.
    asserts.equals(env, 1, len(calls))
    asserts.equals(
        env,
        ["git", "--no-replace-objects", "--git-dir=" + _BARE] + _transport_pins() + ["fetch", _URL, _SHA],
        calls[0].args,
    )
    asserts.equals(env, _transport_env(), calls[0].environment)
    return unittest.end(env)

def _transport_precreates_dirs_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(record, [
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
    asserts.equals(env, "", by_path["_git_bare/info/attributes"])
    asserts.equals(env, "", by_path["_git_empty/keep"])
    return unittest.end(env)

def _transport_fetch_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(record, [
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
        ["git", "--no-replace-objects", "--git-dir=" + _BARE] + _transport_pins() + ["fetch", _URL, _SHA],
        calls[0].args,
    )
    asserts.equals(env, _transport_env(), calls[0].environment)

    # Transport inherits the host's transport configuration: the global
    # and system file selectors stay readable, so `insteadOf` rewrites and
    # credential helpers keep working.
    asserts.false(env, "GIT_CONFIG_GLOBAL" in calls[0].environment)
    asserts.false(env, "GIT_CONFIG_SYSTEM" in calls[0].environment)
    asserts.false(env, "GIT_CONFIG_NOSYSTEM" in calls[0].environment)
    return unittest.end(env)

def _transport_fallback_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(record, [
            struct(return_code = 128, stdout = "", stderr = "couldn't find remote ref"),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    calls = _executes(record)
    asserts.equals(env, 2, len(calls))
    asserts.equals(
        env,
        ["git", "--no-replace-objects", "--git-dir=" + _BARE] + _transport_pins() + ["fetch", _URL, "+refs/*:refs/origin/*"],
        calls[1].args,
    )
    asserts.equals(env, _transport_env(), calls[1].environment)
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
            [struct(return_code = 0, stdout = "", stderr = "")],
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
            [struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = host,
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[0].environment

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
            [struct(return_code = 0, stdout = "", stderr = "")],
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
            [struct(return_code = 0, stdout = "", stderr = "")],
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
            [struct(return_code = 0, stdout = "", stderr = "")],
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
            [struct(return_code = 0, stdout = "", stderr = "")],
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
            [struct(return_code = 0, stdout = "", stderr = "")],
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
    asserts.equals(env, "", by_path["_git_bare/info/attributes"])
    asserts.equals(env, "", by_path["_git_empty_config"])
    asserts.equals(env, "", by_path["_git_empty/keep"])
    return unittest.end(env)

def _materialize_subpath_spec_test_impl(ctx):
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
        _SHA + ":pkgs/foo",
        "test",
    )
    calls = _executes(record)
    asserts.equals(env, _SHA + ":pkgs/foo", calls[4].args[len(calls[4].args) - 1])
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
        *_clears_var_tests
    )

# ---------------------------------------------------------------------------
# Real-git functional probe: `git_hostile_fetch_probe`.
#
# The Starlark tests above pin the environment dicts the helpers build; this
# probe pins what those dicts DO against a real git binary. Each instance
# runs the production sequence (`git_transport_fetch`, `git_materialize`)
# twice over the same commit — once with the true host environment
# (control) and once under a hostile host (the case's `hostile_env`
# overlaid on the process environment) — and requires byte-identical
# results: the hostile fetch must succeed, and its commit tree must equal
# the control's tree. The hostile run drives the helpers through a shim
# context whose `execute` merges exactly like production `ctx.execute`
# does (the helper-built dict over the hostile host), so helper `None`
# entries unset hostile variables and pins and passthrough flow through
# identically; `file`, `path` and `os.environ` pass through to the real
# context and the hostile overlay respectively.
#
# The fallback case (`exercise_fallback`) additionally replays the helper's
# exact fallback command — argv-identical to `git_transport_fetch`, with
# the exact environment dict the helper built — because local transports
# serve any SHA directly and never trigger it: the replay runs the
# all-refs ref transaction (the operation a set-but-empty
# `GIT_QUARANTINE_PATH` forbids on every git version) under the hostile
# host and requires the refs to land. On git versions whose file transport
# negotiates, the helper falls back by itself and the replay is skipped.
#
# Every instance fails the fetch loudly on any deviation and writes a
# `marker.txt` (`expect`/`mode`/`clean`/`hostile`) that
# `//e2e/pub_lock_git:hostile_env_test` re-verifies at test time.
# ---------------------------------------------------------------------------

_SETUP_SCRUB_VARS = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_QUARANTINE_PATH",
    "GIT_INTERNAL_SUPER_PREFIX",
    "GIT_EXEC_PATH",
    "GIT_TEMPLATE_DIR",
    "GIT_INDEX_FILE",
]

def _probe_setup_env(extra = {}):
    """Environment for the probe's own setup commands (origin assembly).

    The hostile overlay must not leak into origin assembly (a hostile
    quarantine path would forbid the clone's own ref updates): the setup
    runs with the true host environment plus pinned commit identity and
    dates for deterministic SHAs, scrubbing only the handful of selectors
    that could redirect the setup commands.
    """
    env = {var: None for var in _SETUP_SCRUB_VARS}
    env.update(extra)
    return env

def _probe_rev_parse(execute, git_dir, rev, env, what):
    kwargs = {} if env == None else {"environment": env}
    res = execute(
        ["git", "--git-dir=" + git_dir, "rev-parse", rev],
        **kwargs
    )
    if res.return_code != 0:
        fail("%s: rev-parse %s failed: %s" % (what, rev, res.stderr))
    return res.stdout.strip()

def _probe_origin_refs(execute, git_dir, env, what):
    res = execute(
        ["git", "--git-dir=" + git_dir, "for-each-ref", "--format=%(refname)", "refs/origin"],
        environment = env,
    )
    if res.return_code != 0:
        fail("%s: listing fetched refs failed: %s" % (what, res.stderr))
    return [line for line in res.stdout.splitlines() if line != ""]

def _probe_make_origin(ctx, bundle, what):
    """Clones the bundle and appends a deterministic second commit.

    Returns the interior (pre-existing bundle tip) commit SHA: advertised
    by no ref after the new commit takes the branch tip.
    """
    origin = str(ctx.path("origin"))
    res = ctx.execute(
        ["git", "clone", "--quiet", "--no-checkout", bundle, origin],
        environment = _probe_setup_env(),
    )
    if res.return_code != 0:
        fail("%s: cloning the probe origin failed: %s" % (what, res.stderr))
    res = ctx.execute(
        ["git", "-C", origin, "checkout", "--quiet", "-b", "main"],
        environment = _probe_setup_env(),
    )
    if res.return_code != 0:
        fail("%s: branching the probe origin failed: %s" % (what, res.stderr))
    ctx.file("probe_empty/keep", "", executable = False)
    res = ctx.execute(
        ["git", "-C", origin] + [
            "-c",
            "user.name=probe",
            "-c",
            "user.email=probe@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=" + str(ctx.path("probe_empty")),
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "probe second commit",
        ],
        environment = _probe_setup_env({
            "GIT_AUTHOR_NAME": "probe",
            "GIT_AUTHOR_EMAIL": "probe@example.invalid",
            "GIT_COMMITTER_NAME": "probe",
            "GIT_COMMITTER_EMAIL": "probe@example.invalid",
            "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+00:00",
            "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+00:00",
        }),
    )
    if res.return_code != 0:
        fail("%s: appending the probe origin commit failed: %s" % (what, res.stderr))
    return _probe_rev_parse(
        ctx.execute,
        origin + "/.git",
        "HEAD~1",
        _probe_setup_env(),
        what + " origin",
    )

def _probe_file_url(path):
    if len(path) > 2 and path[1] == ":":
        return "file:///" + path
    return "file://" + path

def _hostile_probe_impl(ctx):
    what = "git_hostile_fetch_probe \"%s\"" % ctx.name

    hostile = dict(ctx.os.environ)
    hostile.update(ctx.attr.hostile_env)

    recorded = []

    def _shim_execute(args, environment = None):
        merged = dict(hostile)
        if environment != None:
            merged.update(environment)
            recorded.append(environment)
        return ctx.execute(args, environment = merged)

    def _shim_file(path, content, executable = True):
        ctx.file(path, content, executable = executable)

    def _shim_path(path):
        return ctx.path(path)

    shim = struct(
        execute = _shim_execute,
        file = _shim_file,
        path = _shim_path,
        os = struct(environ = hostile),
    )

    url = ctx.attr.url
    control_url = ctx.attr.control_url if ctx.attr.control_url != "" else url
    sha = ctx.attr.resolved_ref
    if ctx.attr.make_origin:
        if ctx.attr.bundle_path == "":
            fail("%s: make_origin needs bundle_path." % what)
        sha = _probe_make_origin(ctx, ctx.attr.bundle_path, what)
        url = _probe_file_url(str(ctx.path("origin")))
        control_url = url
    if url == "" or sha == "":
        fail("%s: needs url and resolved_ref (or make_origin)." % what)

    git_transport_fetch(ctx, control_url, "_clean_bare", sha, what + " control")
    clean_archive = ctx.path("_clean.tar")
    git_materialize(ctx, "_clean_bare", sha, clean_archive, sha, what + " control")
    clean_bare = str(ctx.path("_clean_bare"))
    clean_tree = _probe_rev_parse(ctx.execute, clean_bare, sha + "^{tree}", None, what + " control")

    git_transport_fetch(shim, url, "_hostile_bare", sha, what + " hostile")
    hostile_archive = ctx.path("_hostile.tar")
    git_materialize(shim, "_hostile_bare", sha, hostile_archive, sha, what + " hostile")
    hostile_bare = str(ctx.path("_hostile_bare"))

    # The reads below verify results, so they run scrubbed: the hostile
    # coverage lives in the helper runs above, whose commands all merged
    # the helper-built dict over the hostile host.
    hostile_tree = _probe_rev_parse(_shim_execute, hostile_bare, sha + "^{tree}", _probe_setup_env(), what + " hostile")

    if hostile_tree != clean_tree:
        fail(
            "%s: hostile fetch bytes differ from the clean control: " % what +
            "hostile tree %r vs clean tree %r." % (hostile_tree, clean_tree),
        )

    mode = "sha"
    if len(_probe_origin_refs(_shim_execute, hostile_bare, _probe_setup_env(), what)) > 0:
        mode = "all-refs"
    if ctx.attr.exercise_fallback and mode == "sha":
        if len(recorded) == 0:
            fail("%s: no recorded fetch environment to replay the fallback with." % what)

        # The helper's fallback command, argv-identical to
        # `git_transport_fetch` (whose `_transport_fallback_test_impl` unit
        # test pins it): local transports serve any SHA directly, so the
        # helper's SHA fetch above succeeded without touching refs, and the
        # all-refs ref transaction still needs exercising under the hostile
        # host. The environment is the exact dict the helper built.
        res = _shim_execute(
            ["git", "--no-replace-objects"] + [
                "--git-dir=" + hostile_bare,
                "-c",
                "core.hooksPath=" + str(ctx.path("_git_empty")),
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.untrackedCache=false",
                "fetch",
                url,
                "+refs/*:refs/origin/*",
            ],
            environment = recorded[0],
        )
        if res.return_code != 0:
            fail("%s: fallback all-refs fetch failed under the hostile host: %s" % (what, res.stderr))
        if len(_probe_origin_refs(_shim_execute, hostile_bare, _probe_setup_env(), what)) == 0:
            fail("%s: fallback all-refs fetch landed no refs." % what)
        mode = "all-refs"
    if mode != ctx.attr.expect_fetch_mode:
        fail(
            "%s: expected fetch mode %r but observed %r." % (what, ctx.attr.expect_fetch_mode, mode),
        )

    ctx.file(
        "marker.txt",
        "expect=%s\nmode=%s\nclean=%s\nhostile=%s\n" % (ctx.attr.expect_fetch_mode, mode, clean_tree, hostile_tree),
    )
    ctx.file("BUILD.bazel", "exports_files([\"marker.txt\"])\n")
    ctx.delete(clean_archive)
    ctx.delete(hostile_archive)
    ctx.delete(ctx.path("_clean_bare"))
    ctx.delete(ctx.path("_hostile_bare"))
    if ctx.attr.make_origin:
        ctx.delete(ctx.path("origin"))

git_hostile_fetch_probe = repository_rule(
    implementation = _hostile_probe_impl,
    attrs = {
        "url": attr.string(
            doc = "The fetch URL for the hostile run (and the control, unless control_url is set).",
            default = "",
        ),
        "control_url": attr.string(
            doc = "The fetch URL for the clean control run; defaults to url.",
            default = "",
        ),
        "resolved_ref": attr.string(
            doc = "Full 40-hex commit SHA to fetch; computed from the origin when make_origin is set.",
            default = "",
        ),
        "make_origin": attr.bool(
            doc = "Clone bundle_path and append a deterministic commit, fetching the interior SHA over file://.",
            default = False,
        ),
        "bundle_path": attr.string(
            doc = "Absolute path of the git bundle to clone when make_origin is set.",
            default = "",
        ),
        "hostile_env": attr.string_dict(
            doc = "Hostile GIT_* entries overlaid on the process environment for the hostile run.",
        ),
        "expect_fetch_mode": attr.string(
            doc = "The fetch path the hostile run must take: no ref updates (sha) or all-refs.",
            default = "sha",
            values = ["sha", "all-refs"],
        ),
        "exercise_fallback": attr.bool(
            doc = "Replay the helper's exact fallback command when the SHA fetch took no refs.",
            default = False,
        ),
    },
    doc = "Fetches one commit through the production helpers under a hostile host next to a clean control.",
)
