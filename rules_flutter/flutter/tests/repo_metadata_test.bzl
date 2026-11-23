"""Unit tests for repo_metadata.bzl: only a download-mode repo is reproducible."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:repo_metadata.bzl", "download_mode_metadata")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _fake_ctx(attr):
    """A repository context that records the `reproducible` flag it was given."""
    return struct(
        attr = attr,
        repo_metadata = lambda reproducible: struct(reproducible = reproducible),
    )

def _empty_local_path_test_impl(ctx):
    env = unittest.begin(ctx)
    metadata = download_mode_metadata(_fake_ctx(struct(local_path = "")))
    asserts.true(env, metadata.reproducible)
    return unittest.end(env)

def _local_path_test_impl(ctx):
    env = unittest.begin(ctx)
    metadata = download_mode_metadata(_fake_ctx(struct(local_path = "x")))
    asserts.false(env, metadata.reproducible)
    return unittest.end(env)

def _missing_attr_test_impl(ctx):
    env = unittest.begin(ctx)
    metadata = download_mode_metadata(_fake_ctx(struct()))
    asserts.true(env, metadata.reproducible)
    return unittest.end(env)

_t0_test = unittest.make(_empty_local_path_test_impl)
_t1_test = unittest.make(_local_path_test_impl)
_t2_test = unittest.make(_missing_attr_test_impl)

def repo_metadata_test_suite(name):
    """Declares the repo_metadata unit tests.

    Args:
        name: The test suite name.
    """
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test)
