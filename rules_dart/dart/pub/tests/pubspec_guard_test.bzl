"""Unit tests for the pubspec guard: the SDK-constraint and `environment` refusals.

Every fetch (`pub_lock_package` / `pub_lock_git_package` spokes, the
`pub_lock_scc_package` merge, `pub_package`) fails a pubspec whose present,
non-null `environment.sdk` is not a version constraint pub reads, or whose
`environment` pub's `_parseEnvironment` refuses. The production check is
`pubspec_environment_error` over the decoded pubspec, which the
`_pubspec_probe` rule below runs as the spokes do, so the `expect_failure`
analysis tests exercise the fetch-level refusal path. Each pubspec is the
mapping `yaml_to_json` decodes: a bare YAML number reads as its text.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//dart/pub:yaml.bzl",
    "pubspec_environment_error",
    "pubspec_sdk_constraint",
)
load("//dart/pub/private:language_version.bzl", "derive_language_version")
load("//dart/pub/private:yaml_sdk_constraint.bzl", "is_valid_sdk_constraint")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

visibility(["//dart/..."])

_LABEL = "probe_pkg/pubspec.yaml"

def _env_pubspec(environment):
    """Returns a decoded `probe_pkg` pubspec with the given `environment` value."""
    return {"name": "probe_pkg", "environment": environment}

def _sdk_pubspec(sdk):
    """Returns a decoded `probe_pkg` pubspec whose `environment.sdk` is `sdk`."""
    return _env_pubspec({"sdk": sdk})

# Strings pub_semver 2.2.0 `VersionConstraint.parse` refuses: empty text,
# `*`, bare words, partial versions (with and without `^`), `=` versions,
# unions, a `v` prefix, a fourth part, empty or underscore identifiers,
# int64-overflowing numbers, operators without versions, and text past a
# `^` version.
_REFUSED_STRINGS = [
    "",
    "*",
    "foo",
    "3",
    "3.5",
    "^3",
    "^3.5",
    "=3.0.0",
    "^3.0.0 || ^2.0.0",
    ">=2.12.0 <3.0.0 || >=3.5.0 <4.0.0",
    "v3.0.0",
    "1.2.3.4",
    "^3.0.0 foo",
    "3.0.0-",
    "1.2.3-a..b",
    "1.2.3-a_b",
    "99999999999999999999999.0.0",
    ">=",
]

# (constraint string, base language version) pairs pub reads, with the
# version the fetch derives for each.
_ACCEPTED_CASES = [
    ("^3.5.0", "3.5"),
    ("^3.0.0", "3.0"),
    ("^2.12.0", "2.12"),
    (">=2.12.0 <4.0.0", "2.12"),
    (">=2.12.0", "2.12"),
    (">2.12.0", "2.12"),
    (">= 2.12.0 <4.0.0", "2.12"),
    ("  ^3.0.0  ", "3.0"),
    ("2.12.0", "2.12"),
    ("^3.0.0-dev.1", "3.0"),
    ("^3.0.0+1", "3.0"),
    ("<4.0.0", "2.7"),
    ("any", "2.7"),
]

# The 26 blanks Dart's `String.trim` removes, as the UTF-8 byte sequences the
# decoded text carries them in (see `yaml_sdk_constraint.bzl`). The ASCII six
# read on the base too; the other twenty fail every fetch there while pub
# accepts them. Oracles: package:pub_semver 2.2.0 `VersionConstraint.parse`.
_SDK_BLANKS = [
    " ",
    "\t",
    "\n",
    "\v",
    "\f",
    "\r",
    "\302\205",
    "\302\240",
    "\341\232\200",
    "\342\200\200",
    "\342\200\201",
    "\342\200\202",
    "\342\200\203",
    "\342\200\204",
    "\342\200\205",
    "\342\200\206",
    "\342\200\207",
    "\342\200\210",
    "\342\200\211",
    "\342\200\212",
    "\342\200\250",
    "\342\200\251",
    "\342\200\257",
    "\342\201\237",
    "\343\200\200",
    "\357\273\277",
]

# Characters Dart does not trim (U+200B, U+180E, U+2060): pub refuses them
# wherever they stand.
_SDK_NON_BLANKS = [
    "\342\200\213",
    "\341\240\216",
    "\342\201\240",
]

# Caret constraints refused where `nextBreaking` overflows the int64 range.
_CARET_REFUSED = [
    "^9223372036854775807.0.0",
    "^0.9223372036854775807.0",
    "^9223372036854775807.0.0-alpha",
    "^9223372036854775807.0.0+build",
    "^9223372036854775807.0.0-alpha+build",
    "^0.9223372036854775807.0-alpha",
    "^0.9223372036854775807.0+build",
    "^0.9223372036854775807.0-alpha+build",
    "^0009223372036854775807.0.0",
    "^0.0009223372036854775807.0",
]

# (constraint, language version) pairs at the overflow edge that pub reads:
# one below the edge for each incremented component, every component pub
# does not increment, and `>=`, `<` and bare versions at the int64 maximum,
# which read as on the base.
_CARET_ACCEPTED = [
    ("^9223372036854775806.0.0", "9223372036854775806.0"),
    ("^9223372036854775806.0.0-alpha+build", "9223372036854775806.0"),
    ("^0.9223372036854775806.0", "0.9223372036854775806"),
    ("^0.9223372036854775806.0-pre+build", "0.9223372036854775806"),
    ("^0.0.9223372036854775807", "0.0"),
    ("^0.0.9223372036854775807-alpha+build", "0.0"),
    ("^1.9223372036854775807.0", "1.9223372036854775807"),
    ("^1.9223372036854775807.0+build", "1.9223372036854775807"),
    ("^00.01.02", "0.1"),
    (">=9223372036854775807.0.0", "9223372036854775807.0"),
    ("<9223372036854775807.0.0", "2.7"),
    ("9223372036854775807.0.0", "9223372036854775807.0"),
]

def _blanks_test_impl(ctx):
    env = unittest.begin(ctx)
    for blank in _SDK_BLANKS:
        for value, expected in [
            (blank + "^3.0.0" + blank, "3.0"),
            ("^" + blank + "3.0.0", "3.0"),
            ("^3.0.0" + blank, "3.0"),
            (blank + "2.12.0" + blank, "2.12"),
            (">=2.12.0" + blank + "<4.0.0", "2.12"),
            (">=" + blank + "2.12.0", "2.12"),
            ("<" + blank + "4.0.0", "2.7"),
        ]:
            asserts.true(env, is_valid_sdk_constraint(value), "blank reads: %r" % value)
            content = _sdk_pubspec(value)
            asserts.true(
                env,
                pubspec_environment_error(content, _LABEL) == None,
                "blank reads: %r" % value,
            )
            asserts.equals(
                env,
                expected,
                derive_language_version(pubspec_sdk_constraint(content)),
                "blank derives the ASCII twin's version: %r" % value,
            )
    return unittest.end(env)

def _non_blanks_test_impl(ctx):
    env = unittest.begin(ctx)
    for mark in _SDK_NON_BLANKS:
        for value in [
            mark + "^3.0.0",
            "^3.0.0" + mark,
            "^" + mark + "3.0.0",
            ">=2.12.0" + mark + "<4.0.0",
            ">=" + mark + "2.12.0",
        ]:
            asserts.false(env, is_valid_sdk_constraint(value), "non-blank is refused: %r" % value)
            content = _sdk_pubspec(value)
            asserts.true(
                env,
                pubspec_environment_error(content, _LABEL) != None,
                "non-blank is refused: %r" % value,
            )
    return unittest.end(env)

def _caret_edges_test_impl(ctx):
    env = unittest.begin(ctx)
    for value in _CARET_REFUSED:
        asserts.false(env, is_valid_sdk_constraint(value), "overflowing caret is refused: %r" % value)
        content = _sdk_pubspec(value)
        asserts.true(
            env,
            pubspec_environment_error(content, _LABEL) != None,
            "overflowing caret is refused: %r" % value,
        )
    for value, expected in _CARET_ACCEPTED:
        asserts.true(env, is_valid_sdk_constraint(value), "edge caret reads: %r" % value)
        content = _sdk_pubspec(value)
        asserts.true(
            env,
            pubspec_environment_error(content, _LABEL) == None,
            "edge caret reads: %r" % value,
        )
        asserts.equals(
            env,
            expected,
            derive_language_version(pubspec_sdk_constraint(content)),
            "edge caret derives: %r" % value,
        )
    return unittest.end(env)

def _refused_strings_test_impl(ctx):
    env = unittest.begin(ctx)
    for value in _REFUSED_STRINGS:
        asserts.false(env, is_valid_sdk_constraint(value), "sdk %r is refused" % value)
        content = _sdk_pubspec(value)
        err = pubspec_environment_error(content, _LABEL)
        asserts.true(env, err != None, "sdk %r is refused" % value)
        asserts.true(env, "probe_pkg" in err, "refusal names the package: %s" % err)
        asserts.true(env, "pubspec.yaml" in err, "refusal names pubspec.yaml: %s" % err)
        asserts.true(env, "\"%s\"" % value in err, "refusal quotes the value: %s" % err)
    return unittest.end(env)

def _refused_values_test_impl(ctx):
    env = unittest.begin(ctx)
    for sdk, quoted in [
        # `sdk: 3.5` and `sdk: 3` read as their text.
        ("3.5", "\"3.5\""),
        ("3", "\"3\""),
        (True, "\"True\""),
        ([">=2.12.0"], ">=2.12.0"),
        ({"min": "2.12.0"}, "environment.sdk"),
    ]:
        err = pubspec_environment_error(_sdk_pubspec(sdk), _LABEL)
        asserts.true(env, err != None, "sdk value is refused: %r" % sdk)
        asserts.true(env, "probe_pkg" in err, "refusal names the package: %s" % err)
        asserts.true(env, "pubspec.yaml" in err, "refusal names pubspec.yaml: %s" % err)
        asserts.true(env, quoted in err, "refusal quotes the value: %s" % err)
    return unittest.end(env)

def _accepted_test_impl(ctx):
    env = unittest.begin(ctx)
    for value, expected in _ACCEPTED_CASES:
        asserts.true(env, is_valid_sdk_constraint(value), "sdk %r reads" % value)
        content = _sdk_pubspec(value)
        asserts.true(
            env,
            pubspec_environment_error(content, _LABEL) == None,
            "sdk %r reads" % value,
        )
        asserts.equals(
            env,
            expected,
            derive_language_version(pubspec_sdk_constraint(content)),
            "sdk %r derives base version" % value,
        )
    return unittest.end(env)

def _absent_test_impl(ctx):
    env = unittest.begin(ctx)
    for content in [
        {"name": "probe_pkg"},
        _env_pubspec(None),
        _sdk_pubspec(None),
    ]:
        asserts.true(
            env,
            pubspec_environment_error(content, _LABEL) == None,
            "environment reads as before: %r" % content,
        )
        asserts.equals(env, "", pubspec_sdk_constraint(content), "no constraint")
    return unittest.end(env)

# Environment shapes pub's `_parseEnvironment` refuses at tag SDK-3.13.5:
# a present, non-null `environment` that is not a map, a key named `dart`,
# and a non-null constraint for any SDK that is not a string pub_semver
# 2.2.0 parses. Each entry pairs the `environment` value with the reasons
# the refusal names. pub also refuses an SDK name that is not a string
# (`3:`, `true:`); decoded keys are always text, so that check cannot be
# made and such a name reads like any other SDK (see `_ENVIRONMENT_READS`).
_REFUSED_ENVIRONMENT = [
    ("3", ["\"environment\" field must be a map."]),
    ("sdk", ["\"environment\" field must be a map."]),
    (True, ["\"environment\" field must be a map."]),
    (["sdk"], ["\"environment\" field must be a map."]),
    ({"dart": "^3.0.0"}, ["Use \"sdk\" to for Dart SDK constraints."]),
    ({"sdk": "^3.0.0", "dart": "^3.0.0"}, ["Use \"sdk\" to for Dart SDK constraints."]),
    ({"sdk": "foo", "flutter": "foo"}, ["invalid environment.sdk constraint"]),
    ({"sdk": "^3.0.0", "flutter": "3"}, ["invalid environment.flutter constraint", "\"3\""]),
    ({"sdk": "^3.0.0", "flutter": True}, ["invalid environment.flutter constraint", "\"True\""]),
    ({"sdk": "^3.0.0", "flutter": [">=2.12.0"]}, ["invalid environment.flutter constraint", ">=2.12.0"]),
    ({"sdk": "^3.0.0", "flutter": {"min": "2.12.0"}}, ["invalid environment.flutter constraint", "environment.flutter"]),
    ({"sdk": "^3.0.0", "flutter": "foo"}, ["invalid environment.flutter constraint", "\"foo\""]),
    ({"sdk": "^3.0.0", "flutter": "*"}, ["invalid environment.flutter constraint", "\"*\""]),
    ({"sdk": "^3.0.0", "fuchsia": "1.2.3.4"}, ["invalid environment.fuchsia constraint", "\"1.2.3.4\""]),
]

# Environment shapes that read as before: a null constraint for any SDK,
# string constraints pub_semver parses, and SDK names written as numbers or
# booleans, which read as their text.
_ENVIRONMENT_READS = [
    {"sdk": "^3.0.0", "flutter": None},
    {"sdk": "^3.0.0", "flutter": "any"},
    {"sdk": "^3.0.0", "flutter": ">=2.12.0 <4.0.0"},
    {"sdk": "^3.0.0", "fuchsia": "^1.0.0"},
    {"flutter": "^3.0.0"},
    {"3": "^3.0.0"},
    {"true": "^3.0.0"},
    {"sdk": "^3.0.0", "3": "^3.0.0"},
]

def _refused_environment_test_impl(ctx):
    env = unittest.begin(ctx)
    for environment, reasons in _REFUSED_ENVIRONMENT:
        err = pubspec_environment_error(_env_pubspec(environment), _LABEL)
        asserts.true(env, err != None, "environment is refused: %r" % environment)
        asserts.true(env, "probe_pkg" in err, "refusal names the package: %s" % err)
        asserts.true(env, "pubspec.yaml" in err, "refusal names pubspec.yaml: %s" % err)
        for reason in reasons:
            asserts.true(env, reason in err, "refusal names the reason: %s" % err)
    return unittest.end(env)

def _environment_reads_test_impl(ctx):
    env = unittest.begin(ctx)
    for environment in _ENVIRONMENT_READS:
        asserts.true(
            env,
            pubspec_environment_error(_env_pubspec(environment), _LABEL) == None,
            "environment reads: %r" % environment,
        )
    return unittest.end(env)

_refused_strings_test = unittest.make(_refused_strings_test_impl)
_refused_environment_test = unittest.make(_refused_environment_test_impl)
_environment_reads_test = unittest.make(_environment_reads_test_impl)
_blanks_test = unittest.make(_blanks_test_impl)
_non_blanks_test = unittest.make(_non_blanks_test_impl)
_caret_edges_test = unittest.make(_caret_edges_test_impl)
_refused_values_test = unittest.make(_refused_values_test_impl)
_accepted_test = unittest.make(_accepted_test_impl)
_absent_test = unittest.make(_absent_test_impl)

def _pubspec_probe_impl(ctx):
    """Runs the fetch's pubspec guard over a decoded pubspec, given as JSON.

    Fails analysis with the production message, as the spoke fails its fetch.
    """
    err = pubspec_environment_error(json.decode(ctx.attr.pubspec), ctx.label.name + "/pubspec.yaml")
    if err:
        fail(err)
    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

_pubspec_probe = rule(
    implementation = _pubspec_probe_impl,
    attrs = {"pubspec": attr.string(mandatory = True)},
)

def _bad_sdk_probe_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "invalid environment.sdk constraint")
    return analysistest.end(env)

_bad_sdk_probe_test = analysistest.make(_bad_sdk_probe_impl, expect_failure = True)

def _bad_env_probe_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "\"environment\" field must be a map.")
    return analysistest.end(env)

_bad_env_probe_test = analysistest.make(_bad_env_probe_impl, expect_failure = True)

def pubspec_guard_test_suite(name):
    """Declares the pubspec-guard unit and fetch-level refusal tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name + "_unit",
        _refused_strings_test,
        _refused_environment_test,
        _environment_reads_test,
        _blanks_test,
        _non_blanks_test,
        _caret_edges_test,
        _refused_values_test,
        _accepted_test,
        _absent_test,
    )

    # Each probe fails analysis by design, so both are `manual`: a
    # `//dart/tests/...` wildcard would otherwise analyze them as top-level
    # targets and fail the build. The `expect_failure` tests below still
    # analyze them as `target_under_test`, where the failure is the Pass.
    _pubspec_probe(
        name = name + "_bad_sdk_probe",
        pubspec = json.encode(_sdk_pubspec("3")),
        tags = ["manual"],
    )
    _pubspec_probe(
        name = name + "_bad_env_probe",
        pubspec = json.encode(_env_pubspec("3")),
        tags = ["manual"],
    )
    _bad_sdk_probe_test(
        name = name + "_bad_sdk_test",
        size = "small",
        target_under_test = ":" + name + "_bad_sdk_probe",
    )
    _bad_env_probe_test(
        name = name + "_bad_env_test",
        size = "small",
        target_under_test = ":" + name + "_bad_env_probe",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_bad_sdk_test",
            ":" + name + "_bad_env_test",
        ],
    )
