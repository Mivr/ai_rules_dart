"""Test extension instantiating a git lock spoke with a moving ref.

A git source is pinned only by its full 40-hex commit SHA: a branch name
would track a moving ref, so the spoke must fail before cloning anything.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "pub_lock_git_package")

def _red_impl(ctx):
    pub_lock_git_package(
        name = "bad_git",
        package_name = "evil_pkg",
        version = "1.0.0",
        url = "file:///nonexistent-red-path",
        resolved_ref = "main",
        path = ".",
        hub_name = "deps",
    )

red = module_extension(implementation = _red_impl)
