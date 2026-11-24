"""Tests that the podspec reader lexes Ruby regex literals and fails closed on open syntax (#189)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:podspec_read.bzl", "read_plugin_podspec")
load(
    "//flutter/tests:podspec_read_test.bzl",
    "podspec_expect_failure_test",
    "podspec_failure_probe",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_TAIL = """\
  s.frameworks = ["StoreKit"]
  s.weak_frameworks = 'MetricKit'
  s.libraries = 'sqlite3'
  s.resources = ['Resources/PrivacyInfo.xcprivacy']
end
"""

def _spec(preamble):
    """Return a podspec with `preamble` before `Pod::Spec.new` and the link settings after."""
    return preamble + "\nPod::Spec.new do |s|\n  s.name = 'p'\n" + _TAIL

def _assert_read(env, text):
    """Assert `text` reads to the standard StoreKit/MetricKit/sqlite3/privacy fields."""
    got = read_plugin_podspec(text, "ios/p.podspec", "p", "ios")
    asserts.equals(env, ["StoreKit"], got.frameworks)
    asserts.equals(env, ["MetricKit"], got.weak_frameworks)
    asserts.equals(env, ["sqlite3"], got.libraries)
    asserts.equals(env, ["Resources/PrivacyInfo.xcprivacy"], got.privacy_manifests)

_ISSUE_PREAMBLES = [
    "v = File.read('../pubspec.yaml').match(/^version:\\s*([^\\s#]+)/)[1]",
    "version = File.read(pubspec_path).match(/^version:\\s*([^\\s#]+)/)&.[](1)",
]

def _issue_189_preamble_test_impl(ctx):
    """The `#189` preambles do not swallow the rest of the podspec."""
    env = unittest.begin(ctx)
    for preamble in _ISSUE_PREAMBLES:
        _assert_read(env, _spec(preamble))
    return unittest.end(env)

_issue_189_preamble_test = unittest.make(_issue_189_preamble_test_impl)

_REGEX_PREAMBLES = [
    "x = y.gsub(/[+\"]/, '')",
    "x = /it's/",
    "x = /a\\/b/",
    "x = /^[a/b#\"]+$/",
    "x = /^v/imxo",
    "x = /#{ \"a/'}\" }-#{ {1 => 2}[1] }/i",
    "x = %r{foo#{ bar('}\"') }baz}i",
    "x = %Q{a#{ b }c}",
    "x = [/a/, /b/]\ny = x =~ /a'\"/\nz = !/q'/",
    "puts /^v'/",
    "x = cond ? /a'/ : /b\"/",
    "x = /a\\\nb/",
    "if a =~ /x#y'/ then b = 1 end",
]

def _regex_forms_test_impl(ctx):
    """Regex literals with quotes, escapes, classes, flags and interpolation lex as one token."""
    env = unittest.begin(ctx)
    for preamble in _REGEX_PREAMBLES:
        _assert_read(env, _spec(preamble))
    _assert_read(env, _TAIL_INSIDE.format(line = "x = y.gsub(/[+\"]/, '')"))
    return unittest.end(env)

_regex_forms_test = unittest.make(_regex_forms_test_impl)

_TAIL_INSIDE = (
    "Pod::Spec.new do |s|\n  {line}\n  s.frameworks = [\"StoreKit\"]\n" +
    "  s.weak_frameworks = 'MetricKit'\n  s.libraries = 'sqlite3'\n" +
    "  s.resources = ['Resources/PrivacyInfo.xcprivacy']\nend\n"
)

_DIVISION_PREAMBLES = [
    "x = (10 + 2) / 3",
    "arr = [1]\nx = arr[0] / 2",
    "a = 4\nb = 2\nx = a / b",
    "x = a/b",
    "x = 8\nx /= 2",
    "x = 'ios' / 'Classes'",
    "x = 10 / 2 / 5",
    "x = {a: 1}[:a] / 2",
]

def _division_test_impl(ctx):
    """Division and `Pathname#/` never start a regex, yet a later regex still lexes as one."""
    env = unittest.begin(ctx)
    for division in _DIVISION_PREAMBLES:
        preamble = division + "\ny = x.to_s.match(/['\"]#/)"
        _assert_read(env, _spec(preamble))
        _assert_read(env, _TAIL_INSIDE.format(line = preamble.replace("\n", "\n  ")))
    return unittest.end(env)

_division_test = unittest.make(_division_test_impl)

_MSG5_TAIL = (
    ", which rules_flutter does not build for plugins. " +
    "Replace the plugin's BUILD file with an overlay (flutter.plugin_overlays)."
)

def _case(suffix, text, expected):
    """Build one negative probe case."""
    return struct(suffix = suffix, text = text, expected = expected)

def _eof(suffix, text, line, what):
    """Build a malformed-EOF case expecting the plugin, `ios/p.podspec:<line>`, and `what`."""
    return _case(suffix, text, ['Flutter plugin "p"', "ios/p.podspec:%d" % line, what])

_FAILURE_CASES = [
    _case(
        "issue_189",
        "v = File.read('../pubspec.yaml').match(/^version:\\s*([^\\s#]+)/)[1]\n" +
        "Pod::Spec.new do |s|\n  s.name = 'p'\n  s.frameworks = ['StoreKit']\n" +
        "  s.vendored_frameworks = 'X.xcframework'\nend\n",
        [
            'Flutter plugin "p": ios/p.podspec:5 declares vendored_frameworks ' +
            "('X.xcframework')" + _MSG5_TAIL,
            "flutter.plugin_overlays",
        ],
    ),
    _case(
        "quotes_in_regex",
        "x = y.gsub(/[+\"]/, '')\nPod::Spec.new do |s|\n  s.name = 'p'\n  s.resources = 'Assets/*.png'\nend\n",
        ['Flutter plugin "p": ios/p.podspec:4 declares resources (\'Assets/*.png\')' + _MSG5_TAIL],
    ),
    _eof("eof_single", "x = 1\ny = 'single\nz = 2\n", 2, "single-quoted string"),
    _eof("eof_double", "x = 1\ny = \"double\nz = 2\n", 2, "double-quoted string"),
    _eof("eof_regex", "x = 1\ny = /regex\nz = 2\n", 2, "regex literal"),
    _eof("eof_pct_regex", "x = 1\ny = %r{regex\nz = 2\n", 2, "percent literal"),
    _eof("eof_heredoc", "x = 1\ny = <<-EOF\n  body\n  more\n", 2, "heredoc"),
    _eof("eof_block_comment", "x = 1\n=begin\nnever closed\n", 2, "block comment"),
    _eof("eof_bracket", "x = 1\ny = foo(1,\n  2\n", 2, "`(` bracket"),
    _eof("eof_block", "x = 1\nPod::Spec.new do |s|\n  s.name = 'p'\n", 2, "unclosed block"),
]

def _declare_failure_tests(name):
    """Declare one probe plus `podspec_expect_failure_test` per malformed case."""
    tests = []
    for case in _FAILURE_CASES:
        probe = "%s_%s_probe" % (name, case.suffix)
        podspec_failure_probe(
            name = probe,
            path = "ios/p.podspec",
            plugin = "p",
            text = case.text,
            tags = ["manual"],
        )
        podspec_expect_failure_test(
            name = "%s_%s_failure_test" % (name, case.suffix),
            target_under_test = ":" + probe,
            expected_messages = case.expected,
            size = "small",
        )
        tests.append(":%s_%s_failure_test" % (name, case.suffix))
    return tests

def podspec_read_regex_test_suite(name):
    """Declare the regex-lexing unit tests and fail-closed analysis tests.

    Args:
        name: Name prefix for the declared test targets.
    """
    small_unittest_suite(
        name + "_unit",
        _issue_189_preamble_test,
        _regex_forms_test,
        _division_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"] + _declare_failure_tests(name),
    )
