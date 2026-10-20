"""Test extension instantiating a hosted lock spoke with a blank checksum.

Whitespace-only sha256 values must fail like missing ones: trimming is the
check, so padding a checksum with spaces cannot smuggle an unpinned fetch
past the spoke.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "pub_lock_package")

def _red_impl(ctx):
    pub_lock_package(
        name = "bad_spoke",
        package_name = "collection",
        version = "1.18.0",
        sha256 = "   ",
        base_url = "https://pub.dev",
        hub_name = "deps",
    )

red = module_extension(implementation = _red_impl)
