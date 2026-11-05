"""Hermeticity canary rule reading an undeclared host file."""

visibility("private")

def _hermetic_canary_impl(ctx):
    """Runs the canary tool writing the probed file size to the output.

    Args:
        ctx: Rule context.

    Returns:
        DefaultInfo provider with the declared canary output.
    """
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.run(
        outputs = [out],
        executable = ctx.executable._tool,
        arguments = [out.path],
        tools = [ctx.attr._tool[DefaultInfo].files_to_run],
        mnemonic = "HermeticCanary",
        progress_message = "HermeticCanary %{output}",
        use_default_shell_env = False,
    )
    return [DefaultInfo(files = depset([out]))]

hermetic_canary = rule(
    doc = "Probes an undeclared host path so the strict sandbox fails.",
    implementation = _hermetic_canary_impl,
    attrs = {
        "_tool": attr.label(
            cfg = "exec",
            default = ":tool",
            doc = "Canary executable reading the undeclared host path.",
            executable = True,
        ),
    },
)
