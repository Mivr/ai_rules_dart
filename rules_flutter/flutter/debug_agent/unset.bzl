"""The default of the `:flutter` flag: a target that says how to set it."""

visibility("private")

def _flutter_unset_impl(ctx):
    fail(
        "the debug agent needs your app's `package:flutter`: add\n" +
        "    build --@rules_flutter//flutter/debug_agent:flutter=@deps//:flutter\n" +
        "to your .bazelrc, naming the `flutter` of the pub hub your app uses (here `deps`). (%s)" % ctx.label,
    )

flutter_unset = rule(
    implementation = _flutter_unset_impl,
    doc = "Fails, saying which flag to set.",
)
