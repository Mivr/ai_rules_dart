"""Hostile-host fetch probes: the production git helpers under hostile `GIT_*` environments.

Each `git_hostile_fetch_probe` repository (see
`@rules_dart//dart/tests:git_host_config_test.bzl`) fetches one commit
twice — once with the true host environment and once with the case's
hostile `GIT_*` entries overlaid — and fails the fetch unless the hostile
bytes are identical to the clean control's. The cases below cover every
fetch path: the quarantine variable set and empty, the work-tree variable
set and empty, unknown `GIT_*` names, the all-refs fallback under a
hostile quarantine, and an `insteadOf` rewrite delivered through the
inline-config channel. Like `git_host_config_ext.bzl`, the extension is
marked reproducible so the generated repositories (built from absolute
host paths) are recomputed on every machine and never stored in
`MODULE.bazel.lock`.
"""

load("@rules_dart//dart/tests:git_host_config_test.bzl", "git_hostile_fetch_probe")

_FMTPKG_SHA = "08da52a5f5ee8530fcffaa7b4a6aecdc09a0e9cc"
_REWRITTEN_URL = "https://rewritten.example.invalid/r.git"

def _hostile_impl(mctx):
    bundle = str(mctx.path(Label("//:fmtpkg.bundle")))
    git_hostile_fetch_probe(
        name = "hostile_quarantine_set",
        url = bundle,
        resolved_ref = _FMTPKG_SHA,
        hostile_env = {"GIT_QUARANTINE_PATH": "/nonexistent/quarantine"},
        expect_fetch_mode = "sha",
    )
    git_hostile_fetch_probe(
        name = "hostile_quarantine_empty",
        url = bundle,
        resolved_ref = _FMTPKG_SHA,
        hostile_env = {"GIT_QUARANTINE_PATH": ""},
        expect_fetch_mode = "sha",
    )
    git_hostile_fetch_probe(
        name = "hostile_worktree_set",
        url = bundle,
        resolved_ref = _FMTPKG_SHA,
        hostile_env = {"GIT_WORK_TREE": "/nonexistent/wt"},
        expect_fetch_mode = "sha",
    )
    git_hostile_fetch_probe(
        name = "hostile_worktree_empty",
        url = bundle,
        resolved_ref = _FMTPKG_SHA,
        hostile_env = {"GIT_WORK_TREE": ""},
        expect_fetch_mode = "sha",
    )
    git_hostile_fetch_probe(
        name = "hostile_unknown_vars",
        url = bundle,
        resolved_ref = _FMTPKG_SHA,
        hostile_env = {
            "GIT_FUTURE_TRANSPORT_XYZ": "hostile",
            "GIT_ANOTHER_NEW_VAR": "",
        },
        expect_fetch_mode = "sha",
    )
    git_hostile_fetch_probe(
        name = "hostile_fallback_quarantine",
        make_origin = True,
        bundle_path = bundle,
        hostile_env = {"GIT_QUARANTINE_PATH": "/nonexistent/quarantine"},
        expect_fetch_mode = "all-refs",
        exercise_fallback = True,
    )
    git_hostile_fetch_probe(
        name = "hostile_insteadof",
        url = _REWRITTEN_URL,
        control_url = bundle,
        resolved_ref = _FMTPKG_SHA,
        hostile_env = {
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "url." + bundle + ".insteadOf",
            "GIT_CONFIG_VALUE_0": _REWRITTEN_URL,
        },
        expect_fetch_mode = "sha",
    )
    return mctx.extension_metadata(reproducible = True)

hostile = module_extension(implementation = _hostile_impl)
