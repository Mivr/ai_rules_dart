"""A stand-in for `flutter_android_app` of a pin's `defs.bzl`, for analysis tests.

`flutter_integration_test(platform = "android")` builds the test app's Android side with the app
macro of the pinned Gradle model. This module has no pin of its own, so its analysis tests pass
this function instead: it declares `<name>_apk` with an empty file and the provider a runner reads.
"""

load("//flutter/private/android_model:rules.bzl", "RdfApkInfo")

def _stub_apk_impl(ctx):
    apk = ctx.actions.declare_file(ctx.label.name + ".apk")
    ctx.actions.write(apk, "")
    return [
        DefaultInfo(files = depset([apk])),
        RdfApkInfo(apk = apk, application_id = ctx.attr.application_id),
    ]

_stub_apk = rule(
    implementation = _stub_apk_impl,
    attrs = {
        "application": attr.label(doc = "The Dart program the app would carry."),
        "application_id": attr.string(mandatory = True),
    },
    doc = "An empty `.apk` with `RdfApkInfo`, standing in for the whole APK of an app built from a pin.",
)

def stub_android_app(name, application = None, variant = "debug", abis = None, visibility = None, **_kwargs):
    """Declares `<name>_apk` as `flutter_android_app` of a pin would, without building anything.

    Args:
        name: The app's name.
        application: The Dart program.
        variant: The app variant; part of the stub's application id so a test can read it back.
        abis: Unused.
        visibility: Visibility of the stub.
        **_kwargs: Other arguments of the real macro, unused.

    Returns:
        A struct with `apk` and `application_id`, as the real macro returns.
    """
    _ = abis
    application_id = "com.example.stub." + variant
    _stub_apk(
        name = name + "_apk",
        application = application,
        application_id = application_id,
        tags = ["manual"],
        visibility = visibility,
    )
    return struct(apk = ":" + name + "_apk", application_id = application_id)
