"""Builds targets in Flutter profile mode, whatever the command line asked for."""

visibility("private")

def _profile_transition_impl(_settings, _attr):
    return {
        "//command_line_option:compilation_mode": "opt",
        "@rules_flutter//flutter:profile": True,
    }

_profile_transition = transition(
    implementation = _profile_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "@rules_flutter//flutter:profile",
    ],
)

def _profile_build_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.attr.targets
    ]))]

profile_build = rule(
    implementation = _profile_build_impl,
    doc = "Forwards the files of `targets`, built with `-c opt --@rules_flutter//flutter:profile`.",
    attrs = {
        "targets": attr.label_list(
            cfg = _profile_transition,
            mandatory = True,
            doc = "The targets to build in profile mode.",
        ),
    },
)
