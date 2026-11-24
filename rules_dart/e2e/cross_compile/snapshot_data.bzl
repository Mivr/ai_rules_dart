"""`platform_data` for a `dart_binary`'s raw `snapshot` output group.

`platform_data` follows a target's executable, which for `aot-snapshot` is
now the run launcher rather than the `.aot` snapshot. A cross-compilation test
needs the raw snapshot to read its ELF header, so this rule applies the same
platform transition and exposes the target's `snapshot` output group instead.
"""

def _snapshot_transition_impl(settings, attr):
    """Selects the platform a snapshot is built for."""
    _ = settings
    return {
        "//command_line_option:platforms": str(attr.platform),
    }

_snapshot_transition = transition(
    implementation = _snapshot_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _snapshot_data_impl(ctx):
    """Symlinks the target's raw snapshot under this target's name."""
    snapshot = ctx.attr.target[0][OutputGroupInfo].snapshot
    if len(snapshot.to_list()) != 1:
        fail("%s: expected one raw snapshot, got %s" % (ctx.label, snapshot.to_list()))
    link = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.symlink(
        output = link,
        target_file = snapshot.to_list()[0],
        is_executable = False,
    )
    return [DefaultInfo(
        files = depset([link]),
        runfiles = ctx.runfiles(files = [link]),
    )]

snapshot_data = rule(
    implementation = _snapshot_data_impl,
    attrs = {
        "target": attr.label(
            doc = "The `dart_binary` whose raw snapshot to expose.",
            allow_files = False,
            executable = True,
            mandatory = True,
            cfg = _snapshot_transition,
        ),
        "platform": attr.label(
            doc = "The platform the target is built for.",
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            doc = "Allowlist permitting the platform transition.",
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Exposes a target's raw `snapshot` output group under a platform transition.",
)
