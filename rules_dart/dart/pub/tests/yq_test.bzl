"""Behavioural tests of `yaml_to_json`: documents in, expected data out.

The conversion ran in the `yq_probe` repository rule (see `yq_probe.bzl`)
with the pinned `yaml2json` binary; these tests check what it produced.
"""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@yq_probe//:results.bzl", "RESULTS")
load("//dart/pub/tests:yq_probe.bzl", "DOCUMENTS", "MUST_FAIL")

visibility(["//dart/..."])

# Booleans stay booleans, empty values are None, and every other scalar is
# its source text.
_EXPECTED = {
    "anchors.yaml": {"a": "1.10", "b": "1.10", "c": "0x10", "d": "0x10"},
    "block_scalar.yaml": {"text": "line one\nline two\n", "folded": "a b\n"},
    "bom.yaml": {"name": "bom"},
    "comment_only.yaml": {},
    "crlf.yaml": {"name": "crlf", "version": "1.0.0"},
    "empty.yaml": {},
    "flow.yaml": {"name": "flow", "dependencies": {"a": "^1.0.0", "b": "any"}, "list": ["1", "two"]},
    "lock.yaml": {
        "packages": {
            "collection": {
                "dependency": "direct main",
                "description": {
                    "name": "collection",
                    "sha256": "0123456789012345678901234567890123456789012345678901234567890123",
                    "url": "https://pub.dev",
                },
                "source": "hosted",
                "version": "1.10.0",
            },
            "local": {
                "dependency": "direct main",
                "description": {"path": "../local", "relative": True},
                "source": "path",
                "version": "0.0.1",
            },
        },
        "sdks": {"dart": ">=3.0.0 <4.0.0"},
    },
    "markers.yaml": {"name": "markers"},

    # A merge key stays a literal key, as in `package:yaml`.
    "merge_key.yaml": {"base": {"a": "1"}, "other": {"<<": {"a": "1"}, "c": "2"}},
    "scalars.yaml": {
        "float": "1.10",
        "hex": "0x10",
        "octal": "0o17",
        "word_bool": "yes",
        "bool": True,
        "capital_bool": False,
        "null_word": None,
        "tilde": None,
        "empty": None,
        "quoted_null": "null",
        "digits": "1234567890123456789012345678901234567890",
        "exponent": "123e45",
        "date": "2024-01-01",
        "infinity": ".inf",
        "1": "number key",
    },
}

def _documents_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, RESULTS["batch_error"])
    documents = RESULTS["documents"]
    asserts.equals(env, sorted(DOCUMENTS.keys()), sorted(_EXPECTED.keys()))
    for name in sorted(_EXPECTED.keys()):
        asserts.equals(env, _EXPECTED[name], documents[name], name)
    return unittest.end(env)

def _same_file_twice_test_impl(ctx):
    env = unittest.begin(ctx)
    first = sorted(DOCUMENTS.keys())[0]
    asserts.equals(env, _EXPECTED[first], RESULTS["documents"]["(again) " + first])
    return unittest.end(env)

def _must_fail_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, sorted(MUST_FAIL.keys()), sorted(RESULTS["failures"].keys()))
    for name in sorted(MUST_FAIL.keys()):
        result = RESULTS["failures"][name]
        error = result["error"]
        asserts.equals(env, None, result["data"], name)
        asserts.true(env, error != None, "%s converted without an error" % name)
        if error == None:
            continue

        # The error names the failing file, never the good one before it.
        asserts.true(env, name in error, "%s: error does not name the file: %s" % (name, error))
        asserts.true(env, MUST_FAIL[name][1] in error, "%s: %s" % (name, error))
        asserts.false(env, sorted(DOCUMENTS.keys())[0] in error, "%s: %s" % (name, error))
    return unittest.end(env)

_documents_test = unittest.make(_documents_test_impl)
_same_file_twice_test = unittest.make(_same_file_twice_test_impl)
_must_fail_test = unittest.make(_must_fail_test_impl)

def yq_test_suite(name):
    """Declares the `yaml_to_json` behaviour tests.

    Args:
      name: Name of the generated test suite.
    """
    unittest.suite(
        name,
        partial.make(_documents_test, size = "small"),
        partial.make(_same_file_twice_test, size = "small"),
        partial.make(_must_fail_test, size = "small"),
    )
