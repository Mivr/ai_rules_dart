"""Reads a rule's target platform from the platform constraint attributes."""

load("//flutter/private:common.bzl", "detect_target_platform")

visibility(["//flutter/..."])

def target_platform_from_constraints(ctx):
    """Reads the target platform constraints into a platform record.

    Args:
        ctx: The rule context, whose rule declares `PLATFORM_CONSTRAINT_ATTRS`.

    Returns:
        A struct with `target_platform` (the string `detect_target_platform`
        returns) and the `is_ios` / `is_macos` flags AOT output selection needs.
    """
    constraints = struct(
        is_macos = ctx.target_platform_has_constraint(
            ctx.attr._macos_constraint[platform_common.ConstraintValueInfo],
        ),
        is_ios = ctx.target_platform_has_constraint(
            ctx.attr._ios_constraint[platform_common.ConstraintValueInfo],
        ),
        is_linux = ctx.target_platform_has_constraint(
            ctx.attr._linux_constraint[platform_common.ConstraintValueInfo],
        ),
        is_windows = ctx.target_platform_has_constraint(
            ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
        ),
        is_android = ctx.target_platform_has_constraint(
            ctx.attr._android_constraint[platform_common.ConstraintValueInfo],
        ),
    )
    return struct(
        target_platform = detect_target_platform(
            constraints.is_ios,
            constraints.is_macos,
            constraints.is_linux,
            constraints.is_windows,
            constraints.is_android,
        ),
        is_ios = constraints.is_ios,
        is_macos = constraints.is_macos,
    )
