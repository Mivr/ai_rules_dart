"""Public import macro for prebuilt Apple frameworks.

`flutter_apple_xcframework_import` is the one way the rules import a
prebuilt `.xcframework` or plain `.framework`: the `rules_apple` import rules
on macOS and `flutter_darwin_xcframework_import` on the xtool backend. The
backend comes from the same settings `flutter_ios_app` and
`flutter_macos_app` read, so a user's vendored framework reaches the same
target shape as a binary pod or a SwiftPM binary target.

Usage:

    load("@rules_flutter//flutter:ios.bzl", "flutter_apple_xcframework_import")

    flutter_apple_xcframework_import(
        name = "tinykit",
        framework = "TinyKit.xcframework",
        linkage = "static",
    )
"""

load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import", "apple_static_framework_import", "apple_static_xcframework_import")
load(":flutter_apple_framework_modulemap.bzl", "apple_framework_modulemap_import")
load(":flutter_xtool_bundle.bzl", "flutter_darwin_xcframework_import")

visibility(["//flutter/..."])

_XCFRAMEWORK_SUFFIX = ".xcframework"
_FRAMEWORK_SUFFIX = ".framework"

def _shape_of(framework):
    """Return `"xcframework"`, `"framework"`, or `""` from the label string.

    The choice is made from the label's spelling only: resolving the target's
    files would make a load-time macro depend on analysis.

    Args:
        framework: The `framework` label, as a string or `Label`.

    Returns:
        The shape name, or an empty string when the label names neither.
    """
    text = str(framework)
    if text.endswith(_XCFRAMEWORK_SUFFIX):
        return "xcframework"
    if text.endswith(_FRAMEWORK_SUFFIX):
        return "framework"
    return ""

def _first_unrepresentable(alwayslink, sdk_frameworks, weak_sdk_frameworks, sdk_dylibs):
    """Name the first argument a backend cannot carry, or return `""`.

    Args:
        alwayslink: Whether the import asked to link every object file.
        sdk_frameworks: SDK frameworks the import asked to link.
        weak_sdk_frameworks: SDK frameworks the import asked to link weakly.
        sdk_dylibs: SDK dylibs the import asked to link.

    Returns:
        The offending attribute name, in declaration order, or `""`.
    """
    if alwayslink:
        return "alwayslink"
    if sdk_frameworks:
        return "sdk_frameworks"
    if weak_sdk_frameworks:
        return "weak_sdk_frameworks"
    if sdk_dylibs:
        return "sdk_dylibs"
    return ""

def _shape_error(framework):
    """The analysis error for a label that names neither framework shape.

    Args:
        framework: The offending `framework` label.

    Returns:
        The message text.
    """
    return 'flutter_apple_xcframework_import: "framework" must name one .xcframework or .framework directory, got "%s".' % str(framework)

def _linkage_error(linkage):
    """The analysis error for a linkage other than `"static"` or `"dynamic"`.

    Args:
        linkage: The offending `linkage` value.

    Returns:
        The message text.
    """
    return 'flutter_apple_xcframework_import: "linkage" must be "static" or "dynamic", got "%s".' % linkage

def _dynamic_error(attribute):
    """The analysis error for an argument the dynamic imports cannot carry.

    Args:
        attribute: The offending attribute name.

    Returns:
        The message text.
    """
    return (
        'flutter_apple_xcframework_import: linkage "dynamic" cannot carry "%s". ' +
        "The rules_apple dynamic imports take neither alwayslink nor an SDK framework " +
        'or dylib list; use linkage = "static", or link them from the target that ' +
        "depends on this one."
    ) % attribute

def _xtool_error(attribute):
    """The analysis error for an argument the xtool backend cannot carry.

    Args:
        attribute: The offending attribute name.

    Returns:
        The message text.
    """
    return (
        "flutter_apple_xcframework_import: the xtool backend links prebuilt frameworks " +
        'with -F/-framework and cannot carry "%s". Build with backend = "rules_apple" ' +
        "on macOS, or drop the argument."
    ) % attribute

def _invalid_impl(ctx):
    fail(ctx.attr.message)

_flutter_apple_xcframework_import_invalid = rule(
    implementation = _invalid_impl,
    attrs = {
        "message": attr.string(
            mandatory = True,
            doc = "The analysis error this target reports.",
        ),
    },
    doc = "Reports a `flutter_apple_xcframework_import` argument error at analysis " +
          "time, so an invalid call is an analysis failure rather than a load failure.",
)

def _emit_error(name, message):
    """Declare the target that fails analysis with `message`.

    Tagged `manual` so a `//...` wildcard does not expand a target whose only
    purpose is the analysis failure an explicit test asks for.

    Args:
        name: Name of the target that fails analysis with `message`.
        message: The exact analysis error.
    """
    _flutter_apple_xcframework_import_invalid(
        name = name,
        message = message,
        tags = ["manual"],
    )

def _backend_select(rules_apple, xtool):
    """Select the target for the active Apple backend.

    Both Darwin xtool settings select the xtool target so an iOS app and a
    macOS app with `backend = "xtool"` agree. Anything else, including an
    unconstrained host build, takes the `rules_apple` target, matching the
    engine imports in `ios_app.bzl` and `macos_app.bzl`.

    Args:
        rules_apple: Label of the `rules_apple` branch target.
        xtool: Label of the xtool branch target.

    Returns:
        A `select()` expression over the two backend settings.
    """
    return select({
        Label("//flutter/settings:ios_xtool_backend"): xtool,
        Label("//flutter/settings:macos_xtool_backend"): xtool,
        "//conditions:default": rules_apple,
    })

def _emit_rules_apple_branch(spec):
    """Declare the `rules_apple` import target for one shape and linkage.

    Args:
        spec: The `struct` the public macro builds for the call.
    """
    if spec.linkage == "dynamic":
        offending = _first_unrepresentable(
            spec.alwayslink,
            spec.sdk_frameworks,
            spec.weak_sdk_frameworks,
            spec.sdk_dylibs,
        )
        if offending:
            _emit_error(spec.rules_apple_name, _dynamic_error(offending))
            return

    raw = "%s__raw_import" % spec.rules_apple_name
    if spec.shape == "xcframework":
        if spec.linkage == "static":
            apple_static_xcframework_import(
                name = raw,
                tags = ["manual"],
                alwayslink = spec.alwayslink,
                sdk_dylibs = spec.sdk_dylibs,
                sdk_frameworks = spec.sdk_frameworks,
                weak_sdk_frameworks = spec.weak_sdk_frameworks,
                xcframework_imports = [spec.framework],
            )
        else:
            apple_dynamic_xcframework_import(
                name = raw,
                tags = ["manual"],
                xcframework_imports = [spec.framework],
            )
    elif spec.linkage == "static":
        apple_static_framework_import(
            name = raw,
            tags = ["manual"],
            alwayslink = spec.alwayslink,
            framework_imports = [spec.framework],
            sdk_dylibs = spec.sdk_dylibs,
            sdk_frameworks = spec.sdk_frameworks,
            weak_sdk_frameworks = spec.weak_sdk_frameworks,
        )
    else:
        apple_dynamic_framework_import(
            name = raw,
            tags = ["manual"],
            framework_imports = [spec.framework],
        )
    apple_framework_modulemap_import(
        name = spec.rules_apple_name,
        dep = ":" + raw,
        tags = ["manual"],
        visibility = ["//visibility:private"],
    )

def _emit_xtool_branch(spec):
    """Declare the xtool import target for any shape and linkage.

    Args:
        spec: The `struct` the public macro builds for the call.
    """
    offending = _first_unrepresentable(
        spec.alwayslink,
        spec.sdk_frameworks,
        spec.weak_sdk_frameworks,
        spec.sdk_dylibs,
    )
    if offending:
        _emit_error(spec.xtool_name, _xtool_error(offending))
        return

    flutter_darwin_xcframework_import(
        name = spec.xtool_name,
        tags = ["manual"],
        is_dynamic = spec.linkage == "dynamic",
        xcframework_imports = [spec.framework],
    )

def flutter_apple_xcframework_import(
        name,
        framework,
        linkage = "static",
        alwayslink = False,
        sdk_frameworks = [],
        weak_sdk_frameworks = [],
        sdk_dylibs = []):
    """Import one prebuilt `.xcframework` or plain `.framework`.

    The backend follows `@rules_flutter//flutter/settings:apple_backend`.
    `rules_apple` picks the static or dynamic xcframework or framework import
    rule from the label's shape and `linkage`; xtool always uses
    `flutter_darwin_xcframework_import` and maps `linkage` to `is_dynamic`.
    The macro works for both iOS and macOS.

    Args:
        name: Name of the target that re-exports the imported framework.
        framework: Label whose files are the one `.xcframework` or `.framework`
            directory to import.
        linkage: `"static"` (default) or `"dynamic"`.
        alwayslink: Link every object file, for SDKs that need `-ObjC`
            (categories). Only a static `rules_apple` import can carry it.
        sdk_frameworks: SDK frameworks to link. Only a static `rules_apple`
            import can carry them.
        weak_sdk_frameworks: SDK frameworks to link weakly. Only a static
            `rules_apple` import can carry them.
        sdk_dylibs: SDK dylibs to link. Only a static `rules_apple` import can
            carry them.
    """
    shape = _shape_of(framework)
    if not shape:
        _emit_error(name, _shape_error(framework))
        return
    if linkage not in ("static", "dynamic"):
        _emit_error(name, _linkage_error(linkage))
        return

    spec = struct(
        shape = shape,
        framework = framework,
        linkage = linkage,
        alwayslink = alwayslink,
        sdk_frameworks = sdk_frameworks,
        weak_sdk_frameworks = weak_sdk_frameworks,
        sdk_dylibs = sdk_dylibs,
        rules_apple_name = "_%s__rules_apple" % name,
        xtool_name = "_%s__xtool" % name,
    )
    _emit_rules_apple_branch(spec)
    _emit_xtool_branch(spec)
    native.alias(
        name = name,
        actual = _backend_select(
            ":" + spec.rules_apple_name,
            ":" + spec.xtool_name,
        ),
        tags = ["manual"],
    )
