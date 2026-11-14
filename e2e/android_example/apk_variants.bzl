"""Rebuilds an Android app in a fixed Flutter build mode, whatever the command line asked for.

`bazel test` builds the default configuration, which is release. The two rules
here re-expose one APK built in profile mode and one built in debug mode, so
a Linux test can inspect each without being run under `-c opt` or `-c dbg`.
"""

visibility("private")

def _profile_transition_impl(_settings, _attr):
    return {
        "//command_line_option:compilation_mode": "opt",
        "@rules_android//flags:android_platforms": [str(Label("@rules_flutter//flutter/platforms:android_arm64"))],
        "@rules_flutter//flutter:profile": True,
    }

_profile_transition = transition(
    implementation = _profile_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "@rules_android//flags:android_platforms",
        "@rules_flutter//flutter:profile",
    ],
)

def _debug_transition_impl(_settings, _attr):
    return {
        "//command_line_option:compilation_mode": "dbg",
        "@rules_android//flags:android_platforms": [str(Label("@rules_flutter//flutter/platforms:android_arm64"))],
        "@rules_flutter//flutter:profile": False,
    }

_debug_transition = transition(
    implementation = _debug_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "@rules_android//flags:android_platforms",
        "@rules_flutter//flutter:profile",
    ],
)

def _apk_impl(ctx):
    # A transition on the attribute delivers the dependency as a one-element
    # list. The app target exposes the signed `<name>.apk` and an unsigned
    # variant; select the signed APK by name.
    dep = ctx.attr.apk[0]
    want = dep.label.name + ".apk"
    matches = [f for f in dep[DefaultInfo].files.to_list() if f.basename == want]
    if len(matches) != 1:
        fail("expected exactly one %s from %s, found %s" %
             (want, dep.label, [f.basename for f in matches]))
    out = ctx.actions.declare_file(ctx.label.name + ".apk")
    ctx.actions.symlink(output = out, target_file = matches[0])
    return [DefaultInfo(files = depset([out]))]

profile_apk = rule(
    implementation = _apk_impl,
    doc = "Re-exposes an app's APK built with `-c opt --@rules_flutter//flutter:profile` for arm64.",
    attrs = {
        "apk": attr.label(
            mandatory = True,
            cfg = _profile_transition,
            doc = "A `flutter_android_app` whose APK to build in profile mode.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

debug_apk = rule(
    implementation = _apk_impl,
    doc = "Re-exposes an app's APK built with `-c dbg` for arm64.",
    attrs = {
        "apk": attr.label(
            mandatory = True,
            cfg = _debug_transition,
            doc = "A `flutter_android_app` whose APK to build in debug mode.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
