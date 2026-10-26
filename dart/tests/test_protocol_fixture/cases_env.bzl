"""Captures RunEnvironmentInfo and runfiles from a target."""

def _cases_env_impl(ctx):
    """Writes target's RunEnvironmentInfo.environment to a JSON file and forwards runfiles."""
    out = ctx.actions.declare_file(ctx.label.name + ".json")
    env = ctx.attr.target[RunEnvironmentInfo].environment
    ctx.actions.write(out, json.encode(env))
    runfiles = ctx.runfiles(files = [out])
    runfiles = runfiles.merge(ctx.attr.target[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(files = depset([out]), runfiles = runfiles),
    ]

cases_env = rule(
    doc = "Writes the RunEnvironmentInfo.environment of target to a JSON file and forwards its runfiles.",
    implementation = _cases_env_impl,
    attrs = {
        "target": attr.label(
            doc = "The target whose RunEnvironmentInfo is captured.",
            mandatory = True,
            providers = [RunEnvironmentInfo, DefaultInfo],
        ),
    },
)
