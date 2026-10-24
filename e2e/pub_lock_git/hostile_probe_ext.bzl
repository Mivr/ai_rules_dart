"""Hostile-host fetch probes: the production git helpers under hostile `GIT_*` environments.

Each `git_hostile_fetch_probe` repository (see
`@rules_dart//dart/tests:git_host_config_test.bzl`) fetches one commit
twice — once with the true host environment and once with the case's
hostile `GIT_*` entries overlaid — and fails the fetch unless the hostile
bytes are identical to the clean control's. The cases below cover every
fetch path: the quarantine variable set and empty, the work-tree variable
set and empty, unknown `GIT_*` names, the all-refs fallback under a
hostile quarantine, and an `insteadOf` rewrite of a remote lock URL to a runtime-local origin
delivered through the inline-config channel. The `git_fsck_fetch_probe` repositories next to
them fetch an fsck-failing commit (crafted at test time) under a hostile
`transfer.fsckObjects=true` delivered through a config file, the
inline-config channel, or a `gitdir`-conditional include matching the
fetch directory. The `git_export_subst_probe` repositories fetch a
non-tip package carrying `export-subst`/`export-ignore` attributes under
hostile `protocol.version=0` and `transfer.unpackLimit` configs. Like `git_host_config_ext.bzl`, the extension is
marked reproducible so the generated repositories (built from absolute
host paths) are recomputed on every machine and never stored in
`MODULE.bazel.lock`.

The `hostile_fallback_quarantine` and `hostile_insteadof` cases also stage
a hostile host-global `uploadpack.packObjectsHook`: the production
helpers must never run it (a local fetch resolves to the same isolated
environment either way), while a raw-git control fetch must.
"""

load("@rules_dart//dart/tests:git_host_config_test.bzl", "git_export_subst_probe", "git_fsck_fetch_probe", "git_hostile_fetch_probe")

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
        pack_objects_hook = True,
    )
    git_hostile_fetch_probe(
        name = "hostile_insteadof",
        url = _REWRITTEN_URL,
        control_url = bundle,
        resolved_ref = _FMTPKG_SHA,
        make_origin = True,
        bundle_path = bundle,
        # The host rewrites the remote lock URL to the runtime origin
        # through the inline-config channel (built by the probe: only it
        # knows the origin path), and stages a hostile host-global
        # `uploadpack.packObjectsHook` the helpers must never run.
        insteadof_to_origin = True,
        pack_objects_hook = True,
        hostile_env = {},
        expect_fetch_mode = "sha",
    )
    git_fsck_fetch_probe(
        name = "hostile_fsck_config_file",
        bundle_path = bundle,
        channel = "config-file",
    )
    git_fsck_fetch_probe(
        name = "hostile_fsck_inline",
        bundle_path = bundle,
        channel = "inline",
    )
    git_fsck_fetch_probe(
        name = "hostile_fsck_includeif",
        bundle_path = bundle,
        channel = "includeif",
    )

    # Archive byte channels: a non-tip package with `export-subst` /
    # `export-ignore` attributes under hostile `protocol.version=0` and
    # `transfer.unpackLimit` configs. Each instance requires byte-identical
    # helper archives next to a naive control proving the fixture expands
    # without the override.
    git_export_subst_probe(
        name = "export_subst_protocol0",
        channel = "protocol0",
    )
    git_export_subst_probe(
        name = "export_subst_unpacklimit",
        channel = "unpacklimit",
    )
    return mctx.extension_metadata(reproducible = True)

hostile = module_extension(implementation = _hostile_impl)
