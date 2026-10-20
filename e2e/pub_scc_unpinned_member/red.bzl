"""Test extension instantiating a merged cycle with an unpinned member.

Each member of a merged cycle fetches its own bytes, so each member carries
its own pin: a hosted member without a sha256 must fail the merged
repository before it downloads anything.
"""

load("@rules_dart//dart/pub:pub_lock_scc.bzl", "pub_lock_scc_package")

def _red_impl(ctx):
    pub_lock_scc_package(
        name = "bad_scc",
        repo_name = "bad_scc",
        members_json = "[{\"source\": \"hosted\", \"name\": \"collection\", \"version\": \"1.18.0\", \"sha256\": \"\", \"url\": \"https://pub.dev\", \"code_assets\": []}]",
        hub_name = "deps",
    )

red = module_extension(implementation = _red_impl)
