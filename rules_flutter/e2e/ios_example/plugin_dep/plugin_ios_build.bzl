"""Build a plugin fixture for the iOS device platform from a macOS host.

The plugin's Flutter framework import is an iOS XCFramework, so its inner
`objc_library` must compile for iOS even though the surrounding `build_test`
runs on the macOS host. The transition keeps the test runner in the default
configuration while moving only the library it builds.
"""

visibility("private")

def _plugin_ios_build_impl(ctx):
    return [DefaultInfo(files = ctx.attr.target[0][DefaultInfo].files)]

def _plugin_ios_transition_impl(_settings, _attr):
    return {
        "//command_line_option:ios_multi_cpus": ["arm64"],
        "//command_line_option:platforms": [Label("@apple_support//platforms:ios_arm64")],
    }

_plugin_ios_transition = transition(
    implementation = _plugin_ios_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:ios_multi_cpus",
        "//command_line_option:platforms",
    ],
)

plugin_ios_build = rule(
    implementation = _plugin_ios_build_impl,
    attrs = {
        "target": attr.label(
            cfg = _plugin_ios_transition,
            mandatory = True,
            doc = "The plugin library to build for the iOS device platform.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Re-exposes a plugin library built for the iOS device platform.",
)
