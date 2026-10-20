"""Test extension instantiating a hosted lock spoke with a malformed checksum.

A sha256 that is not 64 lowercase hex digits pins nothing, so the spoke
must fail with the checksum it got instead of handing it to the downloader.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "pub_lock_package")

def _red_impl(ctx):
    pub_lock_package(
        name = "bad_spoke",
        package_name = "collection",
        version = "1.18.0",
        sha256 = "not-hex",
        base_url = "https://pub.dev",
        hub_name = "deps",
    )

red = module_extension(implementation = _red_impl)
