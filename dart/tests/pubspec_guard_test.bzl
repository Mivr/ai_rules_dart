"""Unit tests for the pubspec guard: SDK-constraint refusal and `%` tails.

Every fetch (`pub_lock_package` / `pub_lock_git_package` spokes, the
`pub_lock_scc_package` merge, `pub_package`) fails a pubspec whose present,
non-null `environment.sdk` is not a version constraint pub reads, or that
carries a `%YAML` / `%TAG` line after its `...` end marker. The production
check is `pubspec_sdk_constraint_error` plus the document parse, which the
`_pubspec_probe` rule below runs in the same order the spokes do, so the
`expect_failure` analysis tests exercise the fetch-level refusal path.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//dart/pub:yaml_parser.bzl",
    "is_valid_sdk_constraint",
    "parse_pubspec_document",
    "parse_pubspec_document_error",
    "parse_pubspec_sdk_constraint",
    "pubspec_lock_error",
    "pubspec_sdk_constraint_error",
)

# buildifier: disable=bzl-visibility
load("//dart/pub/private:language_version.bzl", "derive_language_version")
load(":small_suite.bzl", "small_unittest_suite")

_LABEL = "probe_pkg/pubspec.yaml"

def _sdk_pubspec(sdk_line):
    """Returns a `probe_pkg` pubspec with the given `environment:` block lines."""
    return "name: probe_pkg\n" + sdk_line

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
# YAML layer carries them in (see `yaml_sdk_constraint.bzl`). The ASCII six
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
            content = _sdk_pubspec("environment:\n  sdk: \"%s\"\n" % value)
            asserts.true(
                env,
                pubspec_sdk_constraint_error(content, _LABEL) == None,
                "blank reads: %r" % value,
            )
            asserts.equals(
                env,
                expected,
                derive_language_version(parse_pubspec_sdk_constraint(content)),
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
            content = _sdk_pubspec("environment:\n  sdk: \"%s\"\n" % value)
            asserts.true(
                env,
                pubspec_sdk_constraint_error(content, _LABEL) != None,
                "non-blank is refused: %r" % value,
            )
    return unittest.end(env)

def _caret_edges_test_impl(ctx):
    env = unittest.begin(ctx)
    for value in _CARET_REFUSED:
        asserts.false(env, is_valid_sdk_constraint(value), "overflowing caret is refused: %r" % value)
        content = _sdk_pubspec("environment:\n  sdk: \"%s\"\n" % value)
        asserts.true(
            env,
            pubspec_sdk_constraint_error(content, _LABEL) != None,
            "overflowing caret is refused: %r" % value,
        )
    for value, expected in _CARET_ACCEPTED:
        asserts.true(env, is_valid_sdk_constraint(value), "edge caret reads: %r" % value)
        content = _sdk_pubspec("environment:\n  sdk: \"%s\"\n" % value)
        asserts.true(
            env,
            pubspec_sdk_constraint_error(content, _LABEL) == None,
            "edge caret reads: %r" % value,
        )
        asserts.equals(
            env,
            expected,
            derive_language_version(parse_pubspec_sdk_constraint(content)),
            "edge caret derives: %r" % value,
        )
    return unittest.end(env)

def _refused_strings_test_impl(ctx):
    env = unittest.begin(ctx)
    for value in _REFUSED_STRINGS:
        asserts.false(env, is_valid_sdk_constraint(value), "sdk %r is refused" % value)
        content = _sdk_pubspec("environment:\n  sdk: \"%s\"\n" % value)
        err = pubspec_sdk_constraint_error(content, _LABEL)
        asserts.true(env, err != None, "sdk %r is refused" % value)
        asserts.true(env, "probe_pkg" in err, "refusal names the package: %s" % err)
        asserts.true(env, "pubspec.yaml" in err, "refusal names pubspec.yaml: %s" % err)
        asserts.true(env, "\"%s\"" % value in err, "refusal quotes the value: %s" % err)
    return unittest.end(env)

def _refused_values_test_impl(ctx):
    env = unittest.begin(ctx)
    for sdk_line, quoted in [
        ("environment:\n  sdk: 3.5\n", "\"3.5\""),
        ("environment:\n  sdk: 3\n", "\"3\""),
        ("environment:\n  sdk: true\n", "\"True\""),
        ("environment:\n  sdk:\n    - \">=2.12.0\"\n", ">=2.12.0"),
        ("environment:\n  sdk:\n    min: 2.12.0\n", "environment.sdk"),
    ]:
        err = pubspec_sdk_constraint_error(_sdk_pubspec(sdk_line), _LABEL)
        asserts.true(env, err != None, "sdk block is refused:\n%s" % sdk_line)
        asserts.true(env, "probe_pkg" in err, "refusal names the package: %s" % err)
        asserts.true(env, "pubspec.yaml" in err, "refusal names pubspec.yaml: %s" % err)
        asserts.true(env, quoted in err, "refusal quotes the value: %s" % err)
    return unittest.end(env)

def _accepted_test_impl(ctx):
    env = unittest.begin(ctx)
    for value, expected in _ACCEPTED_CASES:
        asserts.true(env, is_valid_sdk_constraint(value), "sdk %r reads" % value)
        content = _sdk_pubspec("environment:\n  sdk: \"%s\"\n" % value)
        asserts.true(
            env,
            pubspec_sdk_constraint_error(content, _LABEL) == None,
            "sdk %r reads" % value,
        )
        asserts.equals(
            env,
            expected,
            derive_language_version(parse_pubspec_sdk_constraint(content)),
            "sdk %r derives base version" % value,
        )
    return unittest.end(env)

def _absent_test_impl(ctx):
    env = unittest.begin(ctx)
    for sdk_line in [
        "",
        "environment:\n",
        "environment:\n  sdk:\n",
    ]:
        content = _sdk_pubspec(sdk_line)
        asserts.true(
            env,
            pubspec_sdk_constraint_error(content, _LABEL) == None,
            "block reads as before:\n%s" % sdk_line,
        )
        asserts.equals(env, "", parse_pubspec_sdk_constraint(content), "no constraint")
    return unittest.end(env)

# Environment shapes pub's `_parseEnvironment` refuses at tag SDK-3.13.5:
# a present, non-null `environment` that is not a map, an SDK name that
# is not a string, a key named `dart`, and a non-null constraint for any
# SDK that is not a string pub_semver 2.2.0 parses. Each entry pairs the
# `environment:` block lines with the reason the refusal names.
_REFUSED_ENVIRONMENT = [
    ("environment: 3\n", ["\"environment\" field must be a map."]),
    ("environment: \"sdk\"\n", ["\"environment\" field must be a map."]),
    ("environment: true\n", ["\"environment\" field must be a map."]),
    ("environment:\n  - sdk\n", ["\"environment\" field must be a map."]),
    ("environment:\n  3: \"^3.0.0\"\n", ["SDK names must be strings."]),
    ("environment:\n  true: \"^3.0.0\"\n", ["SDK names must be strings."]),
    ("environment:\n  dart: \"^3.0.0\"\n", ["Use \"sdk\" to for Dart SDK constraints."]),
    (
        "environment:\n  sdk: \"^3.0.0\"\n  dart: \"^3.0.0\"\n",
        ["Use \"sdk\" to for Dart SDK constraints."],
    ),
    (
        "environment:\n  sdk: \"foo\"\n  flutter: \"foo\"\n",
        ["invalid environment.sdk constraint"],
    ),
    ("environment:\n  sdk: \"^3.0.0\"\n  flutter: 3\n", ["invalid environment.flutter constraint", "\"3\""]),
    ("environment:\n  sdk: \"^3.0.0\"\n  flutter: true\n", ["invalid environment.flutter constraint", "\"True\""]),
    (
        "environment:\n  sdk: \"^3.0.0\"\n  flutter:\n    - \">=2.12.0\"\n",
        ["invalid environment.flutter constraint", ">=2.12.0"],
    ),
    (
        "environment:\n  sdk: \"^3.0.0\"\n  flutter:\n    min: 2.12.0\n",
        ["invalid environment.flutter constraint", "environment.flutter"],
    ),
    ("environment:\n  sdk: \"^3.0.0\"\n  flutter: \"foo\"\n", ["invalid environment.flutter constraint", "\"foo\""]),
    ("environment:\n  sdk: \"^3.0.0\"\n  flutter: \"*\"\n", ["invalid environment.flutter constraint", "\"*\""]),
    ("environment:\n  sdk: \"^3.0.0\"\n  fuchsia: \"1.2.3.4\"\n", ["invalid environment.fuchsia constraint", "\"1.2.3.4\""]),
    (
        "environment:\n  sdk: \"^3.0.0\"\n  3: \"^3.0.0\"\n",
        ["SDK names must be strings."],
    ),
]

# Environment shapes that read as before: a null `environment`, a null
# constraint for any SDK, and string constraints pub_semver parses.
_ENVIRONMENT_READS = [
    "environment:\n  sdk: \"^3.0.0\"\n  flutter:\n",
    "environment:\n  sdk: \"^3.0.0\"\n  flutter: \"any\"\n",
    "environment:\n  sdk: \"^3.0.0\"\n  flutter: \">=2.12.0 <4.0.0\"\n",
    "environment:\n  sdk: \"^3.0.0\"\n  fuchsia: \"^1.0.0\"\n",
    "environment:\n  flutter: \"^3.0.0\"\n",
]

def _refused_environment_test_impl(ctx):
    env = unittest.begin(ctx)
    for sdk_line, reasons in _REFUSED_ENVIRONMENT:
        err = pubspec_sdk_constraint_error(_sdk_pubspec(sdk_line), _LABEL)
        asserts.true(env, err != None, "environment block is refused:\n%s" % sdk_line)
        asserts.true(env, "probe_pkg" in err, "refusal names the package: %s" % err)
        asserts.true(env, "pubspec.yaml" in err, "refusal names pubspec.yaml: %s" % err)
        for reason in reasons:
            asserts.true(env, reason in err, "refusal names the reason: %s" % err)
    return unittest.end(env)

def _environment_reads_test_impl(ctx):
    env = unittest.begin(ctx)
    for sdk_line in _ENVIRONMENT_READS:
        content = _sdk_pubspec(sdk_line)
        asserts.true(
            env,
            pubspec_sdk_constraint_error(content, _LABEL) == None,
            "environment block reads:\n%s" % sdk_line,
        )
    return unittest.end(env)

def _tail_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    for tail in [
        "%YAML 1.2\n",
        "%YAML 1.2\n---\nname: other\n",
        "%TAG ! e:\n",
        "%TAG ! e:\n---\nname: other\n",
    ]:
        content = "name: probe_pkg\n...\n" + tail
        asserts.equals(
            env,
            "probe_pkg in probe_pkg/pubspec.yaml: directive after document end (...) at line 3",
            parse_pubspec_document_error(content, "probe_pkg/pubspec.yaml"),
            "tail refusal names the directive line:\n%s" % tail,
        )
    return unittest.end(env)

def _tail_reads_test_impl(ctx):
    env = unittest.begin(ctx)
    unknown = "name: probe_pkg\n...\n%FOO bar\n"
    asserts.true(
        env,
        parse_pubspec_document_error(unknown, "probe_pkg/pubspec.yaml") == None,
        "unknown directive tail reads",
    )
    asserts.equals(env, "probe_pkg", parse_pubspec_document(unknown)["name"], "name reads")
    comment = "name: probe_pkg\n...\n# trailing comment\n"
    asserts.true(
        env,
        parse_pubspec_document_error(comment, "probe_pkg/pubspec.yaml") == None,
        "comment tail reads",
    )
    asserts.equals(env, "probe_pkg", parse_pubspec_document(comment)["name"], "name reads")
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
_tail_fails_test = unittest.make(_tail_fails_test_impl)
_tail_reads_test = unittest.make(_tail_reads_test_impl)

def _lock_tail_test_impl(ctx):
    env = unittest.begin(ctx)

    # The lock path reads exactly as before: a `%YAML` line after `...`
    # reads past, so the second `---` document is refused naming the `---`
    # line, byte for byte the message the base gives.
    asserts.equals(
        env,
        "test.lock: second document marker (---) at line 5",
        pubspec_lock_error(
            "packages:\n  foo: 1\n...\n%YAML 1.2\n---\npackages: {}\n",
            "test.lock",
        ),
        "lock tail keeps the base message",
    )
    return unittest.end(env)

_lock_tail_test = unittest.make(_lock_tail_test_impl)

def _pubspec_probe_impl(ctx):
    """Runs the fetch's pubspec guard over a `pubspec` string attribute.

    Mirrors the spoke order: the SDK-constraint check first, then the full
    document parse, failing analysis with the production message.
    """
    err = pubspec_sdk_constraint_error(ctx.attr.pubspec, ctx.label.name + "/pubspec.yaml")
    if err:
        fail(err)
    parse_pubspec_document(ctx.attr.pubspec, ctx.label.name + "/pubspec.yaml")
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

def _tail_probe_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "directive after document end (...) at line 3")
    return analysistest.end(env)

_tail_probe_test = analysistest.make(_tail_probe_impl, expect_failure = True)

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
        _tail_fails_test,
        _tail_reads_test,
        _lock_tail_test,
    )

    # Each probe fails analysis by design, so all three are `manual`: a
    # `//dart/tests/...` wildcard would otherwise analyze them as top-level
    # targets and fail the build. The `expect_failure` tests below still
    # analyze them as `target_under_test`, where the failure is the Pass.
    _pubspec_probe(
        name = name + "_bad_sdk_probe",
        pubspec = "name: probe_pkg\nenvironment:\n  sdk: 3\n",
        tags = ["manual"],
    )
    _pubspec_probe(
        name = name + "_yaml_tail_probe",
        pubspec = "name: probe_pkg\n...\n%YAML 1.2\n",
        tags = ["manual"],
    )
    _pubspec_probe(
        name = name + "_tag_tail_probe",
        pubspec = "name: probe_pkg\n...\n%TAG ! e:\n",
        tags = ["manual"],
    )
    _pubspec_probe(
        name = name + "_bad_env_probe",
        pubspec = "name: probe_pkg\nenvironment: 3\n",
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
    _tail_probe_test(
        name = name + "_yaml_tail_test",
        size = "small",
        target_under_test = ":" + name + "_yaml_tail_probe",
    )
    _tail_probe_test(
        name = name + "_tag_tail_test",
        size = "small",
        target_under_test = ":" + name + "_tag_tail_probe",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_bad_sdk_test",
            ":" + name + "_bad_env_test",
            ":" + name + "_yaml_tail_test",
            ":" + name + "_tag_tail_test",
        ],
    )
