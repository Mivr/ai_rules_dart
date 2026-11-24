"""Reproducibility canary rule that produces nondeterministic output."""

visibility("private")

def _repro_canary_impl(ctx):
    """Executes /bin/dd reading at most 32 bytes from /dev/urandom into the declared output.

    Args:
        ctx: Rule context.

    Returns:
        DefaultInfo provider with the declared output file.
    """
    out = ctx.actions.declare_file(ctx.label.name + ".bin")
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
        progress_message = "Generating reproducibility canary %{output}",
        use_default_shell_env = False,
    )
    return [DefaultInfo(files = depset([out]))]

repro_canary = rule(
    doc = "Rule producing a nondeterministic file from /dev/urandom.",
    implementation = _repro_canary_impl,
)
