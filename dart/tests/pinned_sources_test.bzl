"""Unit tests for the single pinned-source validation entry point.

Every ref spelling a fetcher could be handed gets a case: only a full
40-lowercase-hex commit SHA validates as git, and only a non-blank
64-lowercase-hex checksum validates as hosted. Branches, tags, `HEAD`,
short SHAs, revision suffixes and uppercase spellings must all fail closed,
because the merged-cycle rule passes its members' coordinates straight to
git.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/pub:pinned_sources.bzl", "pinned_source_error")
load(":small_suite.bzl", "small_unittest_suite")

_SHA = "08a084d50090f0e6ca907fc627ae335c6ac4fd88"
_HOSTED_SHA = "ee67cb0715911d28db6bf4af1026078bd6f0128b07a5f66fb2ed94ef6783c09a"

def _git_valid_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        None,
        pinned_source_error("git", "mpkg", "1.0.0", resolved_ref = _SHA),
    )
    asserts.equals(
        env,
        None,
        pinned_source_error(
            "git",
            "mpkg",
            "1.0.0",
            resolved_ref = "  " + _SHA + "  ",
        ),
    )
    return unittest.end(env)

def _git_branch_tag_head_test_impl(ctx):
    env = unittest.begin(ctx)
    for ref in ["main", "v1.2.3", "HEAD", "origin/main", "refs/heads/main"]:
        asserts.equals(
            env,
            'pub_lock_scc_package "mpkg" (1.0.0) requires a full 40-hex resolved-ref, got %r.' % ref,
            pinned_source_error(
                "git",
                "mpkg",
                "1.0.0",
                resolved_ref = ref,
                rule = "pub_lock_scc_package",
            ),
        )
    return unittest.end(env)

def _git_short_and_suffix_test_impl(ctx):
    env = unittest.begin(ctx)
    for ref in [
        "deadbeef",
        _SHA[:7],
        _SHA[:39],
        _SHA + "0",
        _SHA + "^{commit}",
        _SHA.upper(),
        "g" + _SHA[1:],
    ]:
        asserts.true(
            env,
            pinned_source_error("git", "mpkg", "1.0.0", resolved_ref = ref) != None,
            "ref %r must fail validation" % ref,
        )
    return unittest.end(env)

def _git_missing_test_impl(ctx):
    env = unittest.begin(ctx)
    for ref in ["", "   ", None]:
        asserts.true(
            env,
            pinned_source_error("git", "mpkg", "1.0.0", resolved_ref = ref) != None,
            "missing ref %r must fail validation" % (ref,),
        )
    asserts.equals(
        env,
        'pub_lock_git_package "mpkg" (1.0.0) requires a full 40-hex resolved-ref, got %r.' % ("main",),
        pinned_source_error(
            "git",
            "mpkg",
            "1.0.0",
            resolved_ref = "main",
            rule = "pub_lock_git_package",
        ),
    )
    return unittest.end(env)

def _hosted_valid_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        None,
        pinned_source_error("hosted", "collection", "1.18.0", sha256 = _HOSTED_SHA),
    )
    asserts.equals(
        env,
        None,
        pinned_source_error(
            "hosted",
            "collection",
            "1.18.0",
            sha256 = "  " + _HOSTED_SHA + "  ",
        ),
    )
    return unittest.end(env)

def _hosted_unpinned_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        'pub_lock_scc_package "collection" (1.18.0) requires a non-empty sha256.',
        pinned_source_error(
            "hosted",
            "collection",
            "1.18.0",
            sha256 = "",
            rule = "pub_lock_scc_package",
        ),
    )
    asserts.equals(
        env,
        'pub_lock_scc_package "collection" (1.18.0) requires a non-empty sha256.',
        pinned_source_error(
            "hosted",
            "collection",
            "1.18.0",
            sha256 = "   ",
            rule = "pub_lock_scc_package",
        ),
    )
    asserts.equals(
        env,
        'pub_lock_scc_package "collection" (1.18.0) has invalid sha256 "abc123": expected 64 lowercase hex digits.',
        pinned_source_error(
            "hosted",
            "collection",
            "1.18.0",
            sha256 = "abc123",
            rule = "pub_lock_scc_package",
        ),
    )
    return unittest.end(env)

def _unknown_source_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(
        env,
        pinned_source_error("sdk", "flutter", "0.0.0") != None,
    )
    return unittest.end(env)

_t0_test = unittest.make(_git_valid_test_impl)
_t1_test = unittest.make(_git_branch_tag_head_test_impl)
_t2_test = unittest.make(_git_short_and_suffix_test_impl)
_t3_test = unittest.make(_git_missing_test_impl)
_t4_test = unittest.make(_hosted_valid_test_impl)
_t5_test = unittest.make(_hosted_unpinned_test_impl)
_t6_test = unittest.make(_unknown_source_test_impl)

def pinned_sources_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
    )
