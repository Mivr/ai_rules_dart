"""Unit tests for the hosted-archive guards in `flutter_pub_scan.bzl`.

A `flutter.pub` hosted spoke must scan its archive before trusting it to
the extractor: the header scan runs before `extract`, a refusal stops the
fetch before anything is extracted, and the symlink walk runs after
extraction. These tests pin that order with a mock repository context in
the same style as the overlay tests, driving the real
`fetch_hosted_archive` pipeline (including the real sha256 check and gzip
trim) with injected scan/walk fakes that log into the same event list as
the mock context. That a real refusal carries rules_dart's wording naming
the package and the entry is proven by the `e2e/pub_hosted_escape`
fixture, which greps each hostile fetch's message.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_scan.bzl", "fetch_hosted_archive")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_SHA256 = "16801f5b6333b3140ba8905d1de811cc718eb6bd0f567fdcfbc4b0929efce2f3"

_REFUSAL = "pub package \"evil\": hard-link \"lib/evil.dart\" points at \"../../outside.txt\""

def _make_mock_fetch_ctx(events, package_name = "evil"):
    """Constructs a fake repository_ctx logging into `events` in order.

    Args:
        events: The shared call log, appended to in order.
        package_name: Value for `ctx.attr.package_name`.

    Returns:
        The mock repository context.
    """

    def _download(sha256 = None, url = None, output = None):
        events.append("download:" + str(url) + "->" + str(output))
        return struct(sha256 = sha256)

    def _read(path, watch = None):
        events.append("read:" + str(path) + ":" + str(watch))
        return "archive-bytes"

    def _file(path, content, executable = False):
        events.append("file:" + str(path) + ":" + str(content) + ":" + str(executable))

    def _delete(path):
        events.append("delete:" + str(path))

    def _extract(archive):
        events.append("extract:" + str(archive))

    return struct(
        attr = struct(
            package_name = package_name,
            version = "1.0.0",
            sha256 = _SHA256,
            base_url = "file://fixtures",
        ),
        download = _download,
        read = _read,
        file = _file,
        delete = _delete,
        extract = _extract,
    )

def _make_scan_fake(events, refusal = ""):
    """A scan fake logging its arguments and answering `refusal`."""

    def _scan(_ctx, archive_path, package_name):
        events.append("scan:" + str(archive_path) + ":" + package_name)
        return refusal

    return _scan

def _make_walk_fake(events):
    """A walk fake logging the package it runs over."""

    def _walk(_ctx, package_name):
        events.append("walk:" + package_name)

    return _walk

_CLEAN_EVENTS = [
    "download:file://fixtures/packages/evil/versions/1.0.0.tar.gz->_archive.tar.gz",
    "read:_archive.tar.gz:no",
    "scan:_archive.tar.gz:evil",
    "extract:_archive.tar.gz",
    "delete:_archive.tar.gz",
    "walk:evil",
]

def _scan_runs_before_extract_test_impl(ctx):
    """The header scan runs after download and before extraction."""
    env = unittest.begin(ctx)

    events = []
    result = fetch_hosted_archive(
        _make_mock_fetch_ctx(events),
        _make_scan_fake(events),
        _make_walk_fake(events),
    )

    asserts.equals(env, "", result)
    asserts.equals(env, _CLEAN_EVENTS, events)

    return unittest.end(env)

scan_runs_before_extract_test = unittest.make(_scan_runs_before_extract_test_impl)

def _refusal_stops_before_extract_test_impl(ctx):
    """A refused archive returns the refusal with nothing extracted."""
    env = unittest.begin(ctx)

    events = []
    result = fetch_hosted_archive(
        _make_mock_fetch_ctx(events),
        _make_scan_fake(events, _REFUSAL),
        _make_walk_fake(events),
    )

    asserts.equals(env, _REFUSAL, result)
    asserts.true(env, "evil" in result and "lib/evil.dart" in result, result)
    asserts.equals(
        env,
        [
            "download:file://fixtures/packages/evil/versions/1.0.0.tar.gz->_archive.tar.gz",
            "read:_archive.tar.gz:no",
            "scan:_archive.tar.gz:evil",
        ],
        events,
    )

    return unittest.end(env)

refusal_stops_before_extract_test = unittest.make(_refusal_stops_before_extract_test_impl)

def _walk_runs_after_extraction_test_impl(ctx):
    """The symlink walk runs after extraction, over the extracted tree."""
    env = unittest.begin(ctx)

    events = []
    result = fetch_hosted_archive(
        _make_mock_fetch_ctx(events, package_name = "ok_clean"),
        _make_scan_fake(events),
        _make_walk_fake(events),
    )

    asserts.equals(env, "", result)
    asserts.true(env, events.index("extract:_archive.tar.gz") < events.index("walk:ok_clean"), events)
    asserts.true(env, events.index("scan:_archive.tar.gz:ok_clean") < events.index("extract:_archive.tar.gz"), events)

    return unittest.end(env)

walk_runs_after_extraction_test = unittest.make(_walk_runs_after_extraction_test_impl)

def flutter_pub_scan_test_suite(name):
    """Registers the hosted-archive guard tests."""
    small_unittest_suite(
        name,
        scan_runs_before_extract_test,
        refusal_stops_before_extract_test,
        walk_runs_after_extraction_test,
    )
