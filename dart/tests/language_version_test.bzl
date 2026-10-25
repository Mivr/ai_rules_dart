"""Unit tests for derive_language_version."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:language_version.bzl", "derive_language_version")
load(":small_suite.bzl", "small_unittest_suite")

# (constraint_string, expected_output, label)
_CASES = [
    ("", "2.7", "empty string"),
    ("any", "2.7", "any"),
    ("*", "2.7", "star"),
    ("^3.5.0", "3.5", "caret 3.5.0"),
    ("^3.0.0", "3.0", "caret 3.0.0"),
    ("^2.12.0", "2.12", "caret 2.12.0"),
    ("^3.0.0+1", "3.0", "caret with build metadata"),
    ("^3.0.0-dev.1", "3.0", "caret with prerelease"),
    (">=2.12.0 <4.0.0", "2.12", "range both bounds"),
    (">=2.12.0", "2.12", "range lower only"),
    (">2.12.0", "2.12", "exclusive lower"),
    (">= 2.12.0 <4.0.0", "2.12", "whitespace after operator"),
    (">=2.12.0   <4.0.0", "2.12", "extra whitespace between bounds"),
    ("<4.0.0", "2.7", "upper only"),
    ("<=4.0.0", "2.7", "upper inclusive only"),
    ("2.12.0", "2.12", "bare exact"),
    ("2.12.0+1", "2.12", "bare exact with build metadata"),
    ("2.12.0-pre", "2.12", "bare exact with prerelease"),
    ("3.5.0-dev.7+meta", "3.5", "bare exact with both"),
    ("^2.0.0 || ^3.0.0", "2.0", "union ascending"),
    ("^3.0.0 || ^2.0.0", "2.0", "union descending — pub sorts to smallest min"),
    (">=2.12.0 <3.0.0 || >=3.5.0 <4.0.0", "2.12", "union of full ranges"),
    ("<2.0.0 || ^3.0.0", "2.7", "union — first range (after sort) has no lower bound"),
    ("garbage", "2.7", "malformed"),
    ("12.34.56", "12.34", "two-digit major.minor"),
    # Intersections: pub parses the terms and derives the tightest min,
    # defaulting to 2.7 when the intersection is empty. Oracles:
    # package:pub_semver 2.2.0 `VersionConstraint.parse` with pub's
    # `LanguageVersion.fromSdkConstraint` at tag SDK-3.13.5.
    (">2.0.0 <2.0.0", "2.7", "empty exclusive range"),
    (">=2.0.0 <2.0.0", "2.7", "empty half-open range"),
    (">2.0.0 <=2.0.0", "2.7", "empty half-open range, other side"),
    (">=2.0.0 <=1.0.0", "2.7", "empty inverted range"),
    ("1.0.0 2.0.0", "2.7", "empty disjoint bare versions"),
    ("2.0.0 >2.0.0", "2.7", "empty bare version past exclusive min"),
    (">1.2.3 1.2.3", "2.7", "empty bare version on exclusive min"),
    (">=2.0.0 <=2.0.0", "2.0", "inclusive single-version range"),
    ("2.0.0 2.0.0", "2.0", "repeated bare version"),
    ("1.2.3 <2.0.0", "1.2", "bare version below upper bound"),
    ("1.2.3 <1.0.0", "2.7", "bare version past upper bound"),
    (">=1.0.0 1.2.3", "1.2", "bare version above lower bound"),
    (">=2.0.0 >=1.0.0", "2.0", "tightest min is not the first term"),
    ("<4.0.0 >=2.12.0", "2.12", "tightest min past the upper bound"),
    (">=1.0.0 >1.0.0", "1.0", "exclusive min wins the tie"),
    (">1.0.0 >=1.0.0", "1.0", "exclusive min wins the tie, other order"),
    ("<=2.0.0", "2.7", "inclusive upper only"),
    ("  any  ", "2.7", "any with blanks"),
    # Pre-releases and builds order the way pub_semver orders versions.
    (">2.0.0-1 <2.0.0-1", "2.7", "empty pre-release range"),
    (">=2.0.0-1 <=2.0.0-1", "2.0", "inclusive pre-release single version"),
    (">=2.0.0-0 <2.0.0-0", "2.7", "empty first-pre-release range"),
    (">2.0.0 <2.0.0-0", "2.7", "empty range past pre-release max"),
    (">=2.0.0-1 <2.0.0", "2.0", "pre-release min below release"),
    (">2.0.0-alpha <2.0.0-beta", "2.0", "string pre-release order"),
    (">=1.0.0-2 <1.0.0-10", "1.0", "numeric pre-release order"),
    (">=1.0.0-1 <1.0.0-a", "1.0", "numeric pre-release before string"),
    (">=1.0.0-a <1.0.0-1", "2.7", "string pre-release past numeric max"),
    (">=1.0.0-a.b <1.0.0-a", "2.7", "longer pre-release past its prefix max"),
    (">=1.0.0+2 <=1.0.0+1", "2.7", "empty build range"),
    ("1.0.0+2 1.0.0+1", "2.7", "empty disjoint builds"),
    (">1.0.0+1 <2.0.0", "1.0", "build min"),
    # Leading zeroes read but derive canonical ints, as pub parses them.
    ("02.12.0", "2.12", "bare version with leading zeroes"),
    ("^02.12.0", "2.12", "caret with leading zeroes"),
    (">=02.12.0 <4.0.0", "2.12", "range with leading zeroes"),
]

def _table_driven_test_impl(ctx):
    env = unittest.begin(ctx)
    for case in _CASES:
        constraint, expected, label = case
        actual = derive_language_version(constraint)
        asserts.equals(env, expected, actual, "case: " + label)
    return unittest.end(env)

_table_driven_test = unittest.make(_table_driven_test_impl)

def language_version_test_suite(name):
    small_unittest_suite(name, _table_driven_test)
