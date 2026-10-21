"""Repository-rule test that git fetching ignores host templates and hooks.

The workspace's `hostile_template/` plays a hostile `GIT_TEMPLATE_DIR`: its
`info/attributes` sets `*.dart export-subst` (a byte channel: the archived
bytes of the pinned commit change) and its `hooks/post-checkout` touches
`$HOOK_MARKER` (an execution channel: host code runs at checkout time).

The probe fetches the same pinned bundle (`//:fmtpkg.bundle`) three ways:

- through the production helpers (`git_transport_fetch`, `git_materialize`
  — the exact sequence `pub_lock_git_package` runs), whose bytes must stay
  pristine: the literal `$Format:%H$` placeholder survives and the commit id
  never leaks into them, because the helpers' `info/attributes` override
  keeps every `export-subst` entry inert;
- raw, with the hostile template as `GIT_TEMPLATE_DIR` and no isolation: the
  archived bytes must expand and the hook must run. These controls fail the
  fetch when the environment cannot show hostility (for example a hook that
  never executes), so a green probe never passes vacuously. The hook control
  is skipped on Windows, where an extensionless hook may not execute;
- planted: a `post-checkout` hook planted into the transported bare
  repository, then materialized through the helper. With no checkout phase
  the planted hook must stay silent on every OS. The hook script failing
  would fail a checkout instead, so silence is asserted by the marker's
  absence.
"""

load("@rules_dart//dart/pub:pinned_sources.bzl", "git_materialize", "git_transport_fetch", "pinned_source_error")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "make_dart_library_build_content")

def _template_probe_impl(ctx):
    sha = ctx.attr.resolved_ref
    err = pinned_source_error(
        "git",
        ctx.attr.package_name,
        ctx.attr.version,
        resolved_ref = sha,
        rule = "git_template_probe",
    )
    if err:
        fail(err)
    bundle = ctx.attr.bundle_path
    template_dir = ctx.attr.template_dir
    what = "git_template_probe \"%s\"" % ctx.attr.package_name

    # 1. The production helper sequence. Its bytes must be pristine: the
    # literal `$Format:%H$` placeholder survives, the commit id never leaks
    # into them.
    git_transport_fetch(ctx, bundle, "_helper_bare", sha, what + " helper")
    archive_path = ctx.path("_helper.tar")
    git_materialize(ctx, "_helper_bare", sha, archive_path, sha, what + " helper")
    ctx.extract(archive_path)
    ctx.delete(archive_path)
    ctx.delete(ctx.path("_helper_bare"))
    helper_src = ctx.read("lib/fmtpkg.dart")
    if "$Format:%H$" not in helper_src or sha in helper_src:
        fail(
            "%s: helper bytes are not pristine: expected the literal " % what +
            "$Format:%H$ placeholder without %s." % sha,
        )

    # 2. Raw hostile control, without any isolation: the same template must
    # expand the archived bytes and run the hook, or the comparison above
    # would pass vacuously.
    raw_clone = str(ctx.path("_raw_clone"))
    res = ctx.execute(
        ["git", "clone", "--no-checkout", "--template=" + template_dir, bundle, raw_clone],
        environment = {"GIT_TEMPLATE_DIR": template_dir},
    )
    if res.return_code != 0:
        fail("%s: control clone failed: %s" % (what, res.stderr))
    raw_marker = str(ctx.path("_raw.marker"))
    res = ctx.execute(
        ["git", "-C", raw_clone, "checkout", "--quiet", sha],
        environment = {"GIT_TEMPLATE_DIR": template_dir, "HOOK_MARKER": raw_marker},
    )
    if res.return_code != 0:
        fail("%s: control checkout failed: %s" % (what, res.stderr))
    raw_archive = str(ctx.path("_raw.tar"))
    res = ctx.execute(
        ["git", "-C", raw_clone, "archive", "--format=tar", "-o", raw_archive, sha],
        environment = {"GIT_TEMPLATE_DIR": template_dir},
    )
    if res.return_code != 0:
        fail("%s: control archive failed: %s" % (what, res.stderr))
    ctx.extract(raw_archive, output = "raw")
    raw_src = ctx.read("raw/lib/fmtpkg.dart")
    if sha not in raw_src:
        fail(
            "%s: byte control vacuous: the hostile template did not " % what +
            "expand the archived bytes, so the helper comparison proves nothing.",
        )
    if ctx.os.name != "windows" and not ctx.path("_raw.marker").exists:
        fail(
            "%s: exec control vacuous: the template hook did not run " % what +
            "at checkout, so the helper comparison proves nothing.",
        )

    # 3. Planted hook silence: a `post-checkout` hook planted into the
    # transported bare repository must never run — materialization streams
    # the archive without any checkout, on every OS.
    git_transport_fetch(ctx, bundle, "_planted_bare", sha, what + " planted")
    hook_marker = str(ctx.path("_planted.marker"))
    ctx.file(
        "_planted_bare/hooks/post-checkout",
        "#!/bin/sh\ntouch \"%s\"\n" % hook_marker,
        executable = True,
    )
    planted_archive = ctx.path("_planted.tar")
    git_materialize(ctx, "_planted_bare", sha, planted_archive, sha, what + " planted")
    ctx.extract(planted_archive, output = "planted")
    ctx.delete(planted_archive)
    ctx.delete(ctx.path("_planted_bare"))
    if ctx.path("_planted.marker").exists:
        fail(
            "%s: planted hook ran during materialization: " % what +
            "fetching must never execute repository hooks.",
        )
    planted_src = ctx.read("planted/lib/fmtpkg.dart")
    if "$Format:%H$" not in planted_src or sha in planted_src:
        fail(
            "%s: planted bytes are not pristine: expected the literal " % what +
            "$Format:%H$ placeholder without %s." % sha,
        )

    ctx.file("BUILD.bazel", make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = [],
        language_version = "3.0",
        code_assets = [],
        has_unreplaced_hook = False,
        version = ctx.attr.version,
        link_hook = "",
    ))

git_template_probe = repository_rule(
    implementation = _template_probe_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version.",
            mandatory = True,
        ),
        "bundle_path": attr.string(
            doc = "Absolute path of the git bundle to clone.",
            mandatory = True,
        ),
        "template_dir": attr.string(
            doc = "Absolute path of the hostile template directory.",
            mandatory = True,
        ),
        "resolved_ref": attr.string(
            doc = "Full 40-hex commit SHA to fetch.",
            mandatory = True,
        ),
    },
    doc = "Fetches one git package through the production helpers next to a raw hostile control.",
)

def _probe_impl(mctx):
    sentinel = str(mctx.path(Label("//:hostile_template/info/attributes")))
    git_template_probe(
        name = "probe",
        package_name = "fmtpkg",
        version = "1.0.0",
        bundle_path = str(mctx.path(Label("//:fmtpkg.bundle"))),
        template_dir = sentinel.removesuffix("/info/attributes"),
        resolved_ref = "08da52a5f5ee8530fcffaa7b4a6aecdc09a0e9cc",
    )
    return mctx.extension_metadata(reproducible = True)

probe = module_extension(implementation = _probe_impl)
