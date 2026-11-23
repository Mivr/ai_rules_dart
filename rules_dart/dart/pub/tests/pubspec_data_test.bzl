"""Unit tests of the checks and projection over decoded `pubspec.lock` and `pubspec.yaml` data.

Each input is the mapping `yaml_to_json` decodes the file to: booleans stay
booleans, empty values are None, every other scalar is its source text.
YAML syntax itself is `yq_test`'s business.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//dart/pub:yaml.bzl",
    "lock_packages",
    "lock_packages_or_error",
    "pubspec_deps",
    "pubspec_sdk_constraint",
)
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

visibility(["//dart/..."])

_LABEL = "//:pubspec.lock"

_COLLECTION_SHA = "ee67cb0715911d28db6bf4af1026078bd6f0128b07a5f66fb2ed94ef6783c09a"

_SAMPLE_LOCK = {
    "packages": {
        "collection": {
            "dependency": "direct main",
            "description": {"name": "collection", "sha256": _COLLECTION_SHA, "url": "https://pub.dev"},
            "source": "hosted",
            "version": "1.18.0",
        },
        "flutter": {
            "dependency": "direct main",
            "description": "flutter",
            "source": "sdk",
            "version": "0.0.0",
        },
    },
    "sdks": {"dart": ">=3.0.0 <4.0.0"},
}

def _entry(source = "hosted", version = "1.0.0"):
    """One lock entry with the given `source` and `version` (None leaves it out)."""
    entry = {}
    if source != None:
        entry["source"] = source
    if version != None:
        entry["version"] = version
    return entry

def _error(packages):
    """The refusal for a lock holding `packages`, or None."""
    return lock_packages_or_error({"packages": packages}, _LABEL).error

def _lock_projection_test_impl(ctx):
    """Entries project to string fields; a scalar description reads as its name."""
    env = unittest.begin(ctx)
    packages = lock_packages(_SAMPLE_LOCK, _LABEL)
    asserts.equals(env, ["collection", "flutter"], sorted(packages.keys()))
    collection = packages["collection"]
    asserts.equals(env, "hosted", collection["source"])
    asserts.equals(env, "1.18.0", collection["version"])
    asserts.equals(env, _COLLECTION_SHA, collection["description"]["sha256"])
    asserts.equals(env, "https://pub.dev", collection["description"]["url"])
    asserts.equals(env, {"name": "flutter"}, packages["flutter"]["description"])
    asserts.equals(env, "sdk", packages["flutter"]["source"])

    # An empty value reads as "", a boolean as its Starlark text.
    empty = lock_packages({"packages": {"a": {
        "description": {"name": "a", "sha256": None, "relative": True},
        "source": "path",
        "version": "0.0.1",
    }}}, _LABEL)
    asserts.equals(env, {"name": "a", "sha256": "", "relative": "True"}, empty["a"]["description"])
    return unittest.end(env)

def _lock_packages_section_test_impl(ctx):
    """`packages: {}` is a valid empty lock; a missing or non-mapping one fails."""
    env = unittest.begin(ctx)
    asserts.equals(env, {}, lock_packages({"packages": {}, "sdks": {"dart": ">=3.0.0 <4.0.0"}}, _LABEL))
    for data in [{"sdks": {"dart": ">=3.0.0 <4.0.0"}}, {"packages": []}, {"packages": "x"}, {}]:
        err = lock_packages_or_error(data, _LABEL).error
        asserts.true(env, err != None and _LABEL in err and "packages" in err, str(err))
    return unittest.end(env)

def _lock_entry_shape_test_impl(ctx):
    """An entry that is not a mapping fails naming the package."""
    env = unittest.begin(ctx)
    for value in ["3", ["a"], None, True]:
        err = _error({"foo": value})
        asserts.true(env, err != None and _LABEL in err and "foo" in err, str(err))
    return unittest.end(env)

def _lock_entry_name_test_impl(ctx):
    """A name pub could never write fails; underscores and capitals stay valid."""
    env = unittest.begin(ctx)
    for name in ["9lives", "has-dash", ""]:
        err = _error({name: _entry()})
        asserts.true(env, err != None and _LABEL in err and repr(name) in err, str(err))
    packages = lock_packages({"packages": {"_ok": _entry(), "CamelCase": _entry("sdk", "0.0.0")}}, _LABEL)
    asserts.equals(env, ["CamelCase", "_ok"], sorted(packages.keys()))
    return unittest.end(env)

def _lock_entry_case_test_impl(ctx):
    """Names equal ignoring case collide, naming both; one alone is valid."""
    env = unittest.begin(ctx)
    err = _error({"Foo": _entry(), "foo": _entry(version = "2.0.0")})
    asserts.true(env, err != None and _LABEL in err and "Foo" in err and "foo" in err, str(err))
    asserts.equals(env, None, _error({"Foo": _entry()}))
    return unittest.end(env)

def _lock_entry_source_test_impl(ctx):
    """A missing or non-text `source` fails; hosted, git, path and sdk read."""
    env = unittest.begin(ctx)
    err = _error({"a": _entry(source = None)})
    asserts.true(env, err != None and _LABEL in err and "source" in err, str(err))
    for source in [True, ["hosted"], {"x": "y"}]:
        err = _error({"a": _entry(source = source)})
        asserts.true(env, err != None and _LABEL in err and "non-string 'source'" in err, str(err))
    packages = lock_packages({"packages": {
        "h": _entry("hosted"),
        "g": _entry("git"),
        "p": _entry("path", "0.0.0"),
        "s": _entry("sdk", "0.0.0"),
    }}, _LABEL)
    asserts.equals(env, "git", packages["g"]["source"])
    return unittest.end(env)

def _lock_entry_version_test_impl(ctx):
    """A version must be a semantic version as pub writes it.

    A bare YAML number reads as its text, so `version: 1.10` and `version: 3`
    fail as the versions `"1.10"` and `"3"` (pub writes neither), and
    `1e999` fails as text instead of overflowing.
    """
    env = unittest.begin(ctx)
    for version in ["3", "1", "1.10", "1e999", "1.0.0\n  plus junk", ""]:
        err = _error({"a": _entry(version = version)})
        asserts.true(env, err != None and _LABEL in err and "invalid version" in err, str(err))
    err = _error({"a": _entry(version = None)})
    asserts.true(env, err != None and _LABEL in err and "'version'" in err, str(err))
    err = _error({"a": _entry(version = True)})
    asserts.true(env, err != None and _LABEL in err and "non-string 'version'" in err, str(err))
    packages = lock_packages({"packages": {
        "a": _entry(version = "1.2.3-dev.4+5"),
        "b": _entry(version = "0.0.0"),
    }}, _LABEL)
    asserts.equals(env, "1.2.3-dev.4+5", packages["a"]["version"])
    asserts.equals(env, "0.0.0", packages["b"]["version"])
    return unittest.end(env)

_SAMPLE_PUBSPEC = {
    "name": "my_app",
    "version": "1.0.0",
    "environment": {"sdk": ">=3.0.0 <4.0.0"},
    "dependencies": {"collection": "^1.18.0", "path": "^1.9.0"},
    "dev_dependencies": {"test": "^1.24.0"},
}

def _pubspec_deps_test_impl(ctx):
    """Only `dependencies:` names count, in file order; other shapes read as none."""
    env = unittest.begin(ctx)
    asserts.equals(env, ["collection", "path"], pubspec_deps(_SAMPLE_PUBSPEC))
    asserts.equals(env, [], pubspec_deps({"name": "empty"}))
    asserts.equals(env, [], pubspec_deps({"name": "x", "dependencies": []}))
    asserts.equals(env, [], pubspec_deps({"name": "x", "dependencies": None}))
    asserts.equals(env, ["a", "b"], pubspec_deps({"name": "x", "dependencies": {"a": "^1.0.0", "b": {"path": "../b"}}}))
    return unittest.end(env)

def _pubspec_sdk_constraint_test_impl(ctx):
    """`environment.sdk` reads as its text; anything else reads as no constraint."""
    env = unittest.begin(ctx)
    asserts.equals(env, ">=3.0.0 <4.0.0", pubspec_sdk_constraint(_SAMPLE_PUBSPEC))
    asserts.equals(env, "^3.5.0", pubspec_sdk_constraint({"environment": {"sdk": "^3.5.0"}}))
    asserts.equals(env, "3", pubspec_sdk_constraint({"environment": {"sdk": "3"}}))
    asserts.equals(env, "", pubspec_sdk_constraint({"environment": {"sdk": None}}))
    asserts.equals(env, "", pubspec_sdk_constraint({"environment": "3"}))
    asserts.equals(env, "", pubspec_sdk_constraint({"name": "x"}))
    asserts.equals(env, "", pubspec_sdk_constraint({}))
    return unittest.end(env)

_lock_projection_test = unittest.make(_lock_projection_test_impl)
_lock_packages_section_test = unittest.make(_lock_packages_section_test_impl)
_lock_entry_shape_test = unittest.make(_lock_entry_shape_test_impl)
_lock_entry_name_test = unittest.make(_lock_entry_name_test_impl)
_lock_entry_case_test = unittest.make(_lock_entry_case_test_impl)
_lock_entry_source_test = unittest.make(_lock_entry_source_test_impl)
_lock_entry_version_test = unittest.make(_lock_entry_version_test_impl)
_pubspec_deps_test = unittest.make(_pubspec_deps_test_impl)
_pubspec_sdk_constraint_test = unittest.make(_pubspec_sdk_constraint_test_impl)

def pubspec_data_test_suite(name):
    """Declares the decoded-data check and projection tests.

    Args:
        name: The test suite name.
    """
    small_unittest_suite(
        name,
        _lock_projection_test,
        _lock_packages_section_test,
        _lock_entry_shape_test,
        _lock_entry_name_test,
        _lock_entry_case_test,
        _lock_entry_source_test,
        _lock_entry_version_test,
        _pubspec_deps_test,
        _pubspec_sdk_constraint_test,
    )
