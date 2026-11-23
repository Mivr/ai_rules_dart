"""Unit tests for the `Package.resolved` reader and pin classifier."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:swiftpm_resolved.bzl",
    "check_swiftpm_config_present",
    "check_swiftpm_dicts",
    "classify_swiftpm_pin",
    "is_swiftpm_identity",
    "is_swiftpm_revision",
    "is_swiftpm_sha256",
    "pub_spoke_swiftpm_attrs",
    "read_swiftpm_checksums",
    "read_swiftpm_pins",
    "swiftpm_github_parts",
    "swiftpm_spoke_attrs",
    "swiftpm_spoke_name",
    "swiftpm_unpinned_errors",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_BIGINT_REV = "63feef7820abb1a8fb08587d7da56bb0b7db8751"
_BIGINT_SHA = "55fc8a63f655a09d9216f2c9bc062c508f98d4eca4b8ebefaf295a3ea4ac8f22"

_V3 = """{
  "pins" : [
    {
      "identity" : "bigint",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/attaswift/BigInt",
      "state" : {
        "revision" : "63feef7820abb1a8fb08587d7da56bb0b7db8751",
        "version" : "6.0.1"
      }
    }
  ],
  "version" : 3
}
"""

_V2 = """{
  "pins" : [
    {
      "identity" : "bigint",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/attaswift/BigInt.git",
      "state" : {
        "branch" : null,
        "revision" : "63feef7820abb1a8fb08587d7da56bb0b7db8751",
        "version" : null
      }
    }
  ],
  "version" : 2
}
"""

def _validators_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_swiftpm_identity("bigint"))
    asserts.true(env, is_swiftpm_identity("a.b_c-d9"))
    asserts.true(env, not is_swiftpm_identity(""))
    asserts.true(env, not is_swiftpm_identity("BigInt"))
    asserts.true(env, not is_swiftpm_identity("big int"))
    asserts.true(env, not is_swiftpm_identity("big/int"))
    asserts.true(env, is_swiftpm_sha256(_BIGINT_SHA))
    asserts.true(env, not is_swiftpm_sha256(_BIGINT_SHA.upper()))
    asserts.true(env, not is_swiftpm_sha256("abc"))
    asserts.true(env, not is_swiftpm_sha256(_BIGINT_SHA + "0"))
    asserts.true(env, is_swiftpm_revision(_BIGINT_REV))
    asserts.true(env, is_swiftpm_revision(_BIGINT_REV.upper()))
    asserts.true(env, not is_swiftpm_revision("main"))
    asserts.equals(env, "deps__swiftpm-bigint", swiftpm_spoke_name("deps", "bigint"))
    return unittest.end(env)

def _location_parts_test_impl(ctx):
    env = unittest.begin(ctx)
    parts = swiftpm_github_parts("https://github.com/attaswift/BigInt")
    asserts.true(env, parts.ok)
    asserts.equals(env, "attaswift", parts.owner)
    asserts.equals(env, "BigInt", parts.repo)
    parts = swiftpm_github_parts("https://github.com/attaswift/BigInt.git")
    asserts.true(env, parts.ok)
    asserts.equals(env, "BigInt", parts.repo)
    parts = swiftpm_github_parts("https://GITHUB.COM/attaswift/BigInt")
    asserts.true(env, parts.ok)
    asserts.equals(env, "attaswift", parts.owner)
    parts = swiftpm_github_parts("https://gitlab.com/some/group")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    parts = swiftpm_github_parts("git@github.com:attaswift/BigInt.git")
    asserts.true(env, parts.ok)
    asserts.equals(env, "attaswift", parts.owner)
    asserts.equals(env, "BigInt", parts.repo)
    parts = swiftpm_github_parts("git@github.com:attaswift/BigInt")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "ssh", parts.reason)
    parts = swiftpm_github_parts("git@gitlab.com:attaswift/BigInt.git")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    parts = swiftpm_github_parts("file:///tmp/BigInt")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    parts = swiftpm_github_parts("https://github.com/onlyowner")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    parts = swiftpm_github_parts("https://github.com/a/b/c")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    return unittest.end(env)

def _reads_v2_and_v3_test_impl(ctx):
    env = unittest.begin(ctx)
    for content in [_V2, _V3]:
        pins = read_swiftpm_pins(content, "//ios:Package.resolved")
        asserts.true(env, pins.ok)
        asserts.equals(env, "", pins.error)
        asserts.equals(env, 1, len(pins.pins))
        asserts.equals(env, "bigint", pins.pins[0].identity)
        asserts.equals(env, _BIGINT_REV, pins.pins[0].revision)
    return unittest.end(env)

def _refuses_v1_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = read_swiftpm_pins('{"object": {"pins": []}, "version": 1}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    asserts.true(env, "version 1" in pins.error)
    asserts.true(env, "//ios:Package.resolved" in pins.error)
    return unittest.end(env)

def _bad_json_names_the_file_test_impl(ctx):
    env = unittest.begin(ctx)
    for content in ["{not json", '{"pins": [}, "version": 3}', '{"pins": []}, trailing', ""]:
        pins = read_swiftpm_pins(content, "//ios:Package.resolved")
        asserts.true(env, not pins.ok)
        asserts.true(env, "//ios:Package.resolved" in pins.error)
    return unittest.end(env)

def _bad_pin_shapes_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = read_swiftpm_pins('{"pins": [], "version": 9}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    pins = read_swiftpm_pins('{"version": 3}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    pins = read_swiftpm_pins('{"pins": [{"identity": "BigInt", "kind": "remoteSourceControl", "location": "https://github.com/a/b", "state": {"revision": "' + _BIGINT_REV + '"}}], "version": 3}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    asserts.true(env, "identity" in pins.error)
    return unittest.end(env)

def _unpinned_shapes_read_ok_test_impl(ctx):
    env = unittest.begin(ctx)

    # Missing or malformed kind, location and revision read fine: every pin
    # gets its repository, and the spoke fetch refuses it before any download.
    cases = [
        '{"identity": "bigint", "location": "https://github.com/a/b", "state": {"revision": "' + _BIGINT_REV + '"}}',
        '{"identity": "bigint", "kind": "remoteSourceControl", "state": {"revision": "' + _BIGINT_REV + '"}}',
        '{"identity": "bigint", "kind": "remoteSourceControl", "location": "https://github.com/a/b", "state": {}}',
        '{"identity": "bigint", "kind": "remoteSourceControl", "location": "https://github.com/a/b", "state": {"revision": "main"}}',
        '{"identity": "bigint", "kind": "remoteSourceControl", "location": "https://github.com/a/b", "state": {"revision": null}}',
        '{"identity": "bigint", "kind": "remoteSourceControl", "location": "https://github.com/a/b"}',
        '{"identity": "bigint", "kind": 7, "location": "https://github.com/a/b", "state": {"revision": "' + _BIGINT_REV + '"}}',
    ]
    for raw in cases:
        pins = read_swiftpm_pins('{"pins": [' + raw + '], "version": 3}', "//ios:Package.resolved")
        asserts.true(env, pins.ok)
        asserts.equals(env, 1, len(pins.pins))
        asserts.equals(env, "bigint", pins.pins[0].identity)
    return unittest.end(env)

def _unpinned_shapes_fail_at_fetch_test_impl(ctx):
    env = unittest.begin(ctx)
    no_kind = read_swiftpm_pins('{"pins": [{"identity": "bigint", "location": "https://github.com/a/b", "state": {"revision": "' + _BIGINT_REV + '"}}], "version": 3}', "//ios:Package.resolved").pins[0]
    classified = classify_swiftpm_pin(no_kind, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "remoteSourceControl" in classified.error)
    asserts.true(env, "deps__swiftpm-bigint" in classified.error)
    asserts.true(env, "//ios:Package.resolved" in classified.error)
    no_location = read_swiftpm_pins('{"pins": [{"identity": "bigint", "kind": "remoteSourceControl", "state": {"revision": "' + _BIGINT_REV + '"}}], "version": 3}', "//ios:Package.resolved").pins[0]
    classified = classify_swiftpm_pin(no_location, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "not a GitHub repository" in classified.error)
    no_revision = read_swiftpm_pins('{"pins": [{"identity": "bigint", "kind": "remoteSourceControl", "location": "https://github.com/a/b", "state": {}}], "version": 3}', "//ios:Package.resolved").pins[0]
    classified = classify_swiftpm_pin(no_revision, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "revision" in classified.error)
    asserts.true(env, "//ios:Package.resolved" in classified.error)
    bad_revision = struct(identity = "bigint", kind = "remoteSourceControl", location = "https://github.com/a/b", revision = "main")
    classified = classify_swiftpm_pin(bad_revision, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "revision" in classified.error)
    return unittest.end(env)

def _classify_pinned_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = read_swiftpm_pins(_V3, "//ios:Package.resolved")
    classified = classify_swiftpm_pin(pins.pins[0], {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, classified.ok)
    asserts.equals(env, "https://github.com/attaswift/BigInt/archive/" + _BIGINT_REV + ".tar.gz", classified.url)
    asserts.equals(env, _BIGINT_SHA, classified.sha256)
    return unittest.end(env)

def _classify_unpinned_names_the_fix_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = read_swiftpm_pins(_V3, "//ios:Package.resolved")
    classified = classify_swiftpm_pin(pins.pins[0], {}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "deps__swiftpm-bigint" in classified.error)
    asserts.true(env, "bigint" in classified.error)
    asserts.true(env, "//ios:Package.resolved" in classified.error)
    asserts.true(env, "has no `swift_package_sha256[" in classified.error)
    asserts.true(env, "https://github.com/attaswift/BigInt/archive/" + _BIGINT_REV + ".tar.gz" in classified.error)
    return unittest.end(env)

def _classify_bad_revision_and_location_test_impl(ctx):
    env = unittest.begin(ctx)
    good = read_swiftpm_pins(_V3, "//ios:Package.resolved").pins[0]
    bad_rev = struct(identity = good.identity, kind = good.kind, location = good.location, revision = "main")
    classified = classify_swiftpm_pin(bad_rev, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "revision" in classified.error)
    bad_sha = classify_swiftpm_pin(good, {"bigint": "xyz"}, "deps", "//ios:Package.resolved")
    asserts.true(env, not bad_sha.ok)
    asserts.true(env, "invalid" in bad_sha.error)
    bad_kind = struct(identity = good.identity, kind = "localSourceControl", location = good.location, revision = _BIGINT_REV)
    classified = classify_swiftpm_pin(bad_kind, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "remoteSourceControl" in classified.error)
    bad_loc = struct(identity = "bigint", kind = "remoteSourceControl", location = "git@github.com:attaswift/BigInt", revision = _BIGINT_REV)
    classified = classify_swiftpm_pin(bad_loc, {}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, ".git" in classified.error)
    file_loc = struct(identity = "bigint", kind = "remoteSourceControl", location = "https://gitlab.com/attaswift/BigInt", revision = _BIGINT_REV)
    classified = classify_swiftpm_pin(file_loc, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "not a GitHub repository" in classified.error)
    return unittest.end(env)

def _config_checks_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", check_swiftpm_config_present(None, {}, {}))
    asserts.true(env, "swift_package_sha256" in check_swiftpm_config_present(None, {"a": "b"}, {}))
    asserts.true(env, "swift_package_build_files" in check_swiftpm_config_present(None, {}, {"a": "b"}))
    asserts.equals(env, "", check_swiftpm_config_present("//ios:Package.resolved", {}, {}))

    # `swift_package_build_files` values are Labels Bazel resolved in the
    # module that wrote the tag, so only the keys are checked here.
    asserts.equals(env, "", check_swiftpm_dicts({"bigint": _BIGINT_SHA}, {"bigint": "//:BigInt.BUILD"}, ["bigint"], "//ios:Package.resolved"))
    asserts.true(env, "pinned nowhere" in check_swiftpm_dicts({"other": _BIGINT_SHA}, {}, ["bigint"], "//ios:Package.resolved"))
    asserts.true(env, "pinned nowhere" in check_swiftpm_dicts({}, {"other": "//:B"}, ["bigint"], "//ios:Package.resolved"))
    asserts.true(env, "64 lowercase hex" in check_swiftpm_dicts({"bigint": "xyz"}, {}, ["bigint"], "//ios:Package.resolved"))
    return unittest.end(env)

def _checksum_table_test_impl(ctx):
    env = unittest.begin(ctx)
    label = "//:swift_package_sha256.json"
    table = read_swiftpm_checksums('{"bigint": "' + _BIGINT_SHA + '"}', label)
    asserts.true(env, table.ok)
    asserts.equals(env, "", table.error)
    asserts.equals(env, _BIGINT_SHA, table.sha256_by_identity["bigint"])

    bad_json = read_swiftpm_checksums("{not json", label)
    asserts.true(env, not bad_json.ok)
    asserts.true(env, label in bad_json.error)
    bad_digest = read_swiftpm_checksums('{"bigint": "xyz"}', label)
    asserts.true(env, not bad_digest.ok)
    asserts.true(env, "invalid checksum" in bad_digest.error)
    asserts.true(env, label in bad_digest.error)
    return unittest.end(env)

def _unpinned_errors_name_the_missing_checksum_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = read_swiftpm_pins(_V3, "//ios:Package.resolved")
    unpinned = swiftpm_unpinned_errors(pins.pins, {}, "deps_unpinned", "//ios:Package.resolved")
    asserts.true(env, "bigint" in unpinned)
    asserts.true(env, 'has no `swift_package_sha256["bigint"]` entry' in unpinned["bigint"])
    pinned = swiftpm_unpinned_errors(pins.pins, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.equals(env, {}, pinned)
    return unittest.end(env)

def _pub_spoke_attrs_test_impl(ctx):
    env = unittest.begin(ctx)
    attrs = pub_spoke_swiftpm_attrs(struct(lock = "//:pubspec.lock", name = "rules_flutter", swift_package_resolved = "//:Package.resolved"))
    asserts.equals(env, "//:Package.resolved", str(attrs.package_resolved))
    asserts.equals(env, "@rules_flutter//:swift_package_sha256.json", str(attrs.package_sha256))
    asserts.equals(env, ["package_resolved", "package_sha256"], dir(attrs))
    asserts.true(env, not hasattr(attrs, "swift_pinned_identities"))
    asserts.true(env, not hasattr(attrs, "swift_unpinned_errors"))
    asserts.true(env, not hasattr(attrs, "swift_package_sha256"))
    attrs = pub_spoke_swiftpm_attrs(struct(lock = "//:pubspec.lock", name = "rules_flutter", swift_package_resolved = None))
    asserts.equals(env, None, attrs.package_resolved)
    asserts.equals(env, None, attrs.package_sha256)
    return unittest.end(env)

def _pub_spoke_attrs_ignore_pin_and_checksum_state_test_impl(ctx):
    env = unittest.begin(ctx)

    # A pin or a checksum lives only in the hub's files, never in a pub
    # spoke's attributes: both tags produce the same constant labels, so a
    # pure-Dart spoke keeps its marker when either file changes.
    first = pub_spoke_swiftpm_attrs(struct(
        lock = "//:pubspec.lock",
        name = "rules_flutter",
        swift_package_resolved = "//:Package.resolved",
        swift_package_sha256 = {"bigint": _BIGINT_SHA},
        swift_package_build_files = {"bigint": "//:BigInt.BUILD"},
    ))
    second = pub_spoke_swiftpm_attrs(struct(
        lock = "//:pubspec.lock",
        name = "rules_flutter",
        swift_package_resolved = "//:Package.resolved",
        swift_package_sha256 = {},
        swift_package_build_files = {},
    ))
    asserts.equals(env, first, second)
    asserts.equals(env, ["package_resolved", "package_sha256"], dir(first))
    asserts.equals(env, "@rules_flutter//:swift_package_sha256.json", str(first.package_sha256))
    return unittest.end(env)

def _swiftpm_spoke_attrs_test_impl(ctx):
    env = unittest.begin(ctx)
    pin = struct(identity = "bigint")
    classified = struct(url = "https://example.com/bigint.tar.gz", sha256 = _BIGINT_SHA, error = "")
    attrs = swiftpm_spoke_attrs("deps", pin, classified, None)
    asserts.equals(env, "deps__swiftpm-bigint", attrs.name)
    asserts.equals(env, "bigint", attrs.identity)
    asserts.equals(env, "deps", attrs.hub_name)
    asserts.equals(env, classified.url, attrs.archive_url)
    asserts.equals(env, _BIGINT_SHA, attrs.sha256)
    asserts.equals(env, "", attrs.unpinned_error)
    asserts.equals(env, None, attrs.build_file)

    # Another pin added to the hub cannot reach this spoke: the arguments
    # are a function of this pin alone, never of the hub's pin list.
    same = swiftpm_spoke_attrs("deps", pin, classified, None)
    asserts.equals(env, attrs, same)
    asserts.true(env, not hasattr(attrs, "pin_identities"))
    return unittest.end(env)

_validators_test = unittest.make(_validators_test_impl)
_location_parts_test = unittest.make(_location_parts_test_impl)
_reads_v2_and_v3_test = unittest.make(_reads_v2_and_v3_test_impl)
_refuses_v1_test = unittest.make(_refuses_v1_test_impl)
_bad_json_names_the_file_test = unittest.make(_bad_json_names_the_file_test_impl)
_bad_pin_shapes_test = unittest.make(_bad_pin_shapes_test_impl)
_unpinned_shapes_read_ok_test = unittest.make(_unpinned_shapes_read_ok_test_impl)
_unpinned_shapes_fail_at_fetch_test = unittest.make(_unpinned_shapes_fail_at_fetch_test_impl)
_classify_pinned_test = unittest.make(_classify_pinned_test_impl)
_classify_unpinned_names_the_fix_test = unittest.make(_classify_unpinned_names_the_fix_test_impl)
_classify_bad_revision_and_location_test = unittest.make(_classify_bad_revision_and_location_test_impl)
_config_checks_test = unittest.make(_config_checks_test_impl)
_checksum_table_test = unittest.make(_checksum_table_test_impl)
_unpinned_errors_name_the_missing_checksum_test = unittest.make(_unpinned_errors_name_the_missing_checksum_test_impl)
_pub_spoke_attrs_test = unittest.make(_pub_spoke_attrs_test_impl)
_pub_spoke_attrs_ignore_pin_and_checksum_state_test = unittest.make(_pub_spoke_attrs_ignore_pin_and_checksum_state_test_impl)
_swiftpm_spoke_attrs_test = unittest.make(_swiftpm_spoke_attrs_test_impl)

def swiftpm_resolved_test_suite(name):
    """Registers the `Package.resolved` reader unit tests."""
    small_unittest_suite(
        name + "_unit",
        _validators_test,
        _location_parts_test,
        _reads_v2_and_v3_test,
        _refuses_v1_test,
        _bad_json_names_the_file_test,
        _bad_pin_shapes_test,
        _unpinned_shapes_read_ok_test,
        _unpinned_shapes_fail_at_fetch_test,
        _classify_pinned_test,
        _classify_unpinned_names_the_fix_test,
        _classify_bad_revision_and_location_test,
        _config_checks_test,
        _checksum_table_test,
        _unpinned_errors_name_the_missing_checksum_test,
        _pub_spoke_attrs_test,
        _pub_spoke_attrs_ignore_pin_and_checksum_state_test,
        _swiftpm_spoke_attrs_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )
