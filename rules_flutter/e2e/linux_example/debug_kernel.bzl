"""Rebuild a `flutter_application` under `-c dbg` and re-expose its kernel dill.

`bazel test //...` builds the default configuration, where a `flutter_application`
compiles AOT and the modular debug kernel path is not taken. This rule forces
`compilation_mode=dbg` on its application through a transition, so the debug
kernel the VM would load is a real build output, while the test that reads it
stays in the default configuration.
"""

visibility("private")

def _force_dbg_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "dbg"}

_force_dbg = transition(
    implementation = _force_dbg_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _debug_kernel_impl(ctx):
    # A transition on the attribute delivers the dependency as a one-element list.
    app = ctx.attr.app[0]
    want = app.label.name + ".dill"
    matches = [f for f in app[DefaultInfo].files.to_list() if f.basename == want]
    if len(matches) != 1:
        fail("expected exactly one %s from %s, found %s" % (want, app.label, [f.basename for f in matches]))
    out = ctx.actions.declare_file(ctx.label.name + ".dill")
    ctx.actions.symlink(output = out, target_file = matches[0])
    return [DefaultInfo(files = depset([out]))]

debug_kernel = rule(
    implementation = _debug_kernel_impl,
    attrs = {
        "app": attr.label(
            mandatory = True,
            cfg = _force_dbg,
            doc = "A flutter_application whose debug kernel dill to expose, built under -c dbg.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Re-exposes a flutter_application's kernel dill built under -c dbg.",
)
