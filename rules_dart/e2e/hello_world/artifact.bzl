"""Helpers that expose a `dart_binary`'s run entry and named outputs to tests.

A `dart_test`'s `data` carries a target's runfiles, not its compiled files, so
the tests here need a small target per artifact they read. Each helper returns
exactly one file, which makes `$(rlocationpath :helper)` unambiguous.
"""

def _launcher_bundle_impl(ctx):
    """Returns a target's run launcher and every runfile it needs."""
    target = ctx.attr.target[DefaultInfo]
    launcher = target.files_to_run.executable
    snapshot = ctx.attr.target[OutputGroupInfo].snapshot
    runfiles = target.default_runfiles.merge(
        ctx.runfiles(files = [launcher] + snapshot.to_list()),
    )
    return [DefaultInfo(
        files = depset([launcher]),
        runfiles = runfiles,
    )]

launcher_bundle = rule(
    implementation = _launcher_bundle_impl,
    attrs = {
        "target": attr.label(
            doc = "The executable `dart_binary` whose launcher to expose.",
            executable = True,
            mandatory = True,
            cfg = "target",
        ),
    },
    doc = "Exposes a `dart_binary`'s `DefaultInfo.executable` to a test.",
)

def _output_group_bundle_impl(ctx):
    """Returns the single file in one of a target's output groups."""
    groups = ctx.attr.target[OutputGroupInfo]
    if not hasattr(groups, ctx.attr.group):
        fail("%s: target has no %r output group" % (ctx.label, ctx.attr.group))
    files = getattr(groups, ctx.attr.group).to_list()
    if len(files) != 1:
        fail("%s: expected one file in output group %r, got %s" % (
            ctx.label,
            ctx.attr.group,
            files,
        ))
    return [DefaultInfo(
        files = depset(files),
        runfiles = ctx.runfiles(files = files),
    )]

output_group_bundle = rule(
    implementation = _output_group_bundle_impl,
    attrs = {
        "target": attr.label(
            doc = "The target owning the output group.",
            mandatory = True,
        ),
        "group": attr.string(
            doc = "The output group to expose.",
            mandatory = True,
        ),
    },
    doc = "Exposes one file from a target's named output group to a test.",
)
