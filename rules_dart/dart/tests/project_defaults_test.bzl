"""Analysis tests of what the macros of `//dart:defs.bzl` default for a project's targets."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_AttrsInfo = provider(
    doc = "The attributes the macro passed to the rule.",
    fields = ["language_version", "package_name", "identity_from_pubspec", "pubspec", "data"],
)

def _attrs_aspect_impl(_target, ctx):
    attr = ctx.rule.attr
    pubspec = getattr(attr, "pubspec", None)
    return [_AttrsInfo(
        language_version = attr.language_version,
        package_name = attr.package_name,
        identity_from_pubspec = getattr(attr, "identity_from_pubspec", None),
        pubspec = str(pubspec.label) if pubspec else None,
        data = [str(d.label) for d in getattr(attr, "data", [])],
    )]

_attrs_aspect = aspect(implementation = _attrs_aspect_impl)

def _project_defaults_test_impl(ctx):
    env = analysistest.begin(ctx)
    got = analysistest.target_under_test(env)[_AttrsInfo]
    asserts.equals(env, ctx.attr.language_version, got.language_version, "language_version")
    asserts.equals(env, ctx.attr.package_name, got.package_name, "package_name")
    if ctx.attr.identity_from_pubspec != "":
        asserts.equals(env, ctx.attr.identity_from_pubspec == "True", got.identity_from_pubspec, "identity_from_pubspec")
    asserts.equals(env, ctx.attr.pubspec or None, got.pubspec, "pubspec")
    asserts.equals(env, sorted(ctx.attr.data), sorted(got.data), "data")
    return analysistest.end(env)

# What a target of the fixture project passes to its rule.
project_defaults_test = analysistest.make(
    _project_defaults_test_impl,
    attrs = {
        "language_version": attr.string(),
        "package_name": attr.string(),
        "identity_from_pubspec": attr.string(doc = "`True`, `False`, or empty for a rule without the attribute."),
        "pubspec": attr.string(),
        "data": attr.string_list(),
    },
    extra_target_under_test_aspects = [_attrs_aspect],
)

def _refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

# A target of the fixture project whose defaults contradict what it states
# elsewhere, and the error that says what to change.
project_defaults_refused_test = analysistest.make(
    _refused_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)
