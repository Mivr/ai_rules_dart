"""Test extension instantiating `pub_package` without a checksum.

The repository rule must refuse to fetch before any download: an explicit
`pub.package()` without a sha256 has no pinned bytes, so the fetch site
fails the build instead of downloading unverified.
"""

# buildifier: disable=bzl-visibility
load("@rules_dart//dart/pub/private:pub_repository.bzl", "pub_package")

def _red_impl(ctx):
    pub_package(
        name = "bad_package",
        package_name = "collection",
        version = "1.18.0",
        sha256 = "",
        deps = [],
    )

red = module_extension(implementation = _red_impl)
