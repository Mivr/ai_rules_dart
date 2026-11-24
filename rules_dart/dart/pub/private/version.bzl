"""Semantic version parsing and comparison for pub packages.

The implementation lives in the leaf `//dart/private:versions.bzl`, which every
layer may load; this module keeps the pub-side name.
"""

load("//dart/private:versions.bzl", _parse_semver = "parse_semver", _semver_gt = "semver_gt")

visibility(["//dart/..."])

parse_semver = _parse_semver
semver_gt = _semver_gt
