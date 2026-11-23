"""Builds each example extension twice: signed ad hoc and signed by a team."""

load("@rules_apple//apple:macos.bzl", "macos_extension")

visibility("private")

def example_macos_extension(name, **kwargs):
    """A `macos_extension` as `name` and its team-signed twin as `name + "_team"`.

    `name` has no profile, so rules_apple signs it ad hoc, with the `group.`
    App Group. `name_team` is signed with `//device:profile` and carries the
    team-prefixed group from `//device`. rules_apple signs each extension in
    its own target, so the app's profile does not reach it: an extension
    without its own is signed ad hoc, has no team, and loses its App Group.

    Args:
        name: The ad hoc target's name.
        **kwargs: Forwarded to both `macos_extension` targets.
    """
    common = dict(
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:macos"],
        # rules_apple's default is no version at all, and an extension's
        # version must match the app's: 1.0, flutter_macos_app's default.
        version = "//:app_version",
        visibility = ["//:__pkg__"],
    )
    common.update(kwargs)
    macos_extension(
        name = name,
        entitlements = ":extension_entitlements",
        **common
    )
    macos_extension(
        name = name + "_team",
        # The same bundle name, so the team app's Contents/PlugIns/ matches.
        bundle_name = name,
        entitlements = ":extension_entitlements_team",
        provisioning_profile = "//device:profile",
        **common
    )
