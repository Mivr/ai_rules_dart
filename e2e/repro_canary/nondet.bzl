"""Reproducibility canary rule producing non-deterministic action outputs."""

def _repro_canary_impl(ctx):
    """Executes an action reading /dev/urandom into the declared output.

    Args:
        ctx: Rule context.

    Returns:
        DefaultInfo provider containing the declared non-deterministic output.
    """
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.run(
        outputs = [out],
        executable = "/bin/dd",
        arguments = [
            "if=/dev/urandom",
            "of=" + out.path,
            "bs=32",
            "count=1",
            "status=none",
        ],
        mnemonic = "ReproCanary",
        progress_message = "Generating non-deterministic reproducibility canary %{output}",
        use_default_shell_env = False,
    )
    return [DefaultInfo(files = depset([out]))]

repro_canary = rule(
    doc = "Produces non-deterministic output by reading from /dev/urandom.",
    implementation = _repro_canary_impl,
)
