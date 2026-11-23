"""A hub target for a lock entry `pub.from_lock` cannot build.

An SDK package, or a path package whose directory has no BUILD file, keeps its
name in the hub so that a target depending on it fails with a message saying
why and what to do, instead of Bazel's "no such target".
"""

load("//dart:providers.bzl", "DartInfo")

# Loaded by the generated hub repositories.
visibility("public")

def _pub_unavailable_package_impl(ctx):
    fail(ctx.attr.message)

pub_unavailable_package = rule(
    implementation = _pub_unavailable_package_impl,
    doc = "Stands for a pub package of the lock that this hub cannot build; fails with `message` when used.",
    attrs = {"message": attr.string(mandatory = True)},
    provides = [DartInfo],
)
