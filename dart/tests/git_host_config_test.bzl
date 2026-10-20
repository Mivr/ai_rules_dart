"""Unit tests for the shared host-git helpers in `//dart/pub`.

`git_fetch`, `git_checkout` and `git_archive` are the only way fetch call
sites may run host `git` (see `pinned_sources_guard_test.dart`). These tests
drive them with a fake context that records every `execute` call — the
arguments and the environment — so the host-independence contract is pinned
without needing a real git binary:

- materialization (`git_archive`) pins every conversion knob on the command
  line and scrubs the host configuration selectors from the environment;
- fetching (`git_fetch`, `git_checkout`, `verify_git_checkout`) passes its
  arguments through with the inherited environment, so transport
  configuration (credentials, `insteadOf` rewrites, proxies) keeps working.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:pinned_sources.bzl", "git_archive", "git_checkout", "git_fetch", "verify_git_checkout")
load(":small_suite.bzl", "small_unittest_suite")

_SHA = "08a084d50090f0e6ca907fc627ae335c6ac4fd88"

def _fake_ctx(record, results = []):
    """Builds a fake repository/module context recording its calls.

    Args:
      record: A list each call appends a struct to (`args`/`environment` for
        `execute`, `path`/`content` for `file`).
      results: `exec` result structs consumed in order, one per `execute`
        call; calls past the end succeed empty.

    Returns:
        A struct with the `execute`, `file` and `path` methods the helpers
        use. `path` answers `/fake/<path>` so the helpers' `str(ctx.path(..))`
        calls behave.
    """
    pending = list(results)

    def _execute(args, environment = None):
        record.append(struct(args = args, environment = environment))
        if pending:
            return pending.pop(0)
        return struct(return_code = 0, stdout = "", stderr = "")

    def _file(path, content):
        record.append(struct(path = path, content = content))

    def _path(path):
        return "/fake/" + path

    return struct(execute = _execute, file = _file, path = _path)

def _executes(record):
    return [call for call in record if hasattr(call, "args")]

def _archive_call_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_archive(_fake_ctx(record), "_clone", "_out.tar", _SHA, "test")
    calls = _executes(record)
    asserts.equals(env, 1, len(calls))
    args = calls[0].args
    asserts.equals(env, "git", args[0])
    for flag in ["core.autocrlf=false", "core.eol=lf", "tar.umask=002"]:
        asserts.true(env, flag in args, "%r must be pinned on the command line" % flag)
    attr_files = [a[len("core.attributesfile="):] for a in args if a.startswith("core.attributesfile=")]
    asserts.equals(env, 1, len(attr_files))
    asserts.true(env, len(attr_files[0]) > 0, "core.attributesFile must point at a written file")
    asserts.true(env, "archive" in args, "the helper must run git archive")
    asserts.equals(env, _SHA, args[len(args) - 1])
    environment = calls[0].environment
    asserts.equals(env, "", environment["GIT_CONFIG_COUNT"])
    asserts.equals(env, "", environment["GIT_CONFIG_PARAMETERS"])
    asserts.equals(env, attr_files[0], environment["GIT_CONFIG_GLOBAL"])
    asserts.equals(env, attr_files[0], environment["GIT_CONFIG_SYSTEM"])
    return unittest.end(env)

def _archive_writes_empty_config_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_archive(_fake_ctx(record), "_clone", "_out.tar", _SHA + ":pkgs/foo", "test")
    files = [call for call in record if hasattr(call, "content")]
    asserts.equals(env, 1, len(files))
    asserts.equals(env, "", files[0].content)
    calls = _executes(record)
    attr_files = [a[len("core.attributesfile="):] for a in calls[0].args if a.startswith("core.attributesfile=")]
    asserts.equals(env, "/fake/" + files[0].path, attr_files[0])
    asserts.equals(env, attr_files[0], calls[0].environment["GIT_CONFIG_GLOBAL"])
    return unittest.end(env)

def _fetch_passthrough_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    res = git_fetch(_fake_ctx(record, [struct(return_code = 0, stdout = "out", stderr = "")]), ["clone", "--no-checkout", "https://example.com/r.git", "_clone"])
    asserts.equals(env, "out", res.stdout)
    calls = _executes(record)
    asserts.equals(env, 1, len(calls))
    asserts.equals(
        env,
        ["git", "clone", "--no-checkout", "https://example.com/r.git", "_clone"],
        calls[0].args,
    )
    asserts.equals(env, None, calls[0].environment)
    return unittest.end(env)

def _checkout_happy_path_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_checkout(_fake_ctx(record), "_clone", _SHA, "test")
    calls = _executes(record)
    asserts.equals(env, 1, len(calls))
    asserts.equals(env, ["git", "-C", "_clone", "checkout", "--quiet", _SHA], calls[0].args)
    asserts.equals(env, None, calls[0].environment)
    return unittest.end(env)

def _checkout_fetches_then_retries_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    git_checkout(
        _fake_ctx(record, [
            struct(return_code = 128, stdout = "", stderr = "unknown revision"),
            struct(return_code = 0, stdout = "", stderr = ""),
            struct(return_code = 0, stdout = "", stderr = ""),
        ]),
        "_clone",
        _SHA,
        "test",
    )
    calls = _executes(record)
    asserts.equals(env, 3, len(calls))
    asserts.equals(env, ["git", "-C", "_clone", "checkout", "--quiet", _SHA], calls[0].args)
    asserts.equals(env, ["git", "-C", "_clone", "fetch", "origin", _SHA], calls[1].args)
    asserts.equals(env, ["git", "-C", "_clone", "checkout", "--quiet", _SHA], calls[2].args)
    for call in calls:
        asserts.equals(env, None, call.environment)
    return unittest.end(env)

def _verify_uses_helper_test_impl(ctx):
    env = unittest.begin(ctx)
    record = []
    verify_git_checkout(
        _fake_ctx(record, [struct(return_code = 0, stdout = _SHA + "\n", stderr = "")]),
        "_clone",
        _SHA,
        "test",
    )
    calls = _executes(record)
    asserts.equals(env, 1, len(calls))
    asserts.equals(env, ["git", "-C", "_clone", "rev-parse", "HEAD^{commit}"], calls[0].args)
    asserts.equals(env, None, calls[0].environment)
    return unittest.end(env)

_t0_test = unittest.make(_archive_call_test_impl)
_t1_test = unittest.make(_archive_writes_empty_config_test_impl)
_t2_test = unittest.make(_fetch_passthrough_test_impl)
_t3_test = unittest.make(_checkout_happy_path_test_impl)
_t4_test = unittest.make(_checkout_fetches_then_retries_test_impl)
_t5_test = unittest.make(_verify_uses_helper_test_impl)

def git_host_config_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
    )
