"""Applies the public aspects to one corpus target.

A BUILD file cannot name an aspect directly: Bazel applies aspects through a
rule attribute (`attr.label(aspects = [...])`) or the command line. This
wrapper makes the two public aspects real attribute applications, so the
corpus' aspect fixtures are analysed like any other target.
"""

load("//flutter:dev_files.bzl", "flutter_dev_files")
load("//flutter:native_hot_patch.bzl", "flutter_native_hot_patch_aspect")

visibility(["//flutter/tests/..."])

def _corpus_aspects_impl(ctx):
    """Returns the dep's files, the aspects having run on their edges."""
    return [DefaultInfo(files = ctx.attr.dep[DefaultInfo].files)]

_corpus_aspects = rule(
    implementation = _corpus_aspects_impl,
    attrs = {
        "dep": attr.label(
            aspects = [flutter_dev_files, flutter_native_hot_patch_aspect],
            mandatory = True,
        ),
    },
    doc = "Applies both public aspects to `dep`.",
)

def corpus_aspects(name, aspects, dep):
    """Instantiates the aspect probe, checking both public aspects are named.

    Args:
        name: Target name.
        aspects: The two public aspect objects, in any order.
        dep: The target both aspects are applied to.
    """
    if len(aspects) != 2:
        fail("corpus_aspects expects both public aspects, got %d" % len(aspects))
    _corpus_aspects(name = name, dep = dep)
