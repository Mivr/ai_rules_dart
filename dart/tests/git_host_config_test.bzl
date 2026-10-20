"""Unit tests for the two-phase host-git helpers in `//dart/pub`.

`git_transport_fetch` and `git_materialize` are the only way fetch call
sites may run host `git` (see `pinned_sources_guard_test.dart`). These
tests drive them with a fake context that records every `execute` call —
the arguments and the environment — and every `file` call, so the
host-independence contract is pinned without needing a real git binary:

- transport (`git_transport_fetch`) assembles a bare repository skeleton
  without running `git init`, then fetches the pinned SHA (falling back
  to all refs), all while inheriting only the allowlisted transport
  variables and scrubbing every other documented non-transport `GIT_*`
  selector — one hostile-value test per variable below;
- materialization (`git_materialize`) refuses alternates, verifies the
  commit id, its type and its tree, and archives the pinned spec, every
  command with an explicit `--git-dir`, `--no-replace-objects` and an
  environment scrubbed to `PATH` plus a scratch `HOME`.
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
# back verbatim.
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
    "GIT_PROXY_COMMAND",
    "GIT_ASKPASS",
    "GIT_TERMINAL_PROMPT",
]

def _transport_env(extra = {}):
    env = {
        "GIT_DIR": "",
        "GIT_OBJECT_DIRECTORY": _BARE + "/objects",
        "GIT_COMMON_DIR": _BARE,
        "GIT_INDEX_FILE": "",
        "GIT_INDEX_VERSION": "",
        "GIT_NAMESPACE": "",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": "",
        "GIT_QUARANTINE_PATH": "",
        "GIT_REPLACE_REF_BASE": "",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_CEILING_DIRECTORIES": "",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM": "",
        "GIT_PREFIX": "",
        "GIT_SUPER_PREFIX": "",
        "GIT_TEMPLATE_DIR": "",
        "GIT_ALLOW_PROTOCOL": "https:http:git:ssh:file",
        "GIT_CONFIG_COUNT": "",
        "GIT_CONFIG_PARAMETERS": "",
        "GIT_GRAFT_FILE": "",
        "GIT_AUTHOR_NAME": "",
        "GIT_AUTHOR_EMAIL": "",
        "GIT_AUTHOR_DATE": "",
        "GIT_COMMITTER_NAME": "",
        "GIT_COMMITTER_EMAIL": "",
        "GIT_COMMITTER_DATE": "",
        "GIT_REFLOG_ACTION": "",
        "GIT_FLUSH": "",
        "GIT_EDITOR": "",
        "GIT_PAGER": "",
        "GIT_EXTERNAL_DIFF": "",
        "GIT_DIFF_OPTS": "",
        "GIT_LITERAL_PATHSPECS": "",
        "GIT_TRACE": "",
        "GIT_TRACE_PACK_ACCESS": "",
        "GIT_TRACE_PACKET": "",
        "GIT_TRACE_PERFORMANCE": "",
        "GIT_TRACE_SETUP": "",
        "GIT_CURL_VERBOSE": "",
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
        "GIT_CONFIG_COUNT": "",
        "GIT_CONFIG_PARAMETERS": "",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_TEMPLATE_DIR": _EMPTY_DIR,
        "GIT_OBJECT_DIRECTORY": _BARE + "/objects",
        "GIT_COMMON_DIR": _BARE,
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": "",
        "GIT_ALLOW_PROTOCOL": "https:http:git:ssh:file",
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

# One hostile value per scrubbed transport variable. Each generated test
# sets its variable in the fake host environment and requires the fetch
# environment to neutralize it to the empty value git reads as unset.
# Per-variable scrub tests: one `_clears_var_<name>_test` rule per
# scrubbed transport variable, each named after the variable it covers.

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
    asserts.equals(env, "", fetch_env[ctx.attr.var])
    return unittest.end(env)

# One test rule per scrubbed variable, each bound to a module-level
# name: `rule()` objects must be exported by the bzl file, so a
# comprehension-generated list is not a valid rule class.
_clears_var_git_dir_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_DIR"), "hostile": attr.string(default = "/hostile/dir")},
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
_clears_var_git_config_parameters_test = unittest.make(
    _clears_var_test_impl,
    attrs = {"var": attr.string(default = "GIT_CONFIG_PARAMETERS"), "hostile": attr.string(default = "'core.hooksPath=/hostile/hooks'")},
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
    _clears_var_git_config_parameters_test,
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

def _transport_inherited_vars_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_transport_fetch(
        _fake_ctx(
            record,
            [struct(return_code = 0, stdout = "", stderr = "")],
            os_environ = {
                "GIT_WORK_TREE": "/hostile/wt",
                "GIT_INTERNAL_SUPER_PREFIX": "hostile/",
            },
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[0].environment

    # These two selectors cannot be scrubbed to empty — git rejects the
    # empty value — so they stay out of the environment dict and are
    # inherited: any non-empty `GIT_WORK_TREE` is ignored by every
    # transport command on the bare repository (no `init` runs anymore),
    # and `GIT_INTERNAL_SUPER_PREFIX` is set only by git itself.
    asserts.false(env, "GIT_WORK_TREE" in fetch_env)
    asserts.false(env, "GIT_INTERNAL_SUPER_PREFIX" in fetch_env)
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
                "GIT_CONFIG_KEY_0": "core.hooksPath",
                "GIT_CONFIG_VALUE_0": "/hostile/hooks",
            },
        ),
        _URL,
        "_git_bare",
        _SHA,
        "test",
    )
    fetch_env = _executes(record)[0].environment

    # Clearing the count neutralizes the whole inline-config channel:
    # smuggled key/value pairs are never copied into the environment, and
    # git ignores them without a count.
    asserts.equals(env, "", fetch_env["GIT_CONFIG_COUNT"])
    asserts.equals(env, "", fetch_env["GIT_CONFIG_PARAMETERS"])
    asserts.false(env, "GIT_CONFIG_KEY_0" in fetch_env)
    asserts.false(env, "GIT_CONFIG_VALUE_0" in fetch_env)
    return unittest.end(env)

def _transport_passthrough_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    host = {var: "/host/sentinel/" + var for var in _TRANSPORT_PASSTHROUGH}
    host["GIT_FOOBAR"] = "hostile"
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

    # The allowlisted transport variables pass through verbatim; nothing
    # else from the host environment is copied into the dict.
    for var in _TRANSPORT_PASSTHROUGH:
        asserts.equals(env, host[var], fetch_env[var])
    asserts.false(env, "GIT_FOOBAR" in fetch_env)
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
    asserts.equals(env, "", environment["GIT_CONFIG_COUNT"])
    asserts.equals(env, "", environment["GIT_CONFIG_PARAMETERS"])
    asserts.equals(env, "1", environment["GIT_NO_REPLACE_OBJECTS"])
    asserts.equals(env, "", environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"])
    asserts.equals(env, _BARE + "/objects", environment["GIT_OBJECT_DIRECTORY"])
    asserts.equals(env, _BARE, environment["GIT_COMMON_DIR"])

    # Transport-executing variables are scrubbed: materialization never
    # touches the network.
    asserts.equals(env, "", environment["GIT_SSH_COMMAND"])
    asserts.equals(env, "", environment["GIT_ASKPASS"])

    # `--git-dir` beats `GIT_DIR` on every git version, so the flag carries
    # the isolation and the variable stays out of the environment.
    asserts.false(env, "GIT_DIR" in environment)
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
_t6_test = unittest.make(_materialize_truncates_attributes_test_impl)
_t7_test = unittest.make(_materialize_subpath_spec_test_impl)
_t8_test = unittest.make(_transport_pins_dirs_test_impl)
_t9_test = unittest.make(_transport_config_count_test_impl)
_t10_test = unittest.make(_transport_passthrough_test_impl)
_t11_test = unittest.make(_transport_inherited_vars_test_impl)

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
        *_clears_var_tests
    )
