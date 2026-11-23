"""Transitions that build the add-to-app xcframework slices (private).

Each transition moves one dependency edge to a single iOS platform in release
mode, so the device arm64 and the simulator arm64 and x86_64 slices are built
in their own configurations.
"""

visibility(["//flutter/..."])

def _xcframework_transition_impl(platform_label):
    """Builds a transition to one iOS platform in release mode.

    Add-to-app xcframeworks are shipping artifacts: the device and simulator
    slices are AOT snapshots, so the transition forces `-c opt` and clears the
    profile flag rather than inheriting whatever the calling build used.
    """
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:platforms": str(platform_label),
        str(Label("//flutter:profile")): False,
    }

def _ios_device_transition_impl(_settings, _attr):
    return _xcframework_transition_impl(Label("//flutter/platforms:ios_arm64"))

def _ios_sim_arm64_transition_impl(_settings, _attr):
    return _xcframework_transition_impl(Label("//flutter/private:ios_sim_arm64"))

def _ios_sim_x64_transition_impl(_settings, _attr):
    return _xcframework_transition_impl(Label("//flutter/platforms:ios_x64"))

ios_device_transition = transition(
    implementation = _ios_device_transition_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
)

ios_sim_arm64_transition = transition(
    implementation = _ios_sim_arm64_transition_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
)

ios_sim_x64_transition = transition(
    implementation = _ios_sim_x64_transition_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
)
